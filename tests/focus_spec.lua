-- Moving focus is the mouse-friendly path: leaving the float collapses it,
-- entering the notification brings it back. Both hang off autocmds, and the
-- interesting part is not that they fire but that they stay quiet when the
-- plugin is the one moving windows.

local config = require("floating-claude.config")
local notification = require("floating-claude.notification")
local state = require("floating-claude.state")
local terminal = require("floating-claude.terminal")

--- A window that is not Claude's, to move focus to and from.
local function elsewhere()
  vim.cmd("new")
  return vim.api.nvim_get_current_win()
end

describe("focus", function()
  local other

  before_each(function()
    config.setup({})
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "Done." })
  end)

  after_each(function()
    notification.hide()
    if state.win_valid() then
      vim.api.nvim_win_close(state.win, true)
    end
    if other and vim.api.nvim_win_is_valid(other) then
      vim.api.nvim_win_close(other, true)
    end
    other = nil
    if state.buf ~= -1 and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_delete(state.buf, { force = true })
    end
    state.buf, state.win, state.mini_buf, state.mini_win = -1, -1, -1, -1
    state.suppress_auto = false
    config.setup({})
  end)

  describe("the notification window", function()
    it("is focusable so a click can reach it", function()
      notification.show()
      assert.is_true(state.mini_win_valid())
      assert.is_true(vim.api.nvim_win_get_config(state.mini_win).focusable)
    end)

    -- Without restore_on_enter there is nothing to click for, and an
    -- unfocusable window stays out of the way of everything.
    it("is unfocusable when restore_on_enter is off", function()
      config.setup({ auto = { restore_on_enter = false } })
      notification.show()
      assert.is_true(state.mini_win_valid())
      assert.is_false(vim.api.nvim_win_get_config(state.mini_win).focusable)
    end)
  end)

  describe("leaving the float", function()
    it("minimizes it", function()
      terminal.open_window()
      assert.is_true(state.win_valid())
      other = elsewhere()
      vim.wait(50, function()
        return state.mini_win_valid()
      end, 5)
      assert.is_false(state.win_valid(), "the float should have been minimized")
      assert.is_true(state.mini_win_valid(), "the notification should be up")
    end)

    it("leaves it alone when minimize_on_leave is off", function()
      config.setup({ auto = { minimize_on_leave = false } })
      terminal.open_window()
      other = elsewhere()
      vim.wait(50)
      assert.is_true(state.win_valid(), "the float should still be open")
    end)

    -- The guard that matters: spawn() enters the float and hands focus back,
    -- and minimize() leaves the float on its way out. Both would otherwise
    -- read as the user turning away.
    it("stays quiet while the plugin is moving windows itself", function()
      terminal.open_window()
      state.suppress_auto = true
      other = elsewhere()
      vim.wait(50)
      assert.is_true(state.win_valid(), "our own move should not minimize")
      state.suppress_auto = false
    end)

    -- ...and it has to survive the flag being cleared on the same tick the
    -- move finishes, which is what quietly() actually does. Holding
    -- suppress_auto across the whole wait, as the spec above does, would let a
    -- guard that only reads the flag a tick later pass while spawn(focus=false)
    -- minimized Claude the moment it launched.
    it("stays quiet even though quietly() clears the flag synchronously", function()
      -- Made before the float exists, so creating it cannot itself queue a
      -- leave: this spec is about the handback and nothing else.
      other = elsewhere()
      terminal.open_window()
      assert.is_true(state.win_valid())

      -- Exactly quietly()'s shape: set, move, reset, all on this tick.
      state.suppress_auto = true
      vim.api.nvim_set_current_win(other)
      state.suppress_auto = false

      vim.wait(50)
      assert.is_true(state.win_valid(), "the handback should not have minimized the float")
      assert.is_false(state.mini_win_valid(), "and no notification should have opened")
    end)

    -- The regression: claudecode.nvim's open_in_new_tab fires this same
    -- WinLeave as a side effect of its own `:tabnew`, synchronously and
    -- before the tab switch settles. A notification opened inline binds to
    -- the tab being left rather than the one the diff lives in, so it is
    -- invisible the moment focus actually lands on the new tab.
    it("puts the notification in the tab focus is landing on, not the one it left", function()
      terminal.open_window()
      local left_tab = vim.api.nvim_get_current_tabpage()

      vim.cmd("tabnew")
      local arrived_tab = vim.api.nvim_get_current_tabpage()
      assert.are_not.equal(left_tab, arrived_tab, "fixture needs :tabnew to actually change tabs")

      assert.is_false(
        state.mini_win_valid(),
        "minimizing inline, before the tab switch settles, is exactly the bug"
      )
      vim.wait(50, function()
        return state.mini_win_valid()
      end, 5)

      assert.is_true(state.mini_win_valid())
      assert.equals(arrived_tab, vim.api.nvim_win_get_tabpage(state.mini_win))

      vim.cmd("tabclose")
    end)
  end)

  describe("entering the notification", function()
    it("restores the float", function()
      other = elsewhere()
      notification.show()
      assert.is_true(state.mini_win_valid())
      -- pcall, because succeeding here looks like failing on Neovim 0.10.
      -- Entering the notification fires WinEnter, which restores the float and
      -- closes this very window before the call returns -- so 0.10 reports
      -- "Failed to switch to window N" for having landed somewhere else. That
      -- is the feature working. The assertions below are the real check.
      pcall(vim.api.nvim_set_current_win, state.mini_win)
      assert.is_true(state.win_valid(), "the float should be back")
      assert.is_false(state.mini_win_valid(), "the notification should be gone")
    end)

    it("does nothing when restore_on_enter is off", function()
      config.setup({ auto = { restore_on_enter = false } })
      other = elsewhere()
      notification.show()
      -- Unfocusable, so a click could not land here anyway; assert the
      -- autocmd is absent rather than that the window cannot be entered.
      assert.same(
        {},
        vim.api.nvim_get_autocmds({
          group = "FloatingClaudeFocus",
          event = "WinEnter",
          buffer = state.mini_buf,
        })
      )
    end)
  end)
end)
