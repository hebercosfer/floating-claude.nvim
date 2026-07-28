-- The claudecode.nvim terminal provider interface:
--   setup, open, close, simple_toggle, focus_toggle, get_active_bufnr,
--   is_available, ensure_visible
--
-- Wire it up with:
--   require("claudecode").setup({
--     terminal = { provider = require("floating-claude").provider },
--   })

local notification = require("floating-claude.notification")
local state = require("floating-claude.state")
local terminal = require("floating-claude.terminal")

local M = {}

-- claudecode.nvim hands us its own terminal config here. The float's style is
-- configured through require("floating-claude").setup() instead, so there is
-- nothing to take from it.
function M.setup(_term_config) end

function M.open(cmd_string, env_table, effective_config, focus)
  if state.buf_valid() then
    if not state.win_valid() then
      -- Process alive but hidden: reattach the buffer to a new float.
      terminal.open_window()
    end
    -- Opening or maximizing the float always lands you in Claude. (The
    -- no-focus "ensure visible" path is handled by M.ensure_visible, which
    -- never reaches here, so this is unconditionally a deliberate open.)
    terminal.focus_window()
  else
    terminal.spawn(cmd_string, env_table, effective_config, focus)
  end
end

function M.close()
  terminal.close()
end

function M.simple_toggle(cmd_string, env_table, effective_config)
  if state.win_valid() then
    terminal.hide_window()
  elseif state.buf_valid() then
    terminal.open_window()
    terminal.focus_window()
  else
    terminal.spawn(cmd_string, env_table, effective_config, true)
  end
end

function M.focus_toggle(cmd_string, env_table, effective_config)
  if state.win_valid() then
    if vim.api.nvim_get_current_win() == state.win then
      terminal.hide_window()
    else
      terminal.focus_window()
    end
  elseif state.buf_valid() then
    terminal.open_window()
    terminal.focus_window()
  else
    terminal.spawn(cmd_string, env_table, effective_config, true)
  end
end

function M.get_active_bufnr()
  if state.buf_valid() then
    return state.buf
  end
  return nil
end

function M.is_available()
  return true
end

-- claudecode.nvim calls this (terminal.ensure_visible) to keep Claude on screen
-- WITHOUT stealing focus -- notably during diff cleanup after an accept/deny.
-- We deliberately do NOT pop the big float here: when minimized we stay
-- minimized, so the float only returns once the watcher decides Claude is
-- waiting for input or done. We just make sure Claude stays represented -- as
-- the corner notification when nothing is currently shown. (Defining this also
-- short-circuits the plugin's fallback, which would otherwise reopen the float
-- via open(focus=false).)
function M.ensure_visible()
  if state.win_valid() or state.mini_win_valid() then
    return true
  end
  if state.buf_valid() then
    notification.show()
    return true
  end
  return false
end

return M
