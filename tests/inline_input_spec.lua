-- The input under the code: a float anchored to a buffer row that takes an
-- instruction, grows with it, and hands it back on <CR>.

local config = require("floating-claude.config")
local input = require("floating-claude.inline.input")

local function keys(text)
  vim.api.nvim_feedkeys(vim.keycode(text), "x", false)
end

-- `startinsert` takes hold once the command that ran it is over, and the keys
-- fed in one call are one long command: the first would be read in normal
-- mode. An empty `:` command first ends one, and insert mode starts for the
-- rest. (feedkeys() ends insert mode again when its keys run out, so each
-- call types in its own session: later ones begin with `A`.)
local function typed(text)
  vim.api.nvim_feedkeys(vim.keycode(":<CR>" .. text), "x", false)
end

-- What typing would have fired by the time you see the result: feedkeys() runs
-- its keys as one command and never gets to the redraw that triggers it.
local function changed()
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0 })
end

local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

local function closed(win)
  return vim.wait(500, function()
    return not vim.api.nvim_win_is_valid(win)
  end)
end

describe("inline input", function()
  local origin, buf, calls

  local function open(opts)
    -- This test's own record: an input an earlier test left to be closed
    -- reports to its test's, not this one's.
    local mine = calls
    return input.open(vim.tbl_extend("force", {
      win = origin,
      row = 2,
      on_submit = function(text)
        table.insert(mine.submitted, text)
      end,
      on_cancel = function()
        mine.cancelled = mine.cancelled + 1
      end,
    }, opts or {}))
  end

  before_each(function()
    config.setup({})
    calls = { submitted = {}, cancelled = 0 }
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_set_current_buf(buf)
    origin = vim.api.nvim_get_current_win()
  end)

  after_each(function()
    vim.cmd("stopinsert")
    for _, win in ipairs(floats()) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    vim.api.nvim_set_current_win(origin)
    vim.api.nvim_buf_delete(buf, { force = true })
    config.setup({})
  end)

  it("opens a float anchored under the row, as wide as the text area", function()
    local win = open()
    local cfg = vim.api.nvim_win_get_config(win)
    assert.equals("win", cfg.relative)
    assert.equals(origin, cfg.win)
    assert.same({ 2, 0 }, cfg.bufpos)
    assert.equals(win, vim.api.nvim_get_current_win())
    local info = vim.fn.getwininfo(origin)[1]
    -- The border is part of what has to fit.
    assert.equals(info.width - info.textoff, cfg.width + 2)
    assert.equals(1, cfg.height)
  end)

  it("is narrower when the text area is", function()
    vim.wo[origin].number = true
    local win = open()
    local info = vim.fn.getwininfo(origin)[1]
    assert.equals(info.width - info.textoff, vim.api.nvim_win_get_config(win).width + 2)
    vim.wo[origin].number = false
  end)

  it("sits right under a line that wraps over several rows", function()
    local long = string.rep("word ", 50)
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { long })
    local rows = vim.api.nvim_win_text_height(origin, { start_row = 2, end_row = 2 }).all
    assert.is_true(rows > 1, "the fixture line does not wrap")
    local win = open()
    assert.equals(rows, vim.api.nvim_win_get_config(win).row)
  end)

  it("hands back what you type on <CR>, and closes", function()
    local win = open()
    typed("hello<CR>")
    assert.same({ "hello" }, calls.submitted)
    assert.equals(0, calls.cancelled)
    assert.is_true(closed(win))
    assert.equals(origin, vim.api.nvim_get_current_win())
    assert.equals("n", vim.api.nvim_get_mode().mode)
  end)

  it("trims what it hands back", function()
    open()
    typed("  hello there  <CR>")
    assert.same({ "hello there" }, calls.submitted)
  end)

  it("takes <CR> in normal mode too", function()
    open()
    typed("hello<Esc><CR>")
    assert.same({ "hello" }, calls.submitted)
  end)

  it("makes a new line on <C-j>, and on <S-CR>", function()
    local win = open()
    typed("one<C-j>two<S-CR>three")
    changed()
    assert.same({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals(3, vim.api.nvim_win_get_height(win))
    keys("<CR>")
    assert.same({ "one\ntwo\nthree" }, calls.submitted)
  end)

  it("grows to the text, up to max_input_height", function()
    config.setup({ inline = { max_input_height = 6 } })
    local win = open()
    typed("a<C-j>b")
    changed()
    assert.equals(2, vim.api.nvim_win_get_height(win))
    keys("A<C-j>c")
    changed()
    assert.equals(3, vim.api.nvim_win_get_height(win))
    for _ = 1, 10 do
      keys("A<C-j>x")
    end
    changed()
    assert.equals(6, vim.api.nvim_win_get_height(win))
  end)

  it("honours another max_input_height", function()
    config.setup({ inline = { max_input_height = 2 } })
    local win = open()
    typed("a<C-j>b<C-j>c<C-j>d")
    changed()
    assert.equals(2, vim.api.nvim_win_get_height(win))
  end)

  it("grows for text that wraps, and shrinks back", function()
    local win = open()
    local width = vim.api.nvim_win_get_width(win)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", width * 2 + 1) })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0 })
    assert.equals(3, vim.api.nvim_win_get_height(win))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0 })
    assert.equals(1, vim.api.nvim_win_get_height(win))
  end)

  it("cancels on an empty <CR>", function()
    local win = open()
    typed("<CR>")
    assert.same({}, calls.submitted)
    assert.equals(1, calls.cancelled)
    assert.is_true(closed(win))
  end)

  it("cancels on a <CR> with only blanks", function()
    open()
    typed("   <C-j>  <CR>")
    assert.same({}, calls.submitted)
    assert.equals(1, calls.cancelled)
  end)

  it("cancels on <Esc> in normal mode", function()
    local win = open()
    typed("draft<Esc>")
    assert.equals(0, calls.cancelled, "the first <Esc> only leaves insert mode")
    assert.is_true(vim.api.nvim_win_is_valid(win))
    keys("<Esc>")
    assert.same({}, calls.submitted)
    assert.equals(1, calls.cancelled)
    assert.is_true(closed(win))
  end)

  it("cancels on q in normal mode", function()
    local win = open()
    typed("draft<Esc>q")
    assert.same({}, calls.submitted)
    assert.equals(1, calls.cancelled)
    assert.is_true(closed(win))
  end)

  it("types q as q in insert mode", function()
    open()
    typed("quick")
    assert.same({ "quick" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.equals(0, calls.cancelled)
  end)

  it("closes, and cancels, when you leave it", function()
    local win = open()
    typed("draft")
    vim.api.nvim_set_current_win(origin)
    assert.is_true(closed(win))
    assert.same({}, calls.submitted)
    assert.equals(1, calls.cancelled)
  end)

  it("reports the end of one input once", function()
    local win = open()
    typed("hello<CR>")
    assert.is_true(closed(win))
    vim.wait(50)
    assert.equals(1, #calls.submitted)
    assert.equals(0, calls.cancelled)
  end)

  it("works without an on_cancel", function()
    local win = input.open({ win = origin, row = 2, on_submit = function() end })
    assert.has_no.errors(function()
      typed("<CR>")
    end)
    assert.is_true(closed(win))
  end)

  it("leaves no buffer behind", function()
    local before = #vim.api.nvim_list_bufs()
    local win = open()
    typed("hello<CR>")
    assert.is_true(closed(win))
    assert.equals(before, #vim.api.nvim_list_bufs())
  end)
end)
