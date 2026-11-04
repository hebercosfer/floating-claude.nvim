-- The big centered float: opening it, spawning the Claude Code job inside it,
-- and swapping between it and the corner notification.

local config = require("floating-claude.config")
local notification = require("floating-claude.notification")
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")
local watcher = require("floating-claude.watcher")

local M = {}

local group = vim.api.nvim_create_augroup("FloatingClaudeFocusFloat", { clear = false })

-- The plugin announces its own moves; :q, <C-w>c or :only on the float are
-- moves too, and a listener left believing Claude is maximized would never
-- bring a hidden Claude back. state.changed() stays quiet when nothing moved.
vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("FloatingClaudeAnnounce", { clear = true }),
  desc = "Announce where Claude is once one of its windows closes",
  callback = function()
    vim.schedule(state.changed)
  end,
})

--- Run `fn` with the focus autocmds disarmed.
---
--- Every window move the plugin makes itself looks exactly like the user
--- stepping away, and two of them would misfire badly: spawn() enters the float
--- and hands focus straight back when focus=false, which would minimize Claude
--- the instant it launched, and minimize() leaves the float on its way out,
--- which would re-enter its own handler.
---
--- The move is also announced once, where it ends (state.batch), rather than
--- step by step.
---@param fn fun()
local function quietly(fn)
  local was = state.suppress_auto
  state.suppress_auto = true
  local ok, err = pcall(state.batch, fn)
  state.suppress_auto = was
  if not ok then
    error(err, 0)
  end
end

-- Leaving the float means you are looking at something else, so get out of the
-- way. Any focus change counts -- a click elsewhere and a window command are
-- the same intent expressed two ways.
--
-- The minimize is deferred a tick, but the decision to minimize is not, and
-- the split matters.
--
-- Deferred action: claudecode.nvim's open_in_new_tab fires this same WinLeave
-- as a side effect of its own `:tabnew`, synchronously, before the tab switch
-- finishes -- so a notification opened inline binds its relative="editor"
-- window to the tab being left, not the diff tab the user is headed to.
-- Running it a tick later means nvim_get_current_tabpage() has settled.
--
-- Immediate decision: whether this leave is the user turning away or the
-- plugin moving its own windows is only knowable now, while the move that
-- fired it is still on the stack. quietly() clears suppress_auto as soon as
-- it returns, which is before any scheduled callback runs -- so reading the
-- flag from inside the deferred half would always find it false and minimize
-- Claude the instant spawn() handed focus back.
local function attach_leave(buf)
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  if not config.options.auto.minimize_on_leave then
    return
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    desc = "Minimize the Claude float when focus leaves it",
    callback = function()
      if state.suppress_auto or not state.win_valid() then
        return
      end
      vim.schedule(function()
        -- A tick has passed: the float may have been closed or minimized by
        -- something else in the meantime.
        if state.suppress_auto or not state.win_valid() then
          return
        end
        M.minimize()
      end)
    end,
  })
end

-- Float dimensions are fractions of the editor when <= 1, absolute cells above.
local function resolve(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.min(math.floor(value), total)
end

local function open_float()
  -- Bringing the full float back always dismisses the notification.
  notification.hide()

  local opts = config.options.float
  local width = resolve(opts.width, vim.o.columns)
  local height = resolve(opts.height, vim.o.lines)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local buf
  if state.buf_valid() then
    buf = state.buf
  else
    buf = vim.api.nvim_create_buf(false, true)
  end
  -- Here rather than in spawn(): every route to a visible float comes through
  -- this function, and re-attaching is idempotent.
  attach_leave(buf)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = opts.border,
    title = opts.title,
    title_pos = opts.title_pos,
  })

  state.buf = buf
  state.win = win
  return buf, win
end

-- Announced once, as the float: not the "hidden" it passes through after the
-- corner closes.
function M.open_window()
  local buf, win
  state.batch(function()
    buf, win = open_float()
  end)
  return buf, win
end

function M.hide_window()
  if state.win_valid() then
    vim.api.nvim_win_hide(state.win)
  end
  state.win = -1
  state.changed()
end

--- `opts.insert = false` lands in normal mode: what an automatic restore does,
--- so keys you were typing elsewhere cannot answer Claude's dialog.
---@param opts { insert: boolean|nil }|nil
function M.focus_window(opts)
  if state.win_valid() then
    vim.api.nvim_set_current_win(state.win)
    if not (opts and opts.insert == false) then
      vim.cmd("startinsert")
    end
  end
end

--- Notification controls ------------------------------------------------------

-- Collapse the float into the corner notification.
function M.minimize()
  if not state.buf_valid() then
    vim.notify("Claude Code is not running.", vim.log.levels.WARN)
    return
  end
  quietly(function()
    M.hide_window()
    notification.show()
  end)
end

