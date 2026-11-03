-- The words the corner shows, made from what Claude's hooks carry: the newest
-- paragraph of a message with its markdown taken off, a one-line summary of a
-- tool call, the question a request puts to you, and which prompts are not
-- yours at all.

local text = require("floating-claude.hooks.text")

describe("prose", function()
  it("keeps a lone opening sentence", function()
    assert.equals(
      "I'll list the current directory's contents.",
      text.prose("I'll list the current directory's contents.\n\n")
    )
  end)

  it("strips inline code and emphasis", function()
    assert.equals(
      "entries, . and .., so it is bare",
      text.prose("entries, `.` and `..`, so it is **bare**")
    )
  end)

  it("skips fenced code, tables and headings", function()
    assert.equals(
      "Intro.",
      text.prose("Intro.\n\n```lua\nlocal x = 1\n```\n\n| a | b |\n|---|---|\n\n## Next")
    )
  end)

  it("flattens a list and keeps link text", function()
    assert.equals(
      "First item see the docs",
      text.prose("- **First** item\n- see [the docs](https://x.y)")
    )
  end)

  it("takes the newest paragraph", function()
    assert.equals("Second one.", text.prose("First one.\n\nSecond one."))
  end)

  it("has nothing to say about nothing", function()
    assert.is_nil(text.prose(nil))
    assert.is_nil(text.prose("```\ncode only\n```"))
  end)
end)

describe("tool lines", function()
  it("summarise tools", function()
    assert.equals(
      "List files",
      text.tool_line("Bash", { command = "ls", description = "List files" })
    )
    assert.equals("ls -la", text.tool_line("Bash", { command = "ls -la" }))
    assert.equals(
      "Edit notification.lua",
      text.tool_line("Edit", { file_path = "/r/lua/notification.lua" })
    )
    assert.equals("Search is_working", text.tool_line("Grep", { pattern = "is_working" }))
    assert.equals(
      "Fetch code.claude.com",
      text.tool_line("WebFetch", { url = "https://code.claude.com/docs/en/hooks" })
    )
    assert.equals("claude-vscode: openDiff", text.tool_line("mcp__claude-vscode__openDiff", {}))
  end)

  it("stay quiet about plumbing", function()
    assert.is_nil(text.tool_line("ToolSearch", { query = "select:ExitPlanMode" }))
  end)

  -- Their request says what they are about; a raw tool name before or after
  -- it is plumbing in the corner.
  it("stay quiet about questions and plans", function()
    assert.is_nil(text.tool_line("AskUserQuestion", { questions = {} }))
    assert.is_nil(text.tool_line("ExitPlanMode", { plan = "# Plan" }))
  end)
end)

describe("request lines", function()
  it("word requests", function()
    assert.equals(
      "Which color do you prefer?",
      text.request_line(
        "AskUserQuestion",
        { questions = { { question = "Which color do you prefer?" } } }
      )
    )
    assert.equals("Plan ready for review", text.request_line("ExitPlanMode", { plan = "# Plan" }))
    assert.equals(
      'Allow Bash: Write "again" to spike2.txt?',
      text.request_line(
        "Bash",
        { command = "printf again > spike2.txt", description = 'Write "again" to spike2.txt' }
      )
    )
    assert.equals("Allow Edit: b.lua?", text.request_line("Edit", { file_path = "/a/b.lua" }))
    assert.equals("Allow x: y?", text.request_line("mcp__x__y", {}))
  end)
end)

describe("synthetic prompts", function()
  it("are told apart from what you typed", function()
    assert.is_true(text.is_synthetic("<task-notification>\n<task-id>bw686dv5b</task-id>"))
    assert.is_true(text.is_synthetic("  <bash-input>ls</bash-input>"))
    assert.is_false(text.is_synthetic("Write a story"))
    assert.is_false(text.is_synthetic("<div> is broken in the footer"))
    assert.is_false(text.is_synthetic(nil))
  end)
end)
