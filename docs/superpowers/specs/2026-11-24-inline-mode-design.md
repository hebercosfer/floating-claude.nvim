# Inline mode: ask Claude about the code in front of you

Design, 2026-11-24. Branch `feature/InlineMode`. Status: waiting for Heber's
approval; nothing is built yet.

## Why

Talking to Claude about a few lines of code today means leaving them: open the
float, type `@file#L12-14`, describe the change, then review the edit in a diff
tab. Heber wants to ask from where the code is, with the exchange looking like
part of the buffer, like Cursor's inline edit, but without the trade the existing
inline plugins make.

[float-claude.nvim](https://github.com/kova1max/float-claude.nvim) (MIT) and
[claude-inline.nvim](https://github.com/AdamAugustinsky/claude-inline.nvim) both
start a headless `claude -p` of their own for each chat (float-claude.nvim with
no tools, no MCP and none of your settings), so the inline exchange happens
outside your session. The difference wanted here is that it happens **in the
session floating-claude is already running**: the same conversation, with the
same context, tools, permissions and history, so the float shows the exchange
too and you can carry on from either place.

## Goals

- Select lines (or use the cursor line), press a key, type an instruction in an
  input that appears right under the code, and send it to the running Claude
  session.
- Show the exchange under the code as virtual lines: what you asked, the tool
  Claude is running, the latest words it says, and when it is asking you
  something.
- When Claude edits the file, show the edit as a unified diff **in the window you
  are in**. Accept with `:w`, reject with a key, or open the float to answer
  Claude's own prompt there ("yes / no, tell Claude what to do differently").
- The exchange is part of the session: it appears in the float's transcript
  exactly as if you had typed it there.

## Non-goals

- **Streaming the edit word by word in session mode.** Claude's Edit tool writes
  a whole hunk at once, so session mode shows an edit when it is proposed.
  Streaming comes with the headless mode instead (see "Headless mode").
- **An input in the corner notification.** The corner stays exactly as it is.
- **Starting Claude for you.** Inline mode needs a running session; with none, it
  says so and points at `:ClaudeCode` (builder may revisit, see the end).
- **Neovim 0.10.** This goes on `main` (0.11+). Backporting to
  `support/nvim-0.10` is a separate decision after the release lands.

## Anti-goals

These would make it a failure even if it works:

- **Touching what you typed into Claude yourself.** A half-written prompt in the
  float is never cleared, merged into, or sent.
- **A second Claude session in session mode**, or anything that writes to the session behind the
  TUI's back. The only way in is the same terminal input you type into. (Headless mode is a separate process on purpose,
  and only when you choose it.)
- **The listener deciding things.** The hooks listener keeps answering every
  event with an empty 200. Inline mode follows events; it never replies to a
  permission request. Approval stays with claudecode.nvim's diff and Claude's
  own prompt.
- **The float jumping over your code.** An inline request must never bring the
  big float back by itself; that would cover the code and the inline lines you
  are reading. (The corner is fine, see step 8.)

## Constraints

- **Hooks are required.** Inline mode follows the turn through hook events
  (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `MessageDisplay`, `Stop`,
  `StopFailure`, `PermissionRequest`, `Elicitation`), which need Claude Code CLI
  2.1.301+ and `hooks.enabled`. Without them, the inline key says why and does
  nothing. Screen scraping is not an acceptable source for this.
- **A claudecode.nvim that knows the unified layout.** `diff_opts.layout =
  "unified"` was renamed from `"inline"` in 288c9bf and shipped in v0.4.0; its
  diff lifecycle events (`ClaudeCodeDiffOpened/Closed`) came with 2390c6e
  (#297), also in v0.4.0. The tested pin (af04fbf, v0.3.0+142) has both, so the
  gate is a **capability check, not a version check** (my call): does
  claudecode.nvim accept `layout = "unified"`, and does a unified diff fire the
  lifecycle events. Without them (the plugin's floor is v0.2.0), inline edits
  use whatever layout claudecode.nvim is configured with, in a new tab, as diffs
  open today.
- **claudecode.nvim's unified diff is its own buffer**, read-only, with removed
  and added lines interleaved. It is not drawn inside your file's buffer.
  claudecode.nvim opens it in a new tab (floating-claude sets
  `open_in_new_tab = true`) or a vsplit, and closes that window when the diff
  is accepted or rejected.
- **claudecode.nvim rejects a diff whose proposed buffer is hidden**
  (`_register_reject_when_hidden`), so the diff buffer must stay on screen until
  it is resolved.
- `diff_opts.layout` is claudecode.nvim's global setting, read when each diff
  opens. Inline mode needs it to be `"unified"` only for diffs that come from an
  inline request.

## Approaches considered

**How the prompt reaches Claude.**

- *A separate headless process per request* (float-claude.nvim,
  claude-inline.nvim). It allows token streaming, but it is not the session.
  Rejected: being in the session is the point.
- *Claude Code's editor connection (MCP).* claudecode.nvim can push context to
  Claude (at-mentions, the selection), but Claude Code accepts no prompts that
  way. Not possible.
- **Typing into the session's terminal (chosen).** floating-claude owns the
  Claude job (`state.jobid`), so it can paste the prompt with `chansend` and
  press Enter, exactly as you would.

**What happens when the terminal input is not clean** (Heber picked A as the
default, with C configurable):

- **A. Wait for a clean prompt (default).** While Claude is mid-turn, the
  request waits and sends when the turn ends. If Claude's input box holds a
  draft, or Claude is asking you something, it does not send and offers to open
  the float. Your text is never touched, and every reply belongs to one request.
- B. Clear the input and send. Rejected: it deletes your draft.
- **C. Send anyway (option).** Claude Code queues it. Simplest, but Claude Code
  can fold a queued message into the running turn, so inline mode cannot always
  tell which reply is its own. When it cannot, it says so in the inline lines and
  shows what it hears.

**What the exchange looks like** (Heber picked virtual lines):

- A popup at the selection with the conversation above an input (the
  float-claude.nvim look). Roomy, but it covers the code and reads as a chat
  window.
- **Virtual lines in the buffer (chosen).** A one-line input under the code,
  growing as you type; once sent, it closes and the exchange appears as dim
  virtual lines under the code, a few lines at most. The full reply is always in
  the float.
- Virtual lines plus an input that stays open. Faster for back-and-forth, but
  there is always another window to dismiss. A possible option later.

**Where the edit appears** (Heber picked c, with a as the fallback):

- a. In a new tab, as diffs open today. Works now; you leave your code.
- b. In a split beside your code. Half the screen.
- **c. In your window (chosen).** The unified diff buffer replaces your file in
  the window you are in, with the cursor on the first change. Your file comes
  back when the diff resolves. Needs a spike to confirm claudecode.nvim can be
  given back the window cleanly (see the build order). If it cannot, the default
  becomes a.

## The design

### Flow

```
 12 │ local function fetch(url)           select 12-14, <leader>ai
 13 │   return http.get(url)
 14 │ end
    ╭───────────────────────────────╮     input under line 14, grows as you
    │ add a retry with backoff_     │     type; <CR> sends, <S-CR>/<C-j>
    ╰───────────────────────────────╯     newline, <Esc> (normal mode) cancels

 12 │ local function fetch(url)           sent: the input closes, the exchange
 13 │   return http.get(url)              shows as virtual lines under line 14
 14 │ end
    ┊ ▸ add a retry with backoff
    ┊ ● Reading lua/net.lua
    ┊ Claude: I'll wrap http.get in a loop with…

 ── window now shows claudecode's unified diff, cursor on the change ──
 12 │ local function fetch(url)
 13 │ - return http.get(url)              :w accepts, the reject key denies,
 13 │ + for attempt = 1, 4 do             <CR> on the inline lines opens the
    ┊ Claude: wants to edit lua/net.lua   float on Claude's prompt
```

1. **Trigger.** `keymaps.inline` (default `<leader>ai`, normal and visual).
   Visual mode uses the selected lines; normal mode uses the cursor line.
   `<leader>ai` is free among floating-claude's own and claudecode.nvim's README
   keys. float-claude.nvim uses the same default; Heber's call is that nobody
   is expected to run both (their features overlap), so nothing handles the
   clash: whoever installs both remaps one of them.
2. **Input.** A borderless or lightly bordered one-line float anchored under the
   last line of the range, as wide as the window's text area, growing with
   wrapped or multi-line text up to `inline.max_input_height`. `<CR>` sends,
   `<S-CR>` and `<C-j>` add a newline, `<Esc>` then `q` or `<Esc>` in normal mode
   cancels. An empty input sends nothing.
3. **Prompt.** What gets typed into the session names the range plus the
   instruction. claudecode.nvim does not type mentions (it sends a structured
   `at_mentioned` over its socket), so whether Claude Code honours a *typed*
   `@lua/net.lua#L12-14` is unverified; spike 2 checks it. If it does, that is
   the form; if not, the range goes in plain words (`In lua/net.lua, lines
   12-14: add a retry with backoff`), which needs no parsing at all (my call).
   Paths are relative to Claude's cwd. Before
   sending, a modified buffer is written (`:update`), since Claude reads and
   edits the file on disk; if it cannot be written, the request stops and says
   why.
4. **Sending** follows `inline.when_busy`:
   - `"wait"` (default, approach A): send only when the session is idle (hook
     phase), Claude is not asking anything, and the input box is empty (read
     with the parser's input-box boundary). If Claude is mid-turn, the inline
     lines show "waiting for Claude to finish" and the request sends on `Stop`.
     If there is a draft or a request open, the inline lines say so and `<CR>`
     on them opens the float; the request is dropped rather than retried.
   - `"send"` (approach C): send at once and let Claude Code queue it. It skips
     only the wait: a draft in the input box or a request open still drops the
     request, as in `"wait"`, since the anti-goal (a half-written prompt is
     never cleared, merged into or sent) binds both.
   The text goes in as one bracketed paste (`ESC[200~ … ESC[201~`) followed by
   `\r`, so multi-line instructions arrive as one prompt.
5. **Owning the turn.** The request is "ours" once a `UserPromptSubmit` arrives
   whose prompt contains the instruction as sent (normalised for whitespace).
   Matching on the instruction, not the whole prompt, keeps it working if
   Claude Code expands a mention or shows a long paste as a placeholder; spike 2
   confirms what the hook carries. From there until the turn ends, the turn's
   events feed the inline lines.

   **The turn ends** on `Stop` or `StopFailure`, or on an interrupt (`Esc` in
   the float). No hook reports an interrupt, so inline mode reuses the session's
   existing screen safety net (`hooks/session.lua`), which already settles an
   interrupted turn (my call). An interrupt releases the request: the inline
   lines say "interrupted", a waiting request is dropped, and the next inline
   request can go. The layout swap is restored when the turn ends **and** no
   inline diff is still open, whichever comes last.
6. **Inline lines.** Virtual lines (an extmark with `virt_lines`) under the last
   line of the range, so they follow the code as lines move. At most
   `inline.lines` (default 3) lines: your instruction, then the latest of the
   current tool, Claude's words (the tail of `MessageDisplay`, then `Stop`'s
   message), and a request line when Claude asks something ("Claude is asking
   you something — <CR> to open"). The text comes from the same reducer and
   text helpers the corner uses, so wording and truncation match it. The lines
   stay until you start another inline request in that buffer or clear them
   (`:FloatingClaudeInline clear`); the builder may add a fade later.
7. **The edit.** While an inline turn is ours, claudecode.nvim diffs open with
   `diff_opts.layout = inline.diff_layout` (default `"unified"`, or `false` to
   leave claudecode.nvim's own layout), set just for that turn and restored
   after. With `inline.diff_in_window = true` (default, option c) the diff
   buffer is shown in the window the request came from, cursor on the first
   change, and the tab or split claudecode.nvim made is closed without hiding
   the buffer. When the diff resolves (`User ClaudeCodeDiffClosed`), that window
   gets your file back with the cursor where the change landed. With
   `diff_in_window = false`, or when the spike shows c cannot work, the diff
   opens as it does today (option a).
   - Accept: `:w` in the diff (claudecode.nvim's own way) or its accept key.
   - Reject: claudecode.nvim's deny (`:ClaudeCodeDiffDeny`, `<leader>ad` by
     default).
   - Talk: `<CR>` on the inline lines restores the float, focused on Claude's
     prompt, where "no, and tell Claude what to do differently" lives.

   While the diff holds your window, your file's buffer (and its extmark) is
   not shown, so the inline lines are **also drawn in the diff buffer**, under
   the first hunk, in inline mode's own namespace, with a buffer-local `<CR>`
   for Talk (my call). Extmarks and a buffer-local map work on claudecode.nvim's
   read-only buffer without modifying it; they go away with the buffer.
8. **The rest of the plugin during an inline turn.** Heber is fine with the
   corner during inline mode, so the corner behaves exactly as today: if it is
   up it keeps showing activity, and `auto.show_hidden` brings a hidden Claude
   back as the corner when Claude asks you something. That also covers asking
   from one file and moving on to another: a permission or question waiting on
   an inline turn shows up in the corner wherever you are, so a forgotten
   request never stalls the session unseen. Two things do change for an inline
   turn (my call, from the anti-goal): `auto.restore_on_input` never brings the
   float back over your code, and the watcher does not minimize or restore
   anything around an inline diff, since the float is not in its way.

### One request at a time

The session runs one turn at a time, so inline mode keeps one request in
flight. Starting a new one while one is waiting or running says so and does
nothing. Asking again about the same lines after a turn ends is just a new
request in the same session, so Claude has the earlier exchange as context.

### Configuration

```lua
inline = {
  enabled = true,
  when_busy = "wait",      -- "wait" (approach A) or "send" (approach C)
  lines = 3,               -- virtual lines shown under the code, at most
  max_input_height = 6,    -- rows the input grows to before scrolling
  diff_layout = "unified", -- layout for an inline turn's diffs; false keeps yours
  diff_in_window = true,   -- the diff in your window (c); false = a new tab (a)
},
keymaps = {
  inline = "<leader>ai",   -- normal and visual; false to skip
},
```

Plus a `:FloatingClaudeInline` command (`clear`, and the same thing the key
does with a range).

## Headless mode

Heber wants a second way to run an inline request: a `claude -p` process of
its own, the way float-claude.nvim works, instead of the floating-claude
session. Same input under the code, same inline lines; what changes is where
the request goes and how an edit lands. It needs neither the floating-claude
session, nor hooks, nor claudecode.nvim.

**Choosing it.** `inline.mode = "session"` (default) or `"headless"` sets what
the key does. `:FloatingClaudeInline session` and `:FloatingClaudeInline
headless` (with a range, or the cursor line) run one request the other way,
whatever the default.

**The process** (my calls, modelled on float-claude.nvim, MIT, read
2026-11-24):

- One `claude -p` per request, started with `--input-format stream-json
  --output-format stream-json --verbose --include-partial-messages`, the prompt
  written as one JSON line on stdin. Token deltas (`stream_event` /
  `content_block_delta` / `text_delta`) drive the streaming; `result` ends it.
- No tools and no MCP (`--tools ""`, `--strict-mcp-config`): it answers from
  what it is sent and cannot touch files, so nothing it does needs approval.
  What it is sent: the file name and filetype, the range, `context_lines`
  (default 40) either side, and the diagnostics in the range.
- A system prompt makes the reply's first word `EDIT` or `ANSWER`. `EDIT` is
  followed by the replacement for the range; `ANSWER` by prose for the inline
  lines (the full answer opens in a scratch float on `<CR>`). An untagged reply
  is an answer.
- One request at a time per buffer; `q`/cancel or `VimLeavePre` stops the
  process (close stdin, then SIGTERM). No follow-up thread: each request starts
  fresh, since continuity is what session mode is for.

**How an edit lands** (Heber picked: both, configurable, review by default),
`inline.headless.apply`:

- `"review"` (default): nothing in the file changes while Claude writes. The
  range's old lines are highlighted as removed (struck through, the
  `ClaudeCodeInlineDiffDelete` look) and the new lines stream in below them as
  virtual lines (`ClaudeCodeInlineDiffAdd` look). Accept writes them in as one
  undo block; reject clears it. Accept/reject are buffer-local maps while a
  review is pending, on the same keys as claudecode.nvim's accept/deny
  (`<leader>aa` / `<leader>ad` by default), so both modes review alike.
- `"stream"`: the new lines are written into the buffer as they arrive, one
  undo block for the whole edit (`undojoin`), the buffer locked against your
  typing in between; one `u` undoes it. If the buffer changes under it, the
  edit stops and leaves what was written.

```lua
inline = {
  mode = "session",        -- or "headless": what <leader>ai does
  headless = {
    cmd = { "claude" },
    model = false,         -- false: the CLI's default
    apply = "review",      -- or "stream"
    context_lines = 40,
  },
},
```

## Build order

1. **Spike, throwaway: the diff in your window.** With a real claudecode.nvim
   at the tested pin (af04fbf), open a unified diff, move its buffer into the
   origin window, close claudecode.nvim's tab, then accept with `:w` and,
   separately, deny. Check that the buffer is never hidden in between (no
   auto-reject), that claudecode.nvim's cleanup does not close the origin
   window or the tab you are in, and that the file comes back. The result sets
   the `diff_in_window` default.
2. **Spike, throwaway: pasting into the TUI.** Paste a one-line and a
   multi-line prompt into a live Claude with `chansend`, including with Claude
   Code's vim editor mode (`/vim`) in normal mode. Confirm what
   `UserPromptSubmit` carries for a long paste, and how the parser reads an
   empty input box versus a draft.
3. The feature, test-first in `tests/` with the existing plenary setup, plus a
   compat spec against the real claudecode.nvim for the diff handoff.
4. Headless mode: the process, the `EDIT`/`ANSWER` reply, `review` then
   `stream`, and the `:FloatingClaudeInline session|headless` command.
5. README section, CHANGELOG, `:checkhealth` lines (inline needs hooks, and
   the unified diff needs a claudecode.nvim that passes the capability check), and a step in `:FloatingClaudeDemo`
   if it fits the tour.

## Left to the builder

- Module layout (an `inline/` folder alongside `hooks/` is the natural home),
  and how the inline module subscribes to session events (`state.subscribe` is
  already the pattern).
- How `diff_opts.layout` is swapped for one turn (claudecode.nvim's config
  table, read at diff open).
- Highlight groups for the input and the inline lines, linked to existing
  groups by default.
- Exact whitespace rules for matching the submitted prompt.
- Whether a modified buffer is written silently or with a short message.
- What the inline lines say when a turn ends with no words (e.g. only tools).

## Open, for later

- Starting Claude hidden when it is not running, and sending once it is ready.
- An input that stays open for quick follow-ups (the hybrid look).
- Backport to `support/nvim-0.10`.

## Spike results

### Diff in your window (Task 1)

Run 2026-11-24 in headless Neovim 0.12.6 with floating-claude loaded
(`claudecode = { auto_start = false }`) and claudecode.nvim at the tested pin,
af04fbf, plus its current main, 8bcc7bb (v0.4.0+152), for comparison. Claude
Code was not running: the spike drove `open_diff_blocking` from a coroutine and
played the CLI's part after each answer (wrote the accepted text, then called
`close_diff_by_tab_name`, as `close_tab` does). Every case ran with
`open_in_new_tab` true and false, with and without Heber's
`ClaudeCodeDiffOpened` autocmd, with one window and with two splits in the tab,
and with four answers: `:w`, `:ClaudeCodeDiffDeny`, and yes or no in Claude's
own prompt. For the prompt answers, the CLI calls `close_tab` while the diff is
still pending (for yes, after writing the file itself).

What held:

- Showing the diff buffer in the origin window **first**, then closing
  claudecode.nvim's window (or every window of its tab, when `tab_number` is
  set), leaves the diff pending on both revisions. Accept and deny then reach
  the coroutine (`FILE_SAVED`/`DIFF_REJECTED`) from the origin window, and the
  cursor lands on the first change. Heber's autocmd makes no difference.
  `close_tab` on a pending diff resolves it as `DIFF_REJECTED`, then cleans up
  in the same call.
- With one window in the tab (floats do not count), the brief's order works
  as written: claudecode.nvim's cleanup leaves the origin window open, and
  showing your file there after `ClaudeCodeDiffClosed` gives the new content.

What did not:

- **With two or more windows in the tab, claudecode.nvim's cleanup closes the
  origin window.** It deletes the diff buffer (`nvim_buf_delete`), and Neovim
  closes every window that shows a buffer it deletes unless that window is the
  last one. `ClaudeCodeDiffClosed` fires after that, so it is too late to
  switch the window back. `winfixbuf` does not stop it.
- Closing claudecode.nvim's window **before** moving the buffer fails. At
  af04fbf the buffer has `bufhidden=wipe` and is wiped at once; inside the
  `ClaudeCodeDiffOpened` handler its `BufWipeout` reject does not fire (no
  nested autocmds), so the diff sits pending with no buffer until `close_tab`.
  Outside the handler both revisions reject it.
- Leaving claudecode.nvim's window open shows the diff twice (a vsplit, or a
  second tab) and still loses the origin window at cleanup.
- af04fbf has no `_register_reject_when_hidden` (it arrived in 36f4a0e, after
  the pin). There the reject comes from the `bufhidden=wipe` wipe; at 8bcc7bb
  from `WinClosed`/`BufHidden`. The safe order is the same for both.
- Switching the window back on a **scheduled** callback from the answer works
  for `:w` and deny, but not for an answer in Claude's prompt. There,
  `close_tab` resolves the diff and deletes its buffer in one call, so the
  scheduled switch comes too late. With two splits, the origin window is gone.

The order Task 6 must use. It held in every case on both revisions:

1. Before asking, note the origin window and your file's buffer.
   `data.target_window` is not the origin window when the diff opens in a new
   tab.
2. In `User ClaudeCodeDiffOpened`, synchronously:
   `nvim_win_set_buf(origin_win, diff_buf)` (`diff_buf` from
   `data.diff_window`), copy that window's cursor, then close `data.diff_window`
   or, if `data.tab_number` is set, every non-float window of that tab. Make the
   origin tab and window current. (Deferring this with `vim.schedule` also held.)
3. Wrap the diff's `resolution_callback`
   (`require("claudecode.diff")._get_active_diffs()[tab_name]`). The wrapper
   switches back, then calls the original. The switch back is
   `vim.bo[diff_buf].bufhidden = "hide"` (only while the buffer is valid), then
   `nvim_win_set_buf(origin_win, file_buf)`. The wrapper does this twice:
   - **synchronously**, which is what saves the window when Claude's prompt is
     answered: `close_tab` calls the callback and then deletes the buffer;
   - and once more on `vim.schedule`, if the window does not show your file by
     then. For `:w`, Neovim puts the diff buffer back in the window once its
     `BufWriteCmd` returns, undoing the synchronous switch.

   `bufhidden = "hide"` comes first because at af04fbf the diff buffer is
   modified with `bufhidden=wipe`, and switching away from it fails with E37.
   Once the window shows your file, the cleanup deletes a hidden buffer and
   leaves the window alone.
4. On `User ClaudeCodeDiffClosed`, `:checktime`. claudecode.nvim also reloads
   the file 100 ms after `close_tab`.

Step 3 relies on claudecode.nvim internals: `_get_active_diffs()` and the
`resolution_callback` field. claudecode.nvim has no event for an answered diff.
The capability check therefore also checks that `_get_active_diffs()` hands back
a `resolution_callback` function for the open diff; without one, the diff opens
as today (option a).

One option needs no internals and also held in every case, the prompt answers
included: show the diff buffer in a float that exactly covers the origin
window, not in the window itself. The cleanup then closes the float, and your
window is never touched. It costs following the window's size and position, and
the diff is not literally in your window. An upstream event for an answered
diff, or a cleanup that leaves windows it did not open, would remove the need
for either.

Not covered:

- A live Claude Code CLI. Its `close_tab` and its file write were played by the
  spike.
- When `close_tab` arrives relative to the answer. The spike called it 50 ms
  after a Neovim answer; step 3's synchronous switch makes the order not matter
  for the window, but this was not measured.
- New-file diffs (`is_new_file`, and `on_new_file_reject`).
- `'nohidden'`.
- The user closing the origin window, or switching it to another buffer, while
  the diff is open.
- `:ClaudeCodeDiffAccept`, `<leader>aa`/`<leader>ad`, `closeAllDiffTabs`, and a
  second diff replacing the first under the same tab name.
- floating-claude's terminal float or corner on screen during the diff, and
  `keep_terminal_focus`.
- A tab with more than two windows, or with the origin window in another tab
  than the one Neovim is in.

Result: `diff_in_window = true`, using steps 1–4 above. In the spike, that
approach held in every case: 64 of 64, on both revisions, with the new tab on and
off, with and without Heber's autocmd, one window and two splits, and all four
answers. The literal order in the brief, which switches back after
`ClaudeCodeDiffClosed`, fails whenever the tab has two or more windows.

### Pasting into the TUI (Task 2)

Run 2026-11-24 against a live Claude Code 2.1.331 in Heber's Neovim config
(floating-claude from his lazy install on this branch, claudecode.nvim), in a
throwaway clone of the repo, driven from outside over `--remote-expr`. Every
paste was `chansend(state.jobid, "\27[200~" .. text .. "\27[201~")`, with lines
joined by `\n`. Nine read-only prompts in all. The permission mode was auto, so
no read asked for permission.

What `UserPromptSubmit.prompt` carries:

- **One line, and three lines:** the text verbatim, line breaks as `\n`. A
  three-line paste shows in the box as three lines.
- **Five lines:** the box shows `[Pasted text #1 +4 lines]` (the footer says
  "paste again to expand"), and the hook gets the text verbatim, wrapped:
  `"\n\n<pasted_content id=\"089a\">\n" .. text .. "\n</pasted_content id=\"089a\">\n"`.
  The id was the same on both five-line pastes, so do not match on it. Four
  lines and a long single line were not tried, so where the threshold sits
  (lines or characters) is unknown.

Either way the instruction is in the prompt as sent, so step 5's match (the
prompt contains the instruction, normalised for whitespace) holds as written.

