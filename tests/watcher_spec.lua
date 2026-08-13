-- The poll loop that moves the float in step with Claude's work cycle, driven
-- with real timers. The intervals are turned right down so the specs finish in
-- milliseconds rather than the second-and-a-bit the defaults ask for.
--
-- What these are really about is what counts as "busy". A diff the user denied
-- and then closed leaves its proposed buffer loaded but hidden (see
-- parser.lua), and while that counted as a live diff the restore never fired.

local config = require("floating-claude.config")
local state = require("floating-claude.state")
local watcher = require("floating-claude.watcher")

local RULE = string.rep("─", 40)

-- Claude at rest: a finished message, then the input prompt, and no live
-- status line between them.
local IDLE = { "Done. Anything else?", "", RULE, "> ", RULE }

-- Claude at rest as the CLI really leaves the screen: the spinner line freezes
-- into a marker and a summary lands under it, both carrying a duration.
local FINISHED = {
  "● Rewrote the parser predicate · 44s",
  "✻ Cooked for 1m 40s",
  RULE,
  "❯ ",
  RULE,
}

-- ...and mid-turn, which is the same shape plus the trailing detail group.
local WORKING = {
  "● Rewrote the parser predicate · 44s",
  "",
  "✽ Infusing… (8m 24s · ↓ 24.8k tokens)",
  RULE,
  "❯ ",
  RULE,
}

describe("watcher", function()
  local restored, minimized, handlers, buffers

  local function terminal(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    table.insert(buffers, buf)
    state.buf = buf
    return buf
  end

  -- The proposed side of an edit approval, on screen in its own window.
  local function diff_on_screen()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "✻ [Claude Code] init.lua (a1b2c3) ⧉ (proposed)")
    table.insert(buffers, buf)
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    return buf, win
  end

  before_each(function()
    config.setup({ auto = { watch_ms = 20, restore_idle_ms = 60 } })
    restored, minimized = 0, 0
    handlers = {
      restore = function()
        restored = restored + 1
      end,
      minimize = function()
        minimized = minimized + 1
      end,
    }
    buffers = {}
    -- Minimized: a live Claude with no float.
    state.buf, state.win = -1, -1
  end)

  after_each(function()
    watcher.stop()
    vim.cmd("silent! only")
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    buffers = {}
    state.buf, state.win = -1, -1
    config.setup({})
  end)

  describe("while minimized", function()
    it("stays put while the diff is on screen", function()
      terminal(IDLE)
      diff_on_screen()
      watcher.start(handlers)

      vim.wait(300, function()
        return restored > 0
      end, 20)
      assert.equals(0, restored, "the float popped back over the diff the user is reading")
    end)

    it("restores once close_tab has torn the diff down", function()
      -- The resolution that cleans up after itself: window closed, proposed
      -- buffer deleted, nothing left to see.
      terminal(IDLE)
      local buf, win = diff_on_screen()
      watcher.start(handlers)
      vim.wait(100)

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })

      assert.is_true(
        vim.wait(1000, function()
          return restored > 0
        end, 20),
        "the float never came back after the diff closed"
      )
    end)

    it("restores when the closed diff's buffer is merely hidden", function()
      -- The regression. Denying does not tear the diff down, so the tab the
      -- user closes by hand leaves a loaded, windowless proposed buffer behind
      -- -- and counting that as busy reset the idle clock on every poll, so
      -- the restore was not late, it never happened.
      terminal(IDLE)
      local buf, win = diff_on_screen()
      watcher.start(handlers)
      vim.wait(100)

      vim.api.nvim_win_close(win, true)
      assert.is_true(vim.api.nvim_buf_is_loaded(buf), "the fixture buffer was wiped, not hidden")

      assert.is_true(
        vim.wait(1000, function()
          return restored > 0
        end, 20),
        "a hidden leftover proposed buffer is still being counted as a live diff"
      )
    end)

    -- The one the user kept hitting after the two fixes above. Nothing here is
    -- about diffs: the turn that produced the diff ends, and what it leaves on
    -- screen reads as a running spinner, so `busy` never falls and the idle
    -- clock never starts. The float stays in the corner indefinitely.
    it("restores once the turn ends, summary line and all", function()
      terminal(FINISHED)
      local _, win = diff_on_screen()
      watcher.start(handlers)
      vim.wait(100)

      vim.api.nvim_win_close(win, true)

      assert.is_true(
        vim.wait(1000, function()
          return restored > 0
        end, 20),
        "Claude's finished-turn summary is still being read as a live status line"
      )
    end)

    it("stays put while Claude is still working", function()
      terminal(WORKING)
      watcher.start(handlers)

      vim.wait(300, function()
        return restored > 0
      end, 20)
      assert.equals(0, restored, "the float came back over your work mid-turn")
    end)
  end)

  describe("while the float is up", function()
    before_each(function()
      vim.cmd("split")
      state.win = vim.api.nvim_get_current_win()
    end)

    it("minimizes when a diff opens", function()
      terminal(IDLE)
      watcher.start(handlers)
      vim.wait(100)
      assert.equals(0, minimized)

      diff_on_screen()

      assert.is_true(
        vim.wait(1000, function()
          return minimized > 0
        end, 20),
        "the diff opened under the float and the float stayed there"
      )
    end)

    it("leaves the float alone for a hidden leftover", function()
      terminal(IDLE)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, "✻ [Claude Code] init.lua (a1b2c3) ⧉ (proposed)")
      table.insert(buffers, buf)

      watcher.start(handlers)
      vim.wait(300, function()
        return minimized > 0
      end, 20)
      assert.equals(0, minimized, "nothing is on screen to make room for")
    end)
  end)
end)
