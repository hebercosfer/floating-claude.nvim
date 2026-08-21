# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
over its public surface: `setup()` options, the provider table, the commands and
the Lua API. The claudecode.nvim / Claude Code versions a release targets are
tracked separately in `compat.lua` — moving that pair is a minor bump, since a
new Claude UI can change what the auto-minimize does without changing the API.

## [Unreleased]

### Added

- Test suite on plenary.nvim covering the parser heuristics, the version
  compatibility checks, the provider contract, config merging and the version
  itself: `make test`, `make test-file FILE=…`, `make lint`.
- GitHub Actions CI running the suite on Neovim 0.10.4, 0.11.7, 0.12.4 and
  nightly, plus a stylua formatting check.
- Compatibility specs that load a real claudecode.nvim instead of stubbing it,
  asserting the things this plugin leans on beyond the documented contract:
  `terminal.ensure_visible` and `claudecode.diff` still exist, upstream's
  `required_functions` is still satisfied by the provider, and the copy of that
  list `provider_spec.lua` keeps by hand still matches. `make test-compat`;
  skipped by `make test`, which has no claudecode.nvim on the runtimepath.
- A weekly `Compat` workflow running those specs against the tip of
  claudecode.nvim and the latest Claude Code CLI rather than the pair
  `compat.lua` pins, reporting version drift and opening an issue when the
  contract no longer holds.
- Mouse-friendly focus handling. Leaving the float minimizes it
  (`auto.minimize_on_leave`) and entering the corner notification restores it
  (`auto.restore_on_enter`), so clicking away collapses Claude and clicking the
  corner brings it back. Both key off focus rather than the mouse specifically,
  so Vim's window commands behave the same way, and both are off with one
  option each. `restore_on_enter` also makes the notification focusable, which
  is what lets a click reach it.
- Colour in the corner notification, over a family of `FloatingClaude*`
  highlight groups — the status verb, the elapsed timer and token count, the
  finished turn's marker, the `⎿`/`●` markers, the echo of your own prompt and
  the `…` that marks what did not fit. Claude's TUI colours the same pieces,
  but none of it survives the trip: Neovim keeps a terminal buffer's cell
  attributes in libvterm's screen state rather than in the buffer, so the
  scraped text arrives plain and there is nothing to copy. Every group is a
  `default` link, so a colourscheme wins over the defaults and your
  `:highlight` wins over both; the table is in the README.

### Changed

- The corner notification now says what Claude is doing in its title and keeps
  the body for what Claude is saying. The title carries the status verb, how
  long the turn has been running and the tokens pulled down (`✽ Infusing… 8m
  24s ↓24.8k`), and nothing else: with nothing running there is no activity to
  report, so it goes back to the plain label.
- The notification moves while Claude does. Claude cycles its spinner glyph
  (`· ✢ * ✶ ✻ ✽` and back) about every 120ms and the title passes that glyph
  through, so `notification.refresh_ms` now samples at the same rate — at the
  old 250ms the glyph landed on aliased frames and a live turn looked stuck. On
  top of that the markers pulse, at two rhythms: a running tool call flickers
  its `⎿` between grey and the working amber every `pulse_ms / 2`, and a
  waiting notification blinks its `❯` between green and dim every `pulse_ms`
  (700ms by default), so the rhythm says which state you are in before you have
  read a word. Only the glyph moves, and a `⎿` from a tool call that has
  already finished holds still. `notification.pulse_ms = false` stops all of
  it. A refresh costs about 0.2ms — roughly 0.2% of one core at the default
  rate — and the pulse adds one extmark write to that.
- The notification says when Claude is waiting on you, on a line under the
  message where the TUI puts its own prompt: `❯ Waiting for you · Cooked for 1m
  40s`, with the finished turn's marker as the detail, or `❯ Waiting for you`
  alone when Claude has only just started and has no turn behind it. Idle is
  idle however Claude got there, a diff you have not resolved included.
  `notification.waiting = false` shows the finished turn's marker on its own
  and nothing when there is none; `notification.status_in_title = false` moves
  the working status down there too.
