# floating-claude.nvim

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
    refresh_ms = 250,   -- how often the notification re-reads the terminal
    max_lines = 12,     -- hard cap on terminal lines tailed
    gaps = 1,           -- blank separators the tail may cross
    border = "rounded",
    title = " Claude ",
    title_pos = "center",
    zindex = 60,
  },
  auto = {
    minimize_on_diff = true,   -- minimize when an edit-approval diff opens
    restore_on_input = true,   -- restore once Claude waits for input
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
- **The live status line** — Claude renders a spinner line (`✶ Baked for 17s …
  (esc to interrupt)`) just above its input prompt while it works. Its absence
  means Claude is idle.

Restore waits for _sustained_ idle (`restore_idle_ms`) after a busy→idle
transition, so the brief lull between approving a diff and Claude resuming
doesn't pop the float back over your work. Because the clock only starts on a
real busy→idle edge, a manual minimize while Claude is already idle is never
undone by the watcher.

The same scraping feeds the notification: it tails the status line plus the
message paragraph above it, refreshing every `refresh_ms`.

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
input prompt and the live `✶ … 17s … (esc to interrupt)` line above it; an older
UI parses as "always idle".

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
`PLENARY_DIR`, and clones it into `.tests/` as a last resort.

claudecode.nvim is deliberately absent from that runtimepath — the specs stub it
into `package.loaded` instead, so the "not installed" path stays reachable and
the suite never depends on which version happens to be checked out. Claude Code
is stubbed the same way, by a shell script that prints a version string.

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
