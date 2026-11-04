-- Claude's state as the corner sees it, reduced from hook records: busy,
-- waiting on you, or done -- and the words to show for it. Most of these
-- replay what Claude Code really posted in the 2026-11-03 spike
-- (tests/fixtures/hooks.lua), unsubscribed and subagent events included.

local fixtures = dofile(vim.fn.fnamemodify("tests/fixtures/hooks.lua", ":p"))
local record = require("floating-claude.hooks.record")
local reducer = require("floating-claude.hooks.reducer")

--- Feed a captured sequence through the listener's compaction and the
--- reducer, the way the main loop will. Only non-nil effects are collected.
local function run(seq)
  local state, effects = reducer.new(), {}
  for _, e in ipairs(seq) do
    local r = record.compact(e.event, e.at)
    if r then
      local _, effect = reducer.apply(state, r)
      if effect then
        table.insert(effects, effect)
      end
    end
  end
  return state, effects
end

describe("the reducer", function()
  it("ends a tool-and-prose turn idle on its last paragraph", function()
    local s, fx = run(fixtures.tool_and_prose)
    assert.equals("idle", s.phase)
    assert.equals("prose", s.body.kind)
    assert.truthy(
      vim.startswith(
        s.body.text,
        "The listing is empty apart from the two standard entries, . and .."
      )
    )
    -- The MessageDisplay that trails Stop adds neither an effect nor a phase.
    assert.equals("finished", fx[#fx])
  end)

  it("holds a question as a request until it is answered", function()
    local s, seen = reducer.new(), false
    for _, e in ipairs(fixtures.question) do
      local r = record.compact(e.event, e.at)
      if r then
        reducer.apply(s, r)
        if r.event == "PermissionRequest" then
          seen = true
          assert.same({ "request", "Which color do you prefer?" }, { s.phase, s.body.text })
        end
      end
    end
    assert.is_true(seen)
    assert.same({ "idle", "You prefer red." }, { s.phase, s.body.text })
  end)

  it("is still working after an interrupt, because nothing fires", function()
    local s = run(fixtures.interrupt_mid_reply)
    assert.equals("working", s.phase)
    assert.truthy(vim.startswith(s.body.text, "The lighthouse stood on a finger of black rock"))
  end)

  it("ignores the subagent tail after Stop", function()
    assert.equals("idle", (run(fixtures.background_task)).phase)
  end)

  it("keeps the tool line through a synthetic prompt", function()
    local s, checked = reducer.new(), false
    for _, e in ipairs(fixtures.interrupted_tool) do
      local r = record.compact(e.event, e.at)
      if r then
        reducer.apply(s, r)
        if r.synthetic then
          checked = true
          assert.same({ "working", "tool" }, { s.phase, s.body.kind })
          break
        end
      end
    end
    assert.is_true(checked)
  end)

  it("ends a plan turn waiting on approval, plumbing ignored", function()
    local s = run(fixtures.plan)
    assert.same({ "request", "Plan ready for review" }, { s.phase, s.body.text })
  end)

  it("drops a request's text once the tool runs", function()
    local s = reducer.new()
    for i, e in ipairs(fixtures.permission) do
      reducer.apply(s, record.compact(e.event, e.at))
      if i == 3 then
        assert.equals('Allow Bash: Write "again" to spike2.txt?', s.body.text)
        assert.equals(2030, s.request_at)
      elseif i == 4 then
        assert.same(
          { "working", "tool", 'Write "again" to spike2.txt' },
          { s.phase, s.body.kind, s.body.text }
        )
      end
    end
    assert.same({ "idle", "Done." }, { s.phase, s.body.text })
  end)

  it("clears an answered question rather than naming its tool", function()
    local s = reducer.new()
    local ask = { questions = { { question = "Which color?" } } }
    reducer.apply(
      s,
      { event = "PermissionRequest", at = 1, tool_name = "AskUserQuestion", tool_input = ask }
    )
    reducer.apply(
      s,
      { event = "PostToolUse", at = 2, tool_name = "AskUserQuestion", tool_input = ask }
    )
    assert.same({ "working" }, { s.phase, s.body })
  end)

  -- The corner shows Claude's latest message and, under it, whatever came
  -- after it -- so the two are kept apart.
  it("remembers Claude's latest message across the tool calls after it", function()
    local s = reducer.new()
    reducer.apply(s, { event = "UserPromptSubmit", at = 1, prompt = "Fix it", synthetic = false })
    reducer.apply(
      s,
      { event = "MessageDisplay", at = 2, delta = "I'll check the parser. Then the corner." }
    )
    reducer.apply(
      s,
      { event = "PreToolUse", at = 3, tool_name = "Grep", tool_input = { pattern = "is_working" } }
    )
    assert.same(
      { text = "I'll check the parser. Then the corner.", event = "MessageDisplay" },
      s.message
    )
    assert.same(
      { "tool", "Search is_working", "PreToolUse" },
      { s.body.kind, s.body.text, s.body.event }
    )
  end)

  it("takes the final reply as the latest message", function()
    local s = reducer.new()
    reducer.apply(s, { event = "Stop", at = 1, message = "All done." })
    assert.same({ text = "All done.", event = "Stop" }, s.message)
    assert.equals("Stop", s.body.event)
  end)

  it("starts the message afresh with a prompt you typed, not a synthetic one", function()
    local s = reducer.new()
    reducer.apply(s, { event = "Stop", at = 1, message = "All done." })
    reducer.apply(
      s,
      { event = "UserPromptSubmit", at = 2, prompt = "<task-notification>…", synthetic = true }
    )
    assert.equals("All done.", s.message.text)
    reducer.apply(s, { event = "UserPromptSubmit", at = 3, prompt = "Again", synthetic = false })
    assert.is_nil(s.message)
  end)

  it("reports a failed turn as a request in the error style", function()
    local s, fx = reducer.apply(reducer.new(), {
      event = "StopFailure",
      at = 1,
      error = "rate_limit",
      message = "API Error: Rate limit reached",
    })
    assert.same(
      { "request", "error", "API Error: Rate limit reached", "request" },
      { s.phase, s.body.kind, s.body.text, fx }
    )
  end)

  it("treats an MCP server's question as a request", function()
    local s, fx =
      reducer.apply(reducer.new(), { event = "Elicitation", at = 4, message = "Pick a project" })
    assert.same(
      { "request", "Pick a project", 4, "request" },
      { s.phase, s.body.text, s.request_at, fx }
    )
  end)

  it("starts the clock on every prompt, and reports it as activity", function()
    local s, fx = reducer.apply(
      reducer.new(),
      { event = "UserPromptSubmit", at = 10, prompt = "Go", synthetic = false }
    )
    assert.same({ "working", 10, 10, "echo", "Go", "activity" }, {
      s.phase,
      s.started,
      s.last_event_at,
      s.body.kind,
      s.body.text,
      fx,
    })
  end)

  it("resets on SessionEnd and tracks compaction", function()
    local s = reducer.new()
    reducer.apply(s, { event = "PreCompact", at = 1, trigger = "auto" })
    assert.is_true(s.compacting)
    reducer.apply(s, { event = "PostCompact", at = 2, trigger = "auto" })
    assert.is_false(s.compacting)
    reducer.apply(s, { event = "UserPromptSubmit", at = 3, prompt = "x", synthetic = false })
    reducer.apply(s, { event = "SessionEnd", at = 4, reason = "clear" })
    assert.same(reducer.new(), s)
  end)
end)
