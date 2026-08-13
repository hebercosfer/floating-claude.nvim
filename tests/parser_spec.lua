-- The scraping heuristics, driven with buffers shaped like Claude Code's TUI.
-- Fixtures mirror what `terminal.lua` actually holds: a conversation, then the
-- live status line, then the input prompt framed by two full-width rules (or,
-- on the older UI, a rounded box).

local config = require("floating-claude.config")
local parser = require("floating-claude.parser")
local state = require("floating-claude.state")

local RULE = string.rep("─", 40)

local buffers = {}

local function buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  table.insert(buffers, buf)
  state.buf = buf
  return buf
end

describe("parser", function()
  after_each(function()
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    buffers = {}
    state.buf = -1
    config.setup({})
  end)

  describe("is_working", function()
    it("sees the live status line above the prompt", function()
      buffer({
        "Previous turn.",
        "",
        "I'll check the parser now.",
        "",
        "✶ Baked for 17s · 1.2k tokens (esc to interrupt)",
        RULE,
        " > ",
        RULE,
      })
      assert.is_true(parser.is_working())
    end)

    it("is idle when the prompt has no status line above it", function()
      buffer({
        "Previous turn.",
        "",
        "Done. Anything else?",
        RULE,
        " > ",
        RULE,
      })
      assert.is_false(parser.is_working())
    end)

    it("looks past a footer line between the status and the prompt", function()
      buffer({
        "Working on it.",
        "",
        "✶ Thinking for 3s (esc to interrupt)",
        "",
        "Tip: press esc to interrupt",
        RULE,
        " > ",
        RULE,
      })
      assert.is_true(parser.is_working())
    end)

    it("recognises the older rounded prompt box", function()
      buffer({
        "Working on it.",
        "✶ Thinking for 5s (esc to interrupt)",
        "╭────────────────────╮",
        "│ >                  │",
        "╰────────────────────╯",
      })
      assert.is_true(parser.is_working())
    end)

    it("does not mistake conversation text for a status line", function()
      buffer({
        "It took 12s to run the suite, which is fine.",
        RULE,
        " > ",
        RULE,
      })
      assert.is_false(parser.is_working())
    end)

    -- The bug that kept the float in the corner for good. Transcribed off a
    -- live screen: the turn is over, but the summary Claude leaves behind
    -- carries a duration and a mid-dot, which the old heuristic read as a
    -- running spinner. `busy` then never went false, the idle clock never
    -- started, and nothing after a diff could bring the float back.
    it("is idle once the turn ends, however the summary is punctuated", function()
      buffer({
        "  ⎿  Found 10 new diagnostic issues in 1 file (ctrl+o to expand)",
        "",
        "● Prioritized 2 leads (is_working flapping; the mini_win branch) · 44s",
        "✻ Cooked for 1m 40s",
        "  ⎿  Tip: Use /btw to ask a side question without interrupting Claude",
        "                                                    ◉ xhigh · /effort",
        RULE,
        "❯ ",
        RULE,
      })
      assert.is_false(parser.is_working())
    end)

    -- ...and the live line from the same screen still has to read as working,
    -- which the interrupt hint no longer covers: this CLI does not render it.
    it("sees the live line even without the interrupt hint", function()
      buffer({
        "● Prioritized 2 leads · 44s",
        "",
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        "  ⎿  Tip: Use /btw to ask a side question without interrupting Claude",
        RULE,
        "❯ ",
        RULE,
      })
      assert.is_true(parser.is_working())
    end)

    it("is false with no terminal buffer", function()
      state.buf = -1
      assert.is_false(parser.is_working())
    end)
  end)

  describe("status_lines", function()
    it("says so when Claude is not running", function()
      state.buf = -1
      assert.same({ "(Claude Code is not running)" }, parser.status_lines())
    end)

    it("pulls the message paragraph in with the status line", function()
      buffer({
        "An older turn nobody asked for.",
        "",
        "Reading parser.lua now.",
        "",
        "✶ Baked for 17s (esc to interrupt)",
        RULE,
        " > ",
        RULE,
      })
      local lines = parser.status_lines()
      assert.equals("Reading parser.lua now.", lines[1])
      assert.is_not_nil(lines[#lines]:find("17s", 1, true))
      -- The blank separator between them is kept; the older turn is not.
      assert.equals(3, #lines)
    end)

    it("shows only the last paragraph when idle", function()
      buffer({
        "An older turn.",
        "",
        "Done. Anything else?",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "Done. Anything else?" }, parser.status_lines())
    end)

    it("honours the max_lines cap", function()
      config.setup({ notification = { max_lines = 3 } })
      buffer({
        "one",
        "two",
        "three",
        "four",
        "five",
        RULE,
        " > ",
        RULE,
      })
      assert.is_true(#parser.status_lines() <= 3)
    end)

    it("reports an empty terminal", function()
      buffer({ "" })
      assert.same({ "(no output yet)" }, parser.status_lines())
    end)
  end)

  describe("diff_pending", function()
    local diff_buf

    after_each(function()
      if diff_buf and vim.api.nvim_buf_is_valid(diff_buf) then
        vim.api.nvim_buf_delete(diff_buf, { force = true })
      end
      diff_buf = nil
    end)

    it("is false with no diff buffers around", function()
      assert.is_false(parser.diff_pending())
    end)

    it("spots the proposed side of an edit approval", function()
      diff_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(diff_buf, "✻ [Claude Code] init.lua (a1b2c3) ⧉ (proposed)")
      assert.is_true(parser.diff_pending())
    end)

    it("spots a proposed new file", function()
      diff_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(diff_buf, "✻ [Claude Code] new.lua (NEW FILE - proposed)")
      assert.is_true(parser.diff_pending())
    end)

    it("ignores ordinary buffers", function()
      diff_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(diff_buf, "lua/floating-claude/parser.lua")
      assert.is_false(parser.diff_pending())
    end)
  end)

  describe("diff_visible", function()
    local diff_buf

    -- The proposed side as upstream builds it: an unlisted scratch buffer,
    -- which is bufhidden="hide", so closing its window leaves it loaded.
    local function proposed()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "✻ [Claude Code] init.lua (a1b2c3) ⧉ (proposed)")
      return buf
    end

    after_each(function()
      vim.cmd("silent! tabonly | silent! only")
      if diff_buf and vim.api.nvim_buf_is_valid(diff_buf) then
        vim.api.nvim_buf_delete(diff_buf, { force = true })
      end
      diff_buf = nil
    end)

    it("is false with no diff buffers around", function()
      assert.is_false(parser.diff_visible())
    end)

    it("is true while the proposed side is in a window", function()
      diff_buf = proposed()
      vim.cmd("split")
      vim.api.nvim_win_set_buf(0, diff_buf)
      assert.is_true(parser.diff_visible())
    end)

    it("sees a diff sitting in another tabpage", function()
      -- open_in_new_tab puts the diff somewhere the current tab cannot see,
      -- and the float would still be drawn over it on the way back.
      diff_buf = proposed()
      vim.cmd("tabnew")
      vim.api.nvim_win_set_buf(0, diff_buf)
      vim.cmd("tabprevious")
      assert.is_true(parser.diff_visible())
    end)

    it("is false once the window closes, though the buffer is still loaded", function()
      -- The regression: a denied diff whose tab the user closed by hand.
      -- diff_pending() still says yes and must -- see provider.lua -- but
      -- counting this as busy kept the float in the corner forever.
      diff_buf = proposed()
      vim.cmd("split")
      vim.api.nvim_win_set_buf(0, diff_buf)
      vim.cmd("close")

      assert.is_true(vim.api.nvim_buf_is_loaded(diff_buf))
      assert.is_true(parser.diff_pending())
      assert.is_false(parser.diff_visible())
    end)
  end)
end)
