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