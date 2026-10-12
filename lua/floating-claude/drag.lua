-- Dragging the corner notification with the mouse, so it can be moved off the
-- part of the screen you are reading -- the end of a file, most often, since
-- the corner sits on the bottom right.
--
-- Neovim drags nothing but status lines and separators, so this takes the left
-- button itself, and only while the corner is up: a press inside the corner
-- (its border included) picks it up instead of reaching the window, the drag
-- moves it, and a release ends it. Anything outside the corner is handed
-- straight on. A press and release that never moved is a click, and does what
-- clicking the corner always did -- bring the float back.
--
-- Where you drop it lives in `state.mini_pos` for the rest of the session: the
-- notification lays itself out again on every refresh, and would otherwise put
-- itself straight back in the corner.

local config = require("floating-claude.config")
local state = require("floating-claude.state")

local M = {}

-- The press in progress: where in the corner it grabbed, and whether it has
-- moved since. nil when the button is up.
local held

local KEYS = { "<LeftMouse>", "<LeftDrag>", "<LeftRelease>" }
local MODES = { "n", "i", "v" }

-- Mappings of the user's own that ours displaced, to put back on detach.
local displaced = nil

--- Where a `height` x `width` corner goes: where it was dropped, kept on
--- screen, or the bottom-right corner when it never was. The border is one
--- cell outside each edge, and the command line stays clear.
---@return integer row, integer col
function M.place(height, width)
  if not state.mini_pos then
    return math.max(1, vim.o.lines - height - 3), math.max(1, vim.o.columns - width - 2)
  end
  local bottom = vim.o.lines - vim.o.cmdheight - height - 2
  local right = vim.o.columns - width - 2
  local row = math.max(0, math.min(bottom, state.mini_pos.row))
  local col = math.max(0, math.min(right, state.mini_pos.col))
  return row, col
end

-- The corner's top-left border cell and its outer size, when it is on screen
-- in this tab.
local function frame()
  if not state.mini_win_valid() then
    return nil
  end
  if vim.api.nvim_win_get_tabpage(state.mini_win) ~= vim.api.nvim_get_current_tabpage() then
    return nil
  end
  local cfg = vim.api.nvim_win_get_config(state.mini_win)
  return math.floor(cfg.row), math.floor(cfg.col), cfg.height + 2, cfg.width + 2
end

--- A button press at `mouse` (getmousepos()'s shape). True when it landed on
--- the corner and was taken.
function M.press(mouse)
  held = nil
  if not config.options.notification.draggable then
    return false
  end
  local row, col, height, width = frame()
  if not row then
    return false
  end
  local r, c = mouse.screenrow - 1, mouse.screencol - 1
  if r < row or r >= row + height or c < col or c >= col + width then
    return false
  end
  held = { dr = r - row, dc = c - col, moved = false }
  return true
end

--- The mouse moving with the button down. True when it is carrying the corner.
function M.move(mouse)
  if not held then
    return false
  end
  local _, _, height, width = frame()
  if not height then
    held = nil
    return false
  end
  state.mini_pos = { row = mouse.screenrow - 1 - held.dr, col = mouse.screencol - 1 - held.dc }
  local row, col = M.place(height - 2, width - 2)
  state.mini_pos = { row = row, col = col }
  held.moved = true
  -- Called from an <expr> mapping, where moving windows is off limits.
  vim.schedule(function()
    if state.mini_win_valid() then
      vim.api.nvim_win_set_config(state.mini_win, { relative = "editor", row = row, col = col })
    end
  end)
  return true
end

--- The button coming up. True when it ends a press on the corner.
function M.release()
  local was = held
  held = nil
  if not was then
    return false
  end
  if not was.moved and config.options.auto.restore_on_enter then
    vim.schedule(function()
      -- Required lazily: terminal.lua requires notification.lua, which
      -- requires this.
      require("floating-claude.terminal").restore()
    end)
  end
  return true
end

--- Whether a press on the corner is still held down.
function M.dragging()
  return held ~= nil
end

local HANDLERS =
  { ["<LeftMouse>"] = M.press, ["<LeftDrag>"] = M.move, ["<LeftRelease>"] = M.release }

--- Take the left button while the corner is up. Idempotent.
function M.attach()
  if displaced or not config.options.notification.draggable then
    return
  end
  displaced = {}
  for _, mode in ipairs(MODES) do
    for _, lhs in ipairs(KEYS) do
      -- A buffer-local mapping outranks ours anyway, so only a global one is
      -- displaced.
      local mine = vim.fn.maparg(lhs, mode, false, true)
      if next(mine) and mine.buffer == 0 then
        table.insert(displaced, mine)
      end
      local handler = HANDLERS[lhs]
      vim.keymap.set(mode, lhs, function()
        if handler(vim.fn.getmousepos()) then
          return ""
        end
        return vim.keycode(lhs)
      end, { expr = true, replace_keycodes = false, desc = "floating-claude: drag the corner" })
    end
  end
end

--- Give the left button back, and whatever mapping it had before.
function M.detach()
  if not displaced then
    return
  end
  held = nil
  for _, mode in ipairs(MODES) do
    for _, lhs in ipairs(KEYS) do
      pcall(vim.keymap.del, mode, lhs)
    end
  end
  for _, mine in ipairs(displaced) do
    vim.fn.mapset(mine)
  end
  displaced = nil
end

return M
