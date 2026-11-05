-- Moves the float in step with Claude's work cycle: out of the way of an
-- edit-approval diff, and back once it is resolved -- and, when Claude is read
-- off the screen, back again once Claude settles.
--
-- Two ways to run it:
--
--   * start_diffs() -- Claude heard through its hooks. The session owns busy
--     and idle; this only follows diffs, and only when windows change: window
--     autocmds schedule the same diff check the poll runs. No timer polls.
--   * start() -- the fallback. A poll every watch_ms reads the screen for busy
--     and idle, and checks for diffs on the same tick.

local config = require("floating-claude.config")
local parser = require("floating-claude.parser")
local state = require("floating-claude.state")

---@type uv
local uv = vim.uv

local M = {}

local DIFF_GROUP = "FloatingClaudeDiffs"

-- start_diffs()'s one-shot timer (see arm_settle).
local settle_timer = nil

function M.stop()
  if state.watch_timer then
    state.watch_timer:stop()
    if not state.watch_timer:is_closing() then
      state.watch_timer:close()
    end
    state.watch_timer = nil
  end
  if settle_timer then
    settle_timer:stop()
    if not settle_timer:is_closing() then
      settle_timer:close()
    end
    settle_timer = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, DIFF_GROUP)
  state.subscribe("watcher", nil)
  state.last_mode = nil
  state.before_diff = nil
  state.was_busy = false
  state.idle_since = nil
end

--- The diff half of the work cycle:
---   * an edit-approval diff appears with the float up -> minimize (the diff
---     would otherwise be hidden behind the float);
---   * the diff closes -> back to what Claude was before it opened: the float
---     comes straight back, the corner and hidden stay as they are.
--- "On screen", not merely loaded: a diff the user denied and then closed
--- leaves its proposed buffer hidden but alive (see parser.lua).
---
--- `track` makes a check with no diff on screen record the mode as the one to
--- return to. The poll does that on every tick; window events must not, since
--- they fire in the middle of the very move a diff makes (see start_diffs).
---@param handlers { minimize: fun(), restore: fun() }
---@param track boolean
---@return boolean has_diff, "float"|"corner"|"hidden" mode
function M.diff_step(handlers, track)
  local opts = config.options.auto
  local has_diff = parser.diff_visible()
  local mode = state.mode()

  if has_diff and state.before_diff == nil then
    -- The first check to see this diff. What Claude was comes from before,
    -- not from now: the diff opens in its own tab, and the WinLeave
    -- claudecode's `:tabnew` fires has usually collapsed the float through
    -- `minimize_on_leave` before this runs.
    state.before_diff = state.last_mode or mode
    -- Still up only when nothing else got there first. Minimize it once,
    -- here, and never on a later check: the user bringing the float back
    -- mid-review -- to reread the request they are approving -- is
    -- deliberate, and used to take two goes because the poll read it as a
    -- diff it had not reacted to yet.
    if mode == "float" and opts.minimize_on_diff then
      handlers.minimize()
    end
  elseif not has_diff then
    if state.before_diff == "float" and mode ~= "float" then
      handlers.restore()
      mode = "float"
    end
    state.before_diff = nil
    if track then
      state.last_mode = mode
    end
  end
  return has_diff, mode
end

-- Poll the live terminal/diff state and move the float in step with the cycle.
-- On top of diff_step():
--   * minimized + Claude settles idle -> restore (Claude is now waiting for
--     the user or done), UNLESS a diff is still up (review that);
--   * hidden + Claude settles idle    -> the corner, so you hear about it
--     without the float landing on your work (unless show_hidden = false).
-- "Busy" = actively working OR a diff on screen.
--
-- Restore waits for SUSTAINED idle (`restore_idle_ms`) after a busy->idle
-- transition: the brief lull between a diff being approved/denied and Claude
-- resuming work is not enough to pop the float -- it only returns when
-- interaction is requested or the task completes. A float the diff took away
-- is the exception: it was open when the diff arrived, so putting it back is
-- undoing the detour, not interrupting anything.
-- The transition gating also means a manual minimize while Claude is already
-- idle is never fought (no busy->idle edge => idle_since never starts).
--
-- `handlers` carries the minimize/restore/show callbacks, so the watcher stays
-- independent of the window layer that owns them.
function M.start(handlers)
  M.stop()
  local opts = config.options.auto
  if not opts.minimize_on_diff and not opts.restore_on_input and not opts.show_hidden then
    return
  end
  state.was_busy = false
  state.watch_timer = uv.new_timer()
  state.watch_timer:start(
    opts.watch_ms,
    opts.watch_ms,
    vim.schedule_wrap(function()
      if not state.buf_valid() then
        M.stop()
        return
      end
      local has_diff, mode = M.diff_step(handlers, true)
      local busy = has_diff or parser.is_working()

      -- The corner answers to restore_on_input, a hidden Claude to
      -- show_hidden. The screen cannot tell a request from a finished turn,
      -- so here either level acts on Claude settling.
      local comes_back = (mode == "corner" and opts.restore_on_input)
        or (mode == "hidden" and opts.show_hidden)
      if comes_back then
        -- Come back only after Claude has been idle long enough to be sure
        -- it is waiting for input / done -- not during the lull right
        -- after a diff is resolved (Claude resumes within that window
        -- and clears idle_since before the threshold).
        if busy then
          state.idle_since = nil
        elseif state.idle_since == nil then
          -- Start the idle clock only on a real busy->idle transition.
          if state.was_busy then
            state.idle_since = uv.now()
          end
        elseif (uv.now() - state.idle_since) >= opts.restore_idle_ms then
          state.idle_since = nil
          if mode == "hidden" then
            handlers.show()
          else
            handlers.restore()
          end
        end
      end
      state.was_busy = busy
    end)
  )
end

-- Record where Claude is as the mode to return to after a diff, once it has
-- stayed put for watch_ms with no diff on screen. The lag is the point, and it
-- is what the poll gave for free: claudecode's `:tabnew` makes WinLeave
-- minimize the float a moment before the diff lands, and that float -- not
-- the corner it just became -- is what the diff took away.
local function arm_settle()
  local timer = settle_timer or uv.new_timer() --[[@as uv.uv_timer_t]]
  settle_timer = timer
  timer:stop()
  timer:start(
    config.options.auto.watch_ms,
    0,
    vim.schedule_wrap(function()
      if state.buf_valid() and not parser.diff_visible() then
        state.last_mode = state.mode()
      end
    end)
  )
end

--- Follow diffs through window events, for a Claude heard through its hooks.
---@param handlers { minimize: fun(), restore: fun() }
function M.start_diffs(handlers)
  M.stop()
  local opts = config.options.auto
  if not opts.minimize_on_diff and not opts.restore_on_input then
    return
  end

  -- Several window events fire for one move; one check after them is enough.
  local queued = false
  local function check()
    if queued then
      return
    end
    queued = true
    vim.schedule(function()
      queued = false
      if state.buf_valid() then
        M.diff_step(handlers, false)
      end
    end)
  end

  local group = vim.api.nvim_create_augroup(DIFF_GROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave", "WinClosed", "TabClosed" }, {
    group = group,
    desc = "Follow edit-approval diffs for the Claude float",
    callback = check,
  })
  state.subscribe("watcher", arm_settle)
  arm_settle()
  -- A diff may already be up.
  check()
end

return M
