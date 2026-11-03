# Read Claude through hooks, not the screen

Design, 2026-11-03. Branch `feature/HooksListener`. Status: waiting for Heber's
approval; nothing is built yet.

## Why

The corner notification learns what Claude is doing by scraping the TUI
(`parser.lua`). It works until the CLI redraws something: then the corner fills
with box lines, tool traces and `/diff` panel text, or it sticks — the 0.2.x
"always working" bug was the status line read wrong. Claude Code can now POST
every lifecycle event to a URL (HTTP hooks, passed with `--settings`). The
plugin should take Claude's state and words from those events, and keep the
screen only for the one line it still needs and as a fallback.

What Heber wants, in his order:

1. **No useless information** in the corner, only real information.
2. **The look stays**: the status in the title, the coloured glyphs, a short
   message.
3. **Efficiency**: listen properly only while minimized. The maximized float
   needs no extra information, and a Claude hidden with `<leader>aq` should cost
   as close to nothing as possible.

Honest framing, agreed with Heber: today's scraping is already cheap (measured in
his live Neovim on a 37-line buffer: ~26µs per watcher poll every 300ms in every
mode, ~150µs per corner refresh every 120ms — about 0.01% and 0.1% of one core).
The payoff is accuracy and fewer CLI-driven breakages. Efficiency is a
constraint this design must hold, not the reason for it.

## Goals

- On the normal path, the corner's state and body come from hook events. No body
  text is scraped.
- No main-loop work while maximized, none while the corner sits idle, and only
  the few events needed to bring Claude back while hidden.
- Tell "Claude finished" from "Claude needs a response", and use that for the
  attention rules below.
- The corner looks the same as today.
- The scraper stays as a complete fallback.

## Non-goals

- Redesigning the corner.
- MCP. Claude only reaches an MCP server when the model calls a tool; nothing is
  pushed.
- Reading Claude's transcript JSONL. It is an internal format.
- Showing subagent activity.
- Deleting `parser.lua`.
- Backporting on this branch (see Rollout).

## Anti-goals — failure even if it technically works

- Claude ever waiting on Neovim: a stall, or hook error lines in Claude's
  transcript during normal use.
- The listener ever answering with a decision (approve, deny, rewrite input).
- Junk in the corner: raw markdown, `<task-notification>` wrappers, plumbing
  tools such as `ToolSearch`, subagent chatter.
- A corner pinned in "working" after an interrupt.
- Claude popping back for something that is not a request when the setting says
  requests only.

## What the spikes established

CLI 2.1.317, Neovim 0.12.5, 2026-11-03. The raw log of the second spike
(51 events, every payload) is at `~/.cache/floating-claude-spike-events.log`;
sanitize it into test fixtures. Findings are also in the project memory
(planned work queue, section 8).

Transport:

- `claude --settings <file>` with `type: "http"` hooks works. Each event is a
  POST with `Content-Length` (axios); an empty `200` makes no decision. These
  hooks run alongside the user's own.
- `SessionStart` and `Setup` never take HTTP hooks (hardcoded in the CLI).
- Claude awaits every hook. With Neovim's main loop busy, each hook waited out
  its whole timeout (a 1.6s turn took 11.7s and printed "timed out" in the
  TUI). A closed port fails instantly but prints an error line per hook.
- A listener on its own `vim.uv.new_thread` loop answered in 1–6ms with the main
  loop blocked for 3s. An idle thread used 0 CPU over 5s. Threads have
  `vim.json`. `uv.new_async` coalesces sends and lost 2 of 3 events; a
  `uv.pipe()` of length-prefixed frames delivered all of them in order,
  including a 300 KB body. `join()` is instant, and quitting Neovim with the
  thread alive does not hang.

Events:

- `MessageDisplay` fires once per completed paragraph, not per token: two events
  in a typical turn. `delta` is logical markdown, not wrapped to the terminal.
  The final one can arrive *after* `Stop`, in the same millisecond.
- `PermissionRequest` fires the instant a dialog appears, for tool permissions,
  `AskUserQuestion` (question text in `tool_input.questions`) and
  `ExitPlanMode`. The `Notification` `permission_prompt` lags it by ~6s.
- **Interrupts fire nothing.** Esc mid-reply, Esc during a running tool, and
  declining a dialog all leave the last event standing, with no `Stop`, no
  `PostToolUseFailure` and no `idle_prompt` even 95s later.
- `UserPromptSubmit` also fires for synthetic prompts: when a background task
  ends, its `prompt` is `<task-notification>…`.
- Subagent events carry `agent_id`, and can arrive after the main `Stop`. A
  `SubagentStop` with an empty `agent_type` arrived outside any turn.
