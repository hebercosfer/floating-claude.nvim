-- The corner notification: a small, unfocusable window that tails Claude's
-- latest output while the big float is hidden.

local config = require("floating-claude.config")
local highlights = require("floating-claude.highlights")
local parser = require("floating-claude.parser")
local state = require("floating-claude.state")

---@type uv
local uv = vim.uv

local M = {}

-- Where the notification's own highlights live, so a redraw can clear exactly
-- what the last one painted.
local ns = vim.api.nvim_create_namespace("floating-claude.notification")

-- What marks a row whose content was cut short.
local MORE = "…"

local function stop_timer()
  if state.mini_timer then
    state.mini_timer:stop()
    if not state.mini_timer:is_closing() then
      state.mini_timer:close()
    end
    state.mini_timer = nil
  end
end

local group = vim.api.nvim_create_augroup("FloatingClaudeFocus", { clear = false })

-- Entering the notification is a request for Claude, however you got there: a
-- click, or a window command. An unfocusable window cannot be clicked at all,
-- so restore_on_enter is what makes it focusable in the first place -- see the
-- window config below.
local function attach_enter(buf)
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  if not config.options.auto.restore_on_enter then
    return
  end
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    buffer = buf,
    desc = "Restore the Claude float when its notification is entered",
    callback = function()
      if state.suppress_auto then
        return
      end
      -- Required lazily: terminal.lua requires this module, so taking it at the
      -- top would close the loop.
      require("floating-claude.terminal").restore()
    end,
  })
end

function M.hide()
  stop_timer()
  if state.mini_win_valid() then
    vim.api.nvim_win_close(state.mini_win, true)
  end
  state.mini_win = -1
end

-- Truncate to `cells` display columns.
local function cut(text, cells)
  if cells <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= cells then
    return text
  end
  local chars = vim.fn.strchars(text)
  while chars > 0 do
    local shorter = vim.fn.strcharpart(text, 0, chars)
    if vim.fn.strdisplaywidth(shorter) <= cells then
      return shorter
    end
    chars = chars - 1
  end
  return ""
end

-- Truncate to `cells`, marking the cut.
local function fit(text, cells)
  if vim.fn.strdisplaywidth(text) <= cells then
    return text
  end
  return cut(text, cells - 1) .. "…"
end

-- The timer and the token counter, in that order, skipping whichever the live
-- line did not carry. Built by hand: a table constructor with a nil in it is a
-- table with a hole, which table.concat refuses to walk.
local function detail_of(status)
  local parts = {}
  if status.elapsed then
    table.insert(parts, status.elapsed)
  end
  if status.tokens then
    table.insert(parts, status.tokens)
  end
  return parts
end

-- The title carries Claude's state, which leaves the body free for what Claude
-- is actually saying: `✽ Infusing… 8m 24s ↓24.8k` while it works,
-- `✓ Cooked for 1m 40s` for the turn it just finished, the plain label when it
-- is waiting on you. The timer and the token counter are the first things
-- dropped when the title will not fit -- the verb is what you read at a glance.
local function title_for(status, width)
  local opts = config.options.notification
  if not opts.status_in_title then
    return { { opts.title } }
  end

  local head, group, tail
  if status.working then
    head = (status.glyph or "✻") .. " " .. (status.verb or "Working")
    group, tail = "FloatingClaudeStatus", detail_of(status)
  elseif status.done then
    head, group, tail = "✓ " .. status.done, "FloatingClaudeDone", {}
  else
    return { { opts.title } }
  end

  local room = width - 2
  while #tail > 0 do
    local detail = table.concat(tail, " ")
    if vim.fn.strdisplaywidth(head .. " " .. detail) + 2 <= room then
      return {
        { " " },
        { head, group },
        { " " .. detail, "FloatingClaudeDetail" },
        { " " },
      }
    end
    table.remove(tail)
  end
  return { { " " }, { fit(head, room - 2), group }, { " " } }
end

-- Claude's own status line, rebuilt for the body when the title is not carrying
-- it (status_in_title = false).
local function status_line(status)
  if status.working then
    local detail = table.concat(detail_of(status), " · ")
    return (status.glyph or "✻")
      .. " "
      .. (status.verb or "Working")
      .. (detail ~= "" and (" (" .. detail .. ")") or "")
  end
  return status.done and ("✓ " .. status.done) or nil
end

