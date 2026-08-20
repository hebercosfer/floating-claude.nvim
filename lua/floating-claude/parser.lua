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
-- task runs. When it is the line we anchor on, we also pull in the message
-- paragraph above it; when Claude is idle there is no such line, so we show
-- only the last message paragraph.
--
-- Two shapes have been observed:
--
--   ✽ Infusing… (8m 24s · ↓ 24.8k tokens)     -- what the tested CLI renders
--   ✶ Baked for 17s … (esc to interrupt)      -- the older wording
--
-- The glyph itself cycles and is not reliably enumerable, so it only ever says
-- "this line might be the spinner"; what makes the line *live* is the detail
-- group after the verb.
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

local function leads_with_spinner(s)
  for _, g in ipairs(SPINNER_GLYPHS) do
    if s:sub(1, #g) == g then
      return true
    end
  end
  return false
end

-- A duration on its own says nothing: when the turn ends, the spinner line
-- freezes into a marker and a summary lands under it, and both carry one.
--
--   ✻ Cooked for 1m 40s
--   ● Ran the suite; two specs still red · 44s
--
-- Those are how a turn FINISHES, so reading either as "working" pins the float
-- in the corner forever -- `busy` never goes false, the idle clock never
-- starts, and the float never comes back after a diff. What separates them from
-- the live line is where the timer sits: running, it is inside the detail group
-- that trails the verb ("(8m 24s ·", "(3s)"); finished, it is bare.
local function is_status_line(line)
  if line == nil then
    return false
  end
  local s = line:gsub("^%s+", "")
  -- The interrupt hint is unambiguous wherever it appears on the line.
  if s:find("esc to interrupt", 1, true) then
    return true
  end
  return leads_with_spinner(s) and s:find("%(%s*%d+[hms]") ~= nil
end

-- How a turn ENDS. The spinner line freezes into a marker -- past tense, timer
-- bare rather than inside a detail group -- and that marker is the only place
-- the finished turn's cost is stated:
--
--   ✻ Cooked for 1m 40s
--
-- is_status_line() must keep reading this as idle (see the note above it); the
-- notification uses it as its caption while Claude waits.
local function done_marker(line)
  if line == nil then
    return nil
  end
  local s = line:gsub("^%s+", ""):gsub("%s+$", "")
  if not leads_with_spinner(s) or s:find("(", 1, true) then
    return nil
  end
  local rest = s:gsub("^%S+%s*", "")
  return rest:match("^%a+ for %d+[hms]") and rest or nil
end

-- Furniture: lines about the UI rather than the conversation.
local function is_tip(line)
  return line:find("Tip:", 1, true) ~= nil
end

-- The user's own prompt, echoed back into the transcript. Its continuation
-- lines are indented exactly like Claude's prose, so an echo is only ever
-- recognisable from the first line of its block.
local PROMPT_GLYPH = "❯"

local function is_prompt_echo(line)
  return line:gsub("^%s+", ""):sub(1, #PROMPT_GLYPH) == PROMPT_GLYPH
end

-- A tool call renders as a header line plus the result, indented under a corner
-- glyph:
--
--   Dumping the live Claude terminal buffer via RPC
--   ⎿  $ cat > /tmp/…/dump.lua <<'LUA'
--      local out = {}
--
-- The result is laid out for the float's width, so re-wrapping it into a 64
-- column notification is what shredded it into ragged, table-looking columns.
-- Collapse the block to its header instead: what Claude is doing, in one line.
local TOOL_RESULT = "⎿"

local function is_tool_result(line)
  return line:gsub("^%s+", ""):sub(1, #TOOL_RESULT) == TOOL_RESULT
end

-- The bullet Claude puts in front of a message or a tool call.
local MESSAGE_BULLETS = { "●", "•", "○", "◦" }

-- Claude's own bullets and list markers, which start a line of their own rather
-- than continuing the one above.
local BULLETS = { "●", "•", "○", "◦", "-", "*", "+", ">", "|" }

local function strip_bullet(text)
  for _, bullet in ipairs(MESSAGE_BULLETS) do
    if text:sub(1, #bullet) == bullet then
      return (text:sub(#bullet + 1):gsub("^%s+", ""))
    end
  end
  return text
end

local function starts_item(body)
  for _, b in ipairs(BULLETS) do
    if body:sub(1, #b) == b and (body:sub(#b + 1, #b + 1) == " " or b == "|") then
      return true
    end
  end
  return body:match("^%d+[%.%)]%s") ~= nil
end

-- Non-breaking spaces come through the TUI in status bars and tips; they are
-- spaces everywhere we care, and converting them keeps trimming honest.
local function clean(line)
  return (line:gsub("\194\160", " "):gsub("%s+$", ""))
end

-- The column Claude wraps its prose at. The rules framing the input box are
-- drawn to the full terminal width, which is exactly that number; failing
-- those, the widest line in the buffer is the best guess available.
local function wrap_column(lines)
  local width = 0
  for _, line in ipairs(lines) do
    if is_rule(line) then
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
  end
  if width == 0 then
    for _, line in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(clean(line)))
    end
  end
  return width > 0 and width or 80
end

-- Undo the TUI's hard wrap: a line that runs to (or near) the wrap column is
-- continued by the line below, so the two are one sentence that we re-wrap at
-- the notification's own width. The slack absorbs the long word that got pushed
-- down -- a path or a URL leaves a short line behind it.
local function unwrap(lines, first, last, column)
  local slack = math.max(12, math.floor(column * 0.12))
  local out, previous = {}, 0
  for i = first, last do
    local text = clean(lines[i])
    local body = text:gsub("^%s+", "")
    if #out > 0 and previous >= column - slack and not starts_item(body) then
      out[#out] = out[#out] .. " " .. body
    else
      table.insert(out, body)
    end
    previous = vim.fn.strdisplaywidth(text)
  end
  return out
end

-- One blank-separated block of the transcript, as the notification wants it:
-- prose unwrapped, a tool call reduced to its header, and the furniture (the
-- live status line, the frozen marker, tips) thrown away. Returns nil for
-- furniture, and otherwise the block, its kind and the lines it consumed --
-- the kind being what tells the caller an echo or a tool call stands alone.
local function render_block(lines, first, last, column, budget)
  if is_status_line(lines[first]) or done_marker(lines[first]) then
    return nil
  end

  -- What you asked is worth showing while Claude has not answered yet -- it is
  -- what Claude is working on -- but never above an answer, where it is just
  -- the seam between two turns.
  if is_prompt_echo(lines[first]) then
    local block = unwrap(lines, first, math.min(last, first + budget - 1), column)
    -- An empty prompt is not something you asked; it is the cursor sitting
    -- there. Skip it, so the body falls through to what Claude last said.
    local typed = block[1]:sub(#PROMPT_GLYPH + 1):gsub("^%s+", ""):gsub("%s+$", "")
    if #block == 1 and typed == "" then
      return nil
    end
    return block, "echo", last - first + 1
  end

  local result
  for i = first, last do
    if is_tool_result(lines[i]) then
      result = i
      break
    end
  end

  if result then
    local header = clean(lines[first]):gsub("^%s+", "")
    if result == first then
      header = header:sub(#TOOL_RESULT + 1):gsub("^%s+", "")
    end
    if is_tip(header) or header == "" then
      return nil
    end
    -- One marker is enough: Claude bullets the header of a tool call it is
    -- running, and "⎿ ● Running 3 shell commands" reads as a stutter.
    return { TOOL_RESULT .. " " .. strip_bullet(header) }, "tool", last - first + 1
  end

  if is_tip(clean(lines[first])) then
    return nil
  end
  local consumed = math.min(last, first + budget - 1)
  return unwrap(lines, first, consumed, column), "prose", consumed - first + 1
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

-- How far above the input box either scan will look. A terminal running a TUI
-- redraws in place, so the buffer holds about a screenful and this never bites;
-- it is here so a buffer that did accumulate scrollback cannot turn the
-- watcher's 300ms poll into a walk over thousands of lines.
local SEARCH_LIMIT = 200

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

-- What the notification shows: the newest block of the transcript worth
-- reading, cleaned up. "Newest" skips the furniture -- the live status line and
-- the frozen end-of-turn marker both belong in the title now -- so what lands
-- here is what Claude last said, the tool it is running, or, before it has
-- answered at all, the prompt you typed. Prose is unwrapped from the float's
-- width so the notification can wrap it at its own; `gaps` blank separators may
-- be crossed to keep the paragraph above it in view, and the echo of your own
-- prompt is the edge no walk crosses.
function M.status_lines()
  if not state.buf_valid() then
    return { "(Claude Code is not running)" }
  end

  local opts = config.options.notification
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local function blank(i)
    return lines[i] == nil or clean(lines[i]) == ""
  end

  local boundary = input_boundary(lines)
  local column = wrap_column(lines)

  local out, gaps, budget = {}, 0, opts.max_lines
  local floor = math.max(1, boundary - SEARCH_LIMIT)
  local i = boundary - 1
  while i >= floor and budget > 0 do
    if is_rule(lines[i]) or is_box_top(lines[i]) then
      break
    elseif blank(i) then
      -- Blanks below the first block found are just the gap above the prompt.
      if #out > 0 then
        gaps = gaps + 1
        if gaps > opts.gaps then
          break
        end
      end
      i = i - 1
    else
      local first = i
      while
        first > 1
        and not blank(first - 1)
        and not is_rule(lines[first - 1])
        and not is_box_top(lines[first - 1])
      do
        first = first - 1
      end

      local block, kind, consumed = render_block(lines, first, i, column, budget)
      if not block and #out > 0 then
        -- Furniture above prose is the edge of the turn -- the status line it
        -- started with, or the echo of the prompt before it. Stopping here is
        -- what keeps `gaps` from stitching the previous turn onto this one.
        break
      end
      if block then
        -- One phrase of the newest thing on screen, and nothing else: the
        -- opening sentence says what this is, and the corner is four lines
        -- tall. `gaps` and `max_lines` only apply to the whole-block mode.
        if opts.body == "sentence" then
          local text, more = M.first_sentence(block[1])
          if more or #block > 1 then
            -- "possible." reads better as "possible…" than as "possible.…";
            -- a question or an exclamation keeps its mark.
            text = text:gsub("%.+$", "") .. "…"
          end
          return { text }
        end

        -- Only prose stacks: a tool call stands alone, and once we have prose
        -- anything else above it belongs to an older part of the turn.
        if #out > 0 and kind ~= "prose" then
          break
        end
        if #out > 0 then
          table.insert(out, 1, "")
        end
        for k = #block, 1, -1 do
          table.insert(out, 1, block[k])
        end
        budget = budget - consumed
        -- Only prose keeps reaching upwards; anything else stands on its own.
        if kind ~= "prose" then
          break
        end
      end
      i = first - 1
    end
  end

  if #out == 0 then
    return { "(no output yet)" }
  end
  return out
end

-- Openers that start a sentence without being a capital letter. Claude opens
-- sentences with a code span constantly, so the backtick matters.
local SENTENCE_OPENERS = { '"', "'", "`", "(", "[", "“", "‘" }

-- Abbreviations whose full stop ends nothing, and which the capital-letter test
-- below cannot catch on its own ("i.e. The rest"). Deliberately short: "etc."
-- is left out because it genuinely does end sentences.
local ABBREVIATIONS = { "e.g.", "i.e.", "cf.", "vs.", "Dr.", "Mr.", "Mrs.", "Ms.", "St." }

local function opens_sentence(rest)
  -- A digit counts: "…restart to see it. 110 specs pass" is two sentences, and
  -- a number almost never opens a clause in the middle of one. The version and
  -- decimal cases this might be confused with -- 0.10, 1.4k -- have no space
  -- after the stop, so they never reach here.
  if rest:sub(1, 1):match("[%u%d]") then
    return true
  end
  for _, opener in ipairs(SENTENCE_OPENERS) do
    if rest:sub(1, #opener) == opener then
      return true
    end
  end
  return false
end

local function is_abbreviation(text)
  local word = text:match("(%S+)$")
  if not word then
    return false
  end
  for _, abbreviation in ipairs(ABBREVIATIONS) do
    if word == abbreviation then
      return true
    end
  end
  return false
end

--- The first sentence of a line, and whether anything followed it.
---
--- Prose is full of full stops that end nothing -- `parser.lua`, `0.10`,
--- `v0.2.0`, `e.g.` -- so a full stop only counts when what follows looks like
--- the start of the next sentence: whitespace, then a capital or an opener. A
--- stop with no whitespace after it is inside a word, a version or a path, and
--- one at the end of the line ends the line, not a sentence within it.
--- @return string, boolean
function M.first_sentence(line)
  local from = 1
  while true do
    local first, last = line:find("[%.!%?]+", from)
    if not first then
      return line, false
    end
    local rest = line:sub(last + 1)
    local gap = rest:match("^%s+")
    if gap then
      local tail = rest:sub(#gap + 1)
      -- Up to and including the stop: an abbreviation is only recognisable
      -- with its own full stop attached ("e.g.", not "e.g").
      if tail ~= "" and opens_sentence(tail) and not is_abbreviation(line:sub(1, last)) then
        return line:sub(1, last), true
      end
    end
    from = last + 1
  end
end

--- Which marker leads a line from status_lines(), so the notification can
--- colour it. The glyphs stay here, next to the scraping that produced them.
--- @return "tool"|"echo"|"bullet"|"prose"
function M.line_kind(line)
  if is_tool_result(line) then
    return "tool"
  end
  if is_prompt_echo(line) then
    return "echo"
  end
  if strip_bullet(line) ~= line then
    return "bullet"
  end
  return "prose"
end

-- Everything the notification title wants to say, read off the one live line:
--
--   ✽ Infusing… (8m 24s · ↓ 24.8k tokens)
--   │ │          │          └ tokens
--   │ │          └ elapsed
--   │ └ verb
--   └ glyph, which cycles as Claude works -- passing it through animates the
--     title for free.
--
-- With no live line the frozen marker stands in (`done`), so a finished turn
-- still says what it cost. Both nil means Claude is waiting on you.
--- @return { working: boolean, glyph: string|nil, verb: string|nil, elapsed: string|nil, tokens: string|nil, done: string|nil }
function M.status()
  local out = { working = false }
  if not state.buf_valid() then
    return out
  end

  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  local boundary = input_boundary(lines)

  for i = boundary - 1, math.max(1, boundary - 6), -1 do
    if is_rule(lines[i]) or is_box_top(lines[i]) then
      break
    end
    if is_status_line(lines[i]) then
      local s = clean(lines[i]):gsub("^%s+", "")
      local rest = s:gsub("^%S+%s*", "")
      local verb, detail = rest:match("^(.-)%s*%((.*)%)$")
      out.working = true
      out.glyph = s:match("^(%S+)%s")
      out.verb = (verb and verb ~= "") and verb or rest
      if detail then
        -- The timer leads the detail group; the token counters follow it.
        local head = detail:match("^([^·]*)"):gsub("^%s*(.-)%s*$", "%1")
        if head:match("^%d+[hms]") then
          out.elapsed = head
        end
        local down = detail:match("↓%s*([%d%.]+[kKmMgG]?)")
        local up = detail:match("↑%s*([%d%.]+[kKmMgG]?)")
        out.tokens = (down and "↓" .. down) or (up and "↑" .. up) or nil
      end
      return out
    end
  end

  for i = boundary - 1, math.max(1, boundary - SEARCH_LIMIT), -1 do
    local marker = done_marker(lines[i])
    if marker then
      out.done = marker
      return out
    end
  end
  return out
end

-- Claude is actively processing when its live status/spinner line is present
-- just above the input box. Absence => idle / waiting for the user's input.
--
-- Deliberately the same scan the notification titles itself from: this is the
-- predicate the auto-restore hangs off, and a second copy of it is a second
-- thing to keep in step with Claude's UI.
function M.is_working()
  return M.status().working
end

return M