- `Stop` lists `background_tasks`. The frozen marker on screen reads
  `✻ Crunched for 5s · done 5:05 PM · 1 shell still running`.
- With a request dialog up there is no live status line. While a tool runs there
  is one (`* Hullaballooing… (8s · ↓ 480 tokens)`).

## Decisions

**Heber's:**

- Go ahead, as a major update, knowing the win is accuracy, not speed.
- Listen properly only while minimized; nothing extra while maximized; hidden
  as quiet as possible.
- What a hidden Claude does is a setup option. The default brings the corner
  back only when Claude requests a response, not when it is merely idle.
- Keep the current look.
- `hooks = false` is the manual switch back to screen reading. The fallback
  also kicks in on its own (see Fallback).
- **Transparency:** a keybinding opens the latest events the listener received
  in a buffer. A user can then check for themselves what the plugin hears:
  that it is safe, or, if a secret did pass through, that it was at least in
  plain view.

**My calls — Heber, overrule any of these:**

1. The listener always answers, and the window mode decides what reaches the
   main loop. The port cannot close while Claude runs: a released port could be
   taken by another process whose replies Claude would trust, and a refused one
   prints errors in Claude's transcript.
2. The title keeps verb, elapsed and tokens by reading the one live status line,
   only while minimized and working. That keeps the look, and the same read is
   the interrupt safety net.
3. The body uses `MessageDisplay`: two events a turn, clean text.
4. A failed turn (`StopFailure`: rate limit, API error) counts as a request,
   since Claude cannot go on without you.
5. A finished turn whose last sentence is a question counts as idle. Telling
   otherwise would mean guessing from prose.
6. Requests act immediately. Finished turns keep the `restore_idle_ms` debounce.
7. The minimized corner keeps today's default (bring the float back on a
   finished turn or a request), but accepts the same values as the hidden
   option.
8. In the fallback the screen cannot tell a request from idle, so "requests
   only" behaves like "idle" there.
9. The hook settings go in a private file, never on the command line, because
   argv is world-readable and the file holds the token.
10. Diff detection is triggered by window events instead of a poll, with a
    diff-only poll as an acceptable fallback.
11. A request that arrived while the float was open counts as handled once you
    minimize, unless the screen shows Claude working. Esc on a dialog fires
    nothing, so this is the only way to drop a stale "needs you".
12. An unknown CLI version means the fallback, not hooks.
13. The safety net only trusts a missing status line once it has seen one
    match in this session.

## Design

### Overview

```
claude ──POST /hook──▶ listener thread ──frames (pipe)──▶ main loop
          (token)       127.0.0.1:<port>                   reducer → attention rules → corner
                        always answers 200 at once
                        ◀──control (pipe): mode, stop──────
```

### Launch and lifetime

- Hooks mode is decided before the job starts, so the CLI version must be known
  by then. Use the blocking `compat.cli_version()` (measured: 6–9ms), cached for
  the Neovim session. If the version is unknown, use the fallback (my call): an
  older CLI fed hook types or events it does not know could print settings
  errors inside Claude, which is junk too.
- `terminal.spawn()`: in hooks mode, start the listener first (it picks a random
  port), then write the settings file into `vim.fn.stdpath("run")` with mode
  0600, then append `--settings <path>` to the argv already built from
  claudecode's `cmd_string`.
- One hook entry per subscribed event:
  `{ type = "http", url = "http://127.0.0.1:<port>/hook", headers = { ["X-Floating-Claude"] = <token> }, timeout = <short, e.g. 2> }`.
  The token is fresh per spawn (`vim.uv.random`, 16 bytes as hex).
- **Subscribed:** `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`,
  `PostToolUse`, `PostToolUseFailure`, `MessageDisplay`, `Stop`, `StopFailure`,
  `Elicitation`, `PreCompact`, `PostCompact`, `SessionEnd`.
- **Not subscribed:** `Notification` (redundant and late), `PostToolBatch`,
  `Subagent*`, `Task*`, `PermissionDenied` (Claude carries on), `SessionStart`
  (impossible over HTTP).
- On job exit and on `terminal.close()`: stop the thread, join it, close the
  pipes, delete the file. Never earlier.

### The listener thread

- It owns the TCP socket on its own loop and does minimal HTTP/1.1: headers up
  to CRLFCRLF, then a body sized by `Content-Length`. A body over a cap (e.g.
  16 MiB) is drained and discarded. It replies `200`, empty,
  `Connection: close`, **before** any other work.