- **Mention form: `at`.** `@lua/floating-claude/state.lua#L1-10 <instruction>`
  works, typed through a paste. Claude Code attaches lines 1–10 itself before
  the turn starts: the screen shows `⎿  Read lua/floating-claude/state.lua (10
  lines)` under the echoed prompt, and the transcript has a file attachment
  with `range = { offset = 1, limit = 10 }` (`numLines` 10 of `totalLines`
  118). The answer described those ten lines and nothing past them. No
  `PreToolUse` or `PostToolUse` fired for it, so the inline lines get no
  "Reading" line for the range from the hooks; a Read Claude makes later, of
  its own accord, does fire them. The mention also worked as the first line of
  a three-line paste (`#L12-14`, "3 lines") and of a five-line paste that
  collapsed to `[Pasted text …]` (`#L5-8`, "4 lines"), where the hook prompt
  carries it inside `<pasted_content>`. The path is relative to Claude's cwd.
- **The send:** the `\r` does not need its own `chansend`. Sent separately
  (half a second or so later) and in the same `chansend` as the paste, it
  submitted both a one-line paste and a collapsed five-line paste; nothing
  needs waiting for.
- **Vim mode:** `/vim` no longer exists in 2.1.331 ("No commands match"). It
  is `/config` → "Editor mode" (`normal` or `vim`), saved as `editorMode` in
  `~/.claude/settings.json`. In INSERT the footer line under the box starts
  with `-- INSERT --`; NORMAL shows no marker, so its screen is the same as
  with vim mode off. Neither blocks: a paste in NORMAL lands in the box as
  text, and `\r` in NORMAL submits it. `input_draft()` needs nothing for vim
  mode, and there is no `vim_normal.txt` fixture.

