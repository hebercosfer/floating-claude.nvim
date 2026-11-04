-- The session: whether this Claude is heard through its hooks, and what the
-- plugin does with what it hears.
--
-- At spawn, prepare() decides. Hooks need the setting on, a CLI new enough,
-- and a command that does not already pass its own --settings; then it starts
-- the listener, writes the settings file and adds `--settings <file>` to
-- Claude's command line. Anything else falls back to reading the screen, and
-- reason() says why.
--
-- After that, records arrive from the listener -- live ones, and a replay of
-- the turn whenever the corner opens. Live records go through the reducer and
-- the attention rules, which may restore the float or show the corner. A
-- replay only rebuilds the state: a corner you just opened is never fought.
--
-- The screen is still read for one line, the live status line, because no
-- hook reports an interrupt. It settles the state when the corner opens, and
-- it is the safety net while the corner shows Claude working (tick). If the
-- corner sees Claude working but the listener has heard nothing all session
-- -- hooks disabled by a policy, say -- the session falls back for good.

local attention = require("floating-claude.attention")
local config = require("floating-claude.config")
local listener = require("floating-claude.hooks.listener")
local parser = require("floating-claude.parser")
local record = require("floating-claude.hooks.record")
local reducer = require("floating-claude.hooks.reducer")
local settings = require("floating-claude.hooks.settings")
local state = require("floating-claude.state")

local M = {}

-- How long, in ms, the status line and the events must both have been silent
-- before the safety net calls a "working" turn finished.
local SAFETY_MS = 1000

---@class floating_claude.Session
---@field active boolean
---@field reason string|nil
---@field scripted boolean
---@field listener floating_claude.Listener|nil
---@field settings_path string|nil
---@field state floating_claude.State
---@field handlers { restore: fun()|nil, show: fun()|nil, fallback: fun()|nil }
---@field timer uv.uv_timer_t|nil
---@field saw_live boolean
---@field live_at integer|nil
---@field mode "float"|"corner"|"hidden"|nil
---@field prev_mode "float"|"corner"|"hidden"|nil

---@return floating_claude.Session
local function fresh()
  return {
    active = false,
    reason = nil,
    scripted = false,
    listener = nil,
    settings_path = nil,
    state = reducer.new(),
    handlers = {},
    timer = nil,
    saw_live = false,
    live_at = nil,
    mode = nil,
    prev_mode = nil,
  }
end

local S = fresh()
-- Outlive any one session: the notification registers once, at load.
local change_fns = {}

local function changed()
  for fn in pairs(change_fns) do
    fn()
  end
end

local function stop_timer()
  if S.timer then
    S.timer:stop()
    if not S.timer:is_closing() then
      S.timer:close()
    end
    S.timer = nil
  end
end

local function call(name)
  local fn = S.handlers[name]
  if fn then
    fn()
  end
end

-- Act on a finished turn after restore_idle_ms, unless Claude moved, a diff
-- came up, or new work started in the meantime.
local function later(name)
  stop_timer()
  local where = state.mode()
  S.timer = vim.uv.new_timer()
  S.timer:start(
    config.options.auto.restore_idle_ms,
    0,
    vim.schedule_wrap(function()
      stop_timer()
      if
        S.active
        and state.mode() == where
        and S.state.phase ~= "working"
        and not parser.diff_visible()
      then
        call(name)
      end
    end)
  )
end

local function act(effect)
  local decision =
    attention.decide(state.mode(), effect, config.options.auto, parser.diff_visible())
  if decision == "cancel" then
    stop_timer()
  elseif decision == "restore_now" then
    stop_timer()
    call("restore")
  elseif decision == "show_now" then
    stop_timer()
    call("show")
  elseif decision == "restore_later" then
    later("restore")
  elseif decision == "show_later" then
    later("show")
  end
end

local function fallback(reason)
  -- The listener keeps answering: Claude was started pointing at it.
  S.active = false
  S.reason = reason
  stop_timer()
  call("fallback")
  changed()
end

