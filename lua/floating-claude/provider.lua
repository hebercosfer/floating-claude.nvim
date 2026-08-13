-- The claudecode.nvim terminal provider interface:
--   setup, open, close, simple_toggle, focus_toggle, get_active_bufnr,
--   is_available, ensure_visible
--
-- Wire it up with:
--   require("claudecode").setup({
--     terminal = { provider = require("floating-claude").provider },
--   })

local notification = require("floating-claude.notification")
local parser = require("floating-claude.parser")
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

-- claudecode.nvim calls this (terminal.ensure_visible) whenever it wants Claude
-- on screen: during diff cleanup after an accept/deny, and after a send such as
-- :ClaudeCodeSend, which routes here rather than to open() unless
-- focus_after_send is set.
--
-- Those two callers want opposite things from a minimized Claude, and the
-- interface gives us no way to tell them apart -- so ask the screen instead. A
-- diff on display is the one reason to stay in the corner; that is what the
-- notification is for. With no diff pending, the caller asked for Claude and a
-- corner notification is not what they meant.
--
-- The diff-cleanup call is the subtle one, and it is why this asks
-- diff_pending() (does a proposed buffer exist) where the watcher asks
-- diff_visible() (is one on screen). It arrives from diff.lua right after the
-- diff tab is closed, which sounds like "no diff pending" -- but the proposed
-- buffer is scratch with bufhidden="hide", so closing its window only hides it
-- and it stays loaded until the deletion a few lines later. diff_pending()
-- looks at loaded buffers, so it still reports true and we take the branch
-- above. The post-diff restore therefore remains the watcher's, gated on
-- restore_idle_ms, which is what stops the float flapping back over your work
-- during the lull before Claude resumes -- once per edit in a multi-edit turn.
-- If upstream ever wipes that buffer instead of hiding it, this call starts
-- restoring immediately and that gating is lost.
--
-- The cost of keeping the wider predicate here: a leftover hidden proposed
-- buffer (a denied diff whose tab the user closed) also holds this branch, so
-- a send in that state stays in the corner. The watcher restores within
-- restore_idle_ms of the deny, which closes the window in which that can
-- happen -- unless restore_on_input is off, and then staying put is at least
-- the setting the user asked for.
--
-- Restoring takes focus, which upstream's no-focus intent argues against. The
-- float is most of the editor: bringing it back over your buffer while the
-- cursor stayed behind it would hide the very thing you were looking at, and
-- send your typing somewhere you cannot see. Landing in Claude is the lesser
-- surprise. Users who want the cursor left alone can keep Claude minimized.
--
-- (Defining this also short-circuits the plugin's fallback, which would
-- otherwise reopen the float via open(focus=false).)
function M.ensure_visible()
  if state.win_valid() then
    return true
  end
  if state.mini_win_valid() then
    if parser.diff_pending() then
      return true
    end
    terminal.restore()
    return true
  end
  if state.buf_valid() then
    notification.show()
    return true
  end
  return false
end

return M
