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

    it("captions the turn Claude just finished", function()
      terminal({
        "  Done. Anything else?",
        "",
        "✻ Cooked for 1m 40s",
        RULE,
        " > ",
        RULE,
      })
      notification.show()
      assert.equals(" ✓ Cooked for 1m 40s ", title())
    end)

    it("falls back to the plain label with no turn behind it", function()
      terminal({ "  Hello.", RULE, " > ", RULE })
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

  describe("body", function()
    it("wraps Claude's prose to its own width, off the border", function()
      terminal({
        "  Checked the queue against the repo as",
        "  it stands. Five things are still open.",
        RULE,
        " > ",
        RULE,
      })
      config.setup({ notification = { width = 40 } })
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
