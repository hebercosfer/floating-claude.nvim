-- User-facing configuration and defaults.

local M = {}

M.defaults = {
  -- The big centered float that hosts the Claude Code terminal.
  float = {
    -- Fractions of the editor (<= 1) or absolute cells (> 1).
    width = 0.8,
    height = 0.8,
    border = "rounded",
    title = " Claude Code ",
    title_pos = "center",
  },

  -- The small corner window Claude collapses into when minimized. It tails
  -- the live status/spinner line plus the message paragraph above it.
  notification = {
    width = 64,
    max_height = 12,
    -- How often the notification re-reads the terminal buffer.
    refresh_ms = 250,
    -- Hard cap on the number of terminal lines tailed.
    max_lines = 12,
    -- Blank-line separators the tail may cross before it stops, so the live
    -- status line can pull in the message paragraph that precedes it.
    gaps = 1,
    border = "rounded",
    title = " Claude ",
    title_pos = "center",
    zindex = 60,
  },

  auto = {
    -- Minimize the float when an edit-approval diff opens, so the diff -- which
    -- the float would otherwise cover -- is visible.
    minimize_on_diff = true,
    -- Restore the float once Claude finishes and waits for input (but not while
    -- a diff is up -- you are reviewing that).
    restore_on_input = true,
    -- Sustained idle required before auto-restoring. This debounce is what
    -- keeps the brief lull between a diff being resolved and Claude resuming
    -- from popping the float back over your work.
    restore_idle_ms = 1200,
    -- How often the watcher polls the terminal and diff state.
    watch_ms = 300,
  },

  keymaps = {
    -- Terminal-mode mapping, set in the Claude buffer, to minimize without
    -- leaving insert mode. Set to false to skip it. The default chord avoids
    -- Alt (swallowed by some terminals) and Claude's own keys.
    minimize = "<C-x><C-m>",
  },

  -- Warn once per session when the installed claudecode.nvim / Claude Code
  -- versions are older than the pair this plugin is built against (see
  -- compat.lua). Nothing is scraped through a stable API, so a mismatch shows
  -- up as an auto-minimize that quietly stops working. Set to false to silence.
  version_check = true,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
