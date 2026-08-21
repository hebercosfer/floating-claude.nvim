-- The Claude Code session the tour scrapes: scripted, and not Claude at all.
--
-- Everything this plugin knows about Claude it reads out of the buffer's lines
-- (parser.lua), so a convincing stand-in owes it exactly that: lines. This one
-- is a scratch buffer painted to look like the TUI -- a transcript, a live
-- status line, the rules framing the input box -- and driven by a clock instead
-- of a language model, which is what lets the demo run with no CLI, no network
-- and no API key, and what makes a recording of it reproducible.
--
-- The wrap matters more than it looks. Claude hard-wraps its prose at the
-- terminal's width and parser.lua undoes exactly that wrap before the
-- notification re-wraps it at its own; prose arriving pre-broken at some other
-- column is what made the corner read ragged. So the transcript is wrapped here
-- at the float's real width -- the same width as the rules, which is where the
-- parser goes looking for it.

local state = require("floating-claude.state")

---@type uv
local uv = vim.uv

local M = {}

local ns = vim.api.nvim_create_namespace("floating-claude.demo")

-- Claude's spinner: one step every 120ms, forward and back. The notification's
-- title passes the glyph straight through, so this is what makes it move.
local SPINNER = { "·", "✢", "*", "✶", "✻", "✽" }
local SPINNER_MS = 120

-- How often the transcript is repainted, and how fast "you" type.
local FRAME_MS = 100
local TYPE_MS = 42

-- The line under the input box, which Claude fills with shortcuts.
local FOOTER = "? for shortcuts"

M.width, M.height = 80, 24
M.buf = -1
M.blocks = {}
M.work = nil
M.typing = nil
M.timer = nil

--- Layout ---------------------------------------------------------------------

--- Greedy wrap on display width.
local function wrap(text, width)
  local rows, current = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      current = candidate
    else
      if current ~= "" then
        table.insert(rows, current)
      end
      current = word
    end
  end
  if current ~= "" then
    table.insert(rows, current)
  end
  return rows
end

--- One block of transcript, laid out the way the TUI lays one out: the marker
--- on the first line, the rest indented two columns under it, the whole thing
--- hard-wrapped at the terminal's width.
local function block(marker, text)
  local out = {}
  for i, row in ipairs(wrap(text, math.max(8, M.width - 2))) do
    table.insert(out, (i == 1 and marker .. " " or "  ") .. row)
  end
  return out
end

--- Claude Code's own welcome box, which is what the top of the screen holds
--- until a long enough session scrolls it off.
local function welcome()
  local width = math.min(58, math.max(30, M.width - 4))
  local rows = {
    "✻ Welcome to Claude Code",
    "",
    "  /help for help, /status for your account",
    "",
    "  cwd: " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~"),
  }
  local out = { "╭" .. string.rep("─", width) .. "╮" }
  for _, row in ipairs(rows) do
    local text = row
    while vim.fn.strdisplaywidth(text) > width - 2 do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
    local pad = width - 1 - vim.fn.strdisplaywidth(text)
    table.insert(out, "│ " .. text .. string.rep(" ", math.max(0, pad)) .. "│")
  end
  table.insert(out, "╰" .. string.rep("─", width) .. "╯")
  return out
end

--- What Claude is saying -------------------------------------------------------

--- The echo of your own prompt, which is where one turn begins.
function M.prompt(text)
  table.insert(M.blocks, block("❯", text))
end

--- A paragraph of Claude's prose.
function M.say(text)
  table.insert(M.blocks, block("●", text))
end

--- A tool call: the bulleted header naming what is running, and the result
--- indented under a corner glyph. The notification collapses this back to the
--- header, which is the one line worth having in a corner.
function M.tool(header, result)
  local lines = block("●", header)
  table.insert(lines, "  ⎿  " .. result)
  table.insert(M.blocks, lines)
end

--- Start a turn. `verb` is the gerund Claude puts next to its spinner.
function M.working(verb)
  M.work = { verb = verb, at = uv.now() }
end

--- Stop working without ending the turn -- the pause between a tool call
--- finishing and Claude picking the thread back up.
function M.idle()
  M.work = nil
end

--- End the turn the way Claude ends one: the live line freezes into a marker
--- carrying what the turn cost, and a one-line summary lands under it. Both
--- carry a duration, and telling them apart from a running spinner is the whole
--- job of parser.is_status_line() -- so a stand-in that skipped this would be
--- demonstrating an easier problem than the real one.
function M.finish(spent, summary)
  M.work = nil
  table.insert(M.blocks, { "✻ " .. spent })
  if summary then
    table.insert(M.blocks, block("●", summary))
  end
end

--- Type into the input box, a character every TYPE_MS.
function M.type(text)
  M.typing = { text = text, at = uv.now() }
end

--- Whether the text handed to type() has finished arriving.
function M.typed()
  if not M.typing then
    return true
  end
  return (uv.now() - M.typing.at) / TYPE_MS >= vim.fn.strchars(M.typing.text)
end

--- Send what is in the input box: it leaves the box and lands in the transcript
--- as the echo of your prompt.
function M.send()
  local text = M.typing and M.typing.text or ""
  M.typing = nil
  if text ~= "" then
    M.prompt(text)
  end
end

--- The frame -------------------------------------------------------------------

local function elapsed_text(ms)
  local seconds = math.floor(ms / 1000)
  if seconds < 60 then
    return seconds .. "s"
  end
  return ("%dm %02ds"):format(math.floor(seconds / 60), seconds % 60)
