# Inline Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ask Claude about the lines in front of you from an input under them, see the exchange as virtual lines below the code, and review the edit in your own window, either through the running floating-claude session (default) or through a headless `claude -p` of its own.

**Architecture:**
- **Session mode:** a pure request state machine (`inline/request.lua`) follows the session's hook records. A sender (`inline/send.lua`) pastes the prompt into the Claude job's terminal only when its gate allows. `inline/diff.lua` swaps claudecode.nvim's diff layout for the inline turn and hands the unified diff to the origin window.
- **Shared UI:** the input float (`inline/input.lua`) and the virtual lines (`inline/lines.lua`), used by both modes.
- **Headless mode:** a `claude -p` stream-json process per request (`inline/headless/process.lua`), an `EDIT`/`ANSWER` reply parser, and an in-place review or stream writer (`inline/headless/apply.lua`).
- `inline/init.lua` is the entry point: the key, the command, the one-request rule.

**Tech Stack:** Lua on Neovim 0.11+; `vim.api` extmarks (`virt_lines`), `vim.fn.chansend`, `vim.system`; plenary.nvim busted specs (`make test`, `make test-file FILE=…`, `make test-compat`); stylua.

**Spec:** `docs/superpowers/specs/2026-11-24-inline-mode-design.md`. Read it first: the decisions and their reasons live there. The plan does not repeat them.

## Global Constraints

- Neovim floor stays 0.11 on `main`. No backport work on this branch.
- The hooks listener keeps answering every event with an empty 200. Nothing in inline mode replies to a hook or decides a permission.
- Session mode types into the terminal only through `vim.fn.chansend(state.jobid, …)`. It never clears or edits a draft in Claude's input box.
- An inline turn never brings the big float back by itself. The corner behaves exactly as today, `auto.show_hidden` included.
- One inline request in flight at a time, across both modes.
- A mapping the user made on the same key is left alone (the existing `keymaps.lua` rule).
- Nothing in inline mode writes to disk except `:update` of the request's buffer before a session-mode send.
- Defaults, copied from the spec: `inline.mode = "session"`, `when_busy = "wait"`, `lines = 3`, `max_input_height = 6`, `diff_layout = "unified"`, `diff_in_window = true` (Task 1 may change this), `headless.cmd = { "claude" }`, `headless.model = false`, `headless.apply = "review"`, `headless.context_lines = 40`, `keymaps.inline = "<leader>ai"`.
- Commits follow Heber's tmux flow from `~/.claude/CLAUDE.md`: message written to `~/.claude/cmsg.txt` with a heredoc, `git commit -e -v -F ~/.claude/cmsg.txt -- <paths>` in a new tmux window, watched until it lands. No `Co-Authored-By` trailer. Push `feature/InlineMode` after each commit; Heber's Neovim already points at it (`:Lazy sync`).
- User-facing copy (exact strings):
  - `waiting for Claude to finish`
  - `Claude's prompt has a draft · <CR> to open Claude`
  - `Claude is asking you something · <CR> to open Claude`
  - `interrupted`
  - `Claude didn't take the prompt · <CR> to open Claude`
  - `Inline mode needs Claude's hooks: <reason>`
  - `Claude isn't running · start it with :ClaudeCode`
  - `An inline request is already running`

## Review Focus

