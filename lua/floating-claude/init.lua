-- floating-claude.nvim
--
-- A floating-window terminal provider for claudecode.nvim: Claude Code opens in
-- a centered float instead of a split, and collapses into a small corner
-- notification -- automatically when an edit-approval diff needs the screen,
-- and back again once Claude is waiting on you.
--
--   require("floating-claude").setup()   -- sets claudecode.nvim up as well
--
-- or, keeping claudecode.nvim as the plugin you set up:
--
--   require("claudecode").setup({
--     terminal = { provider = require("floating-claude").provider },
--   })

local config = require("floating-claude.config")

local M = {}

--- This plugin's version: tostring(M.version) or M.version:string().
M.version = require("floating-claude.version")

-- The claudecode.nvim terminal provider table.
M.provider = require("floating-claude.provider")

-- Whether claudecode.nvim is someone else's to set up: it is set up already,
-- or its own lazy.nvim spec will do it -- after this one, when this plugin is
-- its dependency. Setting it up twice warns that it is already running.
local function set_up_elsewhere(claudecode)
  if vim.tbl_get(claudecode, "state", "initialized") then
    return true
  end
  local ok, lazy = pcall(require, "lazy.core.config")
  local spec = ok and type(lazy.plugins) == "table" and lazy.plugins["claudecode.nvim"] or nil
  return spec ~= nil and (spec.opts ~= nil or spec.config ~= nil)
end

local function set_up_claudecode(opts)
  if opts == false then
    return
  end
  local ok, claudecode = pcall(require, "claudecode")
  if not ok then
    local missing = tostring(claudecode):find("module 'claudecode' not found", 1, true)
    vim.notify(
      missing
          and "floating-claude: claudecode.nvim is not installed. Add coder/claudecode.nvim, or set claudecode = false to set it up yourself."
        or ("floating-claude: claudecode.nvim failed to load: " .. tostring(claudecode)),
      vim.log.levels.WARN
    )
    return
  end
  if set_up_elsewhere(claudecode) then
    return
  end
  -- `terminal = {}` makes the merge build a table of its own rather than
  -- borrow yours, so the provider goes in without touching your options.
  local merged = vim.tbl_deep_extend("force", {
    terminal = {},
    diff_opts = {
      -- Each diff in a full-screen tab of its own, without the terminal as a
      -- split beside it: the float minimizes to the corner when a diff opens,
      -- so the tab is just old | proposed.
      open_in_new_tab = true,
      hide_terminal_in_new_tab = true,
    },
  }, opts or {})
  if merged.terminal.provider == nil then
    merged.terminal.provider = M.provider
  end
  claudecode.setup(merged)
end

--- Configure the float and the corner notification, set claudecode.nvim up to
--- use them, and map claudecode.nvim's commands. Optional when claudecode.nvim
--- is set up by hand with this provider; the defaults in config.lua apply
--- as-is when it is never called.
function M.setup(opts)
  config.setup(opts)
  require("floating-claude.keymaps").apply()
  local keys = require("floating-claude.keys")
  keys.apply(keys.resolve(config.options.keys))
  set_up_claudecode(config.options.claudecode)
end

--- Collapse the float into the corner notification.
function M.minimize()
  require("floating-claude.terminal").minimize()
end

--- Bring the full float back (also dismisses the notification).
function M.restore()
  require("floating-claude.terminal").restore()
end

--- Take Claude off the screen, float and notification both, leaving it running.
--- It comes back as the notification once it is waiting on you.
function M.hide()
  require("floating-claude.terminal").hide()
end

--- Flip between the float and the corner notification.
function M.toggle_mini()
  require("floating-claude.terminal").toggle_mini()
end

--- Open the latest events the plugin heard from Claude, as Claude sent them,
--- in a buffer: what it listens to, where, and what it keeps.
function M.events()
  require("floating-claude.events_view").open()
end

--- Whether Claude Code is currently running in the float.
function M.is_running()
  return require("floating-claude.state").buf_valid()
end

--- Run the guided tour: the float, the corner and the watcher, driven by a
--- scripted stand-in for Claude. Needs neither claudecode.nvim nor the CLI.
--- `opts.auto` makes the moves it would otherwise ask you for.
---@param opts { auto: boolean|nil }|nil
function M.demo(opts)
  require("floating-claude.demo").start(opts)
end

--- End the tour early, putting back everything it borrowed.
function M.demo_stop()
  require("floating-claude.demo").stop()
end

return M
