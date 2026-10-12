-- The provider is the one interface we do not own: claudecode.nvim validates it
-- at setup() and refuses the provider outright if anything is missing, so the
-- contract is worth pinning down here.

local provider = require("floating-claude.provider")
local state = require("floating-claude.state")

-- Mirrors required_functions in claudecode.nvim's terminal.lua.
local REQUIRED = {
  "setup",
  "open",
  "close",
  "simple_toggle",
  "focus_toggle",
  "get_active_bufnr",
  "is_available",
}

describe("provider", function()
  after_each(function()
    state.buf, state.win, state.mini_buf, state.mini_win = -1, -1, -1, -1
  end)

  it("is what the plugin hands out", function()
    assert.equals(provider, require("floating-claude").provider)
  end)

  it("implements every function claudecode.nvim requires", function()
    for _, name in ipairs(REQUIRED) do
      assert.equals("function", type(provider[name]), name .. " is missing")
    end
  end)

  -- Defining this is what stops claudecode.nvim from reopening the float over a
  -- diff you are still reading.
  it("implements the optional ensure_visible", function()
    assert.equals("function", type(provider.ensure_visible))
  end)

  it("swallows the terminal config claudecode.nvim passes", function()
    assert.has_no.errors(function()
      provider.setup({ split_side = "right" })
    end)
  end)

  it("is always available", function()
    assert.is_true(provider.is_available())
  end)

  it("has no active buffer while Claude is not running", function()
    assert.is_nil(provider.get_active_bufnr())
  end)

  it("reports the buffer once one is live", function()
    local buf = vim.api.nvim_create_buf(false, true)
    state.buf = buf
    assert.equals(buf, provider.get_active_bufnr())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  describe("ensure_visible", function()
    it("is false with nothing to show", function()
      assert.is_false(provider.ensure_visible())
    end)

    it("leaves an already visible float alone", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = 10,
        height = 5,
        col = 0,
        row = 0,
      })
      state.buf, state.win = buf, win
      assert.is_true(provider.ensure_visible())
      -- Still the same window: nothing was reopened underneath us.
      assert.equals(win, state.win)
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("brings the notification back when Claude is hidden", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Done." })
      state.buf = buf
      assert.is_true(provider.ensure_visible())
      assert.is_true(state.mini_win_valid())
      require("floating-claude.notification").hide()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- Upstream's diff cleanup calls in here after closing the diff's tab, and
    -- the corner that was in that tab went with it -- so by the windows alone,
    -- every Claude looks hidden at this point. What it was before the diff
    -- opened is what decides.
    describe("during a diff's cleanup", function()
      local buf, diff_buf

      before_each(function()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Done." })
        state.buf = buf
        -- Closed, but still loaded until upstream deletes it a few lines on.
        diff_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(diff_buf, "✻ [Claude Code] init.lua (a1b2c3) ⧉ (proposed)")
      end)

      after_each(function()
        require("floating-claude.notification").hide()
        if state.win_valid() then
          vim.api.nvim_win_close(state.win, true)
        end
        state.before_diff = nil
        vim.api.nvim_buf_delete(diff_buf, { force = true })
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      it("puts the float back if the diff took it away", function()
        state.before_diff = "float"
        assert.is_true(provider.ensure_visible())
        assert.is_true(state.win_valid(), "the float should be back")
        assert.is_false(state.mini_win_valid(), "the corner should not have flashed up first")
      end)

      it("brings the corner back if that is where Claude was", function()
        state.before_diff = "corner"
        assert.is_true(provider.ensure_visible())
        assert.is_true(state.mini_win_valid())
        assert.is_false(state.win_valid())
      end)

      it("keeps Claude hidden if it was hidden", function()
        state.before_diff = "hidden"
        assert.is_true(provider.ensure_visible())
        assert.is_false(state.mini_win_valid(), "the corner came back uninvited")
        assert.is_false(state.win_valid(), "the float came back uninvited")
      end)
    end)

    -- :ClaudeCodeSend routes here rather than to open() unless focus_after_send
    -- is set, so a minimized Claude has to come back or the keymap looks dead.
    describe("with Claude minimized", function()
      local buf, diff_buf

      before_each(function()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Done." })
        state.buf = buf
        require("floating-claude.notification").show()
        assert.is_true(state.mini_win_valid(), "precondition: Claude is minimized")
      end)

      after_each(function()
        require("floating-claude.notification").hide()
        if state.win_valid() then
          vim.api.nvim_win_close(state.win, true)
        end
        if diff_buf and vim.api.nvim_buf_is_valid(diff_buf) then
          vim.api.nvim_buf_delete(diff_buf, { force = true })
        end
        diff_buf = nil
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end)

      it("restores the float when no diff is on screen", function()
        assert.is_true(provider.ensure_visible())
        assert.is_true(state.win_valid(), "the float should be back")
        assert.is_false(state.mini_win_valid(), "the notification should be gone")
      end)

      -- The one reason to stay in the corner: popping the float back over a
      -- diff hides the thing the notification exists to let you read.
      it("stays minimized while a diff is pending", function()
        diff_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(diff_buf, "✻ [Claude Code] init.lua (a1b2c3) ⧉ (proposed)")
        assert.is_true(provider.ensure_visible())
        assert.is_true(state.mini_win_valid(), "should still be minimized")
        assert.is_false(state.win_valid(), "the float should not have reopened")
      end)
    end)
  end)
end)
