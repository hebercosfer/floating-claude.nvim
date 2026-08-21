-- The guided tour, and the one thing it must not get wrong: the screen it
-- paints has to be a screen parser.lua reads the way it reads Claude's own. A
-- stand-in that drifted from the parser would demonstrate a plugin that does
-- not exist.

local config = require("floating-claude.config")
local demo = require("floating-claude.demo")
local diff = require("floating-claude.demo.diff")
local notification = require("floating-claude.notification")
local parser = require("floating-claude.parser")
local state = require("floating-claude.state")
local tui = require("floating-claude.demo.tui")

local ANSWER = "The float comes back only once Claude has been idle for a sustained stretch, and "
  .. "`restore_idle_ms` is how long. That debounce is the whole trick: the lull between a diff "
  .. "being resolved and Claude picking the work back up never lasts long enough to pop the "
  .. "float over what you were reading."

--- A stand-in screen, rendered into a buffer the parser will be pointed at.
local function screen(build)
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  tui.open(buf, 120, 30)
  build()
  tui.render()
  return buf
end

describe("demo", function()
  before_each(function()
    config.setup({})
  end)

  after_each(function()
    demo.stop()
    tui.close()
    notification.hide()
    state.buf, state.win = -1, -1
  end)

  describe("the stand-in Claude", function()
    it("renders a live turn the parser reads as working", function()
      screen(function()
        tui.prompt("why does the float wait before it comes back?")
        tui.tool("Running 2 shell commands", 'rg -n "restore_idle_ms" lua/')
        tui.working("Percolating")
      end)

      local status = parser.status()
      assert.is_true(status.working)
      assert.equals("Percolating…", status.verb)
      assert.is_truthy(status.elapsed:match("^%d+s$"))
      assert.is_truthy(status.tokens:match("^↓[%d%.]+k$"))
      assert.is_truthy(status.glyph)
    end)

    it("collapses a running tool call to its header", function()
      screen(function()
        tui.prompt("why does the float wait before it comes back?")
        tui.tool("Running 2 shell commands", 'rg -n "restore_idle_ms" lua/')
        tui.working("Percolating")
      end)

      assert.same({ "⎿ Running 2 shell commands" }, parser.status_lines())
    end)

    it("wraps its prose where the parser goes looking for the wrap", function()
      screen(function()
        tui.prompt("why does the float wait before it comes back?")
        tui.working("Percolating")
        tui.say(ANSWER)
      end)

      -- Unwrapped and cut at the first full stop: one sentence, not the
      -- fragment the float's own hard wrap would leave behind.
      assert.same({
        "● The float comes back only once Claude has been idle for a sustained stretch, and "
          .. "`restore_idle_ms` is how long…",
      }, parser.status_lines())
    end)

    it("ends a turn as a frozen marker the parser tells from a live one", function()
      screen(function()
        tui.prompt("why does the float wait before it comes back?")
        tui.say(ANSWER)
        tui.finish("Cooked for 24s", "Explained the restore debounce · 24s")
      end)

      local status = parser.status()
      assert.is_false(status.working)
      assert.equals("Cooked for 24s", status.done)
      assert.same({ "● Explained the restore debounce · 24s" }, parser.status_lines())
    end)
  end)

  describe("the stand-in diff", function()
    it("is one the watcher sees, until it is torn down", function()
      -- state.buf stays invalid so the teardown's ensure_visible() -- which is
      -- upstream's call, made in upstream's order -- has nothing to show.
      state.buf = -1
      diff.open(function() end)
      assert.is_true(parser.diff_visible())
      assert.is_true(parser.diff_pending())

      diff.close()
      assert.is_false(parser.diff_visible())
      assert.is_false(parser.diff_pending())
    end)

    it("leaves no buffers behind, not even the one :tabnew made", function()
      state.buf = -1
      local before = #vim.api.nvim_list_bufs()
      diff.open(function() end)
      diff.close()
      assert.equals(before, #vim.api.nvim_list_bufs())
    end)

    it("settles once, on the first answer", function()
      state.buf = -1
      local answers = {}
      diff.open(function(outcome)
        table.insert(answers, outcome)
      end)
      assert.is_false(diff.settled())

      diff.resolve("accepted")
      diff.resolve("rejected")
      assert.same({ "accepted" }, answers)
      assert.is_true(diff.settled())
      diff.close()
    end)
  end)

  describe("the tour", function()
    it("borrows the float and the defaults, and puts both back", function()
      local columns, lines = vim.o.columns, vim.o.lines
      vim.o.columns, vim.o.lines = 120, 40
      config.setup({ notification = { body = "block" } })
      local mine = config.options

      demo.start()
      assert.is_true(demo.running())
      assert.is_true(state.win_valid())
      assert.equals(state.buf, tui.buf)
      assert.equals("sentence", config.options.notification.body)

      demo.stop()
      assert.is_false(demo.running())
      assert.equals(mine, config.options)
      assert.equals("block", config.options.notification.body)
      assert.equals(-1, state.buf)
      assert.equals(-1, state.win)

      vim.o.columns, vim.o.lines = columns, lines
    end)

    it("refuses to take a running Claude's float", function()
      state.buf = vim.api.nvim_create_buf(false, true)
      demo.start()
      assert.is_false(demo.running())
    end)
  end)
end)
