-- floating-claude.nvim
--
-- A floating-window terminal provider for claudecode.nvim: Claude Code opens in
-- a centered float instead of a split, and collapses into a small corner
-- notification -- automatically when an edit-approval diff needs the screen,
-- and back again once Claude is waiting on you.
--
--   require("claudecode").setup({
--     terminal = { provider = require("floating-claude").provider },
--   })

local config = require("floating-claude.config")

local M = {}

--- This plugin's version: tostring(M.version) or M.version:string() -> "0.1.0".
M.version = require("floating-claude.version")

-- The claudecode.nvim terminal provider table.
M.provider = require("floating-claude.provider")

--- Configure the float and the corner notification. Optional; the defaults in
--- config.lua apply as-is when it is never called.
function M.setup(opts)
  config.setup(opts)
end

--- Collapse the float into the corner notification.
function M.minimize()
  require("floating-claude.terminal").minimize()
end

--- Bring the full float back (also dismisses the notification).
function M.restore()
  require("floating-claude.terminal").restore()
end

--- Flip between the float and the corner notification.
function M.toggle_mini()
  require("floating-claude.terminal").toggle_mini()
end

--- Whether Claude Code is currently running in the float.
function M.is_running()
  return require("floating-claude.state").buf_valid()
end

return M