local function hex(bytes)
  return (bytes:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

--- Decide how this Claude is heard, and return the command to start it with.
---@param args string[]
---@param cmd_string string
---@return string[]
function M.prepare(args, cmd_string)
  M.stop()
  local reason
  if not config.options.hooks.enabled then
    reason = "hooks = false in setup()"
  elseif (cmd_string or ""):find("--settings", 1, true) then
    reason = "the claude command already passes --settings"
  else
    local ok, why = require("floating-claude.compat").hooks_ready(cmd_string)
    if not ok then
      reason = why
    end
  end
  if reason then
    S.reason = reason
    return args
  end

  local token = hex(vim.uv.random(16))
  local l, err = listener.start({
    token = token,
    keep = config.options.hooks.keep,
    on_record = M.inject,
    on_ring = M.receive_ring,
  })
  if not l then
    S.reason = "the listener could not start: " .. tostring(err)
    return args
  end
  local path, werr = settings.write(l.port, token)
  if not path then
    -- Nothing points at the port yet, so closing it here is safe.
    l.stop()
    S.reason = "the settings file could not be written: " .. tostring(werr)
    return args
  end

  S.listener, S.settings_path, S.active = l, path, true
  if S.mode then
    l.set_mode(S.mode)
  end
  local out = vim.list_extend({}, args)
  vim.list_extend(out, { "--settings", path })
  return out
end

--- Heard through hooks, without a listener: records come from inject(). For
--- the tour, and for the specs.
function M.start_scripted()
  M.stop()
  S.active, S.scripted = true, true
end

---@return boolean
function M.active()
  return S.active
end

---@return string|nil
function M.reason()
  return S.reason
end

---@param handlers { restore: fun(), show: fun(), fallback: fun() }
function M.attach(handlers)
  S.handlers = handlers or {}
end

---@return floating_claude.State
function M.state()
  return S.state
end

--- Hear about every change to the state, to redraw.
---@param fn fun()
function M.on_change(fn)
  change_fns[fn] = true
end

--- A live record: from the listener, or from the tour.
---@param rec floating_claude.Record
function M.inject(rec)
  if not S.active then
    return
  end
  local _, effect = reducer.apply(S.state, rec)
  changed()
  act(effect)
end

-- The screen's word on the state when the corner opens. A live status line
-- means working, whatever the records say -- a request you answered in the
-- float fires nothing until its tool finishes. No live line means an
-- interrupted turn is over, and a request that arrived while you had the
-- float open was seen there. And a corner that sees Claude working when the
-- listener has heard nothing at all means the hooks never reached it.
local function settle(received)
  local status = parser.status()
  if status.working then
    S.saw_live, S.live_at = true, record.now_ms()
    if received == 0 then
      fallback("no hook events arrived although Claude is working")
      return
    end
    S.state.phase = "working"
  elseif S.state.phase == "working" then
    S.state.phase = "idle"
  elseif S.state.phase == "request" and S.prev_mode == "float" then
    -- You had the float while it asked. Answered, the screen would show
    -- Claude at work; declined (Esc fires nothing), it is over -- however the
    -- float came to be open, and whatever its question said.
    S.state.phase = "idle"
    S.state.body = nil
  end
end

--- The listener's replay of the turn, as the corner opens. Rebuilds the state
--- without acting on any of it.
---@param records floating_claude.Record[]
---@param received integer
function M.receive_ring(records, received)
  if not S.active then
    return
  end
  stop_timer()
  S.state = reducer.new()
  for _, rec in ipairs(records) do
    reducer.apply(S.state, rec)
  end
  settle(received)
  if S.active then
    changed()
  end
end

--- The safety net, on each tick of the corner's working timer. Only the
--- absence of a line it has already seen match is trusted: a CLI that redrew
--- its status line must not turn every long tool run into "done".
---@param status { working: boolean }
function M.tick(status)
  if not S.active then
    return
  end
  local now = record.now_ms()
  if status.working then
    S.saw_live, S.live_at = true, now
    return
  end
  if
    S.saw_live
    and not S.state.compacting
    and S.state.phase == "working"
    and now - (S.state.last_event_at or 0) >= SAFETY_MS
    and now - (S.live_at or 0) >= SAFETY_MS
  then
    S.state.phase = "idle"
    changed()
  end
end

--- Claude moved between its faces (state.changed()).
---@param mode "float"|"corner"|"hidden"
function M.mode_changed(mode)
  S.prev_mode, S.mode = S.mode, mode
  if S.listener then
    S.listener.set_mode(mode)
  end
end

--- What the events view and :checkhealth say about the session.
---@return { active: boolean, reason: string|nil, port: integer|nil, settings_path: string|nil, events: string[], keep: integer }
function M.info()
  return {
    active = S.active,
    reason = S.reason,
    port = S.listener and S.listener.port or nil,
    settings_path = S.settings_path,
    events = record.SUBSCRIBED,
    keep = config.options.hooks.keep,
  }
end

--- The listener's transparency log; nil without a listener.
---@param cb fun(log: floating_claude.Log|nil)
function M.log(cb)
  if S.listener then
    S.listener.log(cb)
  else
    cb(nil)
  end
end

--- Claude exited (or is about to be restarted): close the port, delete the
--- settings file, forget the state.
function M.stop()
  stop_timer()
  if S.listener then
    S.listener.stop()
  end
  settings.remove(S.settings_path)
  local mode = S.mode
  S = fresh()
  S.mode = mode
end

state.subscribe("session", M.mode_changed)

-- Quitting Neovim takes Claude down with it, but no on_exit runs to delete the
-- settings file: do it on the way out.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("FloatingClaudeSession", { clear = true }),
  desc = "Delete floating-claude's hook settings file",
  callback = function()
    settings.remove(S.settings_path)
  end,
})

return M
