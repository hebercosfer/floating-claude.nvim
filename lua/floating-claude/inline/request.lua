-- One inline request in session mode: the prompt that gets typed into Claude,
-- and how the session's hook records and the screen's status line carry it from
-- being sent to being over.
--
--   waiting -> sent -> running -> done | interrupted | failed
--                 \-> failed (Claude never took the prompt)
--                 \-> done (queued behind a turn, and no reply could be told apart)
--   waiting -> dropped (the caller decides: a draft, or a request open)
--
-- The caller moves it out of "waiting" -- it sets `phase = "sent"` and
-- `sent_at` when it pastes the prompt -- and into "dropped", with `note`
-- giving the reason. Everything else happens here, from on_record() and
-- on_tick(), and items() is what the inline lines show of it.
--
-- Two kinds of words end up on the lines and must stay apart: `said` is
-- Claude's, shown after "Claude: "; `note` is the plugin's own, shown exactly
-- as written.
--
-- Pure: no vim.api, so the specs can replay a turn through it.

local text = require("floating-claude.hooks.text")

local M = {}

-- How long, in ms, a sent prompt may go unheard before Claude is taken not to
-- have received it.
local SENT_MS = 5000
-- How long, in ms, the status line and the records must both have been silent
-- before a running turn is called interrupted. The same rule, and number, as
-- the session's safety net (hooks/session.lua): Esc fires no hook.
local SAFETY_MS = 1000
-- How much of the instruction a submitted prompt is matched on. A prompt comes
-- through the listener cut to TEXT_CAP bytes, and has the mention in front of
-- the instruction -- and, when Claude Code collapses a long paste, a wrapper
-- as well -- so the whole of a long instruction would never be found in it.
local MATCH_BYTES = 1500

local ASKING = "Claude is asking you something · <CR> to open Claude"
local DIDNT_TAKE = "Claude didn't take the prompt · <CR> to open Claude"
local COULDNT_TELL = "couldn't tell which reply is this one · <CR> to open Claude"

---@class floating_claude.InlineRequestOpts
---@field file string
---@field line1 integer 1-based
---@field line2 integer 1-based
---@field instruction string
---@field mention "at"|"words"|nil defaults to "at"

---@class floating_claude.InlineRequest
---@field phase "waiting"|"sent"|"running"|"done"|"interrupted"|"failed"|"dropped"
---@field prompt string The text that gets pasted.
---@field asked string The instruction, whitespace-normalised.
---@field activity string|nil The tool Claude is running.
---@field said string|nil Claude's words, this request's own turn's.
---@field heard string|nil What the turn ahead of a queued prompt ended on. Not this request's
---  words: shown only when no reply can be told from them.
---@field note string|nil What the plugin says of how the request ended, verbatim.
---@field asking string|nil Set while Claude is asking you something.
---@field sent_at integer|nil Epoch ms; moved on by a Stop while queued.
---@field last_at integer|nil Epoch ms of the latest record this turn.
---@field queued boolean|nil Sent while Claude was busy, so it waits its turn.
---@field stopped boolean|nil A turn ahead of a queued prompt has ended.
---@field saw_live boolean|nil The status line has been seen.
---@field live_at integer|nil Epoch ms of the last tick that saw it.
---@field compacting boolean|nil
---@field dialog_seen boolean|nil While asking: a tick has seen the input box gone, so the dialog is drawn.
---@field box_since integer|nil Epoch ms the input box was first seen back while asking.

local function normalise(s)
  return vim.trim((s:gsub("%s+", " ")))
end