-- Bring the full float back (also dismisses the notification).
---@param opts { insert: boolean|nil }|nil
function M.restore(opts)
  quietly(function()
    if state.buf_valid() then
      M.open_window()
      M.focus_window(opts)
    else
      notification.hide()
    end
  end)
end

-- Take Claude off the screen entirely -- neither the float nor the corner --
-- with the job still running. It comes back as the corner once it is waiting
-- on you (see watcher.lua), or as the float whenever you open it.
function M.hide()
  if not state.buf_valid() then
    vim.notify("Claude Code is not running.", vim.log.levels.WARN)
    return
  end
  quietly(function()
    M.hide_window()
    notification.hide()
  end)
  -- Hidden during a diff stays hidden once it closes: you put Claude out of
  -- sight, not the diff.
  if state.before_diff then
    state.before_diff = "hidden"
  end
end

-- Flip between the float and the corner notification.
function M.toggle_mini()
  if state.mini_win_valid() then
    M.restore()
  elseif state.win_valid() then
    M.minimize()
  elseif state.buf_valid() then
    notification.show()
  else
    vim.notify("Claude Code is not running.", vim.log.levels.WARN)
  end
end

--- Job ------------------------------------------------------------------------

function M.spawn(cmd_string, env_table, effective_config, focus)
  -- First spawn is the first moment we know which CLI binary claudecode.nvim
  -- launches, and the last moment before the scraping starts mattering.
  require("floating-claude.compat").check(cmd_string)

  local original_win = vim.api.nvim_get_current_win()
  M.open_window()

  local cmd_arg
  if cmd_string:find(" ", 1, true) then
    cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = false })
  else
    cmd_arg = { cmd_string }
  end
  -- Heard through its hooks, Claude starts with `--settings <file>` pointing
  -- them at the plugin's listener; otherwise the command is left as it is.
  cmd_arg = session.prepare(cmd_arg, cmd_string)

  state.jobid = vim.fn.termopen(cmd_arg, {
    env = env_table,
    cwd = effective_config and effective_config.cwd or nil,
    on_exit = function(job_id)
      vim.schedule(function()
        if job_id ~= state.jobid then
          return
        end
        watcher.stop()
        -- Only now: Claude acts on what its hooks reply, so the port stays
        -- ours for as long as Claude runs.
        session.stop()
        notification.hide()
        if state.win_valid() and (not effective_config or effective_config.auto_close ~= false) then
          vim.api.nvim_win_close(state.win, true)
        end
        if state.buf_valid() then
          vim.api.nvim_buf_delete(state.buf, { force = true })
        end
        state.buf = -1
        state.win = -1
        state.jobid = -1
      end)
    end,
  })

  if not state.jobid or state.jobid <= 0 then
    vim.notify("Failed to open Claude floating terminal.", vim.log.levels.ERROR)
    session.stop()
    if state.win_valid() then
      vim.api.nvim_win_close(state.win, true)
    end
    state.buf, state.win, state.jobid = -1, -1, -1
    return false
  end

  vim.bo[state.buf].bufhidden = "hide"

  -- Minimize straight from the terminal without leaving insert mode.
  local minimize_key = config.options.keymaps.minimize
  if minimize_key then
    vim.keymap.set("t", minimize_key, function()
      M.minimize()
    end, { buffer = state.buf, desc = "Minimize Claude to a corner notification" })
  end

  -- Restores the plugin makes on its own -- a request, a finished turn, a diff
  -- resolved -- leave insert mode to you.
  local function restore_quietly()
    M.restore({ insert = false })
  end
  local handlers = { minimize = M.minimize, restore = restore_quietly, show = notification.show }
  if session.active() then
    -- Busy and idle come from Claude's events; only diffs need watching, and
    -- only when windows change. Should the events never arrive after all, the
    -- session falls back to the screen poll.
    session.attach({
      restore = restore_quietly,
      show = notification.show,
      fallback = function()
        watcher.start(handlers)
      end,
    })
    watcher.start_diffs(handlers)
  else
    watcher.start(handlers)
  end

  -- Handing focus back is our own move, not the user turning away: without the
  -- guard, launching with focus=false would minimize Claude on the spot.
  quietly(function()
    if focus ~= false then
      M.focus_window()
    elseif vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
  end)
  return true
end

function M.close()
  watcher.stop()
  -- Our own move: unguarded, the float's WinLeave would schedule a minimize
  -- that lands on whatever float is up by then -- the next Claude's.
  quietly(function()
    notification.hide()
    if state.win_valid() then
      vim.api.nvim_win_close(state.win, true)
    end
  end)
  if state.jobid and state.jobid > 0 then
    vim.fn.jobstop(state.jobid)
    -- The listener goes only once Claude has: on_exit will not do it for a
    -- job this forgets below.
    vim.fn.jobwait({ state.jobid }, 2000)
  end
  session.stop()
  state.buf, state.win, state.jobid = -1, -1, -1
end

return M
