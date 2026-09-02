-- A guided tour of the plugin, driven from a script, for looking at and for
-- recording.
--
-- The float, the corner notification and the watcher are the real ones: the
-- tour only stands in for the two things it cannot ask for on demand -- a
-- Claude Code session (demo/tui.lua) and an edit approval to resolve
-- (demo/diff.lua) -- and narrates the rest from a caption window. That is what
-- lets it run with nothing else installed, and what makes a recording of it
-- come out the same way twice.
--
-- It borrows the plugin's own state for its duration: state.buf is the tour's
-- scratch buffer, and config.options is the defaults, so what the captions
-- claim is what is on screen. stop() puts both back.

local caption = require("floating-claude.demo.caption")
local config = require("floating-claude.config")
local diff = require("floating-claude.demo.diff")
local highlights = require("floating-claude.highlights")
local notification = require("floating-claude.notification")
local script = require("floating-claude.demo.script")
local state = require("floating-claude.state")
local terminal = require("floating-claude.terminal")
local tui = require("floating-claude.demo.tui")
local watcher = require("floating-claude.watcher")

local uv = vim.uv or vim.loop

local M = {}

-- How often the tour looks at the clock and at the plugin's state. Fine enough
-- that a click feels like it advanced the beat, coarse enough to be free.
local TICK_MS = 80

-- Defaults for a beat that does not say otherwise: how long one you only have
-- to look at stays up, how long one that is waiting for you waits before
-- giving up on you, and how long the hands-free run pauses before making the
-- move itself.
local HOLD_MS = 5000
local TIMEOUT_MS = 90000
local AUTO_MS = 2200

---@type table|nil
M.tour = nil

function M.running()
  return M.tour ~= nil
end

local function stop_timer()
  if M.tour and M.tour.timer then
    M.tour.timer:stop()
    if not M.tour.timer:is_closing() then
      M.tour.timer:close()
    end
    M.tour.timer = nil
  end
end

--- Beats -----------------------------------------------------------------------

local function enter(index)
  local tour = M.tour
  local beat = tour.steps[index]
  tour.index = index
  tour.beat = beat
  tour.entered_at = uv.now()
  tour.fired = {}
  tour.acted = false
  tour.card = {
    title = beat.title,
    lines = beat.lines,
    hint = beat.hint,
    foot = beat.foot,
    index = index,
    total = #tour.steps,
  }
  caption.show(tour.card)
  if beat.enter then
    beat.enter()
  end
end

local function advance()
  local tour = M.tour
  if tour.beat and tour.beat.exit then
    tour.beat.exit()
  end
  if tour.index >= #tour.steps then
    M.stop()
    return
  end
  enter(tour.index + 1)
end

local function tick()
  local tour = M.tour
  -- Something took the float away -- :ClaudeCode, a :bwipeout, a closed tab.
  -- Whatever it was, the tour no longer owns what it is narrating.
  if not state.buf_valid() or state.buf ~= tui.buf then
    M.stop()
    return
  end
  -- The stand-in diff opens in its own tab, and an editor-relative window
  -- belongs to the tab it was created in, so the caption follows.
  if caption.stale() then
    caption.show(tour.card)
  end

  local beat = tour.beat
  local elapsed = uv.now() - tour.entered_at

  for i, at in ipairs(beat.beats or {}) do
    if not tour.fired[i] and elapsed >= at[1] then
      tour.fired[i] = true
      at[2]()
    end
  end

  if tour.auto and beat.auto and not tour.acted and elapsed >= (beat.auto_ms or AUTO_MS) then
    tour.acted = true
    beat.auto()
  end

  local over
  if beat.done then
    -- Waiting for you, but not forever: an unattended tour still finishes.
    over = beat.done() or elapsed >= (beat.timeout_ms or TIMEOUT_MS)
  else
    over = elapsed >= (beat.hold_ms or HOLD_MS)
  end
  if over then
    advance()
  end
end

--- Running ---------------------------------------------------------------------

--- Start the tour. `opts.auto` runs it hands-free, making the moves it would
--- otherwise ask you for -- which is the one to record unattended.
---@param opts { auto: boolean|nil }|nil
function M.start(opts)
  opts = opts or {}
  if M.running() then
    vim.notify(
      "The floating-claude tour is already running (:FloatingClaudeDemo stop).",
      vim.log.levels.WARN
    )
    return
  end
  if state.buf_valid() then
    vim.notify(
      "Claude Code is running in the float. Close it before the tour borrows it.",
      vim.log.levels.WARN
    )
    return
  end
  if vim.o.columns < 80 or vim.o.lines < 20 then
    vim.notify("The tour wants an editor at least 80x20.", vim.log.levels.WARN)
    return
  end

  M.tour = {
    auto = opts.auto == true,
    index = 0,
    -- Handed back by stop(), whichever way the tour ends.
    saved = { options = config.options, mouse = vim.o.mouse },
  }

  -- The captions describe the defaults, so the tour runs on them.
  config.setup({})
  -- Half the tour is things to click, and a click reaches a floating window
  -- only when the mouse is enabled at all.
  if not vim.o.mouse:find("[an]") then
    vim.o.mouse = "a"
  end
  highlights.ensure()

  local buf = vim.api.nvim_create_buf(false, true)
  state.buf, state.jobid = buf, -1
  terminal.open_window()
  -- Focusing the float means terminal mode in a real session, and terminal.lua
  -- asks for it with startinsert. The stand-in is a scratch buffer, so what
  -- that lands in is insert mode: nothing to type into, an "-- INSERT --" over
  -- the captions, and the tour's own normal-mode keys shadowed.
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = buf,
    group = vim.api.nvim_create_augroup("FloatingClaudeDemo", { clear = true }),
    desc = "Keep the tour's stand-in terminal out of insert mode",
    callback = function()
      -- Scheduled: called straight from the autocommand, :stopinsert does not
      -- take, and the tour spends the rest of its life in insert mode.
      vim.schedule(function()
        vim.cmd("stopinsert")
      end)
    end,
  })
  vim.cmd("stopinsert")
  tui.open(buf, vim.api.nvim_win_get_width(state.win), vim.api.nvim_win_get_height(state.win))

  local key = config.options.keymaps.minimize
  if key then
    for _, mode in ipairs({ "n", "i", "t" }) do
      vim.keymap.set(mode, key, function()
        terminal.minimize()
      end, { buffer = buf, desc = "Minimize Claude to a corner notification" })
    end
  end

  watcher.start({ minimize = terminal.minimize, restore = terminal.restore })

  M.tour.steps = script.build()
  M.tour.timer = uv.new_timer()
  M.tour.timer:start(
    TICK_MS,
    TICK_MS,
    vim.schedule_wrap(function()
      if not M.running() then
        return
      end
      local ok, err = pcall(tick)
      if not ok then
        M.stop()
        vim.notify("floating-claude tour: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  )
  enter(1)
end

--- End the tour and put back everything it borrowed.
function M.stop()
  local tour = M.tour
  if not tour then
    return
  end
  stop_timer()
  M.tour = nil

  if tour.beat and tour.beat.exit then
    pcall(tour.beat.exit)
  end
  watcher.stop()
  diff.close()
  caption.hide()
  notification.hide()
  if state.win_valid() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = -1
  tui.close()
  state.buf, state.jobid = -1, -1

  config.options = tour.saved.options
  vim.o.mouse = tour.saved.mouse
end

return M
