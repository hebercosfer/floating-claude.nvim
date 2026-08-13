-- Reading Claude's state back out of the terminal buffer.
--
-- Claude Code renders a TUI, so there is no API to ask "what is it doing?" --
-- everything here is scraped from the rendered lines: where the input prompt
-- starts, whether a status/spinner line is live, and what the latest message
-- says.

local config = require("floating-claude.config")
local state = require("floating-claude.state")

local M = {}

-- Top-left corner glyphs of Claude Code's input prompt box.
local BOX_TOPS = { "╭", "┌" }

local function is_box_top(line)
  local s = line:gsub("^%s+", "")
  for _, c in ipairs(BOX_TOPS) do
    if s:sub(1, #c) == c then
      return true
    end
  end
  return false
end

-- Claude's current input prompt is framed by two full-width horizontal rules
-- (────) rather than a corner box. A rule is a line made entirely of one
-- repeated rule glyph (allowing surrounding whitespace).
local RULE_CHARS = { "─", "━", "═", "—", "-", "_" }

local function is_rule(line)
  local s = line:gsub("%s+", "")
  if s == "" then
    return false
  end
  for _, c in ipairs(RULE_CHARS) do
    if s:gsub(c, "") == "" and #s >= #c * 8 then
      return true
    end
  end
  return false
end

-- Claude's live status/spinner line sits directly above the input box while a
-- task runs, e.g. "✶ Baked for 17s … (esc to interrupt)". When it is the line
-- we anchor on, we also pull in the message paragraph above it; when Claude is
-- idle there is no such line, so we show only the last message paragraph.
local SPINNER_GLYPHS = {
  "·",
  "✢",
  "✳",
  "✶",
  "✷",
  "✸",
  "✺",
  "✻",
  "✼",
  "✽",
  "✦",
  "✴",
  "∗",
  "*",
  "◐",
  "◑",
  "◒",
  "◓",
}

local function is_status_line(line)
  if line == nil then
    return false
  end
  local s = line:gsub("^%s+", "")
  if s:find("esc to interrupt", 1, true) then
    return true
  end
  -- Otherwise a live status line pairs a running timer ("17s", "2m 7s") with a
  -- spinner glyph, or the characteristic ellipsis / mid-dot / token counter --
  -- the spinner glyph itself cycles and is not reliably enumerable.
  if not s:find("%f[%d]%d+s%f[%W]") then
    return false
  end
  for _, g in ipairs(SPINNER_GLYPHS) do
    if s:sub(1, #g) == g then
      return true
    end
  end
  return s:find("…", 1, true) ~= nil
    or s:find("·", 1, true) ~= nil
    or s:lower():find("tokens", 1, true) ~= nil
end

-- claudecode.nvim shows an edit approval as a native diff (not a terminal
-- prompt): the proposed side is a scratch buffer (buftype=acwrite) named like
-- "✻ [Claude Code] <file> (<hash>) ⧉ (proposed)" or "… (NEW FILE - proposed)"
-- (claudecode/diff.lua, confirmed via a live capture). The "(New)" names are an
-- older fallback path.
local function is_diff_name(name)
  return name:find("[Claude Code]", 1, true) ~= nil
    or name:find("proposed)", 1, true) ~= nil
    or name:match("%(New%)$") ~= nil
    or name:match("%(NEW FILE%)$") ~= nil
end

-- Two questions about a diff, and they are not the same question.
--
-- Upstream tears a diff down in one place, _cleanup_diff_state, which it runs
-- only when the CLI sends close_tab. Nothing else deletes the proposed buffer:
-- it is scratch with bufhidden="hide", so closing its window merely hides a
-- still-loaded buffer. A denied diff is where the two come apart, because
-- deny_current_diff deliberately leaves the tab open ("Do not close
-- windows/tabs here; just mark as rejected") and the user is then the one who
-- closes it -- which hides the buffer without deleting it. Confirmed against
-- claudecode.nvim @ 2390c6e.

--- Does a proposed-changes buffer exist at all -- displayed or hidden?
--- The narrow question, for the moment during upstream's own cleanup when the
--- diff has left the screen but its buffer is still loaded. See provider.lua.
function M.diff_pending()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and is_diff_name(vim.api.nvim_buf_get_name(b)) then
      return true
    end
  end
  return false
end

--- Is a diff actually on screen, in some window, in any tabpage?
--- The question that matters for staying out of the way: our float is
--- editor-relative and covers a diff it is drawn over, while a hidden leftover
--- covers nothing and must not keep Claude in the corner forever.
function M.diff_visible()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(w)
    if is_diff_name(vim.api.nvim_buf_get_name(buf)) then
      return true
    end
  end
  return false
end

-- Row of the input box's TOP edge; everything above it is the conversation.
-- The prompt is framed by two full-width rules (────) with the input between,
-- or (older UI) a ╭rounded╮ box. Returns #lines+1 when no box is rendered yet.
local function input_boundary(lines)
  local bottom_rule
  for i = #lines, 1, -1 do
    if is_rule(lines[i]) then
      bottom_rule = i
      break
    end
  end
  if bottom_rule then
    for i = bottom_rule - 1, math.max(1, bottom_rule - 6), -1 do
      if is_rule(lines[i]) then
        return i
      end
    end
    return bottom_rule
  end
  for i = #lines, 1, -1 do
    if is_box_top(lines[i]) then
      return i
    end
  end
  return #lines + 1
end

-- The current task status: the trailing block of conversation output that sits
-- ABOVE the input prompt box -- the spinner/status line ("✶ Baked for 17s")
-- plus the message paragraph before it. Falls back to a plain tail if no box
-- has been rendered yet.
function M.status_lines()
  if not state.buf_valid() then
    return { "(Claude Code is not running)" }
  end

  local opts = config.options.notification
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local function blank(i)
    return lines[i] == nil or lines[i]:gsub("%s+$", "") == ""
  end

  -- The input box bounds the bottom; everything above it is the conversation.
  local boundary = input_boundary(lines)

  -- The live status/spinner line (the current task) sits just above the box,
  -- though a "Tip:"/blank footer line may sit between them. Look for it in a
  -- small window; otherwise fall back to the last message line (idle).
  local last
  for i = boundary - 1, math.max(1, boundary - 6), -1 do
    if is_rule(lines[i]) or is_box_top(lines[i]) then
      break
    end
    if is_status_line(lines[i]) then
      last = i
      break
    end
  end
  if not last then
    for i = boundary - 1, 1, -1 do
      if not blank(i) then
        last = i
        break
      end
    end
  end
  if not last then
    return { "(no output yet)" }
  end

  -- When anchored on the live status line, reach across up to `gaps` blank
  -- separators to also grab the message paragraph above it. When idle
  -- (anchored on a message), stop at the first blank so we show only the last
  -- paragraph and never spill into the previous turn.
  local max_gaps = is_status_line(lines[last]) and opts.gaps or 0
  local first, gaps = last, 0
  for i = last - 1, 1, -1 do
    if is_rule(lines[i]) or is_box_top(lines[i]) or (last - i + 1) > opts.max_lines then
      break
    end
    if blank(i) then
      gaps = gaps + 1
      if gaps > max_gaps then
        break
      end
    end
    first = i
  end

  local out = {}
  for i = first, last do
    table.insert(out, (lines[i]:gsub("%s+$", "")))
  end
  while out[1] == "" do
    table.remove(out, 1)
  end
  while out[#out] == "" do
    table.remove(out)
  end
  if #out == 0 then
    out = { "(no output yet)" }
  end
  return out
end

-- Claude is actively processing when its live status/spinner line is present
-- just above the input box. Absence => idle / waiting for the user's input.
function M.is_working()
  if not state.buf_valid() then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local boundary = input_boundary(lines)
  for i = boundary - 1, math.max(1, boundary - 6), -1 do
    if is_rule(lines[i]) or is_box_top(lines[i]) then
      break
    end
    if is_status_line(lines[i]) then
      return true
    end
  end
  return false
end

return M
