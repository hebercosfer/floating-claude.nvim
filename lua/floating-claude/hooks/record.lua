-- What the listener keeps of an event Claude posts, and who gets to hear it.
--
-- Claude's payloads are generous: every one carries the session's paths, a
-- tool call carries its whole input, and a finished one its whole output. The
-- corner needs a sliver of that, so compact() keeps the fields the reducer
-- reads -- strings cut to TEXT_CAP -- and drops the rest, including anything
-- a subagent posted and any event the plugin never subscribed to.
--
-- Runs inside the listener thread as well as on the main loop: plain Lua,
-- vim.uv and the vim.* helpers only.

local text = require("floating-claude.hooks.text")

local M = {}

-- The hooks the plugin registers, in the order the settings file lists them.
M.SUBSCRIBED = {
  "UserPromptSubmit",
  "PreToolUse",
  "PermissionRequest",
  "PostToolUse",
  "PostToolUseFailure",
  "MessageDisplay",
  "Stop",
  "StopFailure",
  "Elicitation",
  "PreCompact",
  "PostCompact",
  "SessionEnd",
}

local SUBSCRIBED = {}
for _, name in ipairs(M.SUBSCRIBED) do
  SUBSCRIBED[name] = true
end

-- Events that mean Claude cannot go on without you: a dialog it is holding
-- open, an MCP server asking you something, a turn that failed.
M.REQUEST = { PermissionRequest = true, Elicitation = true, StopFailure = true }

-- The longest string kept, in bytes, before it is cut.
M.TEXT_CAP = 2000
-- How many records the thread keeps for a replay when the corner opens.
M.RING_MAX = 64

--- Add a record to the turn's ring, the oldest out once it is full -- all but
--- the prompt that opened the turn, which is what the title's clock counts
--- from: a long turn would otherwise replay with its clock stuck at 0s.
---@param ring floating_claude.Record[]
---@param rec floating_claude.Record
function M.push(ring, rec)
  table.insert(ring, rec)
  while #ring > M.RING_MAX do
    table.remove(ring, ring[1].event == "UserPromptSubmit" and 2 or 1)
  end
end

--- Epoch milliseconds. Both sides of the pipe use this one clock, so a
--- record's `at` and the main loop's "now" can be compared.
---@return integer
function M.now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local function is_continuation(byte)
  return byte ~= nil and byte >= 0x80 and byte < 0xC0
end

--- A deep copy with every string longer than `limit` bytes cut at the last
--- character boundary that fits, and marked with how much more there was.
---@param value any
---@param limit integer
---@return any
function M.cap(value, limit)
  if type(value) == "string" then
    if #value <= limit then
      return value
    end
    local keep = limit
    while keep > 0 and is_continuation(value:byte(keep + 1)) do
      keep = keep - 1
    end
    return value:sub(1, keep) .. "… [" .. (#value - keep) .. " bytes more]"
  end
  if type(value) == "table" then
    local copy = {}
    for k, v in pairs(value) do
      copy[k] = M.cap(v, limit)
    end
    return copy
  end
  return value
end

local function capped(s)
  return s ~= nil and M.cap(s, M.TEXT_CAP) or nil
end

---@class floating_claude.Record
---@field event string
---@field at integer Epoch ms the listener received it.
---@field prompt string|nil
---@field synthetic boolean|nil A prompt Claude Code submitted itself.
---@field tool_name string|nil
---@field tool_input table|nil
---@field delta string|nil
---@field final boolean|nil
---@field message string|nil
---@field error string|nil
---@field trigger string|nil
---@field reason string|nil

--- The record of one event, or nil for one the plugin does not read.
---@param event table The decoded payload.
---@param at integer
---@return floating_claude.Record|nil
function M.compact(event, at)
  local name = event.hook_event_name
  if event.agent_id ~= nil or not SUBSCRIBED[name] then
    return nil
  end
  local r = { event = name, at = at }
  if name == "UserPromptSubmit" then
    r.prompt = capped(event.prompt)
    r.synthetic = text.is_synthetic(event.prompt)
  elseif
    name == "PreToolUse"
    or name == "PermissionRequest"
    or name == "PostToolUse"
    or name == "PostToolUseFailure"
  then
    r.tool_name = event.tool_name
    r.tool_input = capped(event.tool_input)
  elseif name == "MessageDisplay" then
    -- The corner shows the newest paragraph: pick it before capping, which
    -- keeps a string's head and would leave a long reply's middle.
    r.delta = capped(text.prose(event.delta))
    r.final = event.final
  elseif name == "Stop" then
    r.message = capped(text.prose(event.last_assistant_message))
  elseif name == "StopFailure" then
    r.message = capped(event.last_assistant_message)
    r.error = event.error
  elseif name == "Elicitation" then
    r.message = capped(event.message)
  elseif name == "PreCompact" or name == "PostCompact" then
    r.trigger = event.trigger
  elseif name == "SessionEnd" then
    r.reason = event.reason
  end
  return r
end

return M
