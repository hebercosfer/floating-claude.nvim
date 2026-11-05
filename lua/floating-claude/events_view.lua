-- The events view (`:FloatingClaudeEvents`, <leader>ae): the latest events
-- the listener heard from Claude, as Claude sent them.
--
-- For transparency. Claude's hooks carry your prompts, its replies, tool
-- inputs and tool output; the plugin cannot ask for less and does not hide any
-- of it. What it can do is keep little, keep it in memory only, and show
-- exactly that here -- so you can see for yourself what it hears, and that a
-- secret that passed through was at least in plain view. Long values are cut
-- where they are stored, and the cut says how much more arrived. The session's
-- token is never shown.

local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")

local M = {}

local NAME = "floating-claude://events"
local TITLE = "Floating Claude — what the plugin heard from Claude Code"

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- A JSON string literal, but with `/` and non-ASCII left alone: a path reads
-- as a path.
local function quote(s)
  return '"'
    .. s:gsub('[%c"\\]', function(c)
      return ESCAPES[c] or ("\\u%04x"):format(c:byte())
    end)
    .. '"'
end

local function scalar(v)
  if type(v) == "string" then
    return quote(v)
  elseif v == nil or v == vim.NIL then
    return "null"
  end
  return tostring(v)
end

local function emit(out, value, pad, prefix, comma, indent)
  if type(value) ~= "table" then
    table.insert(out, pad .. prefix .. scalar(value) .. comma)
    return
  end
  local list = vim.islist(value)
  local keys = {}
  if list then
    for i = 1, #value do
      keys[i] = i
    end
  else
    for k in pairs(value) do
      table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
  end
  if #keys == 0 then
    table.insert(out, pad .. prefix .. (list and "[]" or "{}") .. comma)
    return
  end
  table.insert(out, pad .. prefix .. (list and "[" or "{"))
  for i, k in ipairs(keys) do
    local key = list and "" or (quote(tostring(k)) .. ": ")
    emit(out, value[k], pad .. indent, key, i < #keys and "," or "", indent)
  end
  table.insert(out, pad .. (list and "]" or "}") .. comma)
end

--- JSON-shaped lines with sorted keys, so the same event always reads the same.
---@param value any
---@param indent string
---@return string[]
function M.pretty(value, indent)
  local out = {}
  emit(out, value, "", "", "", indent or "  ")
  return out
end

local function clock(at)
  return os.date("%H:%M:%S", math.floor(at / 1000)) .. "." .. ("%03d"):format(at % 1000)
end

--- The view's text.
---@param info { running: boolean, active: boolean, reason: string|nil, port: integer|nil, settings_path: string|nil, events: string[], keep: integer }
---@param log floating_claude.Log|nil
---@return string[]
function M.lines(info, log)
  local out = { TITLE, "" }
  if not info.running then
    table.insert(out, "Claude Code is not running.")
    return out
  end
  if not info.port and not info.active then
    table.insert(
      out,
      ("Not listening: %s. The plugin reads Claude's screen instead."):format(
        info.reason or "no reason given"
      )
    )
    return out
  end

  if not info.port then
    -- The tour: its stand-in posts what a real Claude Code would, and the
    -- session keeps it the way the listener would.
    table.insert(
      out,
      "Hearing the tour's scripted events: what Claude Code would post to the listener, kept the same way. No listener is running, and no settings file is written."
    )
  elseif info.active then
    table.insert(
      out,
      ("Listening on 127.0.0.1:%d for: %s"):format(info.port, table.concat(info.events, ", "))
    )
  else
    -- Fallen back to the screen mid-session. Claude was started pointing at
    -- the listener, so it stays up and keeps hearing whatever does arrive.
    table.insert(
      out,
      ("Reading Claude's screen: %s. The listener on 127.0.0.1:%d is still up, since Claude was started pointing at it; what it hears is below."):format(
        info.reason or "no reason given",
        info.port
      )
    )
  end
  if info.port then
    table.insert(
      out,
      ("Settings file: %s (it holds this session's token; the token is not shown here)"):format(
        info.settings_path or "?"
      )
    )
  end
  if info.keep > 0 then
    table.insert(
      out,
      ("Kept in memory only: the last %d events, long values cut. Nothing else is written to disk, nothing leaves this machine, and it is all cleared when Claude exits."):format(
        info.keep
      )
    )
  else
    table.insert(out, "Kept in memory only: nothing (keep = 0); only the counts below.")
  end
  log = log or { received = 0, rejected = 0, entries = {} }
  table.insert(out, ("Received %d, rejected %d."):format(log.received or 0, log.rejected or 0))

  for _, entry in ipairs(log.entries or {}) do
    table.insert(out, "")
    if entry.fate == "rejected" then
      table.insert(
        out,
        ("%s  rejected  wrong or missing token  %d bytes"):format(clock(entry.at), entry.size or 0)
      )
    else
      table.insert(
        out,
        ("%s  %s  %s  %d bytes"):format(
          clock(entry.at),
          entry.event or "?",
          entry.fate,
          entry.size or 0
        )
      )
      if entry.payload then
        vim.list_extend(out, M.pretty(entry.payload, "  "))
      end
    end
  end
  return out
end

-- A split cannot come off a floating window -- the Claude float, say -- so step
-- to an ordinary window of this tab first.
local function leave_float()
  if vim.api.nvim_win_get_config(0).relative == "" then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
end

-- In a split at the bottom of this tab, not a tab of its own: the corner is a
-- float, floats belong to the tab they were opened in, and a new tab left it
-- behind. A view already open in this tab is refreshed in place.
local function show(lines)
  local buf, win = vim.fn.bufnr(NAME), nil
  if buf ~= -1 then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(w) == buf then
        win = w
        break
      end
    end
    if not win then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  if win then
    vim.api.nvim_set_current_win(win)
  else
    leave_float()
    vim.cmd(("botright %dsplit"):format(math.max(8, math.floor(vim.o.lines * 0.4))))
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, NAME)
    vim.bo[buf].filetype = "floating-claude-events"
    vim.keymap.set("n", "q", function()
      -- :close refuses the last window (E444); wipe the buffer there instead.
      if not pcall(vim.cmd.close) then
        vim.cmd.bwipeout()
      end
    end, { buffer = buf, nowait = true, desc = "Close the events view" })
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })
end

--- Open the view, as of now.
function M.open()
  local info = vim.tbl_extend("force", session.info(), { running = state.buf_valid() })
  session.log(function(log)
    show(M.lines(info, log))
  end)
end

return M
