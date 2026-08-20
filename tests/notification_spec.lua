-- What the corner window actually renders. The assertions read the real window
-- config and the real buffer, so the title here is the title Neovim draws.

local config = require("floating-claude.config")
local notification = require("floating-claude.notification")
local state = require("floating-claude.state")

local RULE = string.rep("─", 40)

--- A terminal buffer shaped like Claude Code's TUI.
local function terminal(lines)
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
end

local function title()
  local text = ""
  for _, chunk in ipairs(vim.api.nvim_win_get_config(state.mini_win).title or {}) do
    text = text .. chunk[1]
  end
  return text
end

local function body()
  return vim.api.nvim_buf_get_lines(state.mini_buf, 0, -1, false)
end

local function title_chunks()
  return vim.api.nvim_win_get_config(state.mini_win).title
end

--- What the render painted, as { row, col, end_col, hl_group } per mark.
local function paint()
  local ns = vim.api.nvim_create_namespace("floating-claude.notification")
  local out = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(state.mini_buf, ns, 0, -1, { details = true }))
  do
    table.insert(out, {
      row = mark[2],
      col = mark[3],
      end_col = mark[4].end_col,
      hl_group = mark[4].hl_group,
    })
  end
  return out
end

describe("notification", function()
  before_each(function()
    config.setup({})
  end)

  after_each(function()
    notification.hide()
    for _, buf in ipairs({ state.buf, state.mini_buf }) do
      if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    state.buf, state.mini_buf, state.mini_win = -1, -1, -1
    config.setup({})
  end)

  describe("title", function()
    it("carries the verb, the timer and the tokens while Claude works", function()
      terminal({
        "  Reading parser.lua now.",
        "",
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      assert.equals(" ✽ Infusing… 8m 24s ↓24.8k ", title())
      assert.same({ " Reading parser.lua now." }, body())
    end)

    it("goes back to the plain label with nothing running", function()
      terminal({
        "  Done. Anything else?",
        "",
        "✻ Cooked for 1m 40s",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      assert.equals(config.options.notification.title, title())
    end)

    it("drops the tokens, then the timer, rather than the verb", function()
      terminal({
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })

      config.setup({ notification = { width = 24 } })
      notification.show()
      assert.equals(" ✽ Infusing… 8m 24s ", title())

      notification.hide()
      config.setup({ notification = { width = 16 } })
      notification.show()
      assert.equals(" ✽ Infusing… ", title())
    end)

    it("keeps the tokens when the live line carried no timer", function()
      terminal({
        "✽ Infusing… (↓ 1.4k tokens · esc to interrupt)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      assert.equals(" ✽ Infusing… ↓1.4k ", title())
    end)

    it("hands the state back to the body when the title is not carrying it", function()
      terminal({
        "  Reading parser.lua now.",
        "",
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { status_in_title = false } })
      notification.show()
      assert.equals(config.options.notification.title, title())
      assert.same({
        " Reading parser.lua now.",
        " ✽ Infusing… (8m 24s · ↓24.8k)",
      }, body())
    end)
  end)

  describe("waiting", function()
    it("says so under the message, with the finished turn as the detail", function()
      terminal({
        "  Done. Anything else?",
        "",
        "✻ Cooked for 1m 40s",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      assert.same({ " Done…", " ❯ Waiting for you · Cooked for 1m 40s" }, body())
    end)

    it("says so the moment Claude starts, with no turn behind it", function()
      terminal({ "  Welcome to Claude Code!", RULE, " > ", RULE })
      notification.show()
      assert.equals(" ❯ Waiting for you", body()[#body()])
    end)

    it("says nothing while Claude is working", function()
      terminal({
        "  Reading parser.lua now.",
        "",
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      assert.same({ " Reading parser.lua now." }, body())
    end)

    it("leaves the finished turn's marker alone when waiting is off", function()
      terminal({
        "  Done. Anything else?",
        "",
        "✻ Cooked for 1m 40s",
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { waiting = false } })
      notification.show()
      assert.equals(" ✓ Cooked for 1m 40s", body()[#body()])
    end)

    it("says nothing at all when there is no turn and waiting is off", function()
      terminal({ "  Welcome to Claude Code!", RULE, " > ", RULE })
      config.setup({ notification = { waiting = false } })
      notification.show()
      assert.same({ " Welcome to Claude Code!" }, body())
    end)
  end)

  describe("colour", function()
    it("splits the title between the verb and its detail", function()
      terminal({
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      local chunks = title_chunks()
      assert.equals("✽ Infusing…", chunks[2][1])
      assert.equals("FloatingClaudeStatus", chunks[2][2])
      assert.equals(" 8m 24s ↓24.8k", chunks[3][1])
      assert.equals("FloatingClaudeDetail", chunks[3][2])
    end)

    it("paints the waiting line, and the marker under waiting = false", function()
      terminal({
        "  Done. Anything else?",
        "",
        "✻ Cooked for 1m 40s",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      local painted = paint()
      -- The glyph is its own mark so it can pulse without the words moving.
      assert.equals("FloatingClaudeWaiting", painted[#painted - 1].hl_group)
      assert.equals(0, painted[#painted - 1].col)
      assert.equals(1 + #"❯", painted[#painted - 1].end_col)
      assert.equals("FloatingClaudeWaiting", painted[#painted].hl_group)
      assert.equals(#body()[#body()], painted[#painted].end_col)

      notification.hide()
      config.setup({ notification = { waiting = false } })
      notification.show()
      assert.equals("FloatingClaudeDone", paint()[#paint()].hl_group)
    end)

    it("marks a running tool call, and only the marker", function()
      terminal({
        "● Running 3 shell commands · 3s…",
        "  ⎿  $ git push -q",
        "",
        "✽ Infusing… (3s)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      -- Amber, not grey: Claude is working, so the marker is on its bright half.
      assert.same({
        { row = 0, col = 1, end_col = 1 + #"⎿", hl_group = "FloatingClaudeStatus" },
      }, paint())
    end)

    it("marks Claude's bullet, and only the bullet", function()
      terminal({
        "● Reading parser.lua now.",
        "",
        "✽ Infusing… (3s)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      assert.same({
        { row = 0, col = 1, end_col = 1 + #"●", hl_group = "FloatingClaudeBullet" },
      }, paint())
    end)

    it("dims the whole echo of your own prompt, every wrapped row of it", function()
      terminal({
        "❯ and what about the colours in the notification, can we have them?",
        "",
        "✽ Infusing… (3s)",
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 30 } })
      notification.show()
      local painted = paint()
      assert.is_true(#painted >= 2)
      for i, mark in ipairs(painted) do
        assert.equals("FloatingClaudePrompt", mark.hl_group)
        assert.equals(0, mark.col)
        assert.equals(#body()[i], mark.end_col)
      end
    end)

    it("dims the marker on content that did not fit", function()
      terminal({
        "  " .. string.rep("word ", 60),
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 40, max_height = 2 } })
      notification.show()
      local painted = paint()
      assert.equals(1, #painted)
      assert.equals("FloatingClaudeMore", painted[1].hl_group)
      assert.equals(#body()[2], painted[1].end_col)
    end)

    it("survives the redraw that reconfigures a live window", function()
      terminal({
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      -- Not hide() first: this is the path the refresh timer takes four times a
      -- second, where the title goes through nvim_win_set_config instead of
      -- nvim_open_win.
      notification.show()
      assert.equals("FloatingClaudeStatus", title_chunks()[2][2])
      assert.equals(" ✽ Infusing… 8m 24s ↓24.8k ", title())
    end)

    it("dims the marker a shortened sentence ends with", function()
      terminal({
        "● Answering the question directly first: it is not possible. I checked.",
        "",
        "✽ Infusing… (3s)",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      local painted = paint()
      assert.equals("FloatingClaudeBullet", painted[1].hl_group)
      assert.equals("FloatingClaudeMore", painted[#painted].hl_group)
      assert.equals(#body()[#body()], painted[#painted].end_col)
    end)

    it("defines its groups as overridable links", function()
      terminal({ "  Hello.", RULE, " > ", RULE })
      notification.show()
      assert.equals(
        "DiagnosticWarn",
        vim.api.nvim_get_hl(0, { name = "FloatingClaudeStatus" }).link
      )
      assert.equals("Comment", vim.api.nvim_get_hl(0, { name = "FloatingClaudeDetail" }).link)
    end)
  end)

  describe("pulse", function()
    -- One render per half-period, so a redraw is a blink.
    local function every_render()
      config.setup({ notification = { refresh_ms = 120, pulse_ms = 120 } })
    end

    local function glyph()
      return paint()[1].hl_group
    end

    it("blinks the waiting glyph, and leaves the words beside it alone", function()
      terminal({ "  Welcome to Claude Code!", RULE, " > ", RULE })
      every_render()
      notification.show()
      assert.equals("FloatingClaudeWaiting", glyph())
      notification.show()
      assert.equals("FloatingClaudeTick", glyph())
      notification.show()
      assert.equals("FloatingClaudeWaiting", glyph())
      -- Whatever the glyph is doing, the rest of the line holds still.
      assert.equals("FloatingClaudeWaiting", paint()[2].hl_group)
    end)

    it("flickers a running tool call between its own grey and the working amber", function()
      terminal({
        "● Running 3 shell commands · 3s…",
        "  ⎿  $ git push -q",
        "",
        "✽ Infusing… (3s)",
        RULE,
        " > ",
        RULE,
      })
      every_render()
      notification.show()
      assert.equals("FloatingClaudeStatus", glyph())
      notification.show()
      assert.equals("FloatingClaudeTool", glyph())
    end)

    it("holds a tool call still once Claude has stopped", function()
      terminal({
        "● Ran 3 shell commands · 3s…",
        "  ⎿  $ git push -q",
        RULE,
        " > ",
        RULE,
      })
      every_render()
      notification.show()
      assert.equals("FloatingClaudeTool", glyph())
      notification.show()
      assert.equals("FloatingClaudeTool", glyph())
    end)

    it("holds everything still with pulse_ms off", function()
      terminal({ "  Welcome to Claude Code!", RULE, " > ", RULE })
      config.setup({ notification = { pulse_ms = false } })
      notification.show()
      local held = paint()
      notification.show()
      assert.same(held, paint())
      assert.equals(1, #held)
      assert.equals("FloatingClaudeWaiting", held[1].hl_group)
    end)

    it("starts on the bright half every time it opens", function()
      terminal({ "  Welcome to Claude Code!", RULE, " > ", RULE })
      every_render()
      notification.show()
      notification.show()
      assert.equals("FloatingClaudeTick", glyph())
      notification.hide()
      notification.show()
      assert.equals("FloatingClaudeWaiting", glyph())
    end)
  end)

  describe("body", function()
    it("wraps Claude's prose to its own width, off the border", function()
      terminal({
        "  Checked the queue against the repo as",
        "  it stands. Five things are still open.",
        "",
        "✽ Infusing… (3s)",
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 40, body = "block" } })
      notification.show()
      assert.same({
        " Checked the queue against the repo as",
        " it stands. Five things are still open.",
      }, body())
      assert.equals(#body(), vim.api.nvim_win_get_config(state.mini_win).height)
    end)

    it("marks the cut when there is more than fits", function()
      terminal({
        "  " .. string.rep("word ", 60),
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 40, max_height = 3 } })
      notification.show()
      local rendered = body()
      assert.equals(3, #rendered)
      assert.is_true(vim.endswith(rendered[3], "…"))
    end)

    it("survives a window with no room to wrap in", function()
      terminal({
        "  " .. string.rep("a", 120),
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 1, max_height = 4 } })
      notification.show()
      assert.is_true(#body() <= 4)
    end)

    it("places a character wider than the window it has to fit in", function()
      terminal({
        "  " .. string.rep("漢", 20),
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 3, max_height = 4 } })
      notification.show()
      assert.is_true(#body() > 0)
      assert.is_true(#body() <= 4)
    end)

    it("breaks inside a token too wide to fit on its own", function()
      terminal({
        "  " .. string.rep("a", 120),
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 40 } })
      notification.show()
      for _, line in ipairs(body()) do
        assert.is_true(vim.fn.strdisplaywidth(line) <= 40)
      end
    end)
  end)
end)