1. **A paste that Claude never submits** (vim mode in NORMAL, a slash menu open, a TUI redraw): the request must not hang. Expect `Claude didn't take the prompt` after 5000 ms with no matching `UserPromptSubmit`, and the one-request lock released. Test in Task 4.
2. **The buffer changes under the inline lines** (lines deleted above, the range itself deleted): the extmark follows or vanishes, and nothing errors. Test in Task 3.
3. **Claude exits mid-request** (`SessionEnd`, or the job dies): the request ends as `failed`, the layout swap is restored, and the lock is released. Test in Tasks 4 and 6.
4. **A second diff in the same inline turn** (Claude edits two hunks or two files): each diff is handed to the origin window in turn only if it is for the request's file; other files open as today. Test in Task 6.
5. **The headless process cannot start or exits non-zero** (no `claude` on PATH, auth failure): the inline lines show the first line of stderr and the lock is released. Test in Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `lua/floating-claude/config.lua` (modify) | `inline` defaults and `keymaps.inline` |
| `lua/floating-claude/keymaps.lua` (modify) | actions with modes; the inline action in `n` and `x` |
| `plugin/floating-claude.lua` (modify) | `:FloatingClaudeInline [session\|headless\|clear]` with a range |
| `lua/floating-claude/inline/init.lua` | entry: `ask`, `clear`, the one-request lock, mode dispatch |
| `lua/floating-claude/inline/input.lua` | the growing input float under a range |
| `lua/floating-claude/inline/lines.lua` | the virtual lines: render, clear, `<CR>` |
| `lua/floating-claude/inline/request.lua` | pure session-mode request state machine and its line model |
| `lua/floating-claude/inline/send.lua` | the send gate and the bracketed paste |
| `lua/floating-claude/inline/diff.lua` | the layout swap and the in-window handoff |
| `lua/floating-claude/inline/headless/process.lua` | the `claude -p` stream-json process |
| `lua/floating-claude/inline/headless/reply.lua` | prompt building and `EDIT`/`ANSWER` parsing |
| `lua/floating-claude/inline/headless/apply.lua` | `review` and `stream` application |
| `lua/floating-claude/parser.lua` (modify) | `M.input_draft()` |
| `lua/floating-claude/hooks/session.lua` (modify) | `M.on_record(name, fn)`; inline-aware attention |
| `lua/floating-claude/attention.lua` (modify) | the `inline` flag in `decide` |
| `lua/floating-claude/watcher.lua` (modify) | leave inline diffs alone |
| `lua/floating-claude/compat.lua`, `health.lua` (modify) | `unified_diff()` capability check; health lines |
| `README.md`, `CHANGELOG.md` (modify) | the feature |

---

### Task 1: Spike: the unified diff in your window (throwaway)

**Files:** a scratch script outside the repo, in the scratchpad. Nothing is committed except the findings appended to the spec.

- [ ] **Step 1:** In a real Neovim with claudecode.nvim at af04fbf and floating-claude loaded, set `require("claudecode").state.config.diff_opts.layout = "unified"` and `open_in_new_tab = false`. Call `require("claudecode.diff").open_diff_blocking(old, old, new_contents, "spike")` from a coroutine for a small file open in the current window.
- [ ] **Step 2:** In a `User ClaudeCodeDiffOpened` handler, `nvim_win_set_buf(origin_win, diff_buf)` **first**, then close `data.diff_window`. Confirm that the diff is not rejected (`_register_reject_when_hidden` must not fire).
- [ ] **Step 3:** Accept with `:w` in the origin window. Confirm that the file is written, the origin window survives, and after `ClaudeCodeDiffClosed`, `nvim_win_set_buf(origin_win, file_buf)` plus `:checktime` shows the new content. Repeat with `:ClaudeCodeDiffDeny`.
- [ ] **Step 4:** Repeat Steps 1–3 with Heber's own `ClaudeCodeDiffOpened` autocmd from `~/.config/nvim/lua/plugins/claude.lua` active (it only acts when `tab_number` is set).
- [ ] **Step 5:** Append a `## Spike results` section to the spec: works or not, any ordering that matters, and the resulting `diff_in_window` default (`true` if every step held, else `false`). Commit the spec.

### Task 2: Spike: pasting into the live TUI (throwaway)

**Files:** a scratch script in the scratchpad; findings appended to the spec.

- [ ] **Step 1:** In a tmux window, start `nvim --listen <scratch>/nvim.sock` and open Claude with `:ClaudeCode`. From the agent shell, drive it with `nvim --server <sock> --remote-expr`.
- [ ] **Step 2:** `chansend(jobid, "\27[200~" .. text .. "\27[201~")`, then `chansend(jobid, "\r")` as a separate call, for:
  - a one-line prompt;
  - a 5-line prompt;
  - a prompt starting with `@lua/floating-claude/state.lua#L1-10`.

  In `:FloatingClaudeEvents`, record what `UserPromptSubmit.prompt` carries for each, and whether Claude read only lines 1–10 of the mentioned file.