- A wrong or missing token gets `403` and is never forwarded.
- It decodes JSON on the thread, drops every event with an `agent_id`, and turns
  the rest into a compact record: event name, arrival time, and only the fields
  the reducer reads, with long strings capped.
- The main loop sets a **mode** over the control pipe:
  - **float:** keep records, forward nothing;
  - **hidden:** forward only request-class events. When the hidden option is
    `"idle"`, also forward `Stop`, and `UserPromptSubmit` so a new turn can
    cancel a pending show;
  - **corner:** forward everything.

  On entering corner mode, the thread first sends the records kept since the
  last `UserPromptSubmit` (a bounded ring), then streams live.
- Thread→main is a `uv.pipe()` of length-prefixed frames. Never `uv.new_async`:
  it coalesces, and events get lost.
- The thread counts the authenticated events it has received and reports that
  count with the ring. Liveness and `:checkhealth` both need it, and in float
  mode the main loop hears nothing else.
- Stop: a `stop` message closes the server, the thread's loop ends, and the
  main loop joins.

### Events → state (the reducer)

A pure Lua module with no `vim.api`, fed records on the main loop. It is
testable from fixtures alone. State: a **phase** (`idle`, `working`, `request`),
the turn's start time, a compacting flag, a failure text, and the **body**
(kind + text).

| Event (main agent only) | Phase | Body |
|---|---|---|
| `UserPromptSubmit` | working; turn starts now | your prompt as an echo. A synthetic prompt (`<task-notification>…`) keeps the previous body |
| `PreToolUse` | working | the tool line; plumbing tools (`ToolSearch`, `Task*`) leave the body alone |
| `PermissionRequest` | request | the request: the question (`AskUserQuestion`), "Plan ready for review" (`ExitPlanMode`), else the tool plus its description, command or file |
| `PostToolUse`, `PostToolUseFailure` | working if it was a request; otherwise unchanged | unchanged |
| `MessageDisplay` | **never changes the phase** (it can trail `Stop`) | the newest prose paragraph |
| `Stop` | idle | the newest paragraph of `last_assistant_message` |
| `StopFailure` | request, marked failed | the error text |
| `Elicitation` | request | its `message` |
| `PreCompact` / `PostCompact` | compacting on / off | "Compacting conversation…" while on |
| `SessionEnd` | empty idle | cleared |

How the body text is made:

- **Prose:** split into paragraphs, skip code fences, tables and rules, take the
  newest prose paragraph, strip the markdown markup (headings, list markers,
  emphasis, backticks, link targets), then `parser.first_sentence()` for
  `body = "sentence"`, or the paragraph for `"block"`.
- **Tool line:** `⎿ ` plus a summary:
  - Bash: its `description`, or the command;
  - file tools: a verb and the basename;
  - Grep/Glob: the pattern;
  - Web*: the host or the query;
  - Agent: its description;
  - MCP tools: `server: tool`.

### Attention rules

