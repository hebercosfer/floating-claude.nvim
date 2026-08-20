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

  describe("status_lines, whole block", function()
    -- `body = "block"` throughout: the default is one sentence, covered below.
    before_each(function()
      config.setup({ notification = { body = "block" } })
    end)

    it("says so when Claude is not running", function()
      state.buf = -1
      assert.same({ "(Claude Code is not running)" }, parser.status_lines())
    end)

    it("unwraps prose the TUI hard-wrapped at the float's width", function()
      buffer({
        "  Checked the queue against the repo as",
        "  it stands. Five things are still open.",
        RULE,
        " > ",
        RULE,
      })
      assert.same({
        "Checked the queue against the repo as it stands. Five things are still open.",
      }, parser.status_lines())
    end)

    it("leaves lines that stopped well short of the wrap alone", function()
      buffer({
        "  one",
        "  two",
        "  three",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "one", "two", "three" }, parser.status_lines())
    end)

    it("starts a new line at a list marker, however full the line above", function()
      buffer({
        "  Three things are still open, and here",
        "  - the first one, which matters most",
        RULE,
        " > ",
        RULE,
      })
      assert.same({
        "Three things are still open, and here",
        "- the first one, which matters most",
      }, parser.status_lines())
    end)

    it("collapses a tool call to what it is doing", function()
      buffer({
        "  Dumping the live Claude terminal buffer via RPC",
        "  ⎿  $ cat > /tmp/dump.lua <<'LUA'",
        "     local out = {}",
        '     local parser = require("floating-claude.parser")…',
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "⎿ Dumping the live Claude terminal buffer via RPC" }, parser.status_lines())
    end)

    it("does not stutter the marker when Claude bulleted the tool call", function()
      buffer({
        "● Running 3 shell commands · 3s…",
        "  ⎿  $ git push -q",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "⎿ Running 3 shell commands · 3s…" }, parser.status_lines())
    end)

    it("keeps the live status line out of the body", function()
      buffer({
        "  Reading parser.lua now.",
        "",
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "Reading parser.lua now." }, parser.status_lines())
    end)

    it("keeps the frozen end-of-turn marker out of the body", function()
      buffer({
        "  Done. Anything else?",
        "",
        "✻ Cooked for 1m 40s",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "Done. Anything else?" }, parser.status_lines())
    end)

    it("skips the tip footer", function()
      buffer({
        "  Done. Anything else?",
        "",
        "  ⎿ Tip: press esc to interrupt",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "Done. Anything else?" }, parser.status_lines())
    end)

    it("reaches the paragraph above the newest one", function()
      buffer({
        "  First paragraph.",
        "",
        "  Second paragraph.",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "First paragraph.", "", "Second paragraph." }, parser.status_lines())
    end)

    it("shows what you asked while Claude has not answered yet", function()
      buffer({
        "  An answer from the turn before.",
        "",
        "❯ and what about the notification?",
        "",
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "❯ and what about the notification?" }, parser.status_lines())
    end)

    it("stops at the prompt you typed, so one turn never shows the last", function()
      buffer({
        "  An answer from the turn before.",
        "",
        "❯ and what about the notification?",
        "",
        "  This turn's answer.",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "This turn's answer." }, parser.status_lines())
    end)

    it("honours the max_lines cap", function()
      config.setup({ notification = { body = "block", max_lines = 3 } })
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

  describe("status_lines, one sentence", function()
    it("stops at the end of the first sentence", function()
      buffer({
        "● Answering the question directly first: copying Claude's actual",
        "  colours is not possible. I checked against your live terminal buffer.",
        RULE,
        " > ",
        RULE,
      })
      assert.same({
        "● Answering the question directly first: copying Claude's actual colours is not possible…",
      }, parser.status_lines())
    end)

    it("keeps a line that is one sentence whole, and unmarked", function()
      buffer({ "● Reading parser.lua now.", RULE, " > ", RULE })
      assert.same({ "● Reading parser.lua now." }, parser.status_lines())
    end)

    it("keeps a line with no terminator at all", function()
      buffer({ "  Ran 13 shell commands", RULE, " > ", RULE })
      assert.same({ "Ran 13 shell commands" }, parser.status_lines())
    end)

    it("does not end a sentence inside a version or a path", function()
      buffer({
        "  Tags are only v0.1.0 and v0.2.0, and parser.lua is untouched.",
        RULE,
        " > ",
        RULE,
      })
      assert.same({
        "Tags are only v0.1.0 and v0.2.0, and parser.lua is untouched.",
      }, parser.status_lines())
    end)

    it("does not end a sentence on an abbreviation", function()
      buffer({ "  See e.g. The Manual for the rest.", RULE, " > ", RULE })
      assert.same({ "See e.g. The Manual for the rest." }, parser.status_lines())
    end)

    it("ends a sentence before a code span, which Claude opens with", function()
      buffer({
        "  The fix is in notification.lua. `parser.lua` is untouched.",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "The fix is in notification.lua…" }, parser.status_lines())
    end)

    it("keeps a question mark and marks what follows it", function()
      buffer({ "● Done. Anything else?", RULE, " > ", RULE })
      assert.same({ "● Done…" }, parser.status_lines())

      buffer({ "● Anything else? I can keep going.", RULE, " > ", RULE })
      assert.same({ "● Anything else?…" }, parser.status_lines())
    end)

    it("marks a block whose first line is a whole sentence but not the whole block", function()
      buffer({
        "● First line, whole sentence.",
        "  - and a list item under it",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "● First line, whole sentence…" }, parser.status_lines())
    end)

    it("leaves a collapsed tool call alone", function()
      buffer({
        "● Running 3 shell commands · 3s…",
        "  ⎿  $ git push -q",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "⎿ Running 3 shell commands · 3s…" }, parser.status_lines())
    end)

    it("shortens the echo of your prompt the same way", function()
      buffer({
        "❯ start on the notification status work. There are some issues we",
        "  may need to address.",
        "",
        "✽ Infusing… (3s)",
        RULE,
        " > ",
        RULE,
      })
      assert.same({ "❯ start on the notification status work…" }, parser.status_lines())
    end)
  end)

  describe("status", function()
    it("reads the verb, the timer and the tokens off the live line", function()
      buffer({
        "  Working on it.",
        "",
        "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
        RULE,
        " > ",
        RULE,
      })
      local status = parser.status()
      assert.is_true(status.working)
      assert.equals("✽", status.glyph)
      assert.equals("Infusing…", status.verb)
      assert.equals("8m 24s", status.elapsed)
      assert.equals("↓24.8k", status.tokens)
    end)

    it("leaves the older shape's duration in the verb", function()
      buffer({
        "✶ Baked for 17s … (esc to interrupt)",
        RULE,
        " > ",
        RULE,
      })
      local status = parser.status()
      assert.is_true(status.working)
      assert.equals("Baked for 17s …", status.verb)
      assert.is_nil(status.elapsed)
      assert.is_nil(status.tokens)
    end)

    it("captions a finished turn with the frozen marker", function()
      buffer({
        "  Ran the suite; two specs still red · 44s",
        "",
        "✻ Cooked for 1m 40s",
        "",
        "❯ ",
        RULE,
        " > ",
        RULE,
      })
      local status = parser.status()
      assert.is_false(status.working)
      assert.equals("Cooked for 1m 40s", status.done)
    end)

    it("says nothing with no turn behind it", function()
      buffer({
        "  Hello.",
        RULE,
        " > ",
        RULE,
      })
      local status = parser.status()
      assert.is_false(status.working)
      assert.is_nil(status.done)
      assert.is_nil(status.verb)
    end)

    it("is idle with no terminal buffer", function()
      state.buf = -1
      assert.is_false(parser.status().working)
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
