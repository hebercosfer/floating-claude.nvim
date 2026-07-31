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
  end)
end)