-- Wrap one logical line to `width` columns. parser.status_lines() hands over
-- Claude's prose with the TUI's own hard wrap undone, so this is the wrap that
-- decides how the notification reads: break between words, and only inside one
-- when a single token (a path, a URL) is wider than the window on its own.
local function wrap(text, width)
  width = math.max(1, width)
  local rows, current = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      current = candidate
    else
      if current ~= "" then
        table.insert(rows, current)
        current = ""
      end
      while vim.fn.strdisplaywidth(word) > width do
        -- A character wider than the whole window still has to go somewhere, or
        -- cut() keeps handing back nothing and the word never gets shorter.
        local head = cut(word, width)
        if head == "" then
          head = vim.fn.strcharpart(word, 0, 1)
          if head == "" then
            break
          end
        end
        table.insert(rows, head)
        word = word:sub(#head + 1)
      end
      current = word
    end
  end
  table.insert(rows, current)
  return rows
end

-- The block as rows on screen: wrapped, indented off the border, and cut to
-- `max_height` with the last row marked when there is more than fits. Each row
-- carries what paint() needs -- the kind of line it came from, and how many
-- bytes of leading marker it starts with, which only the first row of a wrapped
-- line has.
local function lay_out(content, width, max_height)
  local rows = {}
  for _, line in ipairs(content) do
    if line == "" then
      table.insert(rows, { text = "", kind = "prose", marker = 0 })
    else
      local kind = parser.line_kind(line)
      local glyph = kind ~= "prose" and line:match("^%S+") or nil
      for i, text in ipairs(wrap(line, width)) do
        table.insert(rows, {
          text = text,
          kind = kind,
          marker = (i == 1 and glyph) and #glyph or 0,
        })
      end
    end
  end

  local clipped = #rows > max_height
  while #rows > max_height do
    table.remove(rows)
  end
  if clipped and #rows > 0 then
    local last = rows[#rows]
    if vim.fn.strdisplaywidth(last.text) + 2 <= width then
      last.text = last.text .. " " .. MORE
    else
      last.text = cut(last.text, width - 1) .. MORE
    end
    last.more = true
  end

  -- A row ending in the marker reads as "there is more" however it got there --
  -- cut here, or cut upstream by the sentence it came from. Not on a tool call
  -- though: the ellipsis in "Running 3 shell commands · 3s…" is Claude's own,
  -- and it means still running rather than cut short.
  local last_row = rows[#rows]
  if last_row and last_row.kind ~= "tool" and vim.endswith(last_row.text, MORE) then
    last_row.more = true
  end

  for _, row in ipairs(rows) do
    row.text = " " .. row.text
  end
  return rows
end

-- Colour the pieces Claude colours: its marker glyphs, and the echo of your own
-- prompt as a whole, since that one is not Claude talking at all.
local function paint(buf, rows)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, row in ipairs(rows) do
    if row.kind == "echo" and #row.text > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_col = #row.text,
        hl_group = "FloatingClaudePrompt",
      })
    elseif row.marker > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 1, {
        end_col = 1 + row.marker,
        hl_group = row.kind == "tool" and "FloatingClaudeTool" or "FloatingClaudeBullet",
      })
    end
    if row.more then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, #row.text - #MORE, {
        end_col = #row.text,
        hl_group = "FloatingClaudeMore",
      })
    end
  end
end

-- Render (creating or resizing) the corner notification.
local function render()
  local opts = config.options.notification
  highlights.ensure()
  local status = parser.status()
  local content = parser.status_lines()
  if not opts.status_in_title then
    local line = status_line(status)
    if line then
      table.insert(content, line)
    end
  end

  -- A column of padding each side keeps the text off the border.
  local width = math.min(opts.width, vim.o.columns - 4)
  local rows = lay_out(content, math.max(1, width - 2), opts.max_height)

  if not state.mini_buf_valid() then
    state.mini_buf = vim.api.nvim_create_buf(false, true)
    attach_enter(state.mini_buf)
  end
  vim.bo[state.mini_buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    state.mini_buf,
    0,
    -1,
    false,
    vim.tbl_map(function(row)
      return row.text
    end, rows)
  )
  vim.bo[state.mini_buf].modifiable = false
  paint(state.mini_buf, rows)

  local height = math.max(1, #rows)

  local col = math.max(1, vim.o.columns - width - 2)
  local row = math.max(1, vim.o.lines - height - 3)

  local cfg = {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = opts.border,
    title = title_for(status, width),
    title_pos = opts.title_pos,
    -- Focusable only when entering it is meant to do something. Neovim routes
    -- mouse clicks to focusable windows only, so this is the difference
    -- between a click landing here and passing straight through.
    focusable = config.options.auto.restore_on_enter,
    zindex = opts.zindex,
  }

  if state.mini_win_valid() then
    vim.api.nvim_win_set_config(state.mini_win, cfg)
  else
    state.mini_win = vim.api.nvim_open_win(state.mini_buf, false, cfg)
    -- lay_out() has already wrapped every row to fit, so this only catches the
    -- odd case it could not -- and breaks it between words when it does.
    vim.wo[state.mini_win].wrap = true
    vim.wo[state.mini_win].linebreak = true
  end

  -- Show the block from its start: lay_out() cut it to fit, and the opening
  -- sentence is the part worth reading.
  pcall(vim.api.nvim_win_set_cursor, state.mini_win, { 1, 0 })
end

function M.show()
  if not state.buf_valid() then
    vim.notify("Claude Code is not running.", vim.log.levels.WARN)
    return false
  end
  local refresh_ms = config.options.notification.refresh_ms
  render()
  stop_timer()
  state.mini_timer = uv.new_timer()
  state.mini_timer:start(
    refresh_ms,
    refresh_ms,
    vim.schedule_wrap(function()
      if not state.mini_win_valid() then
        stop_timer()
        return
      end
      if not state.buf_valid() then
        M.hide()
        return
      end
      render()
    end)
  )
  return true
end

return M