- [ ] **Step 3:** Turn on Claude Code's vim mode (`/vim`), press `Esc` into NORMAL, and repeat the one-line paste. Record whether it lands. Then record what the screen shows in NORMAL mode, so `input_draft()` can detect it.
- [ ] **Step 4:** Type a draft by hand and capture the terminal lines (`nvim_buf_get_lines(state.buf, …)`) with an empty box, with a one-line draft, and with a two-line draft. Save them as fixtures in `tests/fixtures/input_box/` (`empty.txt`, `draft.txt`, `draft_multiline.txt`, plus `vim_normal.txt` if Step 3 showed a marker).
- [ ] **Step 5:** Append the findings to the spec's `## Spike results`:
  - **Mention form:** the typed `@path#Lx-y` if it worked, else `In <path>, lines <x>-<y>: <instruction>`.
  - **Vim mode:** how NORMAL mode shows, and whether it blocks the paste. If it blocks, `input_draft()` reports it as a draft.
  - **The send:** whether the `\r` must be a separate `chansend`.

  Commit the spec and the fixtures.

### Task 3: Config, keymap, command, input and virtual lines

**Files:**
- Modify: `lua/floating-claude/config.lua`, `lua/floating-claude/keymaps.lua`, `plugin/floating-claude.lua`
- Create: `lua/floating-claude/inline/init.lua`, `lua/floating-claude/inline/input.lua`, `lua/floating-claude/inline/lines.lua`
- Test: `tests/inline_lines_spec.lua`, `tests/inline_input_spec.lua`, extend `tests/config_spec.lua` and `tests/keys_spec.lua` (or the keymaps spec, wherever `keymaps.apply` is covered)

**Interfaces:**
- Produces:
  - `config.options.inline` with the defaults in Global Constraints, and `config.options.keymaps.inline`.
  - `lines.render(buf: integer, row: integer, items: string[], opts: { on_enter: fun()|nil }): integer`. `row` is the 0-based last row of the range. It returns the extmark id. Items are capped at `config.options.inline.lines` and each is cut to the window's text width with `…`. One extmark per buffer: a later render replaces it. Highlight groups: `FloatingClaudeInline` (default link `Comment`) and `FloatingClaudeInlineAsk` (default link `Question`).
  - `lines.clear(buf: integer)`.
  - `lines.at_cursor(buf: integer): boolean`. True when the cursor row is the extmark's row or within the range it annotates, so `<CR>` can act. The `<CR>` mapping is buffer-local, set only while lines are shown, and falls through to the original `<CR>` elsewhere (`vim.api.nvim_feedkeys` of the original rhs, or `<CR>` itself).
  - `input.open(opts: { win: integer, row: integer, on_submit: fun(text: string), on_cancel: fun()|nil })`. A float `relative = "win"`, anchored at `bufpos = { row, 0 }`, as wide as the text area, starting 1 row high and growing to `max_input_height`. `<CR>` (insert and normal) submits the trimmed text, and an empty one cancels. `<S-CR>` and `<C-j>` insert a newline. `<Esc>` in normal mode and `q` cancel. It closes on `WinLeave`.
  - `inline.ask(opts: { line1: integer, line2: integer, mode: "session"|"headless"|nil })`. It opens the input and dispatches on submit. In this task the dispatch is a stub that renders `▸ <instruction>`; Tasks 5 and 8 fill it in.
  - `inline.clear(buf: integer|nil)`.
  - `:FloatingClaudeInline` with `range = true` and `nargs = "?"`. The arguments are `session`, `headless` and `clear`, with completion.
  - `keymaps.inline` mapped in `n` (cursor line) and `x` (the selection; leave visual mode first, then read the `'<` and `'>` marks).

- [ ] **Step 1: Write the failing tests**
  - `config_spec`: `require("floating-claude.config").setup({}).inline.when_busy == "wait"`, `.inline.headless.apply == "review"`, `.keymaps.inline == "<leader>ai"`.
  - Keymaps: after `apply()`, `vim.fn.maparg("<leader>ai", "x") ~= ""` and `vim.fn.maparg("<leader>ai", "n") ~= ""`. A user mapping on `<leader>ai` in `x` is left alone.
  - `inline_lines_spec`:
    - `render(buf, 2, {"a","b","c","d"})` with `inline.lines = 3` gives one extmark at row 2 with 3 `virt_lines`.
    - A second render replaces it, so there is still one extmark.
    - After `nvim_buf_set_lines(buf, 0, 1, false, {})`, the extmark is at row 1.
    - Deleting rows 0–2 leaves no error, and `clear` still works (Review Focus 2).
  - `inline_input_spec`:
    - `open` creates a float anchored in the window.
    - Feeding `hello<CR>` calls `on_submit("hello")`.
    - Three lines of text grow the height to 3, and 10 lines cap it at `max_input_height`.
    - An empty `<CR>` calls `on_cancel`.
