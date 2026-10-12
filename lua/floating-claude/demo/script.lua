-- The tour itself: what each beat says, and what it does to get there.
--
-- A beat is a caption plus a way of ending. It ends on a clock (`hold_ms`) when
-- it is just something to look at, or on a condition (`done`) when it is
-- waiting for you -- in which case `auto` is the same move made by the tour
-- itself, for the hands-free run. `beats` are things that happen part-way
-- through one, on the same clock.

local config = require("floating-claude.config")
local diff = require("floating-claude.demo.diff")
local drag = require("floating-claude.drag")
local state = require("floating-claude.state")
local terminal = require("floating-claude.terminal")
local tui = require("floating-claude.demo.tui")

local M = {}

-- What the stand-in "says" -- about this plugin, since that is what is on
-- screen. The paragraph is one sentence plus more, which is exactly the case
-- the notification's `body = "sentence"` exists for.
local PROMPT = "why does the float wait before it comes back?"

local TOOL = { "Running 2 shell commands", 'rg -n "restore_idle_ms" lua/floating-claude' }

local ANSWER = "From the corner, the float comes back only once Claude has been idle for a "
  .. "sustained stretch, and `restore_idle_ms` is how long. That debounce is the whole trick: the "
  .. "lull between a diff being resolved and Claude picking the work back up never lasts long "
  .. "enough to pop the float over what you were reading."

local SUMMARY = "Explained the restore debounce · 24s"

--- Carry the corner to `row`, `col` over `ms`, through the same handlers the
--- mouse drives: picked up one cell into its body, moved in steps, let go.
local function glide(row, col, ms)
  if not state.mini_win_valid() then
    return
  end
  local cfg = vim.api.nvim_win_get_config(state.mini_win)
  local from_row, from_col = math.floor(cfg.row), math.floor(cfg.col)
  local function at(r, c)
    return { screenrow = r + 2, screencol = c + 4 }
  end
  drag.press(at(from_row, from_col))
  local steps = 16
  for i = 1, steps do
    vim.defer_fn(function()
      local r = from_row + math.floor((row - from_row) * i / steps + 0.5)
      local c = from_col + math.floor((col - from_col) * i / steps + 0.5)
      drag.move(at(r, c))
      if i == steps then
        drag.release()
      end
    end, math.floor(i * ms / steps))
  end
end

--- The window under the float, which is what "click away" means.
local function elsewhere()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= state.win and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return nil
end