end

local function spinner(ms)
  local n = #SPINNER
  local i = math.floor(ms / SPINNER_MS) % (2 * n - 2)
  if i >= n then
    i = 2 * n - 2 - i
  end
  return SPINNER[i + 1]
end

--- The live status line, or nil when nothing is running. Its shape is the one
--- thing here the plugin genuinely depends on: a spinner glyph, a verb, and an
--- elapsed timer inside the parenthesised detail group that trails it.
local function status_line()
  if not M.work then
    return nil
  end
  local ms = uv.now() - M.work.at
  return ("%s %s… (%s · ↓ %.1fk tokens)"):format(
    spinner(ms),
    M.work.verb,
    elapsed_text(ms),
    1.1 + ms / 1000 * 0.42
  )
end

local function input_line()
  local shown = ""
  if M.typing then
    local chars =
      math.min(math.floor((uv.now() - M.typing.at) / TYPE_MS), vim.fn.strchars(M.typing.text))
    shown = vim.fn.strcharpart(M.typing.text, 0, chars)
  end
  return " ❯ " .. shown .. "▏"
end

--- The whole screen, as plain lines -- exactly what parser.lua will read back.
---
--- Everything sits at the bottom, with the blank above it. Claude Code does not
--- take over the alternate screen: it appends, the terminal scrolls, and what
--- you see in a session this young is a screenful of nothing with the welcome
--- box and the input box at the foot of it. Which is also the only free space a
--- float 80% of the editor has to offer the tour's own caption.
function M.frame()
  local lines = welcome()
  for _, b in ipairs(M.blocks) do
    table.insert(lines, "")
    vim.list_extend(lines, b)
  end
  table.insert(lines, "")

  local status = status_line()
  if status then
    table.insert(lines, status)
  end
  local rule = string.rep("─", M.width)
  table.insert(lines, rule)
  table.insert(lines, input_line())
  table.insert(lines, rule)
  table.insert(lines, "  " .. FOOTER)

  -- Pad from the top, and scroll the oldest lines off once the transcript
  -- outgrows the screen -- welcome box first, exactly as it would go.
  while #lines > M.height do
    table.remove(lines, 1)
  end
  while #lines < M.height do
    table.insert(lines, 1, "")
  end
  return lines
end

--- Painting --------------------------------------------------------------------

local function leads_with_spinner(s)
  for _, glyph in ipairs(SPINNER) do
    if s:sub(1, #glyph) == glyph then
      return true
    end
  end
  return false
end

-- Claude's TUI colours its own markers and none of it survives the trip into
-- the notification (see highlights.lua), so the stand-in is coloured the way
-- the notification colours the same pieces: by what the line is, in the
-- plugin's own groups, which means it follows your colourscheme too.
local function paint(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(lines) do
    local function mark(col, end_col, group)
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, col, { end_col = end_col, hl_group = group })
    end

    local body = line:gsub("^%s+", "")
    local indent = #line - #body
    if body == "" then
      -- nothing to paint
    elseif body:gsub("─", "") == "" then
      mark(0, #line, "NonText")
    elseif body == FOOTER then
      mark(0, #line, "Comment")
    elseif body:sub(1, #"❯") == "❯" and indent > 0 then
      -- The input box: the prompt glyph, then what you have typed, then a caret.
      mark(indent, indent + #"❯", "FloatingClaudeWaiting")
      mark(#line - #"▏", #line, "NonText")
    elseif body:sub(1, #"❯") == "❯" then
      mark(0, #line, "FloatingClaudePrompt")
    elseif body:sub(1, #"●") == "●" then
      mark(indent, indent + #"●", "FloatingClaudeBullet")
    elseif body:sub(1, #"⎿") == "⎿" then
      mark(0, #line, "FloatingClaudeTool")
    elseif leads_with_spinner(body) then
      local detail = line:find("(", 1, true)
      if detail then
        mark(0, detail - 1, "FloatingClaudeStatus")
        mark(detail - 1, #line, "FloatingClaudeDetail")
      else
        mark(0, #line, "FloatingClaudeDone")
      end
    end
  end
end

--- Rendering -------------------------------------------------------------------

function M.render()
  if M.buf == -1 or not vim.api.nvim_buf_is_valid(M.buf) then
    return
  end
  local lines = M.frame()
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.bo[M.buf].modifiable = false
  paint(M.buf, lines)

  if state.win_valid() and vim.api.nvim_win_get_buf(state.win) == M.buf then
    -- Every line is already wrapped to the window's width; soft-wrapping one
    -- of them on top of that would shift the input box off the bottom.
    vim.wo[state.win].wrap = false
    pcall(vim.api.nvim_win_set_cursor, state.win, { #lines, 0 })
  end
end

local function stop_timer()
  if M.timer then
    M.timer:stop()
    if not M.timer:is_closing() then
      M.timer:close()
    end
    M.timer = nil
  end
end

--- Take over `buf` as the stand-in's screen and start repainting it.
function M.open(buf, width, height)
  M.buf, M.width, M.height = buf, width, height
  M.blocks, M.work, M.typing = {}, nil, nil
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "floating-claude-demo"
  M.render()
  stop_timer()
  M.timer = uv.new_timer()
  M.timer:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(M.render))
end

function M.close()
  stop_timer()
  if M.buf ~= -1 and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.buf = -1
  M.blocks, M.work, M.typing = {}, nil, nil
end

return M