The input box, from the fixtures in `tests/fixtures/input_box/` (raw
`state.buf` lines, 168 columns, 37 rows): the box is the rows between the last
two rules. The first row is `❯` and a no-break space (U+00A0), then the text;
an empty box is `❯` and the no-break space, sometimes with trailing spaces.
Continuation rows of a multi-line draft are indented two spaces, and the top
rule moves up a row; in `draft_multiline.txt` the row above it is blank (all
spaces). `draft.txt` and `draft_multiline.txt` also have Claude Code's `Jump to
bottom (ctrl+End) ↓` drawn over the transcript, a few rows above the box, and
`draft_multiline.txt` starts with Claude Code's welcome banner. The fixtures are
the captures with three things made neutral, none of them inside the box: the
banner's cwd (`~/work/repo`) and plan name, and the usage numbers in the status
line below the bottom rule.

Open for the builder: **a box holding text is not always a draft.** With
Claude Code's "Prompt suggestions" setting on (its default), the box often
shows a suggested next prompt after a turn, as dim text (`suggestion.txt`:
`❯ In three words, what is Neovim?`). In the buffer it reads exactly like a
typed draft (`draft.txt`), and it comes back whenever the box is emptied. A new
session's empty box shows a placeholder the same way (`❯ Try "fix typecheck
errors"`). A paste replaces the suggestion, and the hook carried only the
pasted text, so sending over one is safe. But `"wait"` would refuse after most
turns if it read every non-empty box as a draft. `vim.inspect_pos()` reports
nothing for terminal cells, so the dimness is not readable from the buffer.
One way out: count the box as a draft only if you have typed into Claude's
terminal since the last `UserPromptSubmit`.

Not covered: a paste while Claude is mid-turn (`when_busy = "send"`), Enter on
an empty box showing a suggestion, a four-line or long one-line paste, a
mention whose range runs past the end of the file, and a path with spaces.
