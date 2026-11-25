-- The inline entry: the key and the command that start a request, and what
-- they do with the range. Dispatch to Claude is not built here yet -- a
-- submitted instruction is only shown back -- so these specs cover the shared
-- front: the range, the input, the lines, the key and the command.

local config = require("floating-claude.config")
local inline = require("floating-claude.inline")
local keymaps = require("floating-claude.keymaps")
local lines = require("floating-claude.inline.lines")

local function keys(text)
  vim.api.nvim_feedkeys(vim.keycode(text), "x", false)
end

-- `startinsert` takes hold once the command that ran it is over, and the keys
-- fed in one call are one long command: the first would be read in normal
-- mode. An empty `:` command first ends one, and insert mode starts for the
-- rest.
local function typed(text)
  vim.api.nvim_feedkeys(vim.keycode(":<CR>" .. text), "x", false)
end

local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

local function shown(buf)
  local found = vim.api.nvim_buf_get_extmarks(buf, lines.ns, 0, -1, { details = true })
  if #found == 0 then
    return nil
  end
  return found[1][2],
    vim.tbl_map(function(chunks)
      return chunks[1][1]
    end, found[1][4].virt_lines)
end

describe("inline", function()
  local buf, origin

  before_each(function()
    config.setup({})
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })
    vim.api.nvim_set_current_buf(buf)
    origin = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    vim.cmd("stopinsert")
    for _, win in ipairs(floats()) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(lines.clear, buf)
    vim.api.nvim_set_current_win(origin)
    vim.api.nvim_buf_delete(buf, { force = true })
    config.setup({})
  end)

  describe("ask", function()
    it("opens the input under the last line of the range", function()
      inline.ask({ line1 = 2, line2 = 4 })
      local wins = floats()
      assert.equals(1, #wins)
      assert.same({ 3, 0 }, vim.api.nvim_win_get_config(wins[1]).bufpos)
    end)

    it("shows the instruction under the range once submitted", function()
      inline.ask({ line1 = 2, line2 = 4 })
      typed("add a retry<CR>")
      local row, items = shown(buf)
      assert.equals(3, row)
      assert.same({ "▸ add a retry" }, items)
      assert.equals(0, #floats())
    end)

    it("annotates the whole range, so <CR> acts anywhere in it", function()
      inline.ask({ line1 = 2, line2 = 4 })
      typed("add a retry<CR>")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      assert.is_true(lines.at_cursor(buf))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      assert.is_false(lines.at_cursor(buf))
    end)

    it("shows nothing when cancelled", function()
      inline.ask({ line1 = 2, line2 = 2 })
      typed("<CR>")
      assert.is_nil(shown(buf))
      assert.equals(0, #floats())
    end)

    it("says so, and does nothing, with inline.enabled = false", function()
      config.setup({ inline = { enabled = false } })
      local said
      local notify = vim.notify
      vim.notify = function(msg)
        said = msg
      end
      inline.ask({ line1 = 2, line2 = 2 })
      vim.notify = notify
      assert.equals(0, #floats())
      assert.is_truthy(said and said:find("inline.enabled", 1, true))
    end)

    it("takes a range given backwards", function()
      inline.ask({ line1 = 4, line2 = 2 })
      typed("add a retry<CR>")
      local row = shown(buf)
      assert.equals(3, row)
    end)
  end)

  describe("clear", function()
    it("takes the lines down from the buffer asked for", function()
      lines.render(buf, 1, { "a" })
      inline.clear(buf)
      assert.is_nil(shown(buf))
    end)

    it("takes the current buffer's down with no argument", function()
      lines.render(buf, 1, { "a" })
      inline.clear()
      assert.is_nil(shown(buf))
    end)
  end)

  describe("the command", function()
    local ask, original

    before_each(function()
      vim.g.loaded_floating_claude = nil
      vim.cmd("runtime plugin/floating-claude.lua")
      original = inline.ask
      inline.ask = function(opts)
        ask = opts
      end
      ask = nil
    end)

    after_each(function()
      inline.ask = original
    end)

    it("asks about the cursor line without a range", function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.cmd("FloatingClaudeInline")
      assert.same({ line1 = 3, line2 = 3 }, ask)
    end)

    it("asks about the range it is given", function()
      vim.cmd("2,4FloatingClaudeInline")
      assert.same({ line1 = 2, line2 = 4 }, ask)
    end)

    it("takes the mode for one request", function()
      vim.cmd("2,4FloatingClaudeInline headless")
      assert.same({ line1 = 2, line2 = 4, mode = "headless" }, ask)
      vim.cmd("FloatingClaudeInline session")
      assert.equals("session", ask.mode)
    end)

    it("clears with `clear`, and does not ask", function()
      lines.render(buf, 1, { "a" })
      vim.cmd("FloatingClaudeInline clear")
      assert.is_nil(shown(buf))
      assert.is_nil(ask)
    end)

    it("says what it does not know", function()
      local said
      local notify = vim.notify
      vim.notify = function(msg)
        said = msg
      end
      vim.cmd("FloatingClaudeInline sideways")
      vim.notify = notify
      assert.is_nil(ask)
      assert.is_truthy(said and said:find("sideways", 1, true))
    end)

    it("completes the three arguments", function()
      assert.same(
        { "clear", "headless", "session" },
        vim.fn.getcompletion("FloatingClaudeInline ", "cmdline")
      )
      assert.same({ "session" }, vim.fn.getcompletion("FloatingClaudeInline s", "cmdline"))
    end)
  end)

  describe("the key", function()
    local ask, original

    before_each(function()
      keymaps.apply()
      original = inline.ask
      inline.ask = function(opts)
        ask = opts
      end
      ask = nil
    end)

    after_each(function()
      inline.ask = original
    end)

    it("asks about the cursor line from normal mode", function()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      keys("<leader>ai")
      assert.same({ line1 = 3, line2 = 3 }, ask)
    end)

    it("asks about the selected lines from visual mode, and leaves it", function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      keys("Vjj<leader>ai")
      assert.same({ line1 = 2, line2 = 4 }, ask)
      assert.equals("n", vim.api.nvim_get_mode().mode)
    end)

    it("reads a selection made upwards the same way", function()
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      keys("vkk<leader>ai")
      assert.same({ line1 = 2, line2 = 4 }, ask)
    end)

    it("reads a characterwise selection by its lines", function()
      vim.api.nvim_win_set_cursor(0, { 2, 1 })
      keys("vj<leader>ai")
      assert.same({ line1 = 2, line2 = 3 }, ask)
    end)
  end)
end)