- The body is the opening sentence of the newest thing on screen, not the whole
  paragraph — the corner is a few lines tall, and the first sentence is what
  tells you which answer you are looking at. `notification.body = "block"`
  restores the paragraph (and the one above it, as `gaps` allows); `max_lines`
  and `gaps` shape that mode only. Where a sentence ends is the interesting
  part: prose is full of full stops that end nothing — `parser.lua`, `0.10`,
  `e.g.` — so a stop only counts when whitespace and then a capital, a quote or
  a backtick follow it.
- The body reads as prose rather than as terminal wreckage. Claude hard-wraps
  its output at the float's width, so tailing those lines into a 64-column
  notification re-wrapped fragments that were already broken — the ragged,
  half-aligned columns it used to show. The wrap is now undone before the
  notification re-wraps the paragraph at its own width, on word boundaries and
  with a column of padding off the border. Tool calls collapse to the single
  line naming what is running instead of spilling their output into the corner,
  and tips are skipped. The echo of your own prompt is the edge of the turn, so
  the paragraph `gaps` reaches for can never come from the previous one; while
  Claude is working and has not said anything yet, that echo is what the body
  shows, since what you asked is what Claude is doing.

### Fixed

- Sending to Claude while it is minimized (`:ClaudeCodeSend`, and anything else
  routed through `ensure_visible`) now brings the float back instead of leaving
  you with the corner notification. Staying minimized is still what happens
  while an edit-approval diff is on screen, which is the one case it was meant
  for.
- The float comes back after a **denied** diff. Denying does not tear the diff
  down — claudecode.nvim waits for the CLI's `close_tab` for that — so the tab
  lingers, and closing it by hand only hides its proposed buffer, which is
  scratch and stays loaded. The watcher counted that leftover as a live diff,
  which reset the idle clock on every poll, so the restore never fired at all.
  It now asks whether a diff is *on screen* rather than whether one exists.
- A finished turn no longer reads as a working one, which is what actually kept
  the float in the corner after a diff — and after anything else. Claude leaves
  a summary on screen when a turn ends (`● Ran the suite; two specs still red ·
  44s`, under a frozen `✻ Cooked for 1m 40s`), and both carry a duration; the
  status-line heuristic took a duration plus a mid-dot as proof of a running
  spinner. `is_working()` was then true forever, so the idle clock the restore
  waits on never started. It now keys off the live line's parenthesised elapsed
  timer (`✽ Infusing… (8m 24s · ↓ 24.8k tokens)`), which is what a finished turn
  drops.
- The corner notification no longer opens in the wrong tab with
  `diff_opts.open_in_new_tab = true`. claudecode.nvim's own `:tabnew` fires our
  focus-leave auto-minimize as a side effect, synchronously and before the tab
  switch settles, so the notification's editor-relative window bound to the
  tab being left rather than the diff's tab — invisible the moment focus
  actually landed. The minimize now runs a tick later, once the switch has
  settled.

## [0.1.0] - 2026-07-31

First release.

### Added

- Floating-window terminal provider for claudecode.nvim: Claude Code opens in a
  centered float instead of a split.
- Automatic minimize to a corner notification when an edit-approval diff opens,
  and automatic restore once Claude has been idle for `restore_idle_ms`.
- The corner notification, tailing Claude's live status line plus the message
  paragraph above it.
- `:FloatingClaudeMinimize`, `:FloatingClaudeRestore`, `:FloatingClaudeToggle`,
  and the matching Lua API (`minimize`, `restore`, `toggle_mini`,
  `is_running`).
- Terminal-mode `<C-x><C-m>` to minimize without leaving insert mode.
- Version compatibility checking (`compat.lua`): one warning per session when
  claudecode.nvim or the Claude Code CLI is older than the pair this release
  targets, silenced with `version_check = false`.
- `:checkhealth floating-claude`.

### Compatibility

- Neovim 0.10+
- claudecode.nvim `main` @ `2390c6e` (v0.3.0 + 53); minimum 0.2.0
- Claude Code CLI 2.1.220; minimum 2.1.0

[Unreleased]: https://github.com/hebercosfer/floating-claude.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hebercosfer/floating-claude.nvim/releases/tag/v0.1.0