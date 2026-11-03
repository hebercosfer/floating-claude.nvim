# Read Claude Through Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The corner notification takes Claude's state and words from Claude Code's HTTP hook events instead of the screen. Screen reading stays as the fallback, and an events view shows what the plugin heard.

**Architecture:**
- **The listener thread:** a `vim.uv.new_thread` owns a localhost socket and answers every hook with an empty `200` at once. It compacts each event with pure modules it requires itself, then forwards it to the main loop over a `uv.pipe()`, gated by the window mode.
- **The main loop:**
  - a pure reducer turns records into a phase and a body;
  - a pure attention module decides restores and shows;
  - the notification renders from that state, reading only the live status line for its title.
- **The fallback:** today's poll plus parser path, unchanged.

**Tech Stack:** Lua on Neovim 0.11+ (LuaJIT); `vim.uv` threads, pipes and TCP; `vim.json`; plenary.nvim busted specs (`make test`, `make test-file FILE=…`); stylua.

**Spec:** `docs/superpowers/specs/2026-11-03-hooks-listener-design.md`. Read it first: the decisions and their reasons live there.

## Global Constraints

**Versions and the thread:**
- Neovim floor stays 0.11 on `main`. No backport work on this branch.
- Modules the thread requires (`hooks/http.lua`, `hooks/frame.lua`, `hooks/text.lua`, `hooks/record.lua`, `hooks/thread.lua`) use only plain Lua, `vim.uv`, `vim.json` and the `vim.*` string and table helpers. They must not use `vim.api`, `vim.fn`, `vim.schedule` or `vim.notify`.
- A thread can `require` plugin modules only after setting `package.path` to `<root>/lua/?.lua;<root>/lua/?/init.lua` (verified 2026-11-03).
- Thread→main traffic goes only through a `uv.pipe()` of `frame.encode` frames. Never `uv.new_async`: it coalesces sends, and lost 2 of 3 events in the spike.

**The listener:**
- The listener replies before it does any work. The reply is always empty: `200`, or `403` for a bad token. It never sends a decision.
- The listener lives exactly as long as the Claude job. Never close the port while Claude runs, not even when falling back.

**Fixed values from the spec:**
- **Subscribed events, in this order:** `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`, `MessageDisplay`, `Stop`, `StopFailure`, `Elicitation`, `PreCompact`, `PostCompact`, `SessionEnd`.
- **Request-class events:** `PermissionRequest`, `Elicitation`, `StopFailure`.
- **The settings file:**
  - each hook entry: header `X-Floating-Claude`, token of 16 random bytes as hex, hook `timeout = 2` (seconds), URL `http://127.0.0.1:<port>/hook`;
  - the file: in `vim.fn.stdpath("run")`, mode 0600, passed as `--settings <path>`, and the token never on argv.
- **Caps:** body cap 16 MiB; text cap 2000 bytes, with the suffix `… [<n> bytes more]`; ring ≤ 64 records; events view keeps 50 by default, and 0 keeps none.
- **Safety net:** 1000 ms with no live status line and no event.
- **Compat:** `compat.minimum.hooks = "2.1.301"`.
- **Defaults:** `auto.show_hidden = "request"`, `auto.restore_on_input = "idle"` (`true` means `"idle"`), `keymaps.events = "<leader>ae"`, `restore_idle_ms = 1200`, `refresh_ms = 120`.

**Looks and the fallback:**
- The corner's look is unchanged: same title, waiting line, glyphs and highlight groups. The only addition is `FloatingClaudeError`, which links to `DiagnosticError`.
- The fallback path (watcher poll + `parser.status_lines()`) keeps working unchanged. Every existing spec stays green.