--- What gets pasted into Claude for a request: the range, then the instruction.
---
--- `mention = "at"` is Claude Code's own `@path#L12-14`, which it reads the
--- lines for before the turn starts. The path is relative to the working
--- directory, as Claude's is. A path with a space in it cannot be mentioned
--- that way (unverified how Claude Code would take it), so it is named in words
--- instead, as `mention = "words"` always does.
---@param req floating_claude.InlineRequestOpts
---@return string
function M.prompt(req)
  local first, last = math.min(req.line1, req.line2), math.max(req.line1, req.line2)
  local path = vim.fn.fnamemodify(req.file, ":.")
  -- An escape in the text would end the paste early, and the rest would be
  -- typed into Claude as keys.
  local instruction = req.instruction:gsub("\27", "")
  if (req.mention or "at") == "at" and not path:find("%s") then
    local lines = first == last and ("L" .. first) or ("L" .. first .. "-" .. last)
    return "@" .. path .. "#" .. lines .. " " .. instruction
  end
  local lines = first == last and ("line " .. first) or ("lines " .. first .. "-" .. last)
  return "In " .. path .. ", " .. lines .. ": " .. instruction
end

---@param opts floating_claude.InlineRequestOpts
---@return floating_claude.InlineRequest
function M.new(opts)
  return {
    phase = "waiting",
    prompt = M.prompt(opts),
    asked = normalise(opts.instruction),
  }
end

-- Whether a submitted prompt is the one we sent: it holds the instruction, in
-- whatever whitespace. Not the whole prompt, which is the mention and the
-- instruction when typed, and the paste inside a wrapper when Claude Code
-- collapses a long one.
local function is_ours(req, prompt)
  if type(prompt) ~= "string" then
    return false
  end
  return normalise(prompt):find(req.asked:sub(1, MATCH_BYTES), 1, true) ~= nil
end

--- Take in one hook record. True when what the lines show has changed.
---@param req floating_claude.InlineRequest
---@param rec floating_claude.Record
---@return boolean
function M.on_record(req, rec)
  local event = rec.event
  if req.phase == "sent" then
    if event == "UserPromptSubmit" and is_ours(req, rec.prompt) then
      -- From here the turn is this request's, and nothing said before it is.
      req.phase, req.last_at, req.said, req.heard = "running", rec.at, nil, nil
      return true
    elseif event == "Stop" and req.queued then
      -- The turn ahead is over, so the queued prompt should be taken at once.
      -- It gets its 5000 ms from here; and if it is not taken, this reply is
      -- all there is to show for it -- the latest one, or none.
      req.sent_at, req.stopped, req.heard = rec.at, true, rec.message
    end
    return false
  elseif req.phase ~= "running" then
    return false
  end

  req.last_at = rec.at
  local phase, activity, said, asking = req.phase, req.activity, req.said, req.asking
  if event == "PreToolUse" then
    -- Claude's own bookkeeping makes no line: the last tool stays.
    req.activity = text.tool_line(rec.tool_name or "", rec.tool_input) or req.activity
    req.asking = nil
  elseif event == "PostToolUse" or event == "PostToolUseFailure" then
    req.asking = nil
  elseif event == "MessageDisplay" then
    req.said = rec.delta or req.said
  elseif event == "PermissionRequest" or event == "Elicitation" then
    req.asking, req.dialog_seen = ASKING, nil
  elseif event == "Stop" then
    req.said = rec.message or req.said
    req.phase = "done"
  elseif event == "StopFailure" then
    req.said = rec.message or rec.error
    req.phase = "failed"
  elseif event == "SessionEnd" then
    req.phase = "failed"
  elseif event == "PreCompact" then
    req.compacting = true
  elseif event == "PostCompact" then
    req.compacting = false
  end
  return req.phase ~= phase or req.activity ~= activity or req.said ~= said or req.asking ~= asking
end