| Where Claude is | Setting | Request (`PermissionRequest`, `Elicitation`, `StopFailure`) | Finished turn (`Stop`) |
|---|---|---|---|
| Minimized | `auto.restore_on_input = "idle"` (default; `true` still means this) | float back now | float back after `restore_idle_ms` |
| Minimized | `"request"` | float back now | stays |
| Minimized | `false` | stays | stays |
| Hidden | `auto.show_hidden = "request"` (**new, default**) | corner now | stays hidden |
| Hidden | `"idle"` (today's behaviour) | corner now | corner after `restore_idle_ms` |
| Hidden | `false` | stays | stays |

These hold whatever the setting:

- Nothing happens while a diff is visible: you are reviewing it, and it is its
  own notification.
- Only live events trigger these. A replayed ring, or a correction by the safety
  net, never does: a manual minimize is never fought.
- Any new main-agent activity cancels a pending debounce.

### The corner

- **Title:**
  - **Working:** read from the live status line through `parser.status()`
    (glyph, verb, elapsed, tokens), exactly as today. Until that line appears,
    `✻ Working` with the elapsed time counted from `UserPromptSubmit`.
  - **Idle or request:** the plain title, as today.
- **Body:** from the reducer, through the existing `lay_out()` and `paint()`
  (kinds `echo`, `tool`, `prose`/`bullet`) and the existing highlight groups.
  A session with no events yet (fresh, or just resumed) shows no body, only the
  waiting line.
- **Waiting line:**
  - **Idle:** `❯ Waiting for you · <frozen marker>`. The marker is read once
    from the screen at `Stop`, or when the corner opens, and left out if it
    isn't found.
  - **Request:** `❯ Waiting for you`, with the request as the body.
  - **Failed:** the same, with the body in a new error highlight linked to
    `DiagnosticError` (my call).
- **Timer:** only while minimized and working. Every `refresh_ms` it re-reads
  the status line and updates the title and the ⎿ pulse. The body is re-laid
  out only when an event changes it, and there is no timer at all when idle or
  on a request.

### Safety net: interrupts fire nothing

- **Trust:** the net only trusts the *absence* of a live status line once the
  live-line test has matched at least once in this session. If a CLI update
  changes that line, the net goes quiet instead of turning every long tool run
  into idle, and the events keep the state right on their own.
- **Minimized and working:** each timer read doubles as a check. With no live
  status line for ≥ 1s and no event for ≥ 1s, the phase drops to idle, silently.
- **When the float is minimized:** one status-line read.
  - A live line means working. That also covers a request you approved in the
    float.
  - No line while the phase says working means idle (interrupted).
  - No line while the phase says request, and the request arrived while the
    float was open, means plain idle waiting (call 11).
- **Compaction:** check what `/compact` shows on screen. If that line doesn't
  pass the live-line test, suspend the net while compacting.

### Diffs

The behaviour is unchanged: `minimize_on_diff`, `before_diff`, and
`provider.ensure_visible()`. The mechanism changes: window autocmds
(`BufWinEnter`, `BufWinLeave`, `WinClosed`, `TabClosed`) schedule the same check
the poll ran, and `last_mode` is kept current on every mode change. If the
existing diff specs cannot stay green that way, a diff-only poll at `watch_ms`
is acceptable. It never reads the terminal (`diff_visible()` ≈ 3µs).

### Fallback

Today's code path, unchanged (the watcher poll plus the scraped body), is used
when any of these hold:

- `hooks = false`;
- the CLI is older than `compat.minimum.hooks`;
- the claude command already carries `--settings` (until merging is verified);
- the listener fails to start;
- **liveness fails:** the corner reads a live status line but no authenticated
  event has arrived this session. The rest of that session runs on the fallback.

`:checkhealth` says which mode is active and why.

### Transparency: the events view

What it is for (Heber): anyone can see what the plugin listens to, so it can be
checked as safe. If a secret did pass through, the point is that it was in
plain view rather than hidden.

**Opening it:** `:FloatingClaudeEvents`, `require("floating-claude").events()`,
or the new `keymaps.events`, default `<leader>ae`. The default is set only when
that key is free, the same rule `keymaps.hide` follows; `false` skips it. It
opens a read-only scratch buffer in a new tab, which `q` closes. It is a
snapshot taken when opened; opening it again refreshes it.

**The header says, in plain words:**

- **Hooks mode:** listening on `127.0.0.1:<port>`; the events subscribed to;
  the settings file's path, which holds the session token (the token itself is
  never shown); and that events stay in memory only — nothing else is written
  to disk, nothing leaves this machine, and the memory is cleared when Claude
  exits.
- **Fallback:** "Not listening", the reason, and that the plugin reads the
  screen instead.

**The events:** the last N received (default 50; 0 keeps none, for anyone who
would rather the plugin hold nothing), oldest first, with the cursor on the
newest. Each starts with one line: time, event name, and what happened to it
(forwarded, kept, or dropped as subagent). Under it comes the payload **as
Claude sent it**, pretty-printed. String values longer than a cap (e.g. 2,000
characters) are cut when the event is stored and marked `… [n bytes more]`.
The view shows exactly what the plugin keeps, and plainly says that more
arrived. Rejected requests (wrong or missing token) are listed too: time and
size only, with no body.

**Where it lives:** the thread keeps this ring itself, apart from the compact
records the reducer uses. The view asks for it over the control pipe and
receives it as frames, so the ring costs the main loop nothing until someone
opens the view. That keeps the promise for maximized mode.

**What it will show, honestly:** Claude sends whatever its hooks carry:
- your prompts;
- Claude's messages;
- tool inputs (commands, file contents for Write);
- tool output (stdout, files Read).

The plugin cannot ask for less, and does not hide any of it. A `cat .env` will
appear, cut at the cap. The README's security note says this, and points at
the view and at the keep-none setting.

### Configuration

```lua
hooks = true,                  -- false: read the screen only, as before
auto = {
  restore_on_input = "idle",   -- "idle" | "request" | false (true = "idle")
  show_hidden = "request",     -- "request" | "idle" | false (new)
  restore_idle_ms = 1200,      -- finished turns only; requests act at once
  watch_ms = 300,              -- fallback path, and the diff poll if kept
},
notification = {
  refresh_ms = 120,            -- now only the working-title timer
  -- max_lines and gaps shape the fallback only
},
```

