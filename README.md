# floating-claude.nvim

[![CI](https://github.com/hebercosfer/floating-claude.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/hebercosfer/floating-claude.nvim/actions/workflows/ci.yml)

> **For those who read the code, we salute you!** There is no API for "what is
> Claude doing right now". This plugin finds out by squinting at a terminal
> buffer, hunting for a spinning asterisk next to a number followed by the
> letter s. That's it. That's the mechanism. Enjoy `parser.lua`, and mind the
> box-drawing glyphs.

A floating-window terminal provider for
[claudecode.nvim](https://github.com/coder/claudecode.nvim) improving the
workflow for those who read (and write) the code.

Claude Code opens in a centered float instead of a split — and, crucially, gets
out of your way on its own: when Claude proposes an edit, the float collapses
into a small corner notification so the diff is visible, and it comes back the
moment the diff closes.

https://github.com/user-attachments/assets/841ad723-f291-4ac7-b7fd-f6034bf92a98

## See it move

That recording is `:FloatingClaudeDemo auto` running unattended — the float, the
corner it collapses into, both shapes of the notification body, an edit
approval it gets out of the way for and comes back from, and the corner dragged
aside, hidden, and back when Claude is waiting.

`:FloatingClaudeDemo` runs the same tour interactively, pausing to ask you to
click the parts that are about clicking.

The Claude in that float is a scripted stand-in: no CLI, no network, nothing
typed. Everything around it is the real plugin reading a fake terminal, so the
tour runs with neither claudecode.nvim nor the Claude Code CLI installed, and it
comes out the same way twice. It borrows the plugin's defaults while it runs and
hands your own settings back at the end; `:FloatingClaudeDemo stop` ends it
early.

## Requirements

- Neovim 0.11+
- [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) — `main`,
  tested at [`2390c6e`](https://github.com/coder/claudecode.nvim/commit/2390c6e45c4789072c293ac69de051d169668b29)
  (v0.3.0 + 53, 2026-06-25); v0.2.0 is the floor
- Claude Code CLI 2.1+ — tested at 2.1.296

Both are hard requirements, not suggestions: this plugin implements
claudecode.nvim's terminal provider interface and reads Claude's state out of
its rendered TUI, so an older claudecode.nvim (no `terminal.ensure_visible`) or
an older CLI (a different prompt/status area) leaves the auto-minimize silently
not working. See [Compatibility](#compatibility).

On an older Neovim? Previous floors keep their own maintained lines — see
[Older Neovim](#older-neovim).

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
    refresh_ms = 120,   -- how often the corner redraws while Claude works
    pulse_ms = 700,     -- a running tool call's ⎿ flickers every pulse_ms / 2; false holds it still
    body = "sentence",  -- "sentence" (opening sentence) or "block" (paragraph)
    max_lines = 12,     -- "block" mode, when reading the screen: lines tailed
    gaps = 1,           -- "block" mode, when reading the screen: blank separators crossed
    border = "rounded",
    status_in_title = true,  -- Claude's state in the title, not the body
    waiting = "Waiting for you",  -- said under the message while Claude is idle
    title = " Claude ",
    title_pos = "center",
    zindex = 60,
    draggable = true,   -- drag it out of the way with the mouse; false leaves the button alone
  },
  -- Hear Claude through the events Claude Code posts to a small listener on
  -- 127.0.0.1, instead of reading its screen. false reads the screen for
  -- everything; `keep` is how many events :FloatingClaudeEvents can show you
  -- (0 keeps none). See "Privacy and security".
  hooks = { enabled = true, keep = 50 },
  auto = {
    minimize_on_diff = true,   -- minimize when an edit-approval diff opens
    -- What brings the float back from the corner: "idle" when Claude finishes
    -- a turn or asks you something, "request" only when it asks, false never.
    restore_on_input = "idle",
    -- What brings a hidden Claude back, as the corner: "request" when it asks
    -- you something (a permission, a question, a plan, a failed turn), "idle"
    -- also when it finishes a turn, false never.
    show_hidden = "request",
    minimize_on_leave = true,  -- minimize when focus leaves the float
    restore_on_enter = true,   -- restore when the notification is entered
    restore_idle_ms = 1200,    -- wait after a finished turn before restoring; requests act at once
    watch_ms = 300,            -- screen poll interval, when reading the screen
  },
  keymaps = {
    -- Terminal-mode mapping in the Claude buffer, to minimize without leaving
    -- insert mode. Set to false to skip it.
    minimize = "<C-x><C-m>",
    -- Normal-mode mapping that takes Claude off the screen, float and corner
    -- both, while it keeps running. Set to false to skip it; a mapping of
    -- your own on the same key is left alone.
    hide = "<leader>aq",
    -- Normal-mode mapping that opens what the plugin heard from Claude, as
    -- Claude sent it. Same rules as `hide`.
    events = "<leader>ae",
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
| `FloatingClaudeError`   | `DiagnosticError`| a turn that failed (rate limit, API error) |

```lua
-- e.g. the timer without your colourscheme's italic comments
vim.api.nvim_set_hl(0, "FloatingClaudeDetail", { link = "LineNr" })
```

## Commands and API

| Command                        | Lua                                        | Does                                     |
| ------------------------------ | ------------------------------------------ | ---------------------------------------- |
| `:FloatingClaudeMinimize`      | `require("floating-claude").minimize()`     | Collapse the float into the notification |
| `:FloatingClaudeRestore`       | `require("floating-claude").restore()`      | Bring the full float back                |
| `:FloatingClaudeToggle`        | `require("floating-claude").toggle_mini()`  | Flip between the two                     |
| `:FloatingClaudeHide`          | `require("floating-claude").hide()`         | Take both off the screen (`<leader>aq`)  |
| `:FloatingClaudeEvents`        | `require("floating-claude").events()`       | Show what the plugin heard from Claude (`<leader>ae`) |
| `:FloatingClaudeDemo [auto]`   | `require("floating-claude").demo(opts)`     | Run the [guided tour](#see-it-move)      |
| `:FloatingClaudeDemo stop`     | `require("floating-claude").demo_stop()`    | End the tour early                       |

`require("floating-claude").is_running()` reports whether Claude Code is live.

Hiding leaves Claude running with neither window up. It comes back as the
corner on its own when Claude asks you for something — a permission, a
question, a plan to approve, a turn that failed — and, with
`auto.show_hidden = "idle"`, when a turn simply finishes too. `:ClaudeCode` — the
`<leader>ac` in claudecode.nvim's example config — brings back the full float
whenever you want it. `<leader>aq` is mapped in normal mode only: inside the
float your keys go to Claude, so step out with `<C-\><C-n>` first, or minimize
with `<C-x><C-m>` and hide from there.

Example keymap:

```lua
vim.keymap.set("n", "<leader>an", function()
  require("floating-claude").toggle_mini()
end, { desc = "Minimize Claude to notification" })
```

## How the auto-minimize works

### How it hears Claude

When Claude starts, the plugin adds `--settings <file>` to its command line.
The file registers HTTP hooks: Claude Code posts each lifecycle event — a
prompt, a tool call, a permission dialog, a paragraph it wrote, a finished or
failed turn — to a small listener the plugin runs on `127.0.0.1`. The listener
lives on a thread of its own, so it answers within a millisecond or two however
busy Neovim is, and it always answers with an empty `200`: it never approves or
changes anything. Your own hooks keep running alongside these.

What reaches the editor follows where Claude is. Maximized, nothing does: the
listener only remembers the turn. In the corner, every event redraws it. Hidden,
only what could bring Claude back. So the corner takes its words from Claude's
own events, and tells "Claude finished" apart from "Claude needs a response" —
which `auto.restore_on_input` and `auto.show_hidden` use.

The screen is still read for one line. The title borrows Claude's live status
line — `✽ Infusing… 8m 24s ↓24.8k` — and that line is also the safety net:
pressing Esc fires no hook at all, so a corner that sees no live line after
Claude went quiet calls the turn over.

Claude is read off the screen instead, the way the rest of this section
describes, when hooks are unavailable: `hooks = false`, a Claude Code older than
2.1.301 (or one whose version cannot be read), a `claude` command that already
passes its own `--settings`, or a corner that sees Claude working while no event
has ever arrived (hooks disabled by a policy, say). `:checkhealth
floating-claude` says which and why.

### When it reads the screen

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

A diff is a detour: once it closes, Claude goes back to what it was when the
diff opened. A float the diff took away comes straight back, even though Claude
is still working; a Claude that was in the corner stays there, and one you had
hidden stays hidden.

From the corner, Claude comes back as the float once it is waiting on you
(through the hooks: when it finishes a turn, after `restore_idle_ms`, or at once
when it asks you something). Reading the screen, that restore waits for _sustained_ idle (`restore_idle_ms`) after a busy→idle
transition, so the brief lull between approving a diff and Claude resuming
doesn't pop the float over your work. Because the clock only starts on a real
busy→idle edge, a manual minimize while Claude is already idle is never undone
by the watcher. A hidden Claude comes back on that same edge, but only as far
as the corner: enough to tell you it is waiting, without landing on your work.

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

Work moves and waiting holds still, so a glance tells you which one you are in.
Claude cycles its spinner glyph — `· ✢ * ✶ ✻ ✽` and back — about every 120ms,
and the title passes that glyph straight through, which is why `refresh_ms`
samples at the same rate: slower and a live turn looks stuck. A running tool
call flickers its `⎿` between grey and the working amber every `pulse_ms / 2`
on top of that. Only the glyph moves — the words beside it would be unreadable
if they blinked too — and a `⎿` left over from a tool call that has already
finished holds still, because pulsing it would claim work that is not
happening. So does the `❯` of a notification waiting on you: nothing is going
on, and the corner should look it.

```
running tool ⎿     ███···███···███···███···
waiting ❯          ████████████████████████
finished, idle     ························
```

`pulse_ms = false` holds the tool call still too. A refresh costs about 0.2ms, so the
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

The corner can also be dragged, by its body or its border, when it is sitting
on something you need to read — the end of a file, usually. Neovim drags
nothing but status lines and separators, so while the corner is up the plugin
takes the left button: a press inside the corner picks it up, anywhere else is
handed straight on, and a press and release that never moved is still a click
that brings the float back. It stays where you drop it for the rest of the
session, kept on screen if the editor shrinks. A global `<LeftMouse>`,
`<LeftDrag>` or `<LeftRelease>` mapping of your own is set aside while the
corner is up and put back when it goes; `notification.draggable = false` leaves
the button alone entirely.

## Privacy and security

Hearing Claude through its hooks means the plugin receives what Claude Code
posts, and it posts a lot: your prompts, Claude's replies, the input of every
tool call (commands, the contents of files it writes) and their output (command
output, the files it reads). The plugin cannot ask for less. What it does with
it:

- **Kept in memory only.** The listener keeps the last `hooks.keep` events
  (50) for `:FloatingClaudeEvents`, with long values cut at 2000 bytes, plus
  the few fields the corner needs. Nothing is written to disk, nothing leaves
  the machine, and it is all dropped when Claude exits. `hooks = { keep = 0 }`
  keeps no copies at all; `hooks = false` turns the listener off.
- **Look for yourself.** `<leader>ae` (`:FloatingClaudeEvents`) opens those
  events exactly as Claude sent them. A secret that passed through — a `cat
  .env` — shows up there, cut at the cap: in plain view rather than hidden.
- **Only Claude gets in.** The listener binds `127.0.0.1` on a random port and
  drops any request without the session's token, a fresh one each time Claude
  starts. Anything else that connects is hung up on: a request head past 16 KiB,
  a connection that goes quiet for 5 seconds, more than 64 at once. The token
  lives in the settings file, in Neovim's run directory with mode `0600` —
  never on the command line, which every user on the machine can read — and the
  file is deleted when Claude exits or Neovim quits.
- **It never decides anything.** Claude acts on what its hooks reply, so the
  listener only ever replies with an empty `200`. For the same reason the port
  stays open for as long as Claude runs: a port given up early could be taken
  by another program that would answer in its place.

## Compatibility

The supported pair is pinned in `compat.lua` and checked the first time Claude
is spawned; `:checkhealth floating-claude` reports what you actually have.

| Dependency      | Minimum | Tested against                   |
| --------------- | ------- | -------------------------------- |
| Neovim          | 0.11    | 0.12.4                           |
| claudecode.nvim | 0.2.0   | `main` @ `2390c6e` (v0.3.0 + 53) |
| Claude Code CLI | 2.1.0   | 2.1.296                          |

From claudecode.nvim we need `terminal.ensure_visible` — what lets a minimized
Claude *stay* minimized while you resolve a diff — and the `claudecode.diff`
buffer names `parser.diff_pending()` matches. Its in-source version field lags
its tags (the v0.3.0 tree still reports `0.2.0`), so the number is treated as a
floor and the rest is feature-detected. From the CLI we need the rule-framed
input prompt and, above it while a turn runs, a spinner line carrying its
elapsed time in parentheses — `✽ … (8m 24s · …)`, or the older `… (esc to
interrupt)`. A UI that renders neither parses as "always idle".

Hearing Claude through its hooks needs Claude Code 2.1.301 or newer — the first
verified to post the events the listener reads. An older CLI is read off the
screen, as above.

A mismatch is a warning, never a hard failure: the float still works, the
automatic minimize/restore is what degrades. To freeze the tested pair instead
of tracking `main`, pin it in your plugin spec
(`{ "coder/claudecode.nvim", commit = "2390c6e" }`).

## Versioning

Tagged releases follow [Semver (Semantic Versioning)](https://semver.org/), with
the history in [CHANGELOG.md](CHANGELOG.md). The current version is readable at
runtime:

```lua
tostring(require("floating-claude").version)  --> "major.minor.patch"
```

The public surface is `setup()` options, the provider table, the commands and
the Lua API. The versions in the table above are not part of it, and they move
under two different rules:

- **Retarget** — claudecode.nvim or the Claude Code TUI changed and this plugin
  had to follow, usually in `parser.lua`. A **minor** bump: what the
  auto-minimize does changed, without a line of API changing.
- **Re-verify** — a newer version was tested and nothing here needed to change.
  A **patch** bump: the pin is a claim about what was tested, and the claim got
  refreshed.

Either way the pair moves only at release time. Between releases it says what
the last release was tested against, which is the useful thing for it to say.

To follow tagged releases instead of `main`:

```lua
dependencies = { { "hebercosfer/floating-claude.nvim", version = "*" } },
```

### Older Neovim

Raising the minimum Neovim is a breaking change, so it takes a minor bump and
the outgoing line keeps going on its own branch, named `support/nvim-<floor>`.
Those branches take fixes, and features too where they work without the newer
Neovim; only what genuinely needs the higher floor is `main`-only.

| Neovim | Plugin line | Branch              | Pin with             |
| ------ | ----------- | ------------------- | -------------------- |
| 0.11+  | 0.4.x       | `main`              | `version = "~0.4.0"` |
| 0.10   | 0.1.x       | `support/nvim-0.10` | `version = "~0.1.0"` |

```lua
dependencies = { { "hebercosfer/floating-claude.nvim", version = "~0.1.0" } },
```

`~0.1.0` accepts 0.1.1 and 0.1.2 but never 0.2.0, so a floor you cannot run
never arrives as an update.

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

GitHub Actions runs the same `make test` on Neovim 0.11.7 (the floor above),
0.12.4 and nightly, plus `stylua --check`. A nightly failure is reported but
does not fail the run.

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
| `demo/`             | The guided tour: a scripted Claude, a stand-in diff      |
| `docs/`             | The recording at the top of this file, and how to remake it |

## License

MIT