- [ ] **Step 2:** Run `make test-file FILE=tests/inline_lines_spec.lua` (and each new spec). Expected: FAIL (module not found).
- [ ] **Step 3:** Implement the interfaces above. Rewrite `keymaps.ACTIONS` entries to carry `modes` (default `{ "n" }`), and keep `mapped` per action and mode.
- [ ] **Step 4:** Run `make test`. Expected: all specs PASS, old and new.
- [ ] **Step 5:** Commit: `Add the inline input and its virtual lines`.

### Task 4: The session-mode request and the send gate

**Files:**
- Create: `lua/floating-claude/inline/request.lua`, `lua/floating-claude/inline/send.lua`
- Modify: `lua/floating-claude/parser.lua` (add `M.input_draft()`)
- Test: `tests/inline_request_spec.lua`, `tests/inline_send_spec.lua`, extend `tests/parser_spec.lua` with Task 2's fixtures

**Interfaces:**
- Consumes: `floating_claude.Record` (`hooks/record.lua`), `text.tool_line`, `text.request_line` and `text.prose` (`hooks/text.lua`).
- Produces:
  - `parser.input_draft(): string|nil`. `""` for an empty input box, the draft text otherwise, and `nil` when no box can be read. Lines inside `input_boundary` are joined with `\n`, with the `❯` glyph and trailing blanks stripped. Task 2's vim-NORMAL marker counts as a non-empty draft.
  - `request.new(opts: { file: string, line1: integer, line2: integer, instruction: string, mention: "at"|"words" }): Request`. The `Request` fields are:
    - `phase`: `"waiting"|"sent"|"running"|"done"|"interrupted"|"failed"|"dropped"`;
    - `prompt`: the text that gets pasted;
    - `asked`: the instruction, whitespace-normalised;
    - `activity`, `said`, `asking`: `string|nil`;
    - `sent_at`: `integer|nil`.
  - `request.prompt(req): string`. The mention form from Task 2. Paths are relative to `vim.fn.getcwd()`.
  - `request.on_record(req, rec): boolean`, true when the lines changed:
    - In `"sent"`, a `UserPromptSubmit` whose whitespace-normalised `prompt` contains `req.asked` (compare at most the first 1500 bytes of `asked`, since prompts are capped at `record.TEXT_CAP` = 2000) moves to `"running"`.
    - In `"running"`:
      - `PreToolUse` sets `activity = text.tool_line(...)` and clears `asking`.
      - `PostToolUse` and `PostToolUseFailure` clear `asking`.
      - `MessageDisplay` sets `said = rec.delta`.
      - `PermissionRequest` and `Elicitation` set `asking`.
      - `Stop` sets `said = rec.message or said` and moves to `"done"`.
      - `StopFailure` moves to `"failed"` with `said = rec.message or rec.error`.
      - `SessionEnd` moves to `"failed"`.
    - Records in other phases are ignored.
  - `request.on_tick(req, now_ms: integer, status: { working: boolean }): boolean`:
    - In `"sent"`, if `now_ms - sent_at >= 5000`, move to `"failed"` with `said = "Claude didn't take the prompt · <CR> to open Claude"`.
    - In `"running"`, if `not status.working` and no record has arrived for 1000 ms (track `last_at`), move to `"interrupted"`. These are the same SAFETY_MS rules as `session.tick`.
  - `request.items(req): string[]`, the line model, in order:
    - `"▸ " .. asked`;
    - then, by phase:
      - `"waiting"`: `waiting for Claude to finish`;
      - `"running"`: `asking` when set (`Claude is asking you something · <CR> to open Claude`), else `activity`, then `"Claude: " .. said` when set;
      - `"done"` and `"failed"`: `"Claude: " .. said`;
      - `"interrupted"`: `interrupted`.
  - `request.ended(req): boolean`, true for `done`, `interrupted`, `failed` and `dropped`.
  - `send.gate(when_busy: "wait"|"send", session_phase: string, draft: string|nil): "send"|"wait"|"draft"|"asking"`:
    - `"send"` mode always returns `"send"`.
    - In `"wait"` mode, the order is:
      - a phase of `"request"` gives `"asking"`;
      - a `draft ~= ""` (nil counts as a draft) gives `"draft"`;
      - a phase of `"working"` gives `"wait"`;
      - otherwise `"send"`.
  - `send.paste(jobid: integer, text: string)`: `chansend(jobid, "\27[200~" .. text .. "\27[201~")`, then `chansend(jobid, "\r")`, split or joined as Task 2 found.