--- The beats, built at start-up so their text can read the configuration the
--- tour is actually running on.
function M.build()
  local key = config.options.keymaps.minimize or ":FloatingClaudeToggle"
  local hide = config.options.keymaps.hide or ":FloatingClaudeHide"

  return {
    {
      title = "A guided tour",
      lines = {
        "Claude Code in a centered float that gets out of your way on its own, and comes back "
          .. "when it is your turn again.",
        "The Claude in this float is a scripted stand-in: no CLI, no network, nothing typed. "
          .. "Everything around it is the real plugin, reading a fake terminal.",
        "The tour runs on the plugin's defaults and hands your own settings back at the end.",
      },
      enter = function()
        tui.type(PROMPT)
      end,
      hold_ms = 7500,
    },

    {
      title = "The float",
      lines = {
        "Claude opens centered instead of as a split, so nothing in your layout moves to make "
          .. "room for it. `float.width` and `float.height` are fractions of the editor, or "
          .. "absolute cells above 1.",
      },
      enter = function()
        tui.send()
        tui.working("Percolating")
      end,
      beats = {
        {
          1400,
          function()
            tui.tool(TOOL[1], TOOL[2])
          end,
        },
      },
      hold_ms = 5000,
    },

    {
      title = "Minimize it",
      lines = {
        ("`%s` collapses the float from terminal mode, without leaving insert — "):format(key)
          .. "`keymaps.minimize`. `:FloatingClaudeMinimize` and `:FloatingClaudeToggle` do the "
          .. "same thing from anywhere.",
      },
      hint = ("Press `%s` in the float."):format(key),
      done = function()
        return state.mini_win_valid()
      end,
      auto = function()
        terminal.minimize()
      end,
    },

    {
      title = "The corner",
      lines = {
        "The title carries what Claude is doing — glyph, verb, elapsed, tokens — which leaves "
          .. "the body for what Claude is saying: the opening sentence of the newest thing on "
          .. "screen.",
        "The `⎿` of a running tool call flickers amber while it runs. Nothing else moves; the "
          .. "words beside it would be unreadable if they did.",
      },
      beats = {
        {
          1800,
          function()
            tui.say(ANSWER)
          end,
        },
      },
      hold_ms = 9000,
    },

    {
      title = "The whole paragraph",
      lines = {
        '`notification.body = "block"` shows the paragraph instead of its opening sentence, and '
          .. "the one above it as `notification.gaps` allows.",
        "Claude hard-wraps its prose at the float's width, so the corner undoes that wrap before "
          .. "re-wrapping it at its own — otherwise every paragraph arrives pre-broken at the "
          .. "wrong column and stacks up ragged.",
      },
      enter = function()
        config.options.notification.body = "block"
      end,
      exit = function()
        config.options.notification.body = "sentence"
      end,
      hold_ms = 8000,
    },

    {
      title = "Click it back",
      lines = {
        "Entering the notification restores the float — `auto.restore_on_enter`, which is also "
          .. "what makes it focusable in the first place. An unfocusable window never receives a "
          .. "click at all.",
      },
      hint = "Click the notification.",
      done = function()
        return state.win_valid()
      end,
      auto = function()
        terminal.restore()
      end,
    },

    {
      title = "Click away",
      lines = {
        "Leaving the float minimizes it — `auto.minimize_on_leave`. It keys off focus rather "
          .. "than off the mouse, so `<C-w>h` collapses Claude just the same.",
      },
      hint = "Click your own code, anywhere outside the float.",
      done = function()
        return state.mini_win_valid()
      end,
      auto = function()
        local win = elsewhere()
        if win then
          vim.api.nvim_set_current_win(win)
        else
          terminal.minimize()
        end
      end,
    },

    {
      title = "An edit approval",
      lines = {
        "An edit approval arrives as a real Neovim diff. The float is editor-relative and would "
          .. "sit straight on top of it, so the watcher minimizes on sight and keeps Claude in "
          .. "the corner until the diff leaves the screen — `auto.minimize_on_diff`.",
        "The corner followed the diff into its own tab, still reporting.",
      },
      hint = "`a` to accept, `r` to reject — a real one takes `:ClaudeCodeDiffAccept` and "
        .. "`:ClaudeCodeDiffDeny`, which claudecode.nvim's own example config binds to "
        .. "`<leader>aa` and `<leader>ad`. Nothing is written either way.",
      -- The one beat with no blank left at the top of the screen.
      foot = true,
      enter = function()
        terminal.restore()
        tui.working("Forging")
      end,
      beats = {
        {
          1800,
          function()
            diff.open(function() end)
          end,
        },
      },
      done = diff.settled,
      auto = function()
        diff.resolve("accepted")
      end,
      -- The diff opens 1.8s into the beat, so this is really "how long does the
      -- diff stay up" plus that. At 4000 it was gone in 2.2s -- long enough to
      -- see in person, a flicker in a recording, which is the only thing this
      -- number affects.
      auto_ms = 7000,
      timeout_ms = 120000,
    },

    {
      title = "Back where it was",
      lines = {
        "Resolving it puts Claude back the way the diff found it — here the float, straight "
          .. "away, though Claude is back at work. The corner goes with the tab that held it.",
        "From the corner it would stay put until Claude went idle for a sustained stretch — "
          .. "`auto.restore_idle_ms`, 1200ms — and only on a real busy-to-idle edge, which is "
          .. "why a minimize you asked for yourself is never undone.",
      },
      enter = function()
        diff.close()
        tui.working("Simmering")
      end,
      beats = {
        {
          1500,
          function()
            tui.idle()
          end,
        },
      },
      -- On a clock, not on the float coming back: it is back before this beat
      -- has drawn its caption, so waiting for it skipped the beat entirely.
      hold_ms = 8000,
    },

    {
      title = "Waiting for you",
      lines = {
        "With nothing running there is no activity to report, so the title goes back to the "
          .. "plain label and a line under the message says what Claude is waiting for, next to "
          .. "what the turn cost.",
        "The `❯` holds still: nothing is going on, and the corner should look it. Only work "
          .. "moves, so the two states are tellable apart before you have read either.",
      },
      enter = function()
        terminal.minimize()
      end,
      beats = {
        {
          700,
          function()
            tui.finish("Cooked for 24s", SUMMARY)
          end,
        },
      },
      hold_ms = 9000,
    },

    {
      title = "Drag it out of the way",
      lines = {
        "The corner sits on the bottom right, which is where the end of a file is. Grab it by "
          .. "its body or its border and drop it wherever it is not in the way — "
          .. "`notification.draggable`.",
        "It stays where you drop it for the rest of the session. A click that does not move it "
          .. "still brings the float back, and clicks anywhere else pass straight through.",
      },
      hint = "Drag the notification somewhere else.",
      done = function()
        return state.mini_pos ~= nil and not drag.dragging()
      end,
      auto = function()
        glide(14, 62, 1600)
      end,
      -- Two sentences to read before the corner moves, and the move itself
      -- is the thing to watch -- 1800 had it gone before the caption was.
      auto_ms = 4500,
    },

    {
      title = "Hide it",
      lines = {
        ("`%s` takes Claude off the screen entirely, float and corner both, "):format(hide)
          .. "while it keeps running — `keymaps.hide`, or `:FloatingClaudeHide` from anywhere.",
      },
      hint = ("Press `%s` in your code."):format(hide),
      done = function()
        return state.mode() == "hidden"
      end,
      auto = function()
        terminal.hide()
      end,
      auto_ms = 3500,
    },

    {
      title = "Back when it is your turn",
      lines = {
        "Hidden is not forgotten. When Claude finishes and is waiting on you, it comes back as "
          .. "the corner — where you last dropped it — rather than landing the float on your "
          .. "work. `:ClaudeCode` brings the float back whenever you want it.",
      },
      enter = function()
        tui.working("Steeping")
      end,
      beats = {
        {
          2200,
          function()
            tui.finish("Steeped for 2s", "Finished while you were away · 2s")
          end,
        },
      },
      hold_ms = 9000,
    },

    {
      title = "That is the tour",
      lines = {
        "`:FloatingClaudeToggle` flips between the two windows, `:FloatingClaudeMinimize` and "
          .. "`:FloatingClaudeRestore` pick one, `:FloatingClaudeHide` takes both away, and "
          .. '`require("floating-claude").setup{}` reshapes them.',
        "Wire the provider into claudecode.nvim and the same thing happens with a real Claude "
          .. "behind it. `:FloatingClaudeDemo auto` runs this tour hands-free; the README has "
          .. "the rest.",
      },
      enter = function()
        terminal.restore()
      end,
      hold_ms = 10000,
    },
  }
end

return M
