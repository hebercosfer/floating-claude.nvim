-- The inline lines: what an inline request shows under the code it is about,
-- as virtual lines on a single extmark per buffer, with a <CR> that acts on
-- them only while the cursor is on that code.

local config = require("floating-claude.config")
local lines = require("floating-claude.inline.lines")

local ENTER = vim.keycode("<CR>")

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, lines.ns, 0, -1, { details = true })
end

-- The text of each virtual line of an extmark returned by marks().
local function texts(mark)
  return vim.tbl_map(function(chunks)
    return chunks[1][1]
  end, mark[4].virt_lines)
end

local function cursor_to(row)
  vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
end

-- The columns of text a window shows: what a virtual line has to fit in.
local function text_width()
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  return info.width - info.textoff
end

local function press_enter()
  vim.api.nvim_feedkeys(ENTER, "x", false)
end

describe("inline lines", function()
  local buf

  before_each(function()
    config.setup({})
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five", "six" })
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    pcall(lines.clear, buf)
    pcall(vim.keymap.del, "n", "<CR>")
    vim.wo.number = false
    vim.api.nvim_buf_delete(buf, { force = true })
    config.setup({})
  end)

  describe("render", function()
    it("puts the items on one extmark under the row, capped at inline.lines", function()
      config.setup({ inline = { lines = 3 } })
      local id = lines.render(buf, 2, { "a", "b", "c", "d" })
      local found = marks(buf)
      assert.equals(1, #found)
      assert.equals(id, found[1][1])
      assert.equals(2, found[1][2])
      assert.same({ "a", "b", "c" }, texts(found[1]))
    end)

    it("honours a smaller cap", function()
      config.setup({ inline = { lines = 1 } })
      lines.render(buf, 2, { "a", "b" })
      assert.same({ "a" }, texts(marks(buf)[1]))
    end)

    it("replaces the extmark on a second render", function()
      local first = lines.render(buf, 2, { "a", "b" })
      local second = lines.render(buf, 3, { "c" })
      local found = marks(buf)
      assert.equals(1, #found)
      assert.equals(first, second)
      assert.equals(3, found[1][2])
      assert.same({ "c" }, texts(found[1]))
    end)

    it("follows the code when a line above it is deleted", function()
      lines.render(buf, 2, { "a" })
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
      assert.equals(1, marks(buf)[1][2])
    end)

    it("survives its rows being deleted", function()
      lines.render(buf, 2, { "a" }, { first_row = 0 })
      local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, 3, false, {})
      assert.is_true(ok, tostring(err))
      assert.has_no.errors(function()
        lines.at_cursor(buf)
        lines.render(buf, 0, { "b" })
        lines.clear(buf)
      end)
      assert.same({}, marks(buf))
    end)

    it("clamps a row past the end of the buffer", function()
      assert.has_no.errors(function()
        lines.render(buf, 99, { "a" })
      end)
      assert.equals(5, marks(buf)[1][2])
    end)

    it("keeps each item on one line", function()
      lines.render(buf, 2, { "one\ntwo\tthree" })
      assert.same({ "one two three" }, texts(marks(buf)[1]))
    end)

    it("cuts each line to the window's text width, marking the cut", function()
      vim.wo.number = true
      local width = text_width()
      lines.render(buf, 2, { string.rep("x", width + 20), "short" })
      local got = texts(marks(buf)[1])
      assert.equals(width, vim.fn.strdisplaywidth(got[1]))
      assert.equals("…", vim.fn.strcharpart(got[1], vim.fn.strchars(got[1]) - 1))
      assert.equals("short", got[2])
    end)

    it("does not cut a double-width character in half", function()
      local width = text_width()
      lines.render(buf, 2, { string.rep("漢", width) })
      local got = texts(marks(buf)[1])
      assert.is_true(vim.fn.strdisplaywidth(got[1]) <= width)
      assert.equals("…", vim.fn.strcharpart(got[1], vim.fn.strchars(got[1]) - 1))
    end)

    it("leaves a line that fits alone", function()
      local exact = string.rep("x", text_width())
      lines.render(buf, 2, { exact })
      assert.same({ exact }, texts(marks(buf)[1]))
    end)

    it("draws in the dim group, and an ask item in the asking one", function()
      lines.render(buf, 2, { "a", "b" })
      local plain = marks(buf)[1][4].virt_lines
      assert.equals("FloatingClaudeInline", plain[1][1][2])
      assert.equals("FloatingClaudeInline", plain[2][1][2])
      lines.render(buf, 2, { "a", { text = "b", ask = true } })
      local asked = marks(buf)[1][4].virt_lines
      assert.equals("b", asked[2][1][1])
      assert.equals("FloatingClaudeInline", asked[1][1][2])
      assert.equals("FloatingClaudeInlineAsk", asked[2][1][2])
    end)

    it("takes an item as a table without ask, drawn like a string", function()
      lines.render(buf, 2, { { text = "a" }, { text = "b", ask = false } })
      local virt = marks(buf)[1][4].virt_lines
      assert.same({ "a", "b" }, texts(marks(buf)[1]))
      assert.equals("FloatingClaudeInline", virt[1][1][2])
      assert.equals("FloatingClaudeInline", virt[2][1][2])
    end)

    it("keeps an ask item the cap would cut, and drops the one before it", function()
      config.setup({ inline = { lines = 2 } })
      lines.render(buf, 2, { "a", "b", { text = "ask", ask = true } })
      local found = marks(buf)[1]
      assert.same({ "a", "ask" }, texts(found))
      assert.equals("FloatingClaudeInline", found[4].virt_lines[1][1][2])
      assert.equals("FloatingClaudeInlineAsk", found[4].virt_lines[2][1][2])
    end)

    it("keeps an ask item the cap would cut, whatever the cap", function()
      config.setup({ inline = { lines = 1 } })
      lines.render(buf, 2, { "a", "b", { text = "ask", ask = true } })
      assert.same({ "ask" }, texts(marks(buf)[1]))
      config.setup({ inline = { lines = 3 } })
      lines.render(buf, 2, { "a", "b", "c", "d", { text = "ask", ask = true } })
      assert.same({ "a", "b", "ask" }, texts(marks(buf)[1]))
    end)

    it("keeps the order of what it keeps, with the ask item in the middle", function()
      config.setup({ inline = { lines = 2 } })
      lines.render(buf, 2, { "a", { text = "ask", ask = true }, "c" })
      assert.same({ "a", "ask" }, texts(marks(buf)[1]))
    end)

    it("keeps the first ask items when there are more of them than room", function()
      config.setup({ inline = { lines = 2 } })
      lines.render(buf, 2, {
        "a",
        { text = "x", ask = true },
        { text = "y", ask = true },
        { text = "z", ask = true },
      })
      assert.same({ "x", "y" }, texts(marks(buf)[1]))
    end)

    it("cuts an ask item to the width like any other", function()
      local width = text_width()
      lines.render(buf, 2, { { text = string.rep("x", width + 10), ask = true } })
      local got = texts(marks(buf)[1])[1]
      assert.equals(width, vim.fn.strdisplaywidth(got))
      assert.equals("…", vim.fn.strcharpart(got, vim.fn.strchars(got) - 1))
    end)

    it("defines the groups as default links", function()
      lines.render(buf, 2, { "a" })
      assert.equals("Comment", vim.api.nvim_get_hl(0, { name = "FloatingClaudeInline" }).link)
      assert.equals("Question", vim.api.nvim_get_hl(0, { name = "FloatingClaudeInlineAsk" }).link)
    end)
  end)

  describe("render without a row", function()
    it("keeps the extmark where edits moved it, and the range with it", function()
      local id = lines.render(buf, 2, { "a" }, { first_row = 1 })
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new", "newer" })
      assert.equals(id, lines.render(buf, nil, { "b", "c" }))
      local found = marks(buf)
      assert.equals(1, #found)
      assert.equals(4, found[1][2])
      assert.same({ "b", "c" }, texts(found[1]))
      local first, last = lines.range(buf)
      assert.equals(3, first)
      assert.equals(4, last)
    end)

    it("is what a re-render with the original row is not", function()
      lines.render(buf, 2, { "a" }, { first_row = 1 })
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new", "newer" })
      lines.render(buf, 2, { "b" }, { first_row = 1 })
      assert.equals(2, marks(buf)[1][2])
    end)

    it("draws nothing and returns nil when there are no lines to keep", function()
      assert.is_nil(lines.render(buf, nil, { "a" }))
      assert.same({}, marks(buf))
      lines.render(buf, 2, { "a" })
      lines.clear(buf)
      assert.is_nil(lines.render(buf, nil, { "a" }))
      assert.same({}, marks(buf))
    end)

    it("draws nothing when the extmark itself is gone", function()
      lines.render(buf, 2, { "a" })
      vim.api.nvim_buf_clear_namespace(buf, lines.ns, 0, -1)
      assert.is_nil(lines.render(buf, nil, { "a" }))
      assert.same({}, marks(buf))
    end)

    it("takes the on_enter it is given, and acts on the moved range", function()
      lines.render(buf, 2, { "a" }, { first_row = 2 })
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new", "newer" })
      local entered = false
      lines.render(buf, nil, { "a" }, {
        on_enter = function()
          entered = true
        end,
      })
      cursor_to(4)
      press_enter()
      assert.is_true(entered)
      cursor_to(2)
      assert.is_false(lines.at_cursor(buf))
    end)

    it("keeps the highlighting and the cap", function()
      config.setup({ inline = { lines = 2 } })
      lines.render(buf, 2, { "a" })
      lines.render(buf, nil, { "a", "b", { text = "ask", ask = true } })
      local found = marks(buf)[1]
      assert.same({ "a", "ask" }, texts(found))
      assert.equals("FloatingClaudeInlineAsk", found[4].virt_lines[2][1][2])
    end)
  end)

  describe("range", function()
    it("is nil with nothing shown", function()
      assert.is_nil(lines.range(buf))
      lines.render(buf, 2, { "a" })
      lines.clear(buf)
      assert.is_nil(lines.range(buf))
    end)

    it("is the row alone without a first_row, and the whole range with one", function()
      lines.render(buf, 3, { "a" })
      assert.same({ 3, 3 }, { lines.range(buf) })
      lines.render(buf, 3, { "a" }, { first_row = 1 })
      assert.same({ 1, 3 }, { lines.range(buf) })
    end)

    it("follows the code", function()
      lines.render(buf, 3, { "a" }, { first_row = 1 })
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
      assert.same({ 0, 2 }, { lines.range(buf) })
    end)

    it("never starts above the first row", function()
      lines.render(buf, 3, { "a" }, { first_row = 0 })
      vim.api.nvim_buf_set_lines(buf, 0, 2, false, {})
      local first, last = lines.range(buf)
      assert.equals(0, first)
      assert.is_true(last >= first)
    end)

    it("is nil on a buffer that is gone", function()
      assert.is_nil(lines.range(99999))
    end)
  end)

  describe("clear", function()
    it("removes the extmark", function()
      lines.render(buf, 2, { "a" })
      lines.clear(buf)
      assert.same({}, marks(buf))
    end)

    it("is harmless with nothing shown, or on a buffer that is gone", function()
      assert.has_no.errors(function()
        lines.clear(buf)
        lines.clear(buf)
        lines.clear(99999)
      end)
    end)
  end)

  describe("at_cursor", function()
    it("is false with nothing shown", function()
      assert.is_false(lines.at_cursor(buf))
    end)

    it("is true on the row the lines hang from, and nowhere else, without a range", function()
      lines.render(buf, 3, { "a" })
      cursor_to(3)
      assert.is_true(lines.at_cursor(buf))
      cursor_to(2)
      assert.is_false(lines.at_cursor(buf))
      cursor_to(4)
      assert.is_false(lines.at_cursor(buf))
    end)

    it("is true anywhere in the range it annotates", function()
      lines.render(buf, 4, { "a" }, { first_row = 2 })
      for row = 2, 4 do
        cursor_to(row)
        assert.is_true(lines.at_cursor(buf), "row " .. row)
      end
      cursor_to(1)
      assert.is_false(lines.at_cursor(buf))
      cursor_to(5)
      assert.is_false(lines.at_cursor(buf))
    end)

    it("moves with the range when lines are added above it", function()
      lines.render(buf, 4, { "a" }, { first_row = 2 })
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new", "newer" })
      cursor_to(6)
      assert.is_true(lines.at_cursor(buf))
      cursor_to(4)
      assert.is_true(lines.at_cursor(buf))
      cursor_to(3)
      assert.is_false(lines.at_cursor(buf))
    end)

    it("is false when the buffer is not the one in front of you", function()
      lines.render(buf, 3, { "a" })
      cursor_to(3)
      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(other)
      assert.is_false(lines.at_cursor(buf))
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_delete(other, { force = true })
    end)
  end)

  describe("<CR>", function()
    local function enter_map()
      return vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg("<CR>", "n", false, true)
      end)
    end

    it("is mapped in the buffer only while lines are shown", function()
      assert.equals(0, vim.tbl_count(enter_map()))
      lines.render(buf, 3, { "a" }, { on_enter = function() end })
      assert.equals(1, enter_map().buffer)
      lines.clear(buf)
      assert.equals(0, vim.tbl_count(enter_map()))
    end)

    it("is not mapped at all when there is nothing for it to do", function()
      lines.render(buf, 3, { "a" })
      assert.equals(0, vim.tbl_count(enter_map()))
      lines.render(buf, 3, { "a" }, { on_enter = function() end })
      assert.equals(1, enter_map().buffer)
      lines.render(buf, 3, { "a" })
      assert.equals(0, vim.tbl_count(enter_map()))
    end)

    it("keeps your count", function()
      lines.render(buf, 5, { "a" }, { first_row = 5, on_enter = function() end })
      cursor_to(0)
      vim.api.nvim_feedkeys("3" .. ENTER, "x", false)
      assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("runs on_enter with the cursor on the lines", function()
      local entered = 0
      lines.render(buf, 4, { "a" }, {
        first_row = 3,
        on_enter = function()
          entered = entered + 1
        end,
      })
      cursor_to(3)
      press_enter()
      cursor_to(4)
      press_enter()
      assert.equals(2, entered)
    end)

    it("is the plain <CR> anywhere else", function()
      local entered = false
      lines.render(buf, 4, { "a" }, {
        first_row = 3,
        on_enter = function()
          entered = true
        end,
      })
      cursor_to(0)
      press_enter()
      assert.is_false(entered)
      assert.equals(2, vim.api.nvim_win_get_cursor(0)[1], "<CR> did not move down a line")
    end)

    it("is the plain <CR> on the lines when there is no on_enter", function()
      lines.render(buf, 4, { "a" })
      cursor_to(4)
      assert.has_no.errors(press_enter)
      assert.equals(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("uses the on_enter of the latest render", function()
      local which
      lines.render(buf, 3, { "a" }, {
        on_enter = function()
          which = "first"
        end,
      })
      lines.render(buf, 3, { "b" }, {
        on_enter = function()
          which = "second"
        end,
      })
      cursor_to(3)
      press_enter()
      assert.equals("second", which)
    end)

    it("falls through to a global <CR> mapping of your own", function()
      local mine = 0
      vim.keymap.set("n", "<CR>", function()
        mine = mine + 1
      end)
      lines.render(buf, 4, { "a" }, { first_row = 3, on_enter = function() end })
      cursor_to(0)
      press_enter()
      assert.equals(1, mine)
      lines.clear(buf)
      press_enter()
      assert.equals(2, mine)
    end)

    it("falls through to a global <CR> mapping that has an rhs", function()
      vim.keymap.set("n", "<CR>", "G")
      lines.render(buf, 1, { "a" }, { on_enter = function() end })
      cursor_to(0)
      press_enter()
      assert.equals(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("falls through to an expr <CR> mapping of your own", function()
      vim.keymap.set("n", "<CR>", "'G'", { expr = true })
      lines.render(buf, 1, { "a" }, { on_enter = function() end })
      cursor_to(0)
      press_enter()
      assert.equals(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("covers a buffer-local <CR> of your own, and gives it back on clear", function()
      local mine = 0
      vim.keymap.set("n", "<CR>", function()
        mine = mine + 1
      end, { buffer = buf })
      local entered = false
      lines.render(buf, 4, { "a" }, {
        first_row = 3,
        on_enter = function()
          entered = true
        end,
      })
      cursor_to(3)
      press_enter()
      assert.is_true(entered)
      assert.equals(0, mine)
      cursor_to(0)
      press_enter()
      assert.equals(1, mine, "the buffer's own <CR> was not the fallback")
      lines.clear(buf)
      press_enter()
      assert.equals(2, mine, "the buffer's own <CR> was not put back")
    end)
  end)
end)
