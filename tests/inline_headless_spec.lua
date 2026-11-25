-- The headless inline request: how a reply is read (reply.parse), what is sent
-- (reply.prompt) and the claude -p process that carries it (process.start).
-- tests/fixtures/fake_claude.lua stands in for claude; its script is passed in
-- the FAKE_CLAUDE environment variable (see the top of that file).

local process = require("floating-claude.inline.headless.process")
local reply = require("floating-claude.inline.headless.reply")

describe("inline headless reply", function()
  describe("parse", function()
    it("reads EDIT as an edit, with what follows as its body", function()
      assert.same({ kind = "edit", body = "foo" }, reply.parse("EDIT\nfoo"))
      assert.same({ kind = "edit", body = "a\n  b" }, reply.parse("EDIT\na\n  b"))
      assert.same({ kind = "edit", body = "foo" }, reply.parse("EDIT\r\nfoo"))
      assert.same({ kind = "edit", body = "  foo" }, reply.parse("EDIT \n  foo"))
    end)

    it("reads ANSWER as an answer, with what follows as its body", function()
      assert.same({ kind = "answer", body = "It adds." }, reply.parse("ANSWER\nIt adds."))
    end)

    it("is pending until the first word is complete", function()
      for _, text in ipairs({ "", "  \n", "E", "ED", "EDIT", "A", "ANSWE", "ANSWER", "\nEDIT" }) do
        assert.same({ kind = "pending", body = "" }, reply.parse(text), vim.inspect(text))
      end
    end)

    it("is an edit, with nothing yet, as soon as the line break after EDIT is in", function()
      assert.same({ kind = "edit", body = "" }, reply.parse("EDIT\n"))
      assert.same({ kind = "edit", body = "" }, reply.parse("EDIT "))
    end)

    it("takes an untagged reply for an answer, whole", function()
      assert.same({ kind = "answer", body = "Hello" }, reply.parse("Hello"))
      assert.same({ kind = "answer", body = "Hello there" }, reply.parse("Hello there"))
      assert.same({ kind = "answer", body = "The EDIT\nis" }, reply.parse("The EDIT\nis"))
    end)

    it("takes only the exact words as tags", function()
      assert.equals("answer", reply.parse("EDITING the file").kind)
      assert.equals("answer", reply.parse("EDITING").kind)
      assert.equals("answer", reply.parse("EDIT: foo").kind)
      assert.equals("answer", reply.parse("edit\nfoo").kind)
      assert.equals("answer", reply.parse("EDITOR").kind)
    end)

    it("follows a reply as it grows, a piece at a time", function()
      local text, seen = "", {}
      for _, piece in ipairs({ "ED", "IT", "\n", "fo", "o\nb", "ar" }) do
        text = text .. piece
        local parsed = reply.parse(text)
        seen[#seen + 1] = parsed.kind .. ":" .. parsed.body
      end
      assert.same({
        "pending:",
        "pending:",
        "edit:",
        "edit:fo",
        "edit:foo\nb",
        "edit:foo\nbar",
      }, seen)
    end)

    describe("a fenced edit", function()
      it("is unfenced", function()
        assert.same({ kind = "edit", body = "foo\nbar" }, reply.parse("EDIT\n```\nfoo\nbar\n```"))
        assert.same(
          { kind = "edit", body = "foo\nbar" },
          reply.parse("EDIT\n```lua\nfoo\nbar\n```")
        )
        assert.same({ kind = "edit", body = "foo" }, reply.parse("EDIT\n```lua\nfoo\n```\n"))
      end)

      it("keeps the code's own blank lines and indentation", function()
        assert.equals("  a\n\n  b", reply.parse("EDIT\n```\n  a\n\n  b\n```").body)
      end)

      it("shows nothing of the fence while it is still arriving", function()
        assert.equals("", reply.parse("EDIT\n``").body)
        assert.equals("", reply.parse("EDIT\n```lu").body)
        assert.equals("", reply.parse("EDIT\n```lua\n").body)
        assert.equals("foo", reply.parse("EDIT\n```lua\nfoo").body)
        assert.equals("foo\n", reply.parse("EDIT\n```lua\nfoo\n").body)
        assert.equals("foo", reply.parse("EDIT\n```lua\nfoo\n`").body)
        assert.equals("foo", reply.parse("EDIT\n```lua\nfoo\n``").body)
        assert.equals("", reply.parse("EDIT\n```lua\n```").body)
      end)

      it("leaves a fence in the middle of the code alone", function()
        assert.equals("a\n```\nb", reply.parse("EDIT\na\n```\nb").body)
        assert.equals("a```", reply.parse("EDIT\na```").body)
      end)

      it("leaves an unfenced edit alone", function()
        assert.equals("foo\nbar\n", reply.parse("EDIT\nfoo\nbar\n").body)
      end)
    end)
  end)

  describe("prompt", function()
    local ctx = {
      file = "lua/foo.lua",
      filetype = "lua",
      line1 = 10,
      line2 = 11,
      lines = { "local a = 1", "  return a" },
      before = { "-- before", "function f()" },
      after = { "end" },
      diagnostics = { "11:3 error: unexpected symbol" },
      instruction = "rename a to count",
    }

    it("says the file, the range, the selection, its surroundings and the ask", function()
      assert.equals(
        table.concat({
          "File: lua/foo.lua",
          "Filetype: lua",
          "Selection: lines 10-11",
          "",
          "<selection>",
          "local a = 1",
          "  return a",
          "</selection>",
          "",
          "The lines around it, for context only:",
          "<context>",
          "-- before",
          "function f()",
          "[the selection goes here]",
          "end",
          "</context>",
          "",
          "Diagnostics in the selection:",
          "- 11:3 error: unexpected symbol",
          "",
          "Instruction:",
          "rename a to count",
        }, "\n"),
        reply.prompt(ctx)
      )
    end)

    it("leaves out the context and the diagnostics when there are none", function()
      local text =
        reply.prompt(vim.tbl_extend("force", ctx, { before = {}, after = {}, diagnostics = {} }))
      assert.is_nil(text:find("<context>", 1, true))
      assert.is_nil(text:find("Diagnostics", 1, true))
      assert.truthy(text:find("<selection>\nlocal a = 1\n  return a\n</selection>", 1, true))
      assert.truthy(text:find("Instruction:\nrename a to count", 1, true))
    end)

    it("keeps the context when only one side of it has lines", function()
      local text = reply.prompt(vim.tbl_extend("force", ctx, { before = {} }))
      assert.truthy(text:find("<context>\n[the selection goes here]\nend\n</context>", 1, true))
    end)

    it("names a file without a filetype", function()
      local text = reply.prompt(vim.tbl_extend("force", ctx, { filetype = "" }))
      assert.truthy(text:find("Filetype: none", 1, true))
    end)
  end)

  describe("SYSTEM", function()
    it("sets out the two words, a bare edit and no tools", function()
      assert.truthy(reply.SYSTEM:find("EDIT", 1, true))
      assert.truthy(reply.SYSTEM:find("ANSWER", 1, true))
      assert.truthy(reply.SYSTEM:find("Do not use tools", 1, true))
      assert.truthy(reply.SYSTEM:find("no prose before or after", 1, true))
      assert.truthy(reply.SYSTEM:find("no code fences", 1, true))
    end)
  end)
end)

describe("inline headless process", function()
  local FIXTURE = vim.fn.fnamemodify("tests/fixtures/fake_claude.lua", ":p")
  local FAKE = { vim.v.progpath, "-l", FIXTURE }
  local record_file

  before_each(function()
    record_file = vim.fn.tempname()
  end)

  after_each(function()
    vim.fn.setenv("FAKE_CLAUDE", vim.NIL)
    vim.fn.delete(record_file)
  end)

  --- Start the fake with `script` and wait for it to end one way or the other.
  --- What the callbacks saw is in the returned table.
  ---@return table seen, { stop: fun() } handle
  local function run(script, opts)
    opts = opts or {}
    script.record = record_file
    vim.fn.setenv("FAKE_CLAUDE", vim.json.encode(script))
    local seen = { deltas = {}, order = {}, fast = false }
    local handle
    local function note(what)
      seen.order[#seen.order + 1] = what
      if vim.in_fast_event() then
        seen.fast = true
      end
    end
    handle = process.start({
      cmd = opts.cmd or FAKE,
      model = opts.model or false,
      system = "the system prompt",
      prompt = opts.prompt or "the prompt",
      on_delta = function(text)
        note("delta")
        seen.deltas[#seen.deltas + 1] = text
        if opts.on_delta then
          opts.on_delta(text, handle)
        end
      end,
      on_done = function()
        note("done")
        seen.done = (seen.done or 0) + 1
      end,
      on_error = function(msg)
        note("error")
        seen.errors = seen.errors or {}
        seen.errors[#seen.errors + 1] = msg
      end,
    })
    if not opts.no_wait then
      assert.is_true(
        vim.wait(5000, function()
          return seen.done ~= nil or seen.errors ~= nil
        end),
        "neither on_done nor on_error was called"
      )
    end
    return seen, handle
  end

  local function recorded()
    assert.is_true(vim.wait(3000, function()
      return vim.uv.fs_stat(record_file) ~= nil
    end))
    return vim.json.decode(table.concat(vim.fn.readfile(record_file), "\n"))
  end

  it("calls on_delta for each text delta in order, then on_done", function()
    local seen = run({ events = { "EDIT\n", "new ", "line" } })
    assert.same({ "EDIT\n", "new ", "line" }, seen.deltas)
    assert.equals(1, seen.done)
    assert.is_nil(seen.errors)
    assert.same({ "delta", "delta", "delta", "done" }, seen.order)
  end)

  it("calls back on the main loop", function()
    local seen = run({ events = { "a", "b" } })
    assert.is_false(seen.fast)
  end)

  it("ignores everything but text deltas and the result", function()
    local seen = run({
      events = {
        { type = "stream_event", event = { type = "message_start" } },
        {
          type = "stream_event",
          event = {
            type = "content_block_delta",
            delta = { type = "thinking_delta", thinking = "hm" },
          },
        },
        {
          type = "stream_event",
          event = { type = "content_block_delta", delta = { type = "input_json_delta" } },
        },
        "kept",
        { type = "assistant", message = { content = { { type = "text", text = "kept" } } } },
        { type = "user", message = {} },
      },
    })
    assert.same({ "kept" }, seen.deltas)
    assert.equals(1, seen.done)
  end)

  it("puts together a line that arrives in two pieces", function()
    local seen = run({ events = { "EDIT\n", "whole" }, split = true })
    assert.same({ "EDIT\n", "whole" }, seen.deltas)
    assert.equals(1, seen.done)
  end)

  it("sends the prompt as one stream-json line and closes stdin", function()
    -- The fake reads stdin to its end before it answers, so getting here
    -- means stdin was closed.
    run({ events = { "x" } }, { prompt = 'line one\nline two "quoted"' })
    local rec = recorded()
    assert.equals("\n", rec.stdin:sub(-1))
    assert.equals(1, select(2, rec.stdin:gsub("\n", "")))
    assert.same({
      type = "user",
      message = { role = "user", content = 'line one\nline two "quoted"' },
    }, vim.json.decode(rec.stdin))
  end)

  it(
    "starts claude with no tools, MCP, session, settings or slash commands, and the system prompt",
    function()
      run({ events = { "x" } })
      assert.same({
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--tools",
        "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--setting-sources",
        "",
        "--disable-slash-commands",
        "--system-prompt",
        "the system prompt",
      }, recorded().argv)
    end
  )

  it("adds --model when one is set", function()
    run({ events = { "x" } }, { model = "opus" })
    local argv = recorded().argv
    assert.equals("--model", argv[#argv - 1])
    assert.equals("opus", argv[#argv])
  end)

  it("puts its own flags after the ones in cmd", function()
    run({ events = { "x" } }, { cmd = vim.list_extend(vim.list_slice(FAKE), { "--extra", "1" }) })
    local argv = recorded().argv
    assert.same({ "--extra", "1", "-p" }, { unpack(argv, 1, 3) })
  end)

  describe("when it goes wrong", function()
    it("reports the first line of stderr when claude exits non-zero", function()
      local seen = run({ result = false, stderr = "auth failed\nsecond line", exit = 1 })
      assert.same({ "auth failed" }, seen.errors)
      assert.is_nil(seen.done)
    end)

    it("says the exit code when there is nothing on stderr", function()
      local seen = run({ result = false, exit = 2 })
      assert.same({ vim.v.progpath .. " exited with code 2" }, seen.errors)
    end)

    it("is an error when claude ends without a result, too", function()
      local seen = run({ result = false, events = { "half a rep" } })
      assert.same({ "half a rep" }, seen.deltas)
      assert.same({ vim.v.progpath .. " ended without a reply" }, seen.errors)
      assert.is_nil(seen.done)
    end)

    it("reports a result with is_error, once", function()
      local seen = run({
        events = { "x" },
        result = {
          is_error = true,
          subtype = "success",
          result = "Invalid API key\nPlease run /login",
        },
        stderr = "ignored",
        exit = 1,
      })
      -- Let the non-zero exit arrive: it is not a second error.
      vim.wait(300)
      assert.same({ "Invalid API key" }, seen.errors)
      assert.is_nil(seen.done)
    end)

    it("falls back to the subtype for an error result without text", function()
      local seen =
        run({ result = { is_error = true, subtype = "error_during_execution", result = vim.NIL } })
      assert.same({ "error_during_execution" }, seen.errors)
    end)

    it("is over at the result: a later non-zero exit is not an error", function()
      local seen = run({ events = { "x" }, exit = 1, stderr = "noise on the way out" })
      assert.equals(1, seen.done)
      assert.is_nil(seen.errors)
      -- Let the exit arrive.
      vim.wait(300)
      assert.equals(1, seen.done)
      assert.is_nil(seen.errors)
    end)

    it("reports 'cannot run <cmd>' when it cannot start, after start returns", function()
      local seen, handle = run({}, { cmd = { "definitely-not-claude" }, no_wait = true })
      assert.same({}, seen.order, "called back before start returned")
      assert.is_true(vim.wait(3000, function()
        return seen.errors ~= nil
      end))
      assert.same({ "cannot run definitely-not-claude" }, seen.errors)
      assert.is_nil(seen.done)
      -- There is nothing to stop, and stopping it is harmless.
      assert.has_no.errors(function()
        handle.stop()
      end)
    end)
  end)

  describe("stop", function()
    --- Whether a process is gone.
    local function gone(pid)
      return vim.wait(3000, function()
        return not vim.uv.kill(pid, 0)
      end)
    end

    it("ends the process and says nothing more", function()
      local seen, handle = run(
        { events = { "EDIT\n", "x" }, result = false, hang = true },
        { no_wait = true }
      )
      assert.is_true(vim.wait(5000, function()
        return #seen.deltas == 2
      end))
      local pid = recorded().pid
      assert.truthy(vim.uv.kill(pid, 0))
      handle.stop()
      assert.is_true(gone(pid), "the process is still running")
      -- Its exit arrives after stop(); it is not an error.
      vim.wait(300)
      assert.is_nil(seen.done)
      assert.is_nil(seen.errors)
      assert.same({ "delta", "delta" }, seen.order)
    end)

    it("drops what was already on its way", function()
      -- Three deltas and a result, all printed at once: stopping on the first
      -- leaves the rest of them, already read, to be dropped.
      local seen
      seen = run({ events = { "a", "b", "c" } }, {
        no_wait = true,
        on_delta = function(_, handle)
          handle.stop()
        end,
      })
      assert.is_true(vim.wait(5000, function()
        return #seen.deltas >= 1
      end))
      vim.wait(300)
      assert.same({ "a" }, seen.deltas)
      assert.is_nil(seen.done)
      assert.is_nil(seen.errors)
    end)

    it("says nothing for a command that could not start, if stopped before it would", function()
      local seen, handle = run({}, { cmd = { "definitely-not-claude" }, no_wait = true })
      handle.stop()
      vim.wait(300)
      assert.same({}, seen.order)
      assert.is_nil(seen.done)
      assert.is_nil(seen.errors)
    end)

    it("can be called twice, and after the request is over", function()
      local seen, handle = run({ events = { "x" } })
      assert.equals(1, seen.done)
      assert.has_no.errors(function()
        handle.stop()
        handle.stop()
      end)
    end)
  end)
end)
