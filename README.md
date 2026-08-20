# floating-claude.nvim

[![CI](https://github.com/hebercosfer/floating-claude.nvim/actions/workflows/ci.yml/badge.svg?branch=support%2Fnvim-0.10)](https://github.com/hebercosfer/floating-claude.nvim/actions/workflows/ci.yml?query=branch%3Asupport%2Fnvim-0.10)

> [!NOTE]
> **This is the Neovim 0.10 maintenance line (0.1.x).** Active development
> continues on [`main`](https://github.com/hebercosfer/floating-claude.nvim),
> which requires Neovim 0.11+. This branch keeps taking fixes, and features too
> where they work without a newer Neovim; only what genuinely needs the higher
> floor is `main`-only.
>
> Pin to this line with `version = "~0.1.0"`. On Neovim 0.11 or later, use
> `main` instead.

> **For those who read the code, we salute you!** There is no API for "what is
> Claude doing right now". This plugin finds out by squinting at a terminal
> buffer, hunting for a spinning asterisk next to a number followed by the
> letter s. That's it. That's the mechanism. Enjoy `parser.lua`, and mind the
> box-drawing glyphs.

A floating-window terminal provider for [claudecode.nvim](https://github.com/coder/claudecode.nvim).

Claude Code opens in a centered float instead of a split — and, crucially, gets
out of your way on its own: when Claude proposes an edit, the float collapses
into a small corner notification so the diff is visible, and it comes back once
Claude has settled and is waiting for you.

```
┌──────────────────────────────────────┐      ┌──────────────────────────────┐
│                                      │      │  old        │      proposed  │
│      ╭─────  Claude Code  ─────╮     │      │             │                │
│      │                         │     │  →   │             │     ╭ Claude ╮ │
│      │   > implement the …     │     │      │             │     │ ✶ 17s… │ │
│      ╰─────────────────────────╯     │      │             │     ╰────────╯ │
└──────────────────────────────────────┘      └──────────────────────────────┘
        float while you work                     minimized while you review
```

## Requirements

- Neovim 0.10+
- [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) — `main`,
  tested at [`2390c6e`](https://github.com/coder/claudecode.nvim/commit/2390c6e45c4789072c293ac69de051d169668b29)
  (v0.3.0 + 53, 2026-06-25); v0.2.0 is the floor
- Claude Code CLI 2.1+ — tested at 2.1.220

Both are hard requirements, not suggestions: this plugin implements
claudecode.nvim's terminal provider interface and reads Claude's state out of
its rendered TUI, so an older claudecode.nvim (no `terminal.ensure_visible`) or
an older CLI (a different prompt/status area) leaves the auto-minimize silently
not working. See [Compatibility](#compatibility).

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim), as a dependency of
claudecode.nvim:

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "hebercosfer/floating-claude.nvim" },
  opts = function()
    return {
      terminal = {
        provider = require("floating-claude").provider,
      },
      diff_opts = {
        -- Open the diff in its own full-screen tab instead of splitting
        -- the current layout into thirds.
        open_in_new_tab = true,
        -- Don't re-show the Claude terminal as a split in that tab; the
        -- provider's watcher already minimizes it to the corner when a
        -- diff opens, so the tab is just old | proposed.
        hide_terminal_in_new_tab = true,
      },
    }
  end,
}
```

Calling `require("floating-claude").setup()` is optional — it only changes the
defaults below.

## Configuration

```lua
require("floating-claude").setup({
  float = {
    -- Fractions of the editor (<= 1) or absolute cells (> 1).
    width = 0.8,
    height = 0.8,
    border = "rounded",
    title = " Claude Code ",
    title_pos = "center",
  },
  notification = {
    width = 64,
    max_height = 12,
    refresh_ms = 120,   -- how often the notification re-reads the terminal
    pulse_ms = 700,     -- half-period of the marker pulse; false holds it still
    body = "sentence",  -- "sentence" (opening sentence) or "block" (paragraph)
    max_lines = 12,     -- hard cap on terminal lines tailed, in "block" mode
    gaps = 1,           -- blank separators the tail may cross, in "block" mode
    border = "rounded",
    status_in_title = true,  -- Claude's state in the title, not the body
    waiting = "Waiting for you",  -- said under the message while Claude is idle
    title = " Claude ",
    title_pos = "center",
    zindex = 60,
  },
  auto = {
    minimize_on_diff = true,   -- minimize when an edit-approval diff opens
    restore_on_input = true,   -- restore once Claude waits for input
    minimize_on_leave = true,  -- minimize when focus leaves the float
    restore_on_enter = true,   -- restore when the notification is entered
    restore_idle_ms = 1200,    -- sustained idle required before restoring
    watch_ms = 300,            -- watcher poll interval
  },
  keymaps = {
    -- Terminal-mode mapping in the Claude buffer, to minimize without leaving
    -- insert mode. Set to false to skip it.
    minimize = "<C-x><C-m>",
  },
  -- Warn once per session when claudecode.nvim / Claude Code are older than
  -- the pair this plugin is built against. Set to false to silence.
  version_check = true,
})
```

### Highlights

The notification colours what it parsed. Claude's TUI colours the same pieces,
but none of that survives the trip: Neovim keeps a terminal buffer's cell
attributes inside libvterm's screen state rather than in the buffer, so the
scraped text arrives plain and there is nothing to copy. These groups are all
`default` links, so a colourscheme that defines them wins, and your own
`:highlight` wins over both.

| Group                   | Links to         | Paints                                  |
| ----------------------- | ---------------- | --------------------------------------- |
| `FloatingClaudeStatus`  | `DiagnosticWarn` | the spinner glyph and Claude's verb     |
| `FloatingClaudeDetail`  | `Comment`        | the elapsed timer and the token count   |
| `FloatingClaudeWaiting` | `DiagnosticOk`   | the `❯` and "waiting for you"           |
| `FloatingClaudeDone`    | `DiagnosticOk`   | the `✓` and a finished turn's marker    |
| `FloatingClaudeTool`    | `Comment`        | the `⎿` in front of a running tool call |
| `FloatingClaudeBullet`  | `Title`          | Claude's `●` in front of a message      |
| `FloatingClaudePrompt`  | `Comment`        | the echo of what you typed              |
| `FloatingClaudeMore`    | `Comment`        | the `…` marking what did not fit        |
| `FloatingClaudeTick`    | `NonText`        | the dim half of a pulsing marker        |

```lua
-- e.g. the timer without your colourscheme's italic comments
vim.api.nvim_set_hl(0, "FloatingClaudeDetail", { link = "LineNr" })
```

## Commands and API

| Command                   | Lua                                     | Does                                     |
| ------------------------- | --------------------------------------- | ---------------------------------------- |
| `:FloatingClaudeMinimize` | `require("floating-claude").minimize()`  | Collapse the float into the notification |
| `:FloatingClaudeRestore`  | `require("floating-claude").restore()`   | Bring the full float back                |
| `:FloatingClaudeToggle`   | `require("floating-claude").toggle_mini()` | Flip between the two                   |

`require("floating-claude").is_running()` reports whether Claude Code is live.

Example keymap:

```lua
vim.keymap.set("n", "<leader>an", function()
  require("floating-claude").toggle_mini()
end, { desc = "Minimize Claude to notification" })
```

## How the auto-minimize works

Claude Code is a TUI, so there is no API to ask what it is doing. A timer polls
two things:

- **A pending diff** — claudecode.nvim shows edit approvals as native diff
  buffers named `✻ [Claude Code] <file> … (proposed)`. Their presence means the
  float is covering something you need to see, so it minimizes.
- **The live status line** — Claude renders a spinner line (`✽ Infusing… (8m 24s
  · ↓ 24.8k tokens)`) just above its input prompt while it works. Its absence
  means Claude is idle. A duration alone does not make a line live: when the
  turn ends that same line freezes into `✻ Cooked for 1m 40s` and a summary
  lands under it, both carrying one. The parenthesised elapsed timer is what
  separates them.

Restore waits for _sustained_ idle (`restore_idle_ms`) after a busy→idle
transition, so the brief lull between approving a diff and Claude resuming
doesn't pop the float back over your work. Because the clock only starts on a
real busy→idle edge, a manual minimize while Claude is already idle is never
undone by the watcher.

The same scraping feeds the notification, refreshing every `refresh_ms`, and it
keeps the two apart. The title carries what Claude is *doing* — `✽ Infusing… 8m
24s ↓24.8k` — and only that, which leaves the body for what Claude is saying.
With nothing running there is no activity to report, so the title goes back to
the plain label and a line under the message says `❯ Waiting for you · Cooked
for 1m 40s`, where the TUI puts its own prompt. Idle is idle however Claude got
there: a turn it finished, a diff it is waiting on you to resolve, or a session
that has only just started — that last one has no marker to add. Set `waiting =
false` for the finished turn's marker on its own (`✓ Cooked for 1m 40s`), and
nothing at all when there is no turn.

Both states move, so a glance tells you which one you are in. Claude cycles its
spinner glyph — `· ✢ * ✶ ✻ ✽` and back — about every 120ms, and the title passes
that glyph straight through, which is why `refresh_ms` samples at the same rate:
slower and a live turn looks stuck. The markers pulse on top of that, at two
rhythms you can tell apart without reading them. A running tool call flickers
its `⎿` between grey and the working amber every `pulse_ms / 2`; a waiting
notification blinks its `❯` between green and dim every `pulse_ms`, twice as
slow. Only the glyph moves — the words beside it would be unreadable if they
blinked too — and a `⎿` left over from a tool call that has already finished
holds still, because pulsing it would claim work that is not happening.

```
waiting ❯          ██████······██████······
running tool ⎿     ███···███···███···███···
finished, idle     ························
```

`pulse_ms = false` holds everything still. A refresh costs about 0.2ms, so the
default rate is roughly 0.2% of one core while the notification is up, and the
pulse itself is one extmark write on top of that.

The body is the **opening sentence** of the newest thing on screen (`body =
"sentence"`), because the corner is a few lines tall and the first sentence is
what says which of Claude's answers you are looking at. `body = "block"` shows
the whole paragraph instead, and the paragraph above it as `gaps` allows.
Finding where a sentence ends is the interesting part: prose is full of full
stops that end nothing — `parser.lua`, `0.10`, `e.g.` — so a stop only counts
when whitespace and then a capital (or a quote, or a backtick) follow it.

Either way the text is re-flowed first. Claude hard-wraps its prose at the
float's width, so the body undoes that wrap before re-wrapping it at the
notification's own; otherwise every paragraph arrives pre-broken at the wrong
column and stacks up ragged. A tool call collapses to the one line naming what
is running rather than spilling its output into the corner. The echo of your own
prompt bounds the tail, so one turn never shows the last one, and it stands in
as the body while Claude is working but has not said anything yet — what you
asked is what Claude is doing. Set `status_in_title = false` to put the state
back under the message instead.

Focus moves the float too, which is what makes the mouse work. Leaving the
float minimizes it (`minimize_on_leave`) and entering the notification restores
it (`restore_on_enter`) — so clicking away collapses Claude to the corner and
clicking the corner brings it back. Both react to focus rather than to the
mouse specifically, so Vim's own window commands do the same thing; the plugin
disarms them while moving windows itself, which is why launching Claude in the
background does not immediately minimize it. `restore_on_enter` is also what
makes the notification focusable: an unfocusable float never receives a click
at all.

## Compatibility

The supported pair is pinned in `compat.lua` and checked the first time Claude
is spawned; `:checkhealth floating-claude` reports what you actually have.

| Dependency      | Minimum | Tested against                   |
| --------------- | ------- | -------------------------------- |
| Neovim          | 0.10    | 0.12                             |
| claudecode.nvim | 0.2.0   | `main` @ `2390c6e` (v0.3.0 + 53) |
| Claude Code CLI | 2.1.0   | 2.1.220                          |

From claudecode.nvim we need `terminal.ensure_visible` — what lets a minimized
Claude *stay* minimized while you resolve a diff — and the `claudecode.diff`
buffer names `parser.diff_pending()` matches. Its in-source version field lags
its tags (the v0.3.0 tree still reports `0.2.0`), so the number is treated as a
floor and the rest is feature-detected. From the CLI we need the rule-framed
input prompt and, above it while a turn runs, a spinner line carrying its
elapsed time in parentheses — `✽ … (8m 24s · …)`, or the older `… (esc to
interrupt)`. A UI that renders neither parses as "always idle".

A mismatch is a warning, never a hard failure: the float still works, the
automatic minimize/restore is what degrades. To freeze the tested pair instead
of tracking `main`, pin it in your plugin spec
(`{ "coder/claudecode.nvim", commit = "2390c6e" }`).

## Versioning

Tagged releases follow [Semver (Semantic Versioning)](https://semver.org/), with
the history in [CHANGELOG.md](CHANGELOG.md). The current version is readable at
runtime:

```lua
tostring(require("floating-claude").version)  --> "0.1.0"
```

The public surface is `setup()` options, the provider table, the commands and
the Lua API. The versions in the table above are not part of it: retargeting a
newer claudecode.nvim or Claude Code UI is a minor bump, because a redrawn TUI
changes what the auto-minimize does without changing a line of API.

To follow tagged releases instead of `main`:

```lua
dependencies = { { "hebercosfer/floating-claude.nvim", version = "*" } },
```

## Tests

Specs run on [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), against a
runtimepath holding only this plugin and plenary:

```sh
make test                             # the whole suite
make test-file FILE=tests/parser_spec.lua
make lint                             # stylua --check
```

`make test` finds plenary in your lazy.nvim or `pack/vendor` directory, honours
`PLENARY_DIR`, and clones it into `.tests/` as a last resort. plenary is only
ever a test dependency — nothing under `lua/` requires it, so it does not belong
in your plugin spec.

claudecode.nvim is deliberately absent from that runtimepath: the specs stub it
into `package.loaded`, which keeps the "not installed" path reachable and stops
the suite depending on which version happens to be checked out. The cost is that
nothing in `make test` can notice upstream moving, so the contract is checked
separately, against a real one:

```sh
make test-compat                      # needs a claude on PATH
```

That clones claudecode.nvim into `.tests/` unless `CLAUDECODE_DIR` already points
at a checkout, and asserts what this plugin leans on beyond the documented
provider interface: `terminal.ensure_visible` and `claudecode.diff` still exist,
and upstream's `required_functions` is still satisfied by the provider. The
`Compat` workflow runs it weekly against the tip of claudecode.nvim and the
latest CLI, so drift surfaces there instead of in your editor.

claudecode.nvim is deliberately absent from that runtimepath — the specs stub it
into `package.loaded` instead, so the "not installed" path stays reachable and
the suite never depends on which version happens to be checked out. Claude Code
is stubbed the same way, by a shell script that prints a version string.

GitHub Actions runs the same `make test` on Neovim 0.10.4 — the floor above, and
the newest 0.10 there is — plus `stylua --check`. That is the whole matrix: this
line exists for 0.10, so 0.10 is what it proves, and newer releases are `main`'s
to cover. The weekly `Compat` workflow pins the same 0.10.4 and lets everything
else float, so a red run there means claudecode.nvim or the CLI drifted rather
than that Neovim moved on.

## Layout

| File                | Role                                                    |
| ------------------- | ------------------------------------------------------- |
| `provider.lua`      | The claudecode.nvim terminal provider interface         |
| `terminal.lua`      | The big float, the job, minimize/restore                |
| `notification.lua`  | The corner notification window                          |
| `watcher.lua`       | The poll loop driving auto-minimize/restore             |
| `parser.lua`        | Scraping Claude's state out of the terminal buffer      |
| `state.lua`         | Shared buffer/window handles                            |
| `config.lua`        | Defaults and `setup()`                                  |
| `compat.lua`        | Supported claudecode.nvim / Claude Code versions        |
| `version.lua`       | This plugin's own version                               |
| `tests/`            | plenary specs and their minimal init                    |
| `health.lua`        | `:checkhealth floating-claude`                          |

## License

MIT
