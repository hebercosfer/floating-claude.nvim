-- Hidden is the third face: Claude keeps running with neither the float nor
-- the corner up. hide() is the way there, `<leader>aq` the plugin's own key
-- for it, and `<leader>ac` -- claudecode's `:ClaudeCode` -- the way back.

local config = require("floating-claude.config")
local keymaps = require("floating-claude.keymaps")
local notification = require("floating-claude.notification")
local provider = require("floating-claude.provider")
local state = require("floating-claude.state")
local terminal = require("floating-claude.terminal")

describe("hide", function()
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
    if state.buf ~= -1 and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_delete(state.buf, { force = true })
    end
    state.buf, state.win, state.mini_buf, state.mini_win = -1, -1, -1, -1
    state.before_diff = nil
  end)

  it("takes the float down without putting the corner up", function()
    terminal.open_window()
    terminal.hide()
    assert.equals("hidden", state.mode())
    assert.is_true(state.buf_valid(), "hiding stopped Claude")
  end)

  it("takes the corner down", function()
    notification.show()
    terminal.hide()
    assert.equals("hidden", state.mode())
  end)

  it("keeps Claude hidden past the diff it was hidden during", function()
    notification.show()
    state.before_diff = "corner"
    terminal.hide()
    assert.equals("hidden", state.before_diff)
  end)

  it("invents no diff when there is none", function()
    notification.show()
    terminal.hide()
    assert.is_nil(state.before_diff)
  end)

  it("comes back as the float through :ClaudeCode", function()
    notification.show()
    terminal.hide()
    provider.simple_toggle("claude", {}, {})
    assert.equals("float", state.mode())
  end)

  it("says so when Claude is not running", function()
    vim.api.nvim_buf_delete(state.buf, { force = true })
    state.buf = -1
    local said
    local notify = vim.notify
    vim.notify = function(msg)
      said = msg
    end
    terminal.hide()
    vim.notify = notify
    assert.equals("Claude Code is not running.", said)
  end)
end)

describe("keymaps", function()
  local function mapped(lhs)
    return vim.fn.maparg(lhs, "n", false, true)
  end

  after_each(function()
    config.setup({})
    keymaps.apply()
    pcall(vim.keymap.del, "n", "<leader>ax")
  end)

  it("puts hide on <leader>aq out of the box", function()
    config.setup({})
    keymaps.apply()
    assert.equals("Hide Claude", mapped("<leader>aq").desc)
  end)

  it("moves it when remapped", function()
    keymaps.apply()
    config.setup({ keymaps = { hide = "<leader>ax" } })
    keymaps.apply()
    assert.same({}, mapped("<leader>aq"), "the old key was left behind")
    assert.equals("Hide Claude", mapped("<leader>ax").desc)
  end)

  it("drops it under false", function()
    keymaps.apply()
    config.setup({ keymaps = { hide = false } })
    keymaps.apply()
    assert.same({}, mapped("<leader>aq"))
  end)

  it("is re-applied by setup()", function()
    keymaps.apply()
    require("floating-claude").setup({ keymaps = { hide = false } })
    assert.same({}, mapped("<leader>aq"))
  end)

  it("leaves a mapping of your own alone", function()
    config.setup({ keymaps = { hide = false } })
    keymaps.apply()
    vim.keymap.set("n", "<leader>aq", "<Nop>", { desc = "mine" })
    config.setup({})
    keymaps.apply()
    assert.equals("mine", mapped("<leader>aq").desc)
    vim.keymap.del("n", "<leader>aq")
  end)
end)