The `keymaps.hide` comment changes to describe `show_hidden`. Two additions:

- `keymaps.events = "<leader>ae"`;
- how many events the view keeps (default 50, 0 keeps none). The option's name
  and where it sits are the builder's call: for example `hooks` may take a
  table, as long as `hooks = false` keeps working.

### Performance budget (acceptance)

- **Maximized:** zero main-loop work per hook event, and no timer that reads the
  terminal.
- **Minimized and idle, or on a request:** no timers.
- **Minimized and working:** one timer per `refresh_ms` (a status-line read,
  ~25µs, plus a title update). Body work only on events.
- **Hidden:** the main loop wakes only for forwarded events.
- **Hook round trip:** ≤ ~2ms with the main loop blocked.
- **Verification:** measure before and after with the RPC benchmark method
  (memory, section 1).

### Security

- **Exposure:** 127.0.0.1 only, on a random port.
- **Token:** fresh per spawn, carried in a header, kept in a 0600 file in
  `stdpath("run")`, and never on argv.
- **Replies:** always an empty `200`, never a decision.
- **Port lifetime:** held for Claude's whole life.
- **Memory:** bounded per request, and bounded in the thread's ring.
- **Visibility:** the events view shows anyone exactly what was received and
  kept (see Transparency). Only the settings file touches disk.

## Testing

- **Fixtures:** sanitized sequences from the spike log. One per scenario:
  - a tool plus prose;
  - a question;
  - an interrupt mid-reply;
  - a background task with its synthetic prompt and a subagent tail;
  - an interrupted foreground tool;
  - a plan approval, then a decline.
- **Reducer specs:** the phase and body after every event of every fixture.
- **Listener specs:** a real thread and a `uv` TCP client:
  - partial reads, `403`, oversize bodies;
  - rapid posts arriving in order;
  - reply latency with the main loop blocked;
  - stop, join, and Neovim exit.
- **Attention-rule specs:** the full matrix above, with diff suppression and
  "replay or correction never triggers".
- **Notification specs:** title, waiting line, kinds and highlights rendered from
  state, with the look unchanged.
- **Safety-net specs:** the interrupt fixtures.
- **Events-view specs:**
  - header text in hooks mode and in each fallback reason;
  - the token never appears in the buffer;
  - cut strings carry their byte count;
  - rejected requests show no body;
  - keeping 0 keeps nothing;
  - the keymap is not set over an existing mapping.
- **Existing specs:** the parser and watcher specs stay as the fallback's specs
  and stay green.
- **Manual:**
  - **Scenarios:** a prompt, a tool, a permission, a question, a plan, an
    interrupt, `/clear`, the `/diff` panel, a background task, and hide with
    each setting.
  - **How:** Heber drives them on the branch (push the branch and point Neovim
    at it), with the RPC dump method for anything odd.

## Rollout

- **Branch:** all on `feature/HooksListener`.
- **CHANGELOG:**
  - Added: the hooks listener, `show_hidden`, and the events view
    (`:FloatingClaudeEvents`, `<leader>ae`).
  - Changed: the hidden default is now requests only; `restore_on_input` takes
    values; the body's source.
  - The version number is decided at release, per release tags come last.
- **README:** the mechanism section (how the plugin reads Claude),
  compatibility (the minimum CLI for hooks), configuration, and a short security
  note on the localhost listener: what Claude sends, what is kept, and how to
  look at it (`<leader>ae`).
- **compat:** add `minimum.hooks = "2.1.301"`, the oldest CLI verified to have
  HTTP hooks, `PermissionRequest` and `MessageDisplay`. Lower it only if an
  older one is verified. `tested` is refreshed at release.
- **Backport:** afterwards, by the standing 0.10 rule, once the support branch's
  CI shows that threads get `vim.uv` and luv has `uv.pipe()` on 0.10 (`main`
  already requires 0.11).

## Left to the builder

These are the builder's to settle:

- **Naming:** module layout (e.g. `listener.lua`, `events.lua`, `attention.lua`)
  and the names of the new option and highlight group.
- **Wording and cleanup:** the tool-line wording per tool, the markdown cleanup,
  and the list of synthetic-prompt tags.
- **Limits:** HTTP edge cases, the ring size, and the text caps.

These need checking against a real session first:

- whether a user's own `--settings` can be merged with ours;
- what compaction looks like on screen;
- whether `PermissionRequest` fires for claudecode's IDE-diff edits (the
  diff-visible guard covers it either way).

**The tour:** it should drive the reducer with scripted events next to its fake
TUI, so it shows the hooks path rather than the fallback.
