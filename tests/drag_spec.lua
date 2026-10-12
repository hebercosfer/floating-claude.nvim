-- Dragging the corner out of the way of what is under it. Headless Neovim has
-- no UI to deliver mouse events to, so these drive the handlers the mappings
-- call with what getmousepos() would have said; the mappings themselves are
-- only checked for being there.

local config = require("floating-claude.config")
local drag = require("floating-claude.drag")
local notification = require("floating-claude.notification")
local state = require("floating-claude.state")

-- Where the corner sits: row and col are its top-left border cell, 0-based.
local function corner()
  local c = vim.api.nvim_win_get_config(state.mini_win)
  return c.row, c.col, c.height, c.width
end

-- The mouse over a 0-based cell, the way getmousepos() reports it: 1-based.
local function at(row, col)
  return { screenrow = row + 1, screencol = col + 1 }
end

describe("drag", function()
  before_each(function()
    config.setup({})
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "Done." })
    notification.show()
  end)

  after_each(function()
    notification.hide()
    if state.win_valid() then
      vim.api.nvim_win_close(state.win, true)
    end
    vim.api.nvim_buf_delete(state.buf, { force = true })
    state.buf, state.win, state.mini_buf, state.mini_win = -1, -1, -1, -1
    state.mini_pos = nil
    drag.release(at(0, 0))
    config.setup({})
  end)

  it("picks the corner up by its body", function()
    local row, col = corner()
    assert.is_true(drag.press(at(row + 1, col + 3)))
  end)

  it("picks it up by its border, title and all", function()
    local row, col = corner()
    assert.is_true(drag.press(at(row, col + 10)))
  end)

  it("lets a press anywhere else through", function()
    assert.is_false(drag.press(at(0, 0)))
    assert.is_false(drag.move(at(1, 1)), "a drag that never started moved something")
  end)

  it("ignores a corner that lives in another tab", function()
    local row, col = corner()
    vim.cmd("tabnew")
    assert.is_false(drag.press(at(row + 1, col + 3)), "grabbed a window that is not on screen")
    vim.cmd("tabclose")
  end)

  it("moves it with the mouse, and the next redraw keeps it there", function()
    local row, col = corner()
    drag.press(at(row + 1, col + 3))
    assert.is_true(drag.move(at(row - 9, col - 10)))
    vim.wait(50)
    local moved_row, moved_col = corner()
    assert.same({ row - 10, col - 13 }, { moved_row, moved_col })

    drag.release(at(row - 9, col - 10))
    notification.show()
    local kept_row, kept_col = corner()
    assert.same(
      { row - 10, col - 13 },
      { kept_row, kept_col },
      "the redraw put it back in the corner"
    )
  end)

  it("keeps it on screen however far the mouse goes", function()
    local row, col = corner()
    drag.press(at(row + 1, col + 3))
    drag.move(at(-50, -50))
    vim.wait(50)
    local top, left = corner()
    assert.same({ 0, 0 }, { top, left })

    drag.move(at(500, 500))
    vim.wait(50)
    local bottom, right, height, width = corner()
    assert.is_true(bottom + height + 2 <= vim.o.lines - vim.o.cmdheight, "off the bottom")
    assert.is_true(right + width + 2 <= vim.o.columns, "off the right")
  end)

  it("lets go on release", function()
    local row, col = corner()
    drag.press(at(row + 1, col + 3))
    drag.move(at(row - 2, col - 2))
    assert.is_true(drag.release(at(row - 2, col - 2)))
    assert.is_false(drag.move(at(row - 5, col - 5)), "still dragging after the button came up")
  end)

  it("brings Claude back on a click that did not move", function()
    local row, col = corner()
    drag.press(at(row + 1, col + 3))
    drag.release(at(row + 1, col + 3))
    assert.is_true(
      vim.wait(200, function()
        return state.win_valid()
      end, 10),
      "a click on the corner stopped restoring it"
    )
  end)

  it("brings nothing back from a drag", function()
    local row, col = corner()
    drag.press(at(row + 1, col + 3))
    drag.move(at(row - 2, col - 2))
    drag.release(at(row - 2, col - 2))
    vim.wait(100)
    assert.is_false(state.win_valid(), "dropping the corner opened the float")
  end)

  it("leaves a still click alone with restore_on_enter off", function()
    config.setup({ auto = { restore_on_enter = false } })
    local row, col = corner()
    drag.press(at(row + 1, col + 3))
    drag.release(at(row + 1, col + 3))
    vim.wait(100)
    assert.is_false(state.win_valid())
  end)

  it("stays where it is with draggable off", function()
    config.setup({ notification = { draggable = false } })
    local row, col = corner()
    assert.is_false(drag.press(at(row + 1, col + 3)))
  end)

  describe("mappings", function()
    local function mapped()
      return vim.fn.maparg("<LeftMouse>", "n", false, true)
    end

    it("are down while the corner is up, and gone with it", function()
      assert.is_true(mapped().callback ~= nil, "showing the corner did not map the mouse")
      notification.hide()
      assert.same({}, mapped())
    end)

    it("hand back a mouse mapping of your own", function()
      notification.hide()
      vim.keymap.set("n", "<LeftMouse>", "<LeftMouse>", { desc = "mine" })
      notification.show()
      notification.hide()
      assert.equals("mine", mapped().desc)
      vim.keymap.del("n", "<LeftMouse>")
    end)
  end)
end)
