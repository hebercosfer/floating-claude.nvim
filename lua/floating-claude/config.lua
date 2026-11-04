-- User-facing configuration and defaults.

local M = {}

M.defaults = {
  -- The big centered float that hosts the Claude Code terminal.
  float = {
    -- Fractions of the editor (<= 1) or absolute cells (> 1).
    width = 0.8,
    height = 0.8,
    border = "rounded",
    title = " Claude Code ",
    title_pos = "center",
  },

  -- The small corner window Claude collapses into when minimized. It tails
  -- the live status/spinner line plus the message paragraph above it.
  notification = {
    width = 64,
    max_height = 12,
    -- How often the notification re-reads the terminal buffer. Claude cycles
    -- its spinner glyph every 120ms or so and the title passes that glyph
    -- through, so sampling slower than that makes a live turn look stuck. One
    -- refresh costs about 0.2ms.
    refresh_ms = 120,
    -- Sets the pulse on a running tool call: its ⎿ flickers every
    -- `pulse_ms / 2`. A waiting notification holds still whatever this is.
    -- Set to false to hold the tool call still too.
    pulse_ms = 700,
    -- What the body shows: "sentence" for the opening sentence of the newest
    -- thing on screen, "block" for the whole paragraph. `max_lines` and `gaps`
    -- shape the block; they do nothing to a sentence.
    body = "sentence",
    -- What the corner says when Claude is heard through its hooks. "activity":
    -- Claude's latest message and, under it, whatever came after it -- the
    -- tool it is running, what it is asking you, your prompt. "messages":
    -- Claude's words alone, plus anything it needs you for. "events": as
    -- "activity", with each line labelled by its event (`PreToolUse → …`).
    -- Reading the screen instead, the corner shows what is on it.
    content = "activity",
    -- Hard cap on the number of terminal lines tailed.
    max_lines = 12,
    -- Blank-line separators the tail may cross before it stops, so the newest
    -- paragraph can pull in the one that precedes it.
    gaps = 1,
    border = "rounded",
    -- What the notification says under the message while Claude is waiting on
    -- you -- freshly started, done with a turn, or sitting on a diff you have
    -- not resolved. The finished turn's marker follows it as detail. Set to
    -- false to show that marker on its own, and nothing when there is none.
    waiting = "Waiting for you",
    -- Put Claude's state in the title -- the status verb, how long it has been
    -- at it, the tokens it has pulled down -- and leave the body for what
    -- Claude is saying. With false the state goes back to a line under the
    -- message and the title stays the plain label below.
    status_in_title = true,
    title = " Claude ",
    title_pos = "center",
    zindex = 60,
    -- Let the mouse drag the notification out of the way of what is under it.
    -- It stays where you drop it for the rest of the session; a click that
    -- does not move it still brings the float back. Set to false to leave the
    -- left button alone.
    draggable = true,
  },

  -- Learn what Claude is doing from the events Claude Code posts to a small
  -- listener on 127.0.0.1, rather than by reading its screen. false goes back
  -- to reading the screen for everything; the plugin also does that on its own
  -- when the CLI is too old for these hooks. `keep` is how many of the latest
  -- events `:FloatingClaudeEvents` can show you -- 0 keeps none.
  hooks = { enabled = true, keep = 50 },

  auto = {
    -- Minimize the float when an edit-approval diff opens, so the diff -- which
    -- the float would otherwise cover -- is visible.
    minimize_on_diff = true,
    -- What brings the float back from the corner (never while a diff is up --
    -- you are reviewing that): "idle" when Claude finishes a turn or asks you
    -- for something, "request" only when it asks you for something, false
    -- never. true still means "idle".
    restore_on_input = "idle",
    -- What brings a hidden Claude back, as the corner: "request" when Claude
    -- asks you for something -- a permission, a question, a plan to approve, or
    -- a turn that failed -- "idle" also when it finishes a turn, false never.
    show_hidden = "request",
    -- Minimize when focus leaves the float, so stepping away to your code
    -- collapses Claude to the corner instead of leaving it over your work.
    -- Any focus change counts: clicking another window, or moving there with
    -- Vim's own window commands (<C-w>h and friends).
    minimize_on_leave = true,
    -- Restore when the corner notification is entered, so clicking it brings
    -- the float back. This also makes the notification focusable, which is
    -- what lets a click reach it at all.
    restore_on_enter = true,
    -- Sustained idle required before auto-restoring. This debounce is what
    -- keeps the brief lull between a diff being resolved and Claude resuming
    -- from popping the float back over your work.
    restore_idle_ms = 1200,
    -- How often the watcher polls the terminal and diff state.
    watch_ms = 300,
  },

  keymaps = {
    -- Terminal-mode mapping, set in the Claude buffer, to minimize without
    -- leaving insert mode. Set to false to skip it. The default chord avoids
    -- Alt (swallowed by some terminals) and Claude's own keys.
    minimize = "<C-x><C-m>",
    -- Normal-mode mapping, set globally, that takes Claude off the screen
    -- entirely -- the float or the corner, whichever is up -- while it keeps
    -- running. `:ClaudeCode` brings it back as the float, and it comes back as
    -- the corner on its own when Claude asks you for something (see
    -- auto.show_hidden). Set to false to skip it; a mapping of your own on the
    -- same key is left alone.
    hide = "<leader>aq",
    -- Normal-mode mapping, set globally, that opens the latest events the
    -- plugin heard from Claude in a buffer, so you can see exactly what it
    -- listens to. Same rules as `hide`.
    events = "<leader>ae",
  },

  -- Warn once per session when the installed claudecode.nvim / Claude Code
  -- versions are older than the pair this plugin is built against (see
  -- compat.lua). Nothing is scraped through a stable API, so a mismatch shows
  -- up as an auto-minimize that quietly stops working. Set to false to silence.
  version_check = true,
}

M.options = vim.deepcopy(M.defaults)

-- The shorthands setup() accepts, spelled out: `hooks = false` (or true) for
-- the table, and the old boolean `restore_on_input = true` for "idle".
local function normalize(options)
  if type(options.hooks) == "boolean" then
    options.hooks = { enabled = options.hooks, keep = M.defaults.hooks.keep }
  end
  if options.auto.restore_on_input == true then
    options.auto.restore_on_input = "idle"
  end
  return options
end

function M.setup(opts)
  M.options = normalize(vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {}))
  return M.options
end

return M
