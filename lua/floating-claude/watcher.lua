-- Background poller that moves the float in step with Claude's work cycle.

local config = require("floating-claude.config")
local parser = require("floating-claude.parser")
local state = require("floating-claude.state")

local uv = vim.uv or vim.loop

local M = {}

function M.stop()
  if state.watch_timer then
    state.watch_timer:stop()
    if not state.watch_timer:is_closing() then
      state.watch_timer:close()
    end
    state.watch_timer = nil
  end
  state.last_mode = nil
  state.before_diff = nil
  state.was_busy = false
  state.idle_since = nil
end

-- Poll the live terminal/diff state and move the float in step with the cycle:
--   * float open + an edit-approval diff appears  -> minimize (the diff would
--     otherwise be hidden behind the float);
--   * the diff closes                             -> back to what Claude was
--     before it opened: the float comes straight back, the corner and hidden
--     stay as they are;
--   * minimized + Claude settles idle             -> restore (Claude is now
--     waiting for the user or done), UNLESS a diff is still up (review that);
--   * hidden + Claude settles idle                -> the corner, so you hear
--     about it without the float landing on your work.
-- "Busy" = actively working OR a diff on screen. On screen, not merely loaded:
-- a diff the user denied and then closed leaves its proposed buffer hidden but
-- alive (see parser.lua), and counting that as busy resets the idle clock on
-- every poll, so the float never comes back at all.
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
  if not opts.minimize_on_diff and not opts.restore_on_input then
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
      local has_diff = parser.diff_visible()
      local busy = has_diff or parser.is_working()
      local mode = state.mode()

      if has_diff and state.before_diff == nil then
        -- The first poll to see this diff. What Claude was comes from the poll
        -- before, not from now: the diff opens in its own tab, and the
        -- WinLeave claudecode's `:tabnew` fires has usually collapsed the float
        -- through `minimize_on_leave` before this runs.
        state.before_diff = state.last_mode or mode
        -- Still up only when nothing else got there first. Minimize it once,
        -- here, and never on a later poll: the user bringing the float back
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
        state.last_mode = mode
      end

      if mode ~= "float" and opts.restore_on_input then
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

return M
