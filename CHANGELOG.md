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

- Mouse-friendly focus handling. Leaving the float minimizes it
  (`auto.minimize_on_leave`) and entering the corner notification restores it
  (`auto.restore_on_enter`), so clicking away collapses Claude and clicking the
  corner brings it back. Both key off focus rather than the mouse specifically,
  so Vim's window commands behave the same way, and both are off with one
  option each. `restore_on_enter` also makes the notification focusable, which
  is what lets a click reach it.

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
- The corner notification no longer opens in the wrong tab with
  `diff_opts.open_in_new_tab = true`. claudecode.nvim's own `:tabnew` fires our
  focus-leave auto-minimize as a side effect, synchronously and before the tab
  switch settles, so the notification's editor-relative window bound to the
  tab being left rather than the diff's tab — invisible the moment focus
  actually landed. The minimize now runs a tick later, once the switch has
  settled.

## [0.2.0] - 2026-08-10

### Changed

- **Neovim 0.11 is now the floor.** 0.10 is no longer tested or supported. The
  0.1.x line lives on in the `support/nvim-0.10` branch for anyone still there.
- The terminal spawns with `jobstart({ term = true })` instead of `termopen()`,
  which Neovim deprecated in 0.11. Raising the floor is what lets this happen
  without a version guard, and it is the reason the floor moved.
- The timers take `vim.uv` directly rather than falling back to `vim.loop`,
  deprecated since 0.10. The fallback was unreachable, and it widened the
  expression to an unknown type, which silenced field checking on every timer
  handle reached through it.

### Added

- Test suite on plenary.nvim covering the parser heuristics, the version
  compatibility checks, the provider contract, config merging and the version
  itself: `make test`, `make test-file FILE=…`, `make lint`.
- GitHub Actions CI running the suite on Neovim 0.11.7, 0.12.4 and nightly,
  plus a stylua formatting check.
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

### Compatibility

- Neovim 0.11+
- claudecode.nvim `main` @ `2390c6e` (v0.3.0 + 53); minimum 0.2.0
- Claude Code CLI 2.1.220; minimum 2.1.0

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

[Unreleased]: https://github.com/hebercosfer/floating-claude.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/hebercosfer/floating-claude.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hebercosfer/floating-claude.nvim/releases/tag/v0.1.0