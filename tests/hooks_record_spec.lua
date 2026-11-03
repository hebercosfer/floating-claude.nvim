-- What the listener keeps of each event Claude posts: only what the reducer
-- reads, nothing from subagents or events it never asked for, long strings cut
-- on a character boundary -- and, per window mode, whether the main loop hears
-- about it at all.

local record = require("floating-claude.hooks.record")

describe("records", function()
  it("drop subagent and unsubscribed events", function()
    assert.is_nil(
      record.compact({ hook_event_name = "PreToolUse", agent_id = "a71d", tool_name = "Bash" }, 1)
    )
    assert.is_nil(record.compact({ hook_event_name = "PostToolBatch", tool_calls = {} }, 1))
    assert.is_nil(
      record.compact(
        { hook_event_name = "Notification", notification_type = "permission_prompt" },
        1
      )
    )
  end)

  it("keep what the reducer reads and nothing else", function()
    local r = record.compact({
      hook_event_name = "Stop",
      last_assistant_message = "Done.",
      background_tasks = {},
      session_id = "s",
      transcript_path = "/t.jsonl",
    }, 7)
    assert.same({ event = "Stop", at = 7, message = "Done." }, r)
  end)

  it("leave a tool's output behind", function()
    local r = record.compact({
      hook_event_name = "PostToolUse",
      tool_name = "Bash",
      tool_input = { command = "ls" },
      tool_response = { stdout = "secret.txt" },
    }, 3)
    assert.same(
      { event = "PostToolUse", at = 3, tool_name = "Bash", tool_input = { command = "ls" } },
      r
    )
  end)

  -- End-of-task summaries routinely run past the cap; the corner wants the
  -- last paragraph, not the first 2000 bytes and a cut marker.
  it("keep the newest paragraph of a long reply", function()
    local paragraphs = {}
    for i = 1, 10 do
      table.insert(paragraphs, ("Paragraph %d says %s."):format(i, string.rep("x", 250)))
    end
    table.insert(paragraphs, "Final: all tests pass now.")
    local long = table.concat(paragraphs, "\n\n")
    local stop = record.compact({ hook_event_name = "Stop", last_assistant_message = long }, 1)
    assert.equals("Final: all tests pass now.", stop.message)
    local shown =
      record.compact({ hook_event_name = "MessageDisplay", delta = long, final = true }, 1)
    assert.equals("Final: all tests pass now.", shown.delta)
  end)

  it("mark synthetic prompts", function()
    local r = record.compact(
      { hook_event_name = "UserPromptSubmit", prompt = "<task-notification>\n…" },
      1
    )
    assert.is_true(r.synthetic)
    assert.is_false(
      record.compact({ hook_event_name = "UserPromptSubmit", prompt = "hi" }, 1).synthetic
    )
  end)

  it("cut long strings on a character boundary", function()
    assert.equals(
      string.rep("é", 1000) .. "… [1000 bytes more]",
      record.cap(string.rep("é", 1500), 2000)
    )
    -- 1 + 3*666 = 1999 bytes kept of 2101
    assert.equals(
      "a" .. string.rep("€", 666) .. "… [102 bytes more]",
      record.cap("a" .. string.rep("€", 700), 2000)
    )
  end)

  it("cut nested strings and leave the original alone", function()
    local input = { tool_input = { content = string.rep("x", 10) }, n = 3 }
    assert.same(
      { tool_input = { content = "xxxx… [6 bytes more]" }, n = 3 },
      record.cap(input, 4)
    )
    assert.equals(string.rep("x", 10), input.tool_input.content)
  end)

  it("gate by window mode", function()
    local req, stop, ups, pre =
      { event = "PermissionRequest" },
      { event = "Stop" },
      { event = "UserPromptSubmit" },
      { event = "PreToolUse" }
    assert.is_false(record.forwarded(req, "float", "request"))
    assert.is_true(record.forwarded(pre, "corner", "request"))
    assert.is_true(record.forwarded(req, "hidden", "request"))
    assert.is_false(record.forwarded(stop, "hidden", "request"))
    assert.is_true(record.forwarded(stop, "hidden", "idle"))
    assert.is_true(record.forwarded(ups, "hidden", "idle"))
    assert.is_false(record.forwarded(pre, "hidden", "idle"))
    assert.is_false(record.forwarded(req, "hidden", false))
  end)

  it("tell the time in epoch milliseconds", function()
    local before = os.time() * 1000
    local now = record.now_ms()
    assert.is_true(now >= before and now < before + 2000)
  end)
end)