**Process (Heber's standing rules):**
- **Commits:**
  - Never run `git commit` in the agent shell. Write the message to `~/.claude/cmsg.txt` with a heredoc.
  - For new files, `git add -N` them first.
  - Dry-run with `git commit --dry-run -F ~/.claude/cmsg.txt -- <paths>`, then open the commit with `tmux new-window -n commit -c <repo> "git commit -e -v -F ~/.claude/cmsg.txt -- <paths>"`.
  - No trailers. Imperative subject, prose body.
  - After it lands, push the branch, and point `~/.config/nvim/lua/plugins/claude.lua` at `feature/HooksListener` (the `branch` key on the floating-claude dependency). Then tell Heber to `:Lazy sync`.
- **Formatting:** `make lint` (stylua) passes before every commit.
- **Test output:** when reporting a run, paste its whole output, never a summary.

## Review Focus

1. **Claude restarted in the same Neovim** (exit, then `:ClaudeCode`, or `--resume`): a fresh port, token and settings file; the old file deleted; the state reset. Covered in Task 9.
2. **A user's own `--settings` in claudecode's `terminal_cmd`:** the command passes through untouched, and the fallback states the reason. Covered in Task 9.
3. **Multibyte text at the cap** (accents, CJK, emoji in tool output): cut on a character boundary, so the events view never shows broken UTF-8. Covered in Task 4.
4. **A huge payload** (a Read of a 20 MB file): answered `200` at once, dropped, logged as too large. Covered in Task 6.
5. **A session that is never minimized, for hours:** the ring and the log stay bounded, and nothing crosses to the main loop. Covered in Task 6.

---

## File map

| File | Responsibility |
|---|---|
| `lua/floating-claude/hooks/frame.lua` (new) | Length-prefixed frames, both directions |
| `lua/floating-claude/hooks/http.lua` (new) | Request-head parsing; canned empty responses |
| `lua/floating-claude/hooks/text.lua` (new) | Body text: prose cleanup, tool and request lines, synthetic prompts |
| `lua/floating-claude/hooks/record.lua` (new) | Event → compact record; capping; mode gating; the clock |
| `lua/floating-claude/hooks/reducer.lua` (new) | Records → phase and body; effects |
| `lua/floating-claude/hooks/thread.lua` (new) | The thread: socket, token, ring, transparency log |
| `lua/floating-claude/hooks/listener.lua` (new) | Main-side handle on the thread |
| `lua/floating-claude/hooks/settings.lua` (new) | The `--settings` file |
| `lua/floating-claude/hooks/session.lua` (new) | Orchestration: mode decision, wiring, settle, safety net, liveness, debounce |
| `lua/floating-claude/attention.lua` (new) | Pure restore and show decisions |
| `lua/floating-claude/events_view.lua` (new) | The transparency buffer |
| `config.lua`, `state.lua`, `notification.lua`, `highlights.lua`, `watcher.lua`, `terminal.lua`, `compat.lua`, `health.lua`, `keymaps.lua`, `init.lua`, `plugin/floating-claude.lua`, `demo/init.lua`, `demo/tui.lua`, `README.md`, `CHANGELOG.md` | Modified as each task says |
| `tests/fixtures/hooks.lua`, `tests/helpers/post.lua` (new) | Spike-derived event sequences; a curl-based poster |

---

### Task 1: The new options

**Files:**
- Modify: `lua/floating-claude/config.lua`
- Test: `tests/config_spec.lua`

**Interfaces:**
- Produces:
  - `config.options.hooks: { enabled: boolean, keep: integer }`. Normalized: `hooks = true` or `false` becomes `{ enabled = <bool>, keep = 50 }`.
  - `config.options.auto.restore_on_input: "idle"|"request"|false`, with `true` normalized to `"idle"`.
  - `config.options.auto.show_hidden: "request"|"idle"|false`.
  - `config.options.keymaps.events: string|false`.

- [ ] **Step 1: Write the failing tests**

```lua
it("defaults hooks on, keeping 50 events", function()
  config.setup({})
  assert.same({ enabled = true, keep = 50 }, config.options.hooks)
end)
it("accepts hooks = false", function()
  config.setup({ hooks = false })
  assert.same({ enabled = false, keep = 50 }, config.options.hooks)
end)
it("accepts a table that keeps none", function()
  config.setup({ hooks = { keep = 0 } })
  assert.same({ enabled = true, keep = 0 }, config.options.hooks)
end)
it("reads restore_on_input = true as idle", function()
  config.setup({ auto = { restore_on_input = true } })
  assert.equals("idle", config.options.auto.restore_on_input)
end)
it("defaults show_hidden to request and the events key to <leader>ae", function()
  config.setup({})
  assert.equals("request", config.options.auto.show_hidden)
  assert.equals("<leader>ae", config.options.keymaps.events)
end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/config_spec.lua`.** Expected: the five new specs FAIL.
- [ ] **Step 3: Implement.** Add the defaults with user-facing comments in the file's existing voice, and normalize in `M.setup()` after the deep extend. `keymaps.hide`'s comment now describes `show_hidden`: "comes back as the corner on its own when Claude asks you for something".
- [ ] **Step 4: Run the same command.** Expected: all PASS. Then run `make test`: everything green.
- [ ] **Step 5: Commit** `config.lua`, `tests/config_spec.lua`. Subject: `Add the options for reading Claude through hooks`.

### Task 2: Frames and HTTP heads

**Files:**
- Create: `lua/floating-claude/hooks/frame.lua`, `lua/floating-claude/hooks/http.lua`
- Test: `tests/hooks_wire_spec.lua`

**Interfaces:**
- Produces:
  - `frame.encode(kind: string, payload: string) -> string`. The format is `"<kind> <#payload>\n<payload>"`.
  - `frame.decoder() -> fun(chunk: string): { kind: string, payload: string }[]`. Stateful, and returns complete frames only.
  - `http.MAX_BODY = 16 * 1024 * 1024`.
  - `http.head(buf: string) -> { method: string, path: string, headers: table<string,string>, length: integer, size: integer }|nil`. Header names are lower-case. `length` is 0 without `Content-Length`. `size` is the byte length of the head including CRLFCRLF. Returns nil until the blank line arrives.
  - `http.response(status: 200|403) -> string`.

- [ ] **Step 1: Write the failing tests**

```lua
it("round-trips frames fed one byte at a time", function()
  local wire = frame.encode("record", 'a\nb "é"') .. frame.encode("port", "41234")
  local decode, got = frame.decoder(), {}
  for i = 1, #wire do vim.list_extend(got, decode(wire:sub(i, i))) end
  assert.same({ { kind = "record", payload = 'a\nb "é"' }, { kind = "port", payload = "41234" } }, got)
end)
it("waits for the blank line", function()
  assert.is_nil(http.head("POST /hook HTTP/1.1\r\nHost: x\r\n"))
end)
it("reads the head", function()
  local raw = "POST /hook HTTP/1.1\r\nX-Floating-Claude: t0k\r\nContent-Length: 12\r\n\r\n{...}"
  assert.same({ method = "POST", path = "/hook", headers = { ["x-floating-claude"] = "t0k", ["content-length"] = "12" }, length = 12, size = #raw - 5 }, http.head(raw))
end)
it("treats a missing Content-Length as an empty body", function()
  assert.equals(0, http.head("GET / HTTP/1.1\r\n\r\n").length)
end)
it("answers with empty bodies", function()
  assert.equals("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", http.response(200))
  assert.equals("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", http.response(403))
end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/hooks_wire_spec.lua`.** Expected: FAIL, module not found.
- [ ] **Step 3: Implement both modules.** Keep them thread-safe (Global Constraints).
- [ ] **Step 4: Run it again.** Expected: PASS.
- [ ] **Step 5: Commit** both modules and the spec. Subject: `Add the wire format for the hooks listener`.

### Task 3: Body text from events

**Files:**
- Create: `lua/floating-claude/hooks/text.lua`
- Test: `tests/hooks_text_spec.lua`

**Interfaces:**
- Produces:
  - `text.prose(markdown: string|nil) -> string|nil`: the newest prose paragraph, with its markup stripped.
  - `text.detail(name: string, input: table|nil) -> string|nil`.
  - `text.tool_line(name: string, input: table|nil) -> string|nil`: nil for plumbing tools.
  - `text.request_line(name: string, input: table|nil) -> string`.
  - `text.is_synthetic(prompt: string|nil) -> boolean`.
  - `text.PLUMBING`: the set `ToolSearch`, `TodoWrite`, `TaskCreate`, `TaskUpdate`, `TaskGet`, `TaskList`, `TaskOutput`, `TaskStop`.

**The rules the implementer needs:**
- **`prose`:**
  - Walk the lines, toggling a fence state on lines that start with ```` ``` ````, and drop fenced lines.
  - Drop table lines (starting `|`), rules (`---`, `***`, `___`) and headings (`#`).
  - Paragraphs are separated by blank lines; join a paragraph's lines with single spaces.
  - Strip list markers (`- `, `* `, `+ `, `1. `), `**x**`, `*x*`, `_x_` and `` `x` ``. Turn `[t](u)` into `t`.
  - Return the last non-empty paragraph.
- **`detail`:**
  - Bash: `description`, or `command`;
  - Read, Edit, MultiEdit, Write, NotebookEdit: the basename of `file_path` or `notebook_path`;
  - Grep, Glob: `pattern`;
  - WebFetch: the URL's host;
  - WebSearch: `query`;
  - Agent, Task: `description`;
  - otherwise nil.
- **`tool_line`:**
  - Bash, Agent, Task: the detail alone;
  - verb plus detail: Read → `Read `, Edit/MultiEdit/NotebookEdit → `Edit `, Write → `Write `, Grep → `Search `, Glob → `Find `, WebFetch → `Fetch `, WebSearch → `Search the web: `;
  - MCP tools: `mcp__<server>__<tool>` becomes `<server>: <tool>`;
  - otherwise the tool's name.
- **`request_line`:**
  - AskUserQuestion: the first question's `question`;
  - ExitPlanMode: `Plan ready for review`;
  - otherwise `Allow <name>: <detail>?`, or `Allow <name>?` when there is no detail.
- **`is_synthetic`:** after leading whitespace, the prompt starts with `<` plus one of `task-notification`, `command-name`, `command-message`, `local-command-caveat`, `local-command-stdout`, `bash-input`, `bash-stdout`, `bash-stderr`, then `>`.

- [ ] **Step 1: Write the failing tests**

```lua
it("keeps a lone opening sentence", function()
  assert.equals("I'll list the current directory's contents.", text.prose("I'll list the current directory's contents.\n\n"))
end)
it("strips inline code and emphasis", function()
  assert.equals("entries, . and .., so it is bare", text.prose("entries, `.` and `..`, so it is **bare**"))
end)
it("skips fenced code, tables and headings", function()
  assert.equals("Intro.", text.prose("Intro.\n\n```lua\nlocal x = 1\n```\n\n| a | b |\n|---|---|\n\n## Next"))
end)
it("flattens a list and keeps link text", function()
  assert.equals("First item see the docs", text.prose("- **First** item\n- see [the docs](https://x.y)"))
end)
it("summarises tools", function()
  assert.equals("List files", text.tool_line("Bash", { command = "ls", description = "List files" }))
  assert.equals("ls -la", text.tool_line("Bash", { command = "ls -la" }))
  assert.equals("Edit notification.lua", text.tool_line("Edit", { file_path = "/r/lua/notification.lua" }))
  assert.equals("Search is_working", text.tool_line("Grep", { pattern = "is_working" }))
  assert.equals("Fetch code.claude.com", text.tool_line("WebFetch", { url = "https://code.claude.com/docs/en/hooks" }))
  assert.equals("claude-vscode: openDiff", text.tool_line("mcp__claude-vscode__openDiff", {}))
  assert.is_nil(text.tool_line("ToolSearch", { query = "select:ExitPlanMode" }))
end)
it("words requests", function()
  assert.equals("Which color do you prefer?", text.request_line("AskUserQuestion", { questions = { { question = "Which color do you prefer?" } } }))
  assert.equals("Plan ready for review", text.request_line("ExitPlanMode", { plan = "# Plan" }))
  assert.equals('Allow Bash: Write "again" to spike2.txt?', text.request_line("Bash", { command = "printf again > spike2.txt", description = 'Write "again" to spike2.txt' }))
  assert.equals("Allow Edit: b.lua?", text.request_line("Edit", { file_path = "/a/b.lua" }))
end)
it("knows synthetic prompts", function()
  assert.is_true(text.is_synthetic("<task-notification>\n<task-id>bw686dv5b</task-id>"))
  assert.is_false(text.is_synthetic("Write a story"))
  assert.is_false(text.is_synthetic("<div> is broken in the footer"))
end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/hooks_text_spec.lua`.** Expected: FAIL.
- [ ] **Step 3: Implement `text.lua`** (thread-safe).
- [ ] **Step 4: Run it again.** Expected: PASS.
- [ ] **Step 5: Commit.** Subject: `Turn hook payloads into the corner's wording`.

### Task 4: Records

**Files:**
- Create: `lua/floating-claude/hooks/record.lua`
- Test: `tests/hooks_record_spec.lua`

**Interfaces:**
- Consumes: `text.is_synthetic` (Task 3).
- Produces:
  - `record.SUBSCRIBED: string[]`, in the order given in Global Constraints.
  - `record.REQUEST: table<string, true>`.
  - `record.TEXT_CAP = 2000` and `record.RING_MAX = 64`.
  - `record.now_ms() -> integer`: epoch milliseconds from `vim.uv.gettimeofday()`. Both sides use this one clock.
  - `record.cap(value: any, limit: integer) -> any`: a deep copy. Strings longer than `limit` bytes are cut at the last UTF-8 boundary at or below `limit` and suffixed `"… [" .. (original_bytes - kept_bytes) .. " bytes more]"`.
  - `record.compact(event: table, at: integer) -> Record|nil`.
  - `record.forwarded(rec: Record, mode: "float"|"corner"|"hidden", show_hidden: "request"|"idle"|false) -> boolean`.
- **`Record`:** `{ event, at, prompt?, synthetic?, tool_name?, tool_input? (capped), delta?, final?, message?, error?, trigger?, reason? }`.
  - `message` is `last_assistant_message` for `Stop` and `StopFailure`, and `message` for `Elicitation`.
  - `compact` returns nil when `event.agent_id ~= nil` or the event is not in `SUBSCRIBED`.

- [ ] **Step 1: Write the failing tests**

```lua
it("drops subagent and unsubscribed events", function()
  assert.is_nil(record.compact({ hook_event_name = "PreToolUse", agent_id = "a71d", tool_name = "Bash" }, 1))
  assert.is_nil(record.compact({ hook_event_name = "PostToolBatch", tool_calls = {} }, 1))
  assert.is_nil(record.compact({ hook_event_name = "Notification", notification_type = "permission_prompt" }, 1))
end)
it("keeps what the reducer reads", function()
  local r = record.compact({ hook_event_name = "Stop", last_assistant_message = "Done.", background_tasks = {}, session_id = "s" }, 7)
  assert.same({ event = "Stop", at = 7, message = "Done." }, r)
end)
it("marks synthetic prompts", function()
  assert.is_true(record.compact({ hook_event_name = "UserPromptSubmit", prompt = "<task-notification>\n…" }, 1).synthetic)
end)
it("cuts long strings on a character boundary", function()
  assert.equals(string.rep("é", 1000) .. "… [1000 bytes more]", record.cap(string.rep("é", 1500), 2000))
  local cut = record.cap("a" .. string.rep("€", 700), 2000) -- 1 + 3*666 = 1999 bytes kept
  assert.equals("a" .. string.rep("€", 666) .. "… [102 bytes more]", cut)
end)
it("gates by mode", function()
  local req, stop, ups, pre = { event = "PermissionRequest" }, { event = "Stop" }, { event = "UserPromptSubmit" }, { event = "PreToolUse" }
  assert.is_false(record.forwarded(req, "float", "request"))
  assert.is_true(record.forwarded(pre, "corner", "request"))
  assert.is_true(record.forwarded(req, "hidden", "request"))
  assert.is_false(record.forwarded(stop, "hidden", "request"))
  assert.is_true(record.forwarded(stop, "hidden", "idle"))
  assert.is_true(record.forwarded(ups, "hidden", "idle"))
  assert.is_false(record.forwarded(pre, "hidden", "idle"))
  assert.is_false(record.forwarded(req, "hidden", false))
end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/hooks_record_spec.lua`.** Expected: FAIL.
- [ ] **Step 3: Implement `record.lua`** (thread-safe).
- [ ] **Step 4: Run it again.** Expected: PASS.
- [ ] **Step 5: Commit.** Subject: `Compact hook events into records`.

### Task 5: Fixtures and the reducer

**Files:**
- Create: `tests/fixtures/hooks.lua`, `lua/floating-claude/hooks/reducer.lua`
- Test: `tests/hooks_reducer_spec.lua`

**Interfaces:**
- Consumes: `record.compact`, `text.prose`, `text.tool_line`, `text.request_line`.
- Produces:
  - `reducer.new() -> State`, where State is `{ phase = "idle", started = nil, last_event_at = nil, request_at = nil, compacting = false, body = nil }`.
  - `body` is `{ kind = "echo"|"tool"|"prose"|"error", text = string }`.
  - `reducer.apply(state: State, rec: Record) -> State, Effect|nil`. It mutates and returns `state`.
  - `Effect = "activity"|"request"|"finished"`.

**The rules** (the spec's event table, with one refinement):

| Record | Phase | Body | Effect |
|---|---|---|---|
| `UserPromptSubmit` | working; `started = at` | an echo of `prompt` unless `synthetic` | `activity` |
| `PreToolUse` | working | `tool_line` unless nil | `activity` |
| `PermissionRequest` | request; `request_at = at` | prose `request_line` | `request` |
| `PostToolUse`, `PostToolUseFailure` | working if it was a request | **if it was a request, `tool_line` of this record**: a request's text must not outlive it | `activity` |
| `MessageDisplay` | unchanged | prose `text.prose(delta)` if non-nil | nil |
| `Stop` | idle | prose `text.prose(message)` if non-nil | `finished` |
| `StopFailure` | request; `request_at = at` | error: `message` or `error` | `request` |
| `Elicitation` | request; `request_at = at` | prose `message` | `request` |
| `PreCompact` / `PostCompact` | `compacting` true / false | unchanged | nil |
| `SessionEnd` | everything reset to `new()` | — | nil |

`last_event_at = at` for every record.

- [ ] **Step 1: Build `tests/fixtures/hooks.lua`.**
  - **Source:** `~/.cache/floating-claude-spike-events.log`. Each line is `<ms> <raw json>`, sections start `--- T1` … `--- T5`, and section `T4b` exists too.
  - **Return:** `{ tool_and_prose, question, interrupt_mid_reply, background_task, interrupted_tool, plan, permission }`. Each is a list of `{ at = <ms>, event = <decoded table> }`, in log order, keeping the unsubscribed events and those with an `agent_id`.
  - **Mapping:** T1 → `tool_and_prose`, T2 → `question`, T3 → `interrupt_mid_reply`, T4 → `background_task`, T4b → `interrupted_tool`, T5 → `plan`.
  - **Sanitize:** ids become `"id"`; `cwd`, `transcript_path`, `scratchpad_dir` and `agent_transcript_path` become `"/project"` or `"/project/t.jsonl"`; `/home/cosfer` becomes `/home/user`; `tool_response` strings are cut to 200 bytes.
  - **`permission`, written by hand:**
    - `UserPromptSubmit` with prompt `Run printf`;
    - `PreToolUse`, Bash, `{ command = "printf again > spike2.txt", description = 'Write "again" to spike2.txt' }`;
    - `PermissionRequest` with the same tool;
    - `PostToolUse` with the same tool;
    - `Stop` with message `Done.`.
- [ ] **Step 2: Write the failing tests.** A helper, `run(seq) -> state, effects`, feeds each event through `record.compact(e.event, e.at)` (skipping nils) and `reducer.apply`, and collects only the non-nil effects.

```lua
it("ends a tool-and-prose turn idle on its last paragraph", function()
  local s, fx = run(fixtures.tool_and_prose)
  assert.equals("idle", s.phase)
  assert.equals("prose", s.body.kind)
  assert.truthy(vim.startswith(s.body.text, "The listing is empty apart from the two standard entries, . and .."))
  assert.equals("finished", fx[#fx]) -- the MessageDisplay trailing Stop adds no effect and no phase
end)
it("holds a question as a request until it is answered", function()
  local s = reducer.new()
  for _, e in ipairs(fixtures.question) do
    local r = record.compact(e.event, e.at)
    if r then reducer.apply(s, r) end
    if r and r.event == "PermissionRequest" then
      assert.same({ "request", "Which color do you prefer?" }, { s.phase, s.body.text })
    end
  end
  assert.same({ "idle", "You prefer red." }, { s.phase, s.body.text })
end)
it("is still working after an interrupt, because nothing fires", function()
  assert.equals("working", (run(fixtures.interrupt_mid_reply)).phase)
end)
it("ignores the subagent tail after Stop", function()
  assert.equals("idle", (run(fixtures.background_task)).phase)
end)
it("keeps the tool line through a synthetic prompt", function()
  local s = reducer.new()
  for _, e in ipairs(fixtures.interrupted_tool) do
    local r = record.compact(e.event, e.at)
    if r and r.synthetic then
      reducer.apply(s, r)
      assert.equals("tool", s.body.kind)
      break
    elseif r then reducer.apply(s, r) end
  end
end)
it("ends a plan turn waiting on approval, plumbing ignored", function()
  local s = run(fixtures.plan)
  assert.same({ "request", "Plan ready for review" }, { s.phase, s.body.text })
end)
it("drops a request's text once the tool runs", function()
  local s = reducer.new()
  for i, e in ipairs(fixtures.permission) do
    reducer.apply(s, record.compact(e.event, e.at))
    if i == 3 then assert.equals('Allow Bash: Write "again" to spike2.txt?', s.body.text) end
    if i == 4 then assert.same({ "working", "tool", 'Write "again" to spike2.txt' }, { s.phase, s.body.kind, s.body.text }) end
  end
end)
it("reports a failed turn as a request in the error style", function()
  local s, fx = reducer.new(), nil
  s, fx = reducer.apply(s, { event = "StopFailure", at = 1, error = "rate_limit", message = "API Error: Rate limit reached" })
  assert.same({ "request", "error", "API Error: Rate limit reached", "request" }, { s.phase, s.body.kind, s.body.text, fx })
end)
it("resets on SessionEnd and tracks compaction", function()
  local s = reducer.new()
  reducer.apply(s, { event = "PreCompact", at = 1 }); assert.is_true(s.compacting)
  reducer.apply(s, { event = "SessionEnd", at = 2, reason = "clear" })
  assert.same(reducer.new(), s)
end)
```

- [ ] **Step 3: Run `make test-file FILE=tests/hooks_reducer_spec.lua`.** Expected: FAIL.
- [ ] **Step 4: Implement `reducer.lua`.** It is pure, with no `vim.api`.
- [ ] **Step 5: Run it again.** Expected: PASS.
- [ ] **Step 6: Commit** the fixtures, the reducer and the spec. Subject: `Reduce hook records to Claude's state`.

### Task 6: The listener thread

**Files:**
- Create: `lua/floating-claude/hooks/thread.lua`, `lua/floating-claude/hooks/listener.lua`, `tests/helpers/post.lua`
- Test: `tests/hooks_listener_spec.lua`

**Interfaces:**
- Consumes: `frame`, `http`, `record`, `text`.
- Produces:
  - `listener.start(opts) -> Listener|nil, err`, where `opts = { token: string, keep: integer, show_hidden: "request"|"idle"|false, on_record: fun(rec: Record), on_ring: fun(records: Record[], received: integer) }`.
  - `Listener = { port: integer, received: integer, set_mode: fun(mode: "float"|"corner"|"hidden"), set_show_hidden: fun(v), log: fun(cb: fun(log: Log)), stop: fun() }`.
  - `Log = { received: integer, rejected: integer, entries: { at: integer, event: string|nil, fate: string, size: integer, payload: table|nil }[] }`.
  - `fate` is one of: `"forwarded"`, `"kept"`, `"dropped: subagent"`, `"dropped: unsubscribed"`, `"dropped: too large"`, `"dropped: unreadable"`, `"rejected"`.
  - `thread.run(write_fd: integer, read_fd: integer, token: string, opts_json: string)`. `opts_json` carries `{ keep, show_hidden, lua_path }`.
  - `post.sync(port, token, body: string, path?: string) -> { code: integer, time: number }` and `post.async(port, token, body, delay_s) -> vim.SystemObj`. Both run curl through `vim.system`: `-s -o /dev/null -w "%{http_code} %{time_total}"`, with the body written to a tempfile and sent with `--data-binary @file`.

**What the thread does:**
- **Start:** set `package.path`, require the four pure modules, bind `127.0.0.1:0`, and send a `port` frame.
- **Initial mode:** float.
- **Control frames from main:** `mode`, `show_hidden`, `log` (empty payload), `stop`.
- **Frames to main:**
  - `port`;
  - `record` (JSON of a Record);
  - `ring` (JSON `{ records, received }`), sent first on every switch *into* corner mode;
  - `log` (JSON Log).
- **Per request:**
  1. Parse the head and check the token. On a mismatch, write the `403` reply and log `rejected` with its size and no payload.
  2. Over `MAX_BODY`, read and discard the body, reply `200`, and log `dropped: too large`.
  3. Otherwise, write the `200` reply, then `pcall(vim.json.decode)`.
  4. Log the entry with `payload = record.cap(event, record.TEXT_CAP)`, keeping the newest `keep` entries.
  5. `compact` the event. Apply the ring rule: a non-synthetic `UserPromptSubmit` clears the ring, which keeps at most `RING_MAX` records.
  6. Forward when `record.forwarded(...)` says so.
- **Count:** `received` counts every token-valid request.

**The main side:**
- `listener.start` builds the thread function as `function(...) package.path = select(5, ...) .. ";" .. package.path; require("floating-claude.hooks.thread").run(...) end`.
- It reads frames through `vim.schedule` and waits up to 2000 ms for the `port` frame.
- `stop()` sends `stop`, joins the thread and closes both pipes.

- [ ] **Step 1: Write the failing tests**

```lua
local UPS = '{"hook_event_name":"UserPromptSubmit","prompt":"%s"}'
it("answers 200 and forwards in corner mode", function()
  local got = {}
  local l = assert(listener.start({ token = "t", keep = 50, show_hidden = "request", on_record = function(r) table.insert(got, r) end, on_ring = function() end }))
  l.set_mode("corner")
  assert.equals(200, post.sync(l.port, "t", UPS:format("hi")).code)
  assert.is_true(vim.wait(1000, function() return #got == 1 end))
  assert.equals("hi", got[1].prompt)
  l.stop()
end)
it("forwards nothing while maximized, then replays the turn on minimize", function()
  -- post UPS then a PreToolUse in float mode; on_record stays empty for 200ms;
  -- set_mode("corner") -> on_ring receives 2 records and received == 2
end)
it("rejects a wrong token with 403 and never forwards it", function()
  -- post with token "nope" -> 403; log -> rejected == 1, entry fate "rejected", payload nil
end)
it("keeps order across rapid posts", function()
  -- corner mode; 20 sequential post.sync with prompts "1".."20"; on_record prompts == {"1",...,"20"}
end)
it("answers within 500ms while the main loop is blocked", function()
  -- corner mode; local job = post.async(l.port, "t", UPS:format("x"), 0.2)
  -- busy-loop the main thread for 1500ms; local code, time = job:wait().stdout:match("(%d+) ([%d%.]+)")
  -- assert code == "200" and tonumber(time) < 0.5
end)
it("answers an oversized body with 200 and logs it as too large", function() -- Review Focus 4
  -- 17 MiB body -> 200; log entry fate "dropped: too large", payload nil
end)
it("forwards only requests while hidden by default", function()
  -- set_mode("hidden"); post Stop then PermissionRequest -> on_record gets only PermissionRequest
end)
it("keeps the newest entries, with long values cut", function()
  -- keep = 3; post 5 prompts, the last 3000 bytes long -> 3 entries, the last prompt ends "… [1000 bytes more]"
end)
it("keeps nothing with keep = 0 but still counts", function()
  -- keep = 0; post 2 -> log.entries empty, received == 2
end)
it("stays bounded over a long maximized session", function() -- Review Focus 5
  -- float mode, keep = 50; post 300 events -> no on_record; log has 50 entries; corner -> ring ≤ 64
end)
it("closes the port on stop", function()
  -- l.stop(); post.sync(port, "t", "{}").code == 0
end)
```

  Write each test in full. The comments give the exact assertions.

- [ ] **Step 2: Run `make test-file FILE=tests/hooks_listener_spec.lua`.** Expected: FAIL.
- [ ] **Step 3: Implement `thread.lua`, `listener.lua` and `tests/helpers/post.lua`.**
- [ ] **Step 4: Run it again.** Expected: PASS. Then run it twice more to catch flakiness: PASS all three times.
- [ ] **Step 5: Commit.** Subject: `Listen for Claude's hooks on a thread of their own`.

### Task 7: The settings file and the version gate

**Files:**
- Create: `lua/floating-claude/hooks/settings.lua`
- Modify: `lua/floating-claude/compat.lua`
- Test: `tests/hooks_settings_spec.lua`, `tests/compat_spec.lua`

**Interfaces:**
- Consumes: `record.SUBSCRIBED`.
- Produces:
  - `settings.HEADER = "X-Floating-Claude"` and `settings.TIMEOUT_S = 2`.
  - `settings.build(port: integer, token: string) -> table`.
  - `settings.write(port: integer, token: string) -> string|nil, string|nil`. It writes `stdpath("run") .. "/floating-claude-" .. pid .. "-" .. n .. ".json"`, opening the file with `vim.uv.fs_open(path, "w", 384)`.
  - `settings.remove(path: string)`.
  - `compat.minimum.hooks = "2.1.301"`.
  - `compat.hooks_ready(cmd_string: string) -> boolean, string|nil`. It calls the blocking `compat.cli_version(cmd_string, 1000)` once per binary per session. Reasons, verbatim:
    - `"the Claude Code version could not be read"`;
    - `("Claude Code %s is older than %s, the first with the hooks this plugin uses"):format(v, M.minimum.hooks)`.

- [ ] **Step 1: Write the failing tests**

```lua
it("registers one HTTP hook per subscribed event and nothing else", function()
  local s = settings.build(41234, "t0k")
  assert.same(record.SUBSCRIBED, vim.tbl_keys(s.hooks) --[[sorted both sides]])
  local h = s.hooks.Stop[1].hooks[1]
  assert.same({ type = "http", url = "http://127.0.0.1:41234/hook", headers = { ["X-Floating-Claude"] = "t0k" }, timeout = 2 }, h)
end)
it("writes a private file and removes it", function()
  local path = assert(settings.write(41234, "t0k"))
  assert.equals(384, vim.uv.fs_stat(path).mode % 512)
  assert.same(settings.build(41234, "t0k"), vim.json.decode(table.concat(vim.fn.readfile(path), "\n")))
  settings.remove(path)
  assert.is_nil(vim.uv.fs_stat(path))
end)
it("reports an unwritable run directory", function()
  -- stub vim.fn.stdpath to return "/nonexistent/run"; settings.write returns nil and an error string
end)
-- compat_spec.lua:
it("gates hooks on the CLI version, once per binary", function()
  -- stub compat.cli_version: "2.1.317" -> true, nil; called twice -> stub called once
  -- "2.1.296" -> false, "Claude Code 2.1.296 is older than 2.1.301, the first with the hooks this plugin uses"
  -- nil -> false, "the Claude Code version could not be read"
end)
```

- [ ] **Step 2: Run both spec files.** Expected: the new specs FAIL.
- [ ] **Step 3: Implement.** Update `compat.lua`'s header comment so it says what is scraped now: the status line, plus the fallback.
- [ ] **Step 4: Run them again.** Expected: PASS.
- [ ] **Step 5: Commit.** Subject: `Write the hook settings and gate them on the CLI version`.

### Task 8: Attention rules

**Files:**
- Create: `lua/floating-claude/attention.lua`
- Test: `tests/attention_spec.lua`

**Interfaces:**
- Produces: `attention.decide(where: "float"|"corner"|"hidden", effect: Effect|nil, opts: { restore_on_input, show_hidden }, diff_visible: boolean) -> "restore_now"|"restore_later"|"show_now"|"show_later"|"cancel"|nil`. It is pure.

- [ ] **Step 1: Write the failing tests.** Make it table-driven over the spec's matrix:

```lua
local cases = {
  -- where,   setting,   request,         finished
  { "corner", "idle",    "restore_now",   "restore_later" },
  { "corner", "request", "restore_now",   nil },
  { "corner", false,     nil,             nil },
  { "hidden", "request", "show_now",      nil },
  { "hidden", "idle",    "show_now",      "show_later" },
  { "hidden", false,     nil,             nil },
}
-- for each: decide(where, "request", opts, false) == col 3; decide(where, "finished", opts, false) == col 4
-- (opts.restore_on_input = setting for corner rows, opts.show_hidden = setting for hidden rows)
it("never acts while a diff is visible", function() --[[request and finished -> nil for both wheres]] end)
it("cancels on activity anywhere", function() --[[decide(w, "activity", ...) == "cancel" for float, corner, hidden]] end)
it("leaves the float alone", function() --[[decide("float", "request"|"finished", ...) == nil]] end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/attention_spec.lua`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it again.** Expected: PASS.
- [ ] **Step 5: Commit.** Subject: `Decide when Claude may interrupt you`.

### Task 9: The session

**Files:**
- Create: `lua/floating-claude/hooks/session.lua`
- Modify: `lua/floating-claude/state.lua`
- Test: `tests/hooks_session_spec.lua`

**Interfaces:**
- Consumes: `listener`, `settings`, `reducer`, `record`, `attention`, `compat.hooks_ready`, `parser.status`, `parser.diff_visible`, `config`.
- Produces:
  - In `state.lua`: `state.subscribe(fn: fun(mode))` and `state.changed()`. `changed()` calls each subscriber with `state.mode()` when that differs from the mode last announced.
  - `session.prepare(args: string[], cmd_string: string) -> string[]`.
  - `session.active() -> boolean` and `session.reason() -> string|nil`.
  - `session.attach(handlers: { restore: fun(), show: fun(), fallback: fun() })`.
  - `session.state() -> State`.
  - `session.on_change(fn: fun())`: notification re-renders through this.
  - `session.inject(rec: Record)`: the live-record path, for the tour and the specs.
  - `session.receive_ring(records: Record[], received: integer)`: the `on_ring` handler, public for the specs.
  - `session.mode_changed(mode)`: the `state.subscribe` handler.
  - `session.tick(status: table)`: the safety net.
  - `session.start_scripted()`: active without a listener.
  - `session.stop()`.
  - `session.info() -> { active: boolean, reason: string|nil, port: integer|nil, settings_path: string|nil, events: string[], keep: integer }`.
  - `session.log(cb: fun(log: Log|nil))`.

**Behaviour the specs pin:**
- **`prepare` reasons, verbatim:**
  - `"hooks = false in setup()"`;
  - the compat reason;
  - `"the claude command already passes --settings"`, when `cmd_string` contains `--settings`;
  - `"the listener could not start: " .. err`;
  - `"the settings file could not be written: " .. err`.

  On success, it returns `args` plus `"--settings", path`.
- **Live records:**
  1. Apply them to the reducer, then call the `on_change` subscribers.
  2. Run `attention.decide(state.mode(), effect, config.options.auto, parser.diff_visible())`.
  3. Act on the result:
     - `*_now`: call the handler;
     - `*_later`: a one-shot `restore_idle_ms` timer re-checks the mode and the diff, then acts;
     - `cancel`: stop that timer.
- **`receive_ring`:**
  1. Reset the reducer, apply all records with no effects, and remember `received`.
  2. Settle. If `parser.status().working`, the phase is working. Else, if the phase is working, it becomes idle. Else, if the phase is request, the mode before this one was float, and `request_at >= float_opened_at`, it becomes idle. A settle never triggers attention.
  3. Liveness: `received == 0` while `parser.status().working` → `fallback("no hook events arrived although Claude is working")`. That calls `handlers.fallback()` and makes `active()` false. The listener keeps running.
- **`tick(status)`:**
  - `status.working` sets `saw_live = true` and `live_at = now`.
  - Otherwise, when `saw_live`, the phase is working, `now - last_event_at >= 1000` and `now - live_at >= 1000`, the phase becomes idle, silently.
  - The net is suspended while `state.compacting`: the compaction screen is unverified, so the net never trusts it.
  - `now` comes from `record.now_ms`. The specs stub it.
- **`mode_changed(mode)`:** forwards to `listener.set_mode`, and records `float_opened_at` on entering float.
- **`stop()`:** stops the listener, removes the settings file, stops the timer and resets everything.

- [ ] **Step 1: Write the failing tests.** Stub `compat.hooks_ready` to return true. Fake handlers count their calls. Corner mode needs a real `state.mini_win` (a small float) plus `state.changed()`.

```lua
it("prepare appends --settings and a private file", function()
  local args = session.prepare({ "claude" }, "claude")
  assert.equals("--settings", args[2]); assert.truthy(vim.uv.fs_stat(args[3])); assert.is_true(session.active())
end)
it("leaves a command with its own --settings alone", function() -- Review Focus 2
  assert.same({ "claude", "--settings", "x.json" }, session.prepare({ "claude", "--settings", "x.json" }, "claude --settings x.json"))
  assert.equals("the claude command already passes --settings", session.reason())
end)
it("honours hooks = false", function() --[[reason "hooks = false in setup()", args untouched]] end)
it("gives a restarted Claude a fresh port, token and file", function() -- Review Focus 1
  -- prepare -> info1; stop -> info1.settings_path gone; prepare -> port and path differ
end)
it("brings the float back on a request at once, and on a finished turn after the debounce", function()
  -- restore_idle_ms = 50; start_scripted; corner mode
  -- inject PermissionRequest -> restore called 1x immediately
  -- inject Stop -> 0 calls at 20ms, 1 call by 200ms
end)
it("does not restore when a new turn starts inside the debounce", function()
  -- inject Stop, then UserPromptSubmit at 10ms -> no restore by 200ms
end)
it("never restores from a ring replay", function()
  -- corner mode; receive_ring({ Stop record }, 1) -> restore not called
end)
it("settles an interrupted turn to idle without restoring", function()
  -- inject UPS in float; terminal buffer with no live status line; enter corner + receive_ring({UPS}, 1)
  -- -> phase idle, restore not called
end)
it("leaves a compacting turn alone", function()
  -- saw_live; inject PreCompact; tick({working=false}) at +5000ms -> still working
end)
it("trusts a missing status line only after seeing one", function()
  -- phase working; tick({working=false}) at +5000ms -> still working
  -- tick({working=true}) at t; tick({working=false}) at t+1000 with last_event_at <= t -> idle
end)
it("falls back when Claude works but nothing arrived", function()
  -- receive_ring({}, 0) with a WORKING terminal buffer -> fallback called once, active() false,
  -- reason "no hook events arrived although Claude is working"
end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/hooks_session_spec.lua`.** Expected: FAIL.
- [ ] **Step 3: Implement `session.lua`, and `state.subscribe` and `state.changed`.**
- [ ] **Step 4: Run it again.** Expected: PASS. Then run `make test`: everything green.
- [ ] **Step 5: Commit.** Subject: `Wire the listener, the reducer and the attention rules together`.

### Task 10: The corner renders from the session

**Files:**
- Modify: `lua/floating-claude/notification.lua`, `lua/floating-claude/highlights.lua`
- Test: `tests/notification_spec.lua`

**Interfaces:**
- Consumes: `session.active`, `session.state`, `session.on_change`, `session.tick`, `parser.status`, `parser.first_sentence`.
- Produces:
  - `notification.refresh()`: re-render if visible, and start or stop the timer by the policy below.
  - The highlight group `FloatingClaudeError = "DiagnosticError"`.

**Rendering when `session.active()`:**
- **Entries:**
  - echo: `{ text = "❯ " .. t, kind = "echo" }`;
  - tool: `{ text = "⎿ " .. t, kind = "tool", marker = #"⎿" }`;
  - prose: `{ text = t, kind = "prose" }`;
  - error: `{ text = t, kind = "error" }`, painted whole in `FloatingClaudeError`.

  With `body = "sentence"`, apply `first_sentence` with today's `…` rule. Never call `parser.status_lines()`. When `state.body` is nil (a fresh or resumed session), show no body, only the waiting line.
- **Title:**
  - Working: `parser.status()` when it has a live line. Otherwise `✻ Working` plus elapsed time since `state.started`, formatted `Ns`, `Nm Ns` or `Nh Nm`.
  - Idle or request: the plain title.
- **Waiting line:**
  - Idle: `❯ Waiting for you`, plus `" · " .. done` when `parser.status().done` exists. Read it once per `Stop`, cached on `state.last_event_at`.
  - Request: `❯ Waiting for you`, with no marker.
- **Timer policy:** only while the phase is working. Each tick renders and calls `session.tick(status)`. Without an active session, the timer works exactly as today.
- **Wiring:** subscribe `refresh` with `session.on_change` once, at module load.

- [ ] **Step 1: Write the failing tests.** Use `session.start_scripted()` and `session.inject`, plus a terminal buffer as in the existing helpers.

```lua
it("echoes the prompt until Claude answers", function() --[[inject UPS "Run the suite"; body {" ❯ Run the suite"}, FloatingClaudePrompt]] end)
it("shows a running tool behind ⎿", function() --[[inject PreToolUse Bash description "List files"; body " ⎿ List files"]] end)
it("shows the opening sentence of a streamed paragraph", function() --[[MessageDisplay delta "One. Two." -> " One…"]] end)
it("shows a request with the waiting line and the plain title", function() --[[PermissionRequest AskUserQuestion]] end)
it("paints a failed turn in FloatingClaudeError", function() end)
it("runs no timer once Claude is idle", function() --[[after Stop: state.mini_timer == nil]] end)
it("titles from the live status line", function() --[[WORKING buffer -> title contains "Infusing… 8m 24s ↓24.8k"]] end)
it("titles from its own clock before the status line appears", function() --[[IDLE buffer, phase working, started 65s ago -> "✻ Working 1m 5s"]] end)
it("never shows scraped text on the hooks path", function()
  -- terminal buffer full of box lines and a /diff panel; inject MessageDisplay "Clean words."
  -- body is exactly {" Clean words."} and the waiting line, nothing else
end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/notification_spec.lua`.** Expected: the new specs FAIL and the old ones PASS.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it again, then run `make test`.** Expected: all PASS.
- [ ] **Step 5: Commit.** Subject: `Render the corner from Claude's events`.

### Task 11: Diff detection without the poll

**Files:**
- Modify: `lua/floating-claude/watcher.lua`
- Test: `tests/watcher_spec.lua`

**Interfaces:**
- Produces:
  - `watcher.diff_step(handlers)`: the diff half of today's poll body, with unchanged semantics.
  - `watcher.start(handlers)`: the fallback. The poll runs `diff_step` plus today's idle logic.
  - `watcher.start_diffs(handlers)`: for hooks mode.
  - `watcher.stop()`: stops both kinds.

**How `start_diffs` works:**
- It sets up `BufWinEnter`, `BufWinLeave`, `WinClosed` and `TabClosed` autocmds in the augroup `"FloatingClaudeDiffs"`. Each one `vim.schedule`s `diff_step`.
- It subscribes to `state.subscribe`. Every mode change re-arms one one-shot timer of `watch_ms`. When that timer fires with no diff visible, it stores `state.last_mode = state.mode()`.
- This reproduces the poll's lag: a float minimized by the diff's own `:tabnew` still counts as float.
- There is no repeating timer.

- [ ] **Step 1: Write the failing tests.**
  - Parametrize the existing `"once a diff closes"` and diff-minimize describes over `{ "poll", "events" }`, using `watcher.start` and `watcher.start_diffs` respectively.
  - Add:

```lua
it("keeps no repeating timer in hooks mode", function() --[[start_diffs; state.watch_timer == nil]] end)
it("still counts a float the diff's own tab minimized as float", function()
  -- float open; minimize (as WinLeave would) then within watch_ms open a "(proposed)" buffer in a new tab
  -- -> state.before_diff == "float"
end)
```

  The idle-restore specs stay poll-only: that behaviour belongs to the fallback now.
- [ ] **Step 2: Run `make test-file FILE=tests/watcher_spec.lua`.** Expected: the `events` variants and the new specs FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it again, then run `make test`.** Expected: all PASS.
- [ ] **Step 5: Commit.** Subject: `Watch for diffs through window events instead of a poll`.

### Task 12: Spawning Claude with the listener

**Files:**
- Modify: `lua/floating-claude/terminal.lua`, `lua/floating-claude/notification.lua`
- Test: `tests/hooks_spawn_spec.lua`

**Interfaces:**
- Consumes: `session.prepare`, `session.attach`, `session.active`, `session.stop`, `watcher.start`, `watcher.start_diffs`, `state.changed`.

**Changes:**
- `spawn()`: set `cmd_arg = session.prepare(cmd_arg, cmd_string)` right before `jobstart`. After a successful start:
  - when `session.active()`: `session.attach({ restore = M.restore, show = notification.show, fallback = function() watcher.start(handlers) end })` and `watcher.start_diffs(handlers)`;
  - otherwise: `watcher.start(handlers)`.
- `on_exit` and `close()` call `session.stop()` next to `watcher.stop()`.
- Every window move ends with `state.changed()`: `open_window`, `hide_window`, `minimize`, `restore`, `hide`, `notification.show` and `notification.hide`.

- [ ] **Step 1: Write the failing tests.**
  - Stub `compat.hooks_ready` to return true.
  - Write a script to `vim.fn.tempname()`: `#!/bin/sh` + `printf '%s\n' "$@" > "$ARGV_OUT"; sleep 30`, with `chmod +x`.
  - Spawn with that path as `cmd_string`, and `env = { ARGV_OUT = out }`.

```lua
it("passes --settings <file> to Claude", function() --[[argv file lines[1] == "--settings", lines[2] exists]] end)
it("removes the file and closes the port when Claude exits", function() --[[jobstop; wait on_exit; fs_stat nil; post.sync code 0]] end)
it("passes the command untouched on the fallback", function() --[[hooks = false -> argv file empty]] end)
it("tells the listener when Claude is minimized", function() --[[spawn; minimize; a state.subscribe spy saw "corner"]] end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/hooks_spawn_spec.lua`.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it again, then run `make test`.** Expected: all PASS.
- [ ] **Step 5: Commit, then do the push-and-point step (Global Constraints).** Subject: `Start the listener with Claude`. From here on, Heber can drive the real thing.

### Task 13: The events view, its command and key, and the health check

**Files:**
- Create: `lua/floating-claude/events_view.lua`
- Modify: `lua/floating-claude/init.lua`, `plugin/floating-claude.lua`, `lua/floating-claude/keymaps.lua`, `lua/floating-claude/health.lua`
- Test: `tests/events_view_spec.lua`

**Interfaces:**
- Consumes: `session.info`, `session.log`, `state.buf_valid`.
- Produces:
  - `events_view.lines(info, log|nil) -> string[]`, which is pure.
  - `events_view.pretty(value, indent: string) -> string[]`: JSON-like output with sorted keys.
  - `events_view.open()`.
  - `require("floating-claude").events()`.
  - The `:FloatingClaudeEvents` command.
  - `keymaps.events`: same rule as `hide`, never set over an existing mapping. Both `lhs` values are tracked for re-apply.

**Exact copy:**
- **Line 1, always:** `Floating Claude — what the plugin heard from Claude Code`, then a blank line.
- **Hooks mode:**
  - `Listening on 127.0.0.1:<port> for: <events joined with ", ">`
  - `Settings file: <path> (it holds this session's token; the token is not shown here)`
  - `Kept in memory only: the last <keep> events, long values cut. Nothing else is written to disk, nothing leaves this machine, and it is all cleared when Claude exits.`
  - With keep = 0, the line above becomes: `Kept in memory only: nothing (keep = 0); only the counts below.`
  - `Received <received>, rejected <rejected>.`
- **Fallback:** `Not listening: <reason>. The plugin reads Claude's screen instead.`
- **Not running:** `Claude Code is not running.`
- **Each entry:** a blank line, then `<HH:MM:SS.mmm>  <event>  <fate>  <size> bytes`, then `pretty(payload, "  ")`.
- **A rejected entry:** `<time>  rejected  wrong or missing token  <size> bytes`, with no payload.
- **The buffer:** opened with `tabnew`, named `floating-claude://events`, with `buftype=nofile`, `bufhidden=wipe` and `modifiable=false`. `q` closes it, and the cursor starts on the last line.

**The `:checkhealth` section "hooks":**
- ok: `reading Claude through its hooks on 127.0.0.1:<port>; <n> events received (:FloatingClaudeEvents shows them)`;
- warn: `reading Claude's screen: <reason>`;
- info: `Claude Code is not running`.

- [ ] **Step 1: Write the failing tests**

```lua
it("states what is heard and never prints the token", function()
  local info = { active = true, port = 41234, settings_path = "/run/fc-1.json", events = record.SUBSCRIBED, keep = 50 }
  local text = table.concat(events_view.lines(info, { received = 3, rejected = 1, entries = {} }), "\n")
  assert.truthy(text:find("Listening on 127.0.0.1:41234 for: UserPromptSubmit, PreToolUse", 1, true))
  assert.truthy(text:find("Received 3, rejected 1.", 1, true))
  assert.falsy(text:find("t0k", 1, true)) -- the token the session used
end)
it("says why it is not listening", function() --[[active=false, reason "hooks = false in setup()"]] end)
it("shows a cut value with its byte count", function() --[[payload.prompt "…… [1000 bytes more]" appears]] end)
it("lists a rejected request without a body", function() end)
it("says it keeps nothing with keep = 0", function() end)
it("pretty-prints with sorted keys", function()
  assert.same({ "{", '  "a": 1,', '  "b": {', '    "c": "x"', "  }", "}" }, events_view.pretty({ b = { c = "x" }, a = 1 }, "  "))
end)
it("opens a read-only buffer that q closes", function() end)
it("maps <leader>ae unless the key is taken", function() end)
```

- [ ] **Step 2: Run `make test-file FILE=tests/events_view_spec.lua`.** Expected: FAIL.
- [ ] **Step 3: Implement**, including the health section.
- [ ] **Step 4: Run it again, then run `make test`.** Expected: all PASS. Then run `nvim --headless -c 'checkhealth floating-claude' -c 'w! /dev/stdout' -c qa` with the plugin on the runtimepath. Expected: the "hooks" section is present.
- [ ] **Step 5: Commit, then push and point.** Subject: `Show what the plugin heard from Claude`.

### Task 14: The tour speaks hooks

**Files:**
- Modify: `lua/floating-claude/demo/init.lua`, `lua/floating-claude/demo/tui.lua`
- Test: `tests/demo_spec.lua`

**Interfaces:**
- Consumes: `session.start_scripted`, `session.inject`, `session.stop`.

**Changes:**
- Tour `start` calls `session.start_scripted()`, and tour `stop` calls `session.stop()`.
- Next to its screen change, each `tui` function also injects records:
  - `prompt(t)`: `UserPromptSubmit{prompt=t}`;
  - `say(t)`: `MessageDisplay{delta=t}`;
  - `tool(header, result)`: `PreToolUse{tool_name="Bash", tool_input={description=header}}`, then `PostToolUse` of the same;
  - `finish(spent, summary)`: `Stop{message=summary}`.
- `working()` and `frame()` stay as they are: the status line still titles the corner.
- Any caption that claims the corner reads the screen is updated to say it hears Claude's events.

- [ ] **Step 1: Write the failing test.** `it("takes the corner's words from its scripted events")`: run the tour to its first corner beat. Assert `session.active()`, and that the body equals the injected message's first sentence.
- [ ] **Step 2: Run `make test-file FILE=tests/demo_spec.lua`.** Expected: the new spec FAILS and the old ones PASS.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it again, then run `make test`.** Expected: all PASS.
- [ ] **Step 5: Commit, then push and point.** Subject: `Drive the tour through the hooks path`.

### Task 15: Docs, the performance check, and the manual pass

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, and the header comments of `lua/floating-claude/parser.lua` and `lua/floating-claude/compat.lua`

**Steps:**

- [ ] **Step 1: README.**
  - Under "How the auto-minimize works", add "How it reads Claude": hooks, the listener thread, the fallback and when it applies, and the safety net.
  - In "Configuration": `hooks`, `auto.show_hidden`, the values of `auto.restore_on_input`, and `keymaps.events`.
  - In "Commands and API": `:FloatingClaudeEvents` and `events()`.
  - In "Compatibility": hooks need Claude Code 2.1.301 or newer; older CLIs get screen reading.
  - Add a new section, "Privacy and security":
    - the localhost listener and its token;
    - the settings file;
    - the honest list of what Claude's hooks carry: prompts, replies, tool inputs, tool output;
    - that nothing is written beyond the settings file and nothing leaves the machine;
    - `<leader>ae` to look, and `hooks = { keep = 0 }` to keep nothing.
- [ ] **Step 2: CHANGELOG `[Unreleased]`.**
  - Added: the hooks listener; the events view (`:FloatingClaudeEvents`, `<leader>ae`); `auto.show_hidden`.
  - Changed: a hidden Claude now comes back only when it asks you for something (it used to come back on a finished turn too, which `show_hidden = "idle"` restores); `auto.restore_on_input` takes `"idle"`, `"request"` or `false`; the corner's body comes from Claude's events; diff detection no longer polls.
- [ ] **Step 3: The `parser.lua` header** says it now serves the title's status line, the safety net, the diff predicates, and the whole fallback.
- [ ] **Step 4: Performance check in Heber's Neovim.** He is on the branch after `:Lazy sync`. Over the RPC socket (`nvim --server $NVIM --remote-expr`), with Claude maximized and the hooks path active, assert `state.watch_timer == nil` and `state.mini_timer == nil`. Then minimize during a turn and benchmark one `render()` with the method from memory, section 1. Expected: no timers while maximized, and a working render well under today's ~150µs.
- [ ] **Step 5: Manual pass, with Heber driving.** Work through each of these and note anything odd. The RPC dump method is for capturing it.
  - a prompt;
  - a tool;
  - a Bash permission;
  - an AskUserQuestion;
  - a plan approval and a decline;
  - Esc mid-reply, then minimize;
  - `/clear`;
  - the `/diff` panel;
  - a background task;
  - hide with each `show_hidden` value;
  - `<leader>ae`;
  - `hooks = false`.
- [ ] **Step 6: `make lint && make test`.** Expected: all green, with the full output pasted.
- [ ] **Step 7: Commit, then push and point.** Subject: `Document reading Claude through hooks`.
