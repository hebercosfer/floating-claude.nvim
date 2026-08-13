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
  state.diff_seen = false
  state.was_busy = false
  state.idle_since = nil
end

-- Poll the live terminal/diff state and move the float in step with the cycle:
--   * float open + an edit-approval diff appears  -> minimize (the diff would
--     otherwise be hidden behind the float);
--   * float minimized + Claude settles idle       -> restore (Claude is now
--     waiting for the user or done), UNLESS a diff is still up (review that).
-- "Busy" = actively working OR a diff on screen. On screen, not merely loaded:
-- a diff the user denied and then closed leaves its proposed buffer hidden but
-- alive (see parser.lua), and counting that as busy resets the idle clock on
-- every poll, so the float never comes back at all.
--
-- Restore waits for SUSTAINED idle (`restore_idle_ms`) after a busy->idle
-- transition: the brief lull between a diff being approved/denied and Claude
-- resuming work is not enough to pop the float -- it only returns when
-- interaction is requested or the task completes.
-- The transition gating also means a manual minimize while Claude is already
-- idle is never fought (no busy->idle edge => idle_since never starts).
--
-- `handlers` carries the minimize/restore callbacks, so the watcher stays
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
      if state.win_valid() then
        if opts.minimize_on_diff and has_diff then
          if not state.diff_seen then
            state.diff_seen = true
            handlers.minimize()
          end
        elseif not has_diff then
          state.diff_seen = false
        end
      elseif opts.restore_on_input then
        -- Restore only after Claude has been idle long enough to be sure
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
          handlers.restore()
        end
      end
      state.was_busy = busy
    end)
  )
end

return M
