-- Claude's state as the corner sees it, reduced from hook records.
--
-- Three phases: working, a request (Claude cannot go on without you -- a
-- dialog, a question from an MCP server, a turn that failed), and idle. Each
-- record moves the phase, changes the words the corner shows, or both, and
-- may report an effect the attention rules act on:
--
--   "activity"  new work started; a pending restore or show is off
--   "request"   Claude needs a response
--   "finished"  a turn ended
--
-- What it cannot see: an interrupt. Esc fires no hook at all, so a turn you
-- cut short stays "working" here -- the session's safety net, which reads the
-- live status line, is what brings it back to idle.
--
-- Pure: no vim.api, so the specs can replay captured sessions through it.

local text = require("floating-claude.hooks.text")

local M = {}

---@class floating_claude.Body
---@field kind "echo"|"tool"|"prose"|"error"
---@field text string
---@field event string The hook event that made it.

---@class floating_claude.State
---@field phase "idle"|"working"|"request"
---@field started integer|nil When the current turn began (epoch ms).
---@field last_event_at integer|nil
---@field request_at integer|nil When the open request arrived.
---@field compacting boolean
---@field body floating_claude.Body|nil The latest thing to show.
---@field message { text: string, event: string }|nil Claude's latest words this turn.

---@return floating_claude.State
function M.new()
  return { phase = "idle", compacting = false }
end

local function prose(markdown, event)
  local words = text.prose(markdown)
  return words and { kind = "prose", text = words, event = event } or nil
end

-- Claude's words, kept apart from what came after them: the corner shows the
-- latest message and, under it, the latest other event.
local function said(state, body)
  if body then
    state.message = { text = body.text, event = body.event }
  end
  return body
end

local function tool(rec)
  local line = text.tool_line(rec.tool_name or "", rec.tool_input)
  return line and { kind = "tool", text = line, event = rec.event } or nil
end

local function request(state, rec, body)
  state.phase = "request"
  state.request_at = rec.at
  body.event = rec.event
  state.body = body
  return "request"
end

--- Apply one record, in place.
---@param state floating_claude.State
---@param rec floating_claude.Record
---@return floating_claude.State, "activity"|"request"|"finished"|nil
function M.apply(state, rec)
  local event, effect = rec.event, nil
  state.last_event_at = rec.at

  if event == "UserPromptSubmit" then
    state.phase = "working"
    state.started = rec.at
    -- A prompt Claude Code submitted itself (a background task finishing)
    -- starts a turn, but it is not something you asked.
    local typed = not rec.synthetic and rec.prompt and vim.trim((rec.prompt:gsub("%s+", " ")))
    if typed and typed ~= "" then
      state.body = { kind = "echo", text = typed, event = rec.event }
      -- A prompt you typed starts the corner afresh: the last turn's words
      -- are not what this one is about.
      state.message = nil
    end
    effect = "activity"
  elseif event == "PreToolUse" then
    state.phase = "working"
    state.body = tool(rec) or state.body
    effect = "activity"
  elseif event == "PermissionRequest" then
    effect = request(state, rec, {
      kind = "prose",
      text = text.request_line(rec.tool_name or "", rec.tool_input),
    })
  elseif event == "PostToolUse" or event == "PostToolUseFailure" then
    -- The tool ran, so whatever it asked you was answered: its question must
    -- not outlive it.
    if state.phase == "request" then
      state.phase = "working"
      state.body = tool(rec)
    end
    effect = "activity"
  elseif event == "MessageDisplay" then
    -- Words only, never the phase: the final paragraph's display can arrive
    -- just after Stop, and must not make a finished turn look busy again.
    state.body = said(state, prose(rec.delta, rec.event)) or state.body
  elseif event == "Stop" then
    state.phase = "idle"
    state.body = said(state, prose(rec.message, rec.event)) or state.body
    effect = "finished"
  elseif event == "StopFailure" then
    effect =
      request(state, rec, { kind = "error", text = rec.message or rec.error or "The turn failed" })
  elseif event == "Elicitation" then
    effect = request(state, rec, {
      kind = "prose",
      text = rec.message or "An MCP server is asking you something",
    })
  elseif event == "PreCompact" then
    state.compacting = true
  elseif event == "PostCompact" then
    state.compacting = false
  elseif event == "SessionEnd" then
    for key in pairs(state) do
      state[key] = nil
    end
    for key, value in pairs(M.new()) do
      state[key] = value
    end
  end
  return state, effect
end

return M
