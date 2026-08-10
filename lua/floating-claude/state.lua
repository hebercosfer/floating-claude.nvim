-- Handles for the live Claude Code terminal and its two windows, shared by the
-- float, the corner notification and the watcher.

local M = {
  -- The terminal buffer and the big float showing it.
  buf = -1,
  win = -1,
  jobid = -1,
  -- The minimized "notification" window that tails the latest message.
  mini_buf = -1,
  mini_win = -1,
  mini_timer = nil,
  -- Background watcher that auto-minimizes on diffs and restores when idle.
  watch_timer = nil,
  diff_seen = false,
  was_busy = false,
  -- Timestamp (uv.now ms) of the busy->idle transition, for debouncing the
  -- auto-restore so the brief lull after a diff is resolved doesn't pop the
  -- float before Claude has resumed.
  idle_since = nil,
  -- Set while the plugin is moving windows itself. The focus autocmds cannot
  -- tell our own juggling from the user stepping away -- spawn() enters the
  -- float and then hands focus back, which would otherwise minimize Claude the
  -- instant it launches, and minimize() leaving the float would re-enter its
  -- own handler.
  suppress_auto = false,
}

function M.buf_valid()
  return M.buf ~= -1 and vim.api.nvim_buf_is_valid(M.buf)
end

function M.win_valid()
  return M.win ~= -1 and vim.api.nvim_win_is_valid(M.win)
end

function M.mini_buf_valid()
  return M.mini_buf ~= -1 and vim.api.nvim_buf_is_valid(M.mini_buf)
end

function M.mini_win_valid()
  return M.mini_win ~= -1 and vim.api.nvim_win_is_valid(M.mini_win)
end

return M