- [ ] **Step 1: Write the failing tests**
  - Request transitions, one `it` each:
    - a matching prompt moves `sent` to `running`;
    - a non-matching prompt stays in `sent`;
    - `PreToolUse` with `tool_name = "Read"` gives an `activity` equal to `text.tool_line("Read", input)`;
    - `Stop` with `message = "Done."` gives `done`, and `items()[2] == "Claude: Done."`;
    - `PermissionRequest` gives `items()[2] == "Claude is asking you something · <CR> to open Claude"`;
    - `SessionEnd` gives `failed` (Review Focus 3);
    - `on_tick` 5000 ms after `sent` gives `failed` with the didn't-take message (Review Focus 1);
    - `on_tick` with `working = false` and a 1000 ms silence gives `interrupted`;
    - a long instruction (3000 bytes) still matches a prompt capped at 2000.
  - `send.gate` table test, covering every row of the order above.
  - `parser.input_draft()` returns `""`, `"draft text"` and the two-line join from the fixtures.
- [ ] **Step 2:** Run `make test-file FILE=tests/inline_request_spec.lua`. Expected: FAIL.
- [ ] **Step 3:** Implement. `request.lua` and `send.gate` are pure (no `vim.api`). Only `send.paste` touches the job.
- [ ] **Step 4:** Run `make test`. Expected: all PASS.
- [ ] **Step 5:** Commit: `Follow an inline request through the session's hooks`.

### Task 5: Wire session mode end to end

**Files:**
- Modify: `lua/floating-claude/inline/init.lua`, `lua/floating-claude/hooks/session.lua`, `lua/floating-claude/attention.lua`
- Test: `tests/inline_session_spec.lua`, extend `tests/attention_spec.lua`, `tests/hooks_session_spec.lua`