-- A prompt that is out and not yet taken. With Claude busy it is queued, and
-- is taken when the turn ahead ends: while the status line is live there is
-- nothing to time. Past that, its 5000 ms start from the last moment the line
-- was seen (or the turn ahead's Stop, which moves `sent_at`), so a queued prompt
-- that Claude Code never sends -- an Esc on the turn ahead fires no hook -- is
-- still given up on.
local function tick_sent(req, now_ms, status)
  if status.working then
    req.queued, req.saw_live, req.live_at = true, true, now_ms
    return false
  end
  if not req.sent_at then
    return false
  end
  local since = req.queued and math.max(req.sent_at, req.live_at or 0) or req.sent_at
  if now_ms - since < SENT_MS then
    return false
  end
  if req.stopped then
    -- The turn ahead ended, and no prompt of ours followed it: whatever it
    -- said was the last reply, and maybe ours.
    req.phase, req.note, req.said, req.heard = "done", COULDNT_TELL, req.heard, nil
  else
    req.phase, req.note = "failed", DIDNT_TAKE
  end
  return true
end

-- Esc fires no hook, so a turn that was cut short is found as session.tick
-- finds one: only the absence of a status line already seen is trusted, and
-- only once the records have been silent as long as it has been gone.
--
-- While Claude asks you something that is no use: a dialog draws no status
-- line and fires nothing. What gives away an Esc on the dialog is the input box
-- coming back where it was, with nothing heard since. The request can come
-- before the dialog is drawn, with the box still showing, so the box only means
-- anything once a tick has seen it gone.
local function tick_running(req, now_ms, status)
  if status.working then
    req.saw_live, req.live_at, req.box_since = true, now_ms, nil
    return false
  end
  local heard = req.last_at or req.sent_at or now_ms
  if req.asking then
    if status.box == false then
      req.dialog_seen = true
    end
    if not status.box or not req.dialog_seen then
      req.box_since = nil
      return false
    end
    req.box_since = req.box_since or now_ms
    if now_ms - math.max(req.box_since, heard) < SAFETY_MS then
      return false
    end
  elseif
    not req.saw_live
    or req.compacting
    or now_ms - heard < SAFETY_MS
    or now_ms - req.live_at < SAFETY_MS
  then
    return false
  end
  req.phase = "interrupted"
  return true
end

--- The clock and the screen's say, on each tick while the request is out.
--- True when what the lines show has changed.
---@param req floating_claude.InlineRequest
---@param now_ms integer
---@param status { working: boolean, box: boolean|nil } `working`: the status
---  line is live. `box`: the input box can be read (parser.input_draft() ~= nil).
---@return boolean
function M.on_tick(req, now_ms, status)
  if req.phase == "sent" then
    return tick_sent(req, now_ms, status)
  elseif req.phase == "running" then
    return tick_running(req, now_ms, status)
  end
  return false
end

--- What the inline lines show: the instruction first, then, by phase, what is
--- happening. The lines are capped from the top, so this is in priority order.
--- Claude's question is an `ask` item, which the cap never cuts.
---@param req floating_claude.InlineRequest
---@return floating_claude.InlineItem[]
function M.items(req)
  local out = { "▸ " .. req.asked }
  local phase = req.phase
  if phase == "waiting" then
    table.insert(out, "waiting for Claude to finish")
  elseif phase == "running" then
    if req.asking then
      table.insert(out, { text = req.asking, ask = true })
    elseif req.activity then
      table.insert(out, req.activity)
    end
    if req.said then
      table.insert(out, "Claude: " .. req.said)
    end
  elseif phase == "done" or phase == "failed" or phase == "dropped" then
    -- What the plugin has to say comes as written; only Claude's words carry
    -- its name. A turn that ends with neither says how it ended.
    if req.note then
      table.insert(out, req.note)
    end
    if req.said then
      table.insert(out, "Claude: " .. req.said)
    end
    if #out == 1 and phase ~= "dropped" then
      table.insert(out, phase)
    end
  elseif phase == "interrupted" then
    table.insert(out, "interrupted")
  end
  return out
end

--- Whether the request is over, whichever way.
---@param req floating_claude.InlineRequest
---@return boolean
function M.ended(req)
  local phase = req.phase
  return phase == "done" or phase == "interrupted" or phase == "failed" or phase == "dropped"
end

return M