**Interfaces:**
- Consumes: Tasks 3 and 4.
- Produces:
  - `session.on_record(name: string, fn: fun(rec: floating_claude.Record)|nil)`. It is called from `M.inject` after the reducer, for every live record. A replay (`receive_ring`) does not call it.
  - `session.set_inline(active: boolean)`, `session.inline_active(): boolean`.
  - `attention.decide(where, effect, opts, diff_visible, inline: boolean|nil)`. When `inline` is true and `where == "corner"`, it returns `nil` for everything but `"activity"`, so the float is never restored. `where == "hidden"` is unchanged, so `show_hidden` still brings the corner.
  - `inline.ask` in session mode:
    - Refuse with `vim.notify` (WARN) and the exact copy in these cases:
      - another request is in flight;
      - `not require("floating-claude").is_running()`;
      - `not session.active()` (append `session.reason()`).
    - Then `:update` the buffer (refuse with the write error if it fails), build the request, render, and gate:
      - `"send"`: paste, set `phase = "sent"` and `sent_at`.
      - `"wait"`: `phase = "waiting"`, sent on the next record that leaves `session.state().phase == "idle"` (after `Stop`), if the gate then says `"send"`; otherwise the request is dropped with the gate's line.
      - `"draft"` and `"asking"`: render the matching line, set `phase = "dropped"`, and release the lock.
    - On every record, `request.on_record`, then re-render.
    - While the request is not ended, a 250 ms `vim.uv` timer calls `request.on_tick(req, record.now_ms(), parser.status())`.
    - When the request ends, stop the timer, `session.set_inline(false)`, and release the lock. The lines stay.
    - `<CR>` on the lines calls `require("floating-claude").restore()` (the float, focused on Claude's prompt).

- [ ] **Step 1: Write the failing tests**
  - `attention_spec`: `decide("corner", "finished", { restore_on_input = "idle" }, false, true) == nil`, `decide("corner", "request", …, true) == nil`, `decide("hidden", "request", { show_hidden = "request" }, false, true) == "show_now"`.
  - `inline_session_spec`, with `session.start_scripted()`, a fake `state.jobid` (a `jobstart({"cat"})`), and `send.paste` spied on:
    - an idle session sends at once, and the paste carries the mention and the instruction;
    - a scripted `UserPromptSubmit`, `PreToolUse`, then `Stop` leave the lines at `▸ …` and `Claude: …`;
    - a `"working"` session waits, then sends after `Stop`;
    - a draft returns `"draft"`, nothing is pasted, and the lock is free;
    - a second `ask` while one runs notifies `An inline request is already running`;
    - `is_running() == false` notifies `Claude isn't running · start it with :ClaudeCode`.
  - `hooks_session_spec`: `on_record` hears live records and not replays.
- [ ] **Step 2:** Run each new spec. Expected: FAIL.
- [ ] **Step 3:** Implement. `session.act` passes `S.inline` to `attention.decide`.
- [ ] **Step 4:** Run `make test`. Expected: all PASS.
- [ ] **Step 5:** Commit: `Send inline requests into the running session`. Then check by hand in Heber's Neovim: select lines, `<leader>ai`, ask a question, and watch the lines and the float's transcript.

### Task 6: The diff, in your window

**Files:**
- Create: `lua/floating-claude/inline/diff.lua`
- Modify: `lua/floating-claude/inline/init.lua`, `lua/floating-claude/watcher.lua`, `lua/floating-claude/compat.lua`
- Test: `tests/inline_diff_spec.lua` (stubs), `tests/integration/inline_diff_spec.lua` (real claudecode.nvim, run by `make test-compat`)

**Interfaces:**
- Consumes: the `Request` and the origin `win` and `buf` from Task 5. claudecode.nvim's `User ClaudeCodeDiffOpened` and `ClaudeCodeDiffClosed` events and `require("claudecode").state.config.diff_opts`.
- Produces:
  - `compat.unified_diff(): boolean`. True when claudecode.nvim is loaded, its config validator accepts `layout = "unified"` (`pcall` on its `config.apply` with a copy), and `require("claudecode.diff_inline")` loads.
  - `diff.begin(ctx: { file: string, win: integer, buf: integer, on_change: fun() })`. Saves `diff_opts.layout` and `open_in_new_tab`, then sets `layout = config.options.inline.diff_layout` (when not `false` and `unified_diff()` holds). With `diff_in_window`, it also sets `open_in_new_tab = false`. It registers the autocmds:
    - `ClaudeCodeDiffOpened` for `data.file_path == ctx.file`, when `diff_in_window` is on and `ctx.win` is valid: carry out Task 1's handoff in its recorded order. Then draw `lines.render(diff_buf, first_changed_row, items)` and put the cursor on the first changed row. Diffs for other files are left as they open (Review Focus 4).
    - `ClaudeCodeDiffClosed` for that `tab_name`: put `ctx.buf` back in `ctx.win`, run `:checktime`, put the cursor on the first changed row, then call `on_change`.
  - `diff.finish()`. Restores the saved options once the request has ended **and** no handed-off diff is open, and removes the autocmds. It is idempotent.
  - `diff.active(): boolean`, true while a handed-off diff is open. `watcher` skips minimize and restore while it is true.

- [ ] **Step 1: Write the failing tests**
  - Stub spec:
    - `begin` sets `layout = "unified"` and `open_in_new_tab = false` on a stub config table;
    - `finish` restores both;
    - `finish` while `active()` is deferred until the closed event;
    - a `SessionEnd` during the diff still restores (Review Focus 3);
    - an opened event for another file is ignored.
  - Integration spec, against the real claudecode.nvim:
    - a blocking diff for a temp file is handed to the origin window;
    - `:w` writes the file and the origin window shows the new content;
    - `ClaudeCodeDiffDeny` leaves the file unchanged with the origin window intact.
- [ ] **Step 2:** Run `make test-file FILE=tests/inline_diff_spec.lua` and `make test-compat`. Expected: FAIL.
- [ ] **Step 3:** Implement. If Task 1 set `diff_in_window = false`, implement only the layout swap and leave the handoff behind the option.
- [ ] **Step 4:** Run `make test` and `make test-compat`. Expected: all PASS.
- [ ] **Step 5:** Commit: `Open an inline edit's diff in the window you asked from`. Check by hand: ask for an edit, then `:w`; ask again and deny.

### Task 7: Health, README, CHANGELOG for session mode

**Files:** `lua/floating-claude/health.lua`, `README.md`, `CHANGELOG.md`; extend `tests/setup_spec.lua` if health is covered there.

- [ ] **Step 1:** Health gets an "Inline mode" section:
  - OK when hooks are active, WARN otherwise with the reason;
  - OK or WARN for `compat.unified_diff()`, where the WARN says that edits open in claudecode.nvim's own layout;
  - the key, or "not mapped".
- [ ] **Step 2:** README gets an "Inline mode" section after "See it move":
  - what it does, with a text sketch;
  - `<leader>ai`;
  - the `inline` options block from the spec;
  - the requirements (hooks; the unified layout);
  - a note that float-claude.nvim uses the same key.

  CHANGELOG gets an `Unreleased` entry.
- [ ] **Step 3:** Run `make test` and `:checkhealth floating-claude` in a headless Neovim. Expected: PASS, and the section renders.
- [ ] **Step 4:** Commit: `Document inline mode`.

### Task 8: Headless process and reply

**Files:**
- Create: `lua/floating-claude/inline/headless/process.lua`, `lua/floating-claude/inline/headless/reply.lua`, `tests/fixtures/fake_claude.lua` (run with `nvim -l`, it prints stream-json lines from a script given by environment variable)
- Test: `tests/inline_headless_spec.lua`

**Interfaces:**
- Produces:
  - `reply.prompt(ctx: { file: string, filetype: string, line1: integer, line2: integer, lines: string[], before: string[], after: string[], diagnostics: string[], instruction: string }): string`. The user message: the file, filetype and range, the selection in `<selection>` tags, the context in `<context>` tags, the diagnostics, and the instruction.
  - `reply.SYSTEM`, the system prompt. The reply's first word is `EDIT` or `ANSWER`. After `EDIT`, the reply is only the replacement lines for the selection, with no code fences. After `ANSWER`, it is prose.
  - `reply.parse(text: string): { kind: "edit"|"answer"|"pending", body: string }`. It is `"pending"` until the first word is complete, and an untagged reply is an `"answer"`. For an edit, one surrounding ``` fence is stripped if present.
  - `process.start(opts: { cmd: string[], model: string|false, system: string, prompt: string, on_delta: fun(text: string), on_done: fun(), on_error: fun(msg: string) }): { stop: fun() }`.
    - Arguments: `-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --tools "" --strict-mcp-config --no-session-persistence --system-prompt <system>`, plus `--model <m>` when set.
    - It writes one `{type="user",message={role="user",content=prompt}}` line and closes stdin.
    - stdout is split on newlines:
      - `stream_event` with `content_block_delta` and `text_delta` calls `on_delta`;
      - `result` calls `on_done`, or `on_error` when `is_error`.
    - A non-zero exit before `result` calls `on_error` with the first line of stderr, or `cannot run <cmd[1]>` when the spawn fails.
    - `stop()` closes stdin, then sends SIGTERM.
- [ ] **Step 1: Write the failing tests**
  - `reply.parse("EDIT\nfoo") == { kind = "edit", body = "foo" }`.
  - `reply.parse("ED")` gives `pending`.
  - `reply.parse("Hello")` gives `answer`.
  - A fenced edit is unfenced.
  - `process.start` with `cmd = { "nvim", "-l", "tests/fixtures/fake_claude.lua" }`:
    - the deltas arrive in order, then `on_done`;
    - with the fake exiting 1 and stderr `auth failed`, `on_error("auth failed")`;
    - `cmd = { "definitely-not-claude" }` gives `on_error("cannot run definitely-not-claude")` (Review Focus 5).
- [ ] **Step 2:** Run `make test-file FILE=tests/inline_headless_spec.lua`. Expected: FAIL.
- [ ] **Step 3:** Implement with `vim.system(cmd, { stdin = true, stdout = fn, stderr = fn })`, with callbacks scheduled onto the main loop.
- [ ] **Step 4:** Run `make test`. Expected: all PASS.
- [ ] **Step 5:** Commit: `Run headless inline requests through claude -p`.

### Task 9: Headless review and stream, wired in

**Files:**
- Create: `lua/floating-claude/inline/headless/apply.lua`
- Modify: `lua/floating-claude/inline/init.lua`
- Test: `tests/inline_apply_spec.lua`

**Interfaces:**
- Consumes: Task 8, plus `lines` and `input` from Task 3.
- Produces:
  - `apply.review(buf: integer, line1: integer, line2: integer): Review`, where `Review` is `{ update: fun(new_lines: string[]), accept: fun(), reject: fun() }`:
    - `update` highlights the old rows with `ClaudeCodeInlineDiffDelete` (defined with `default = true` as claudecode.nvim does, when it is absent) and redraws the new lines as `virt_lines` with `ClaudeCodeInlineDiffAdd` below the range.
    - `accept` replaces the range in one undo block.
    - `reject` clears it.
    - While a review is pending, buffer-local `<leader>aa` and `<leader>ad` (normal mode) call accept and reject. They are removed after either, and the user's own mappings come back.
  - `apply.stream(buf: integer, line1: integer, line2: integer): Stream`, where `Stream` is `{ update: fun(new_lines: string[]), finish: fun(), stopped: boolean }`:
    - Each `update` writes the complete lines into the range with `nvim_buf_set_lines`. The first write starts an undo block (`let &l:undolevels = &l:undolevels`) and the rest use `undojoin`.
    - The buffer is `modifiable = false` between writes.
    - If `changedtick` moved since the last write by anything but this code, it sets `stopped = true` and writes no more.
  - `inline.ask` in headless mode:
    - Build the context (40 lines either side and the diagnostics in the range).
    - Start the process, feeding deltas into `reply.parse`:
      - an `answer` renders `Claude: <latest paragraph>` in the lines, and `<CR>` opens the full answer in a scratch float;
      - an `edit` goes to `review` or `stream` per `inline.headless.apply`, and the lines show `editing…`, then `accept <leader>aa · reject <leader>ad` for a review.
    - Errors render `Claude: <message>`.
    - The lock is released on done or error. `:FloatingClaudeInline headless|session` overrides `inline.mode` for one request.

- [ ] **Step 1: Write the failing tests**
  - Review:
    - `update({"x","y"})` leaves the buffer unchanged, with two add `virt_lines` and the delete highlight on the range;
    - `accept` replaces the range, and one `u` restores it;
    - `reject` leaves the buffer unchanged and no extmarks;
    - `<leader>aa` is buffer-local only while pending.
  - Stream:
    - three `update`s, then one `u`, restore the original;
    - a foreign edit between updates sets `stopped`.
  - End to end with `fake_claude.lua` emitting `EDIT\nnew line`: in review mode the buffer is unchanged until `<leader>aa`; in stream mode the line is written.
- [ ] **Step 2:** Run `make test-file FILE=tests/inline_apply_spec.lua`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test`. Expected: all PASS.
- [ ] **Step 5:** Commit: `Review or stream a headless inline edit in place`. Then add headless mode to the README section, the health line (`claude` on PATH), and the CHANGELOG. Fold that into this commit if it is still HEAD, otherwise a `Document headless inline mode` commit. Check by hand: `:'<,'>FloatingClaudeInline headless`.

### Task 10: Whole-branch check

- [ ] **Step 1:** Run `make test`, `make test-compat` and `make lint`. Paste the full output, untruncated.
- [ ] **Step 2:** Walk through the spec's Goals and Anti-goals in Heber's Neovim, both modes, and list anything that differs.
- [ ] **Step 3:** If it fits the tour, add a demo step (scripted session-mode request) to `:FloatingClaudeDemo`. Otherwise, record in the spec why not.
