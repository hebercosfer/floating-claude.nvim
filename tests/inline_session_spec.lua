-- Inline mode in session mode, end to end: a request typed into the running
-- Claude, followed through its hook records and the regular look at the screen,
-- and shown as the lines under the code. Claude is a scripted session (records
-- injected as the hooks would deliver them), a `cat` standing in for its job,
-- and the paste, the screen and the clock are the spec's.

local config = require("floating-claude.config")
local inline = require("floating-claude.inline")
local input = require("floating-claude.inline.input")
local lines = require("floating-claude.inline.lines")
local parser = require("floating-claude.parser")
local record = require("floating-claude.hooks.record")
local request = require("floating-claude.inline.request")
local send = require("floating-claude.inline.send")
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")

local DRAFT = "Claude's prompt has a draft · <CR> to open Claude"
local ASKING = "Claude is asking you something · <CR> to open Claude"
local EXITED = "Claude exited · start it with :ClaudeCode"

-- The extmark's row, and what the lines say.
local function shown(buf)
  local found = vim.api.nvim_buf_get_extmarks(buf, lines.ns, 0, -1, { details = true })
  if #found == 0 then
    return nil
  end
  return found[1][2],
    vim.tbl_map(function(chunks)
      return chunks[1][1]
    end, found[1][4].virt_lines)
end

local function texts(buf)
  local _, items = shown(buf)
  return items
end

describe("inline session mode", function()
  local file, buf, claude
  local pasted, notes, opened, submit_text, restored
  local clock, ticks, working, box
  local saved = {}

  local function stub(tbl, name, fn)
    table.insert(saved, { tbl, name, tbl[name] })
    tbl[name] = fn
  end

  local function at(ms)
    clock = ms
  end

  -- Ask about lines 2-4, typing `text` into the input.
  local function ask(text, line1, line2, mode)
    submit_text = text
    inline.ask({ line1 = line1 or 2, line2 = line2 or 4, mode = mode or "session" })
  end

  local function prompt_of(n)
    return pasted[n or 1][2]
  end

  local function submitted(extra)
    return vim.tbl_extend("force", {
      event = "UserPromptSubmit",
      at = clock,
      prompt = prompt_of(),
      synthetic = false,
    }, extra or {})
  end

  local function turn_ahead()
    session.inject({
      event = "UserPromptSubmit",
      at = clock,
      prompt = "something else",
      synthetic = false,
    })
  end

  local function permission()
    session.inject({
      event = "PermissionRequest",
      at = clock,
      tool_name = "Bash",
      tool_input = { command = "rm -rf build" },
    })
  end

  -- Wait for the next look at the screen.
  local function next_tick()
    local seen = ticks
    assert.is_true(vim.wait(2000, function()
      return ticks > seen
    end))
  end

  local function notes_text()
    return vim.tbl_map(function(note)
      return note[1]
    end, notes)
  end

  before_each(function()
    config.setup({})
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    file = dir .. "/net.lua"
    vim.fn.writefile({ "one", "two", "three", "four", "five" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    buf = vim.api.nvim_get_current_buf()

    session.start_scripted()
    claude = vim.api.nvim_create_buf(false, true)
    state.buf = claude
    state.jobid = vim.fn.jobstart({ "cat" })

    pasted, notes, restored, opened = {}, {}, 0, 0
    submit_text, clock, ticks, working, box = nil, 1000, 0, false, ""
    stub(send, "paste", function(job, text)
      table.insert(pasted, { job, text })
    end)
    stub(input, "open", function(opts)
      opened = opened + 1
      if submit_text then
        opts.on_submit(submit_text)
      end
    end)
    stub(parser, "input_draft", function()
      return box
    end)
    stub(parser, "status", function()
      ticks = ticks + 1
      return { working = working }
    end)
    stub(record, "now_ms", function()
      return clock
    end)
    stub(vim, "notify", function(msg, level)
      -- Not the editor's own chatter (an LSP client attaching to the temp file).
      if not msg:find("^Attached to LSP") then
        table.insert(notes, { msg, level })
      end
    end)
    stub(require("floating-claude"), "restore", function()
      restored = restored + 1
    end)
  end)

  after_each(function()
    pcall(inline.clear, buf)
    for i = #saved, 1, -1 do
      local tbl, name, original = unpack(saved[i])
      tbl[name] = original
    end
    saved = {}
    session.stop()
    if state.jobid > 0 then
      vim.fn.jobstop(state.jobid)
    end
    state.buf, state.win, state.jobid = -1, -1, -1
    for _, b in ipairs({ buf, claude }) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    vim.fn.delete(vim.fn.fnamemodify(file, ":h"), "rf")
    config.setup({})
  end)

  describe("refusing", function()
    it("says so, and opens no input, while another request is running", function()
      ask("add a retry")
      assert.equals(1, #pasted)
      notes, opened = {}, 0
      ask("and a timeout")
      assert.same({ { "An inline request is already running", vim.log.levels.WARN } }, notes)
      assert.equals(0, opened)
      assert.equals(1, #pasted)
    end)

    it("says so when Claude is not running", function()
      state.buf = -1
      ask("add a retry")
      assert.same(
        { { "Claude isn't running · start it with :ClaudeCode", vim.log.levels.WARN } },
        notes
      )
      assert.equals(0, opened)
      assert.equals(0, #pasted)
      assert.is_nil(shown(buf))
    end)

    it("says why when Claude is not heard through its hooks", function()
      config.setup({ hooks = false })
      session.prepare({ "claude" }, "claude")
      ask("add a retry")
      assert.same({
        { "Inline mode needs Claude's hooks: hooks = false in setup()", vim.log.levels.WARN },
      }, notes)
      assert.equals(0, opened)
      assert.equals(0, #pasted)
    end)

    it("asks again at the submit, for the input stayed open while things changed", function()
      local on_submit
      stub(input, "open", function(opts)
        on_submit = opts.on_submit
      end)
      ask(nil)
      state.buf = -1
      on_submit("add a retry")
      assert.same({
        { "Claude isn't running · start it with :ClaudeCode", vim.log.levels.WARN },
      }, notes)
      assert.equals(0, #pasted)
    end)

    it("says why, and sends nothing, when the buffer cannot be written", function()
      vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.tempname() .. "/no/such/dir/x.lua"))
      local unwritable = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(unwritable, 0, -1, false, { "a", "b" })
      ask("add a retry", 1, 2)
      assert.equals(1, #notes)
      assert.is_truthy(notes[1][1]:find("^Inline mode couldn't save "))
      assert.is_truthy(notes[1][1]:find("E212", 1, true))
      assert.equals(vim.log.levels.WARN, notes[1][2])
      assert.equals(0, #pasted)
      assert.is_nil(shown(unwritable))
      assert.is_false(session.inline_active())
      -- Nothing is held: the next request is not told one is running.
      vim.cmd("buffer " .. buf)
      vim.api.nvim_buf_delete(unwritable, { force = true })
      notes = {}
      ask("add a retry")
      assert.equals(1, #pasted)
      assert.same({}, notes)
    end)

    it("says so for a buffer that is not a file", function()
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(scratch)
      ask("add a retry", 1, 1)
      assert.same({
        { "Inline mode needs a file: this buffer is not one on disk", vim.log.levels.WARN },
      }, notes)
      assert.equals(0, #pasted)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_delete(scratch, { force = true })
    end)

    it("does not look at Claude for a request that will not go to it", function()
      state.buf = -1
      ask("add a retry", 2, 4, "headless")
      assert.same({}, notes)
      assert.same({ "▸ add a retry" }, texts(buf))
    end)
  end)

  describe("sending", function()
    it("sends at once to an idle session: one paste of the mention and the instruction", function()
      ask("add a retry")
      assert.same({
        { state.jobid, "@" .. vim.fn.fnamemodify(file, ":.") .. "#L2-4 add a retry" },
      }, pasted)
      assert.same({}, notes)
    end)

    it("writes the buffer first, for Claude reads the file", function()
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "TWO" })
      assert.is_true(vim.bo[buf].modified)
      ask("add a retry")
      assert.is_false(vim.bo[buf].modified)
      assert.same({ "one", "TWO", "three", "four", "five" }, vim.fn.readfile(file))
      assert.equals(1, #pasted)
    end)

    it("shows the instruction under the range, from the last row of it", function()
      ask("add a retry")
      local row, items = shown(buf)
      assert.equals(3, row)
      assert.same({ "▸ add a retry" }, items)
      assert.same({ 1, 3 }, { lines.range(buf) })
    end)

    it("takes the place for the request, and keeps the float from coming back for it", function()
      assert.is_false(session.inline_active())
      ask("add a retry")
      assert.is_true(session.inline_active())
    end)

    describe("with when_busy = send", function()
      before_each(function()
        config.setup({ inline = { when_busy = "send" } })
      end)

      it("sends to a working session at once, the box empty", function()
        turn_ahead()
        ask("add a retry")
        assert.equals(1, #pasted)
        assert.same({ "▸ add a retry" }, texts(buf))
        assert.is_true(session.inline_active())
      end)

      it("sends over Claude's suggestion, which nobody typed", function()
        turn_ahead()
        box = "In three words, what is Neovim?"
        ask("add a retry")
        assert.equals(1, #pasted)
      end)

      it("still does not send over a draft you typed, busy or not", function()
        stub(send, "typed", function()
          return true
        end)
        box = "half a thought"
        turn_ahead()
        ask("add a retry")
        assert.equals(0, #pasted)
        assert.same({ "▸ add a retry", DRAFT }, texts(buf))
        assert.is_false(session.inline_active())
      end)

      it("does not send when the box cannot be read: that is not known to be empty", function()
        turn_ahead()
        box = nil
        ask("add a retry")
        assert.equals(0, #pasted)
        assert.same({ "▸ add a retry", DRAFT }, texts(buf))
      end)

      it("still does not answer a question Claude is asking", function()
        permission()
        ask("add a retry")
        assert.equals(0, #pasted)
        assert.same({ "▸ add a retry", ASKING }, texts(buf))
        assert.is_false(session.inline_active())
      end)
    end)

    describe("with something in Claude's input box", function()
      local typed_flag, typed_when, cleared

      before_each(function()
        typed_flag, typed_when, cleared = false, nil, {}
        stub(send, "typed", function()
          return typed_flag
        end)
        stub(send, "typed_at", function()
          return typed_when
        end)
        stub(send, "clear_typed_if_empty", function(draft)
          table.insert(cleared, draft)
        end)
      end)

      it("drops the request, and sends nothing, when it is a draft you typed", function()
        box, typed_flag, typed_when = "half a thought", true, clock - 5000
        ask("add a retry")
        assert.equals(0, #pasted)
        assert.same({ "▸ add a retry", DRAFT }, texts(buf))
        assert.same({}, notes)
        assert.is_false(session.inline_active())
      end)

      it("lets go of the place when it drops one, so the next request is not refused", function()
        box, typed_flag, typed_when = "half a thought", true, clock - 5000
        ask("add a retry")
        box, typed_flag, typed_when = "", false, nil
        ask("add a retry again")
        assert.same({}, notes)
        assert.equals(1, #pasted)
      end)

      it("drops it when the box cannot be read: that is not known to be empty", function()
        box = nil
        ask("add a retry")
        assert.equals(0, #pasted)
        assert.same({ "▸ add a retry", DRAFT }, texts(buf))
      end)

      it("sends over Claude's suggested prompt, which nobody typed", function()
        box = "In three words, what is Neovim?"
        ask("add a retry")
        assert.equals(1, #pasted)
        assert.same({ box }, cleared)
      end)

      it("forgets what was typed once the box has been empty a while", function()
        box, typed_flag, typed_when = "", true, clock - 600
        ask("add a retry")
        assert.same({ "" }, cleared)
        assert.equals(1, #pasted)
      end)

      it("does not believe an empty box a moment after a key, nor forget the key", function()
        box, typed_flag, typed_when = "", true, clock - 100
        ask("add a retry")
        assert.same({}, cleared)
        assert.equals(0, #pasted)
        assert.same({ "▸ add a retry", DRAFT }, texts(buf))
      end)
    end)

    describe("when Claude is asking you something", function()
      it("drops the request with the question's line, and sends nothing", function()
        permission()
        ask("add a retry")
        assert.equals(0, #pasted)
        assert.same({ "▸ add a retry", ASKING }, texts(buf))
        assert.is_false(session.inline_active())
      end)

      it("does the same with the box empty or full", function()
        permission()
        box = "half a thought"
        ask("add a retry")
        assert.same({ "▸ add a retry", ASKING }, texts(buf))
      end)
    end)
  end)

  describe("waiting for Claude to finish", function()
    it("holds a request while Claude works, and sends it after the Stop", function()
      turn_ahead()
      ask("add a retry")
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", "waiting for Claude to finish" }, texts(buf))
      assert.is_true(session.inline_active())

      session.inject({ event = "PreToolUse", at = clock, tool_name = "Read", tool_input = {} })
      session.inject({ event = "MessageDisplay", at = clock, delta = "Looking." })
      assert.equals(0, #pasted)

      session.inject({ event = "Stop", at = clock, message = "Done ahead." })
      assert.equals(1, #pasted)
      assert.equals("@" .. vim.fn.fnamemodify(file, ":.") .. "#L2-4 add a retry", prompt_of())
      assert.same({ "▸ add a retry" }, texts(buf))
      assert.is_true(session.inline_active())
    end)

    it("is followed on from there: the turn is its own once its prompt is submitted", function()
      turn_ahead()
      ask("add a retry")
      session.inject({ event = "Stop", at = clock, message = "Done ahead." })
      session.inject(submitted())
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      assert.same({ "▸ add a retry", "Claude: Added a retry." }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("is dropped, with the draft's line, if you have typed one by then", function()
      local typed_flag = false
      stub(send, "typed", function()
        return typed_flag
      end)
      turn_ahead()
      ask("add a retry")
      box, typed_flag = "half a thought", true
      session.inject({ event = "Stop", at = clock, message = "Done ahead." })
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", DRAFT }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("goes on waiting while Claude asks you something mid-turn", function()
      turn_ahead()
      ask("add a retry")
      permission()
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", "waiting for Claude to finish" }, texts(buf))
      session.inject({ event = "PostToolUse", at = clock, tool_name = "Bash", tool_input = {} })
      session.inject({ event = "Stop", at = clock, message = "Done ahead." })
      assert.equals(1, #pasted)
    end)

    it("is dropped when the turn ahead fails, which leaves Claude asking you", function()
      turn_ahead()
      ask("add a retry")
      session.inject({ event = "StopFailure", at = clock, error = "rate_limit" })
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", ASKING }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("ends as failed when Claude's session ends first", function()
      turn_ahead()
      ask("add a retry")
      session.inject({ event = "SessionEnd", at = clock })
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", EXITED }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("sends when the turn ahead settles without a record: an Esc the safety net found", function()
      turn_ahead()
      ask("add a retry")
      session.state().phase = "idle"
      assert.is_true(vim.wait(2000, function()
        return #pasted == 1
      end))
    end)

    it("is let go of by clear, which also takes the lines down", function()
      turn_ahead()
      ask("add a retry")
      inline.clear(buf)
      assert.is_nil(shown(buf))
      assert.is_false(session.inline_active())
      session.inject({ event = "Stop", at = clock, message = "Done ahead." })
      assert.equals(0, #pasted)
      notes = {}
      ask("add a retry again")
      assert.same({}, notes)
    end)
  end)

  describe("when the screen and the session disagree about Claude working", function()
    it("waits when the status line is live though the session says idle", function()
      -- The corner opening can reset the session to idle a moment after a prompt.
      working = true
      ask("add a retry")
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", "waiting for Claude to finish" }, texts(buf))
      assert.is_true(session.inline_active())
    end)

    it("sends once the status line is gone, with no record to say so", function()
      working = true
      ask("add a retry")
      assert.equals(0, #pasted)
      working = false
      assert.is_true(vim.wait(2000, function()
        return #pasted == 1
      end))
      assert.same({ "▸ add a retry" }, texts(buf))
    end)

    it("goes on waiting past a Stop while the status line is still drawn", function()
      turn_ahead()
      working = true
      ask("add a retry")
      session.inject({ event = "Stop", at = clock, message = "Done ahead." })
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", "waiting for Claude to finish" }, texts(buf))
      working = false
      assert.is_true(vim.wait(2000, function()
        return #pasted == 1
      end))
    end)

    it("does not look at the screen for when_busy = send", function()
      config.setup({ inline = { when_busy = "send" } })
      working = true
      ask("add a retry")
      assert.equals(1, #pasted)
    end)

    it("still asks about a draft after waiting out the status line", function()
      local typed_flag = true
      stub(send, "typed", function()
        return typed_flag
      end)
      working = true
      box = "half a thought"
      ask("add a retry")
      assert.equals(0, #pasted)
      assert.same({ "▸ add a retry", DRAFT }, texts(buf))
    end)
  end)

  describe("when Claude exits", function()
    local function exits()
      inline.claude_exited()
    end

    it("ends a waiting request as failed, says so, and lets go", function()
      turn_ahead()
      ask("add a retry")
      exits()
      assert.same({ "▸ add a retry", EXITED }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("ends a request that was sent, or is running, the same way", function()
      ask("add a retry")
      exits()
      assert.same({ "▸ add a retry", EXITED }, texts(buf))
      assert.is_false(session.inline_active())

      notes = {}
      ask("add a retry again")
      assert.same({}, notes)
      session.inject(submitted({ prompt = prompt_of(2) }))
      session.inject({
        event = "PreToolUse",
        at = clock,
        tool_name = "Read",
        tool_input = { file_path = "/x/net.lua" },
      })
      exits()
      assert.same({ "▸ add a retry again", EXITED }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("keeps what Claude had said, after the note", function()
      ask("add a retry")
      session.inject(submitted())
      session.inject({ event = "MessageDisplay", at = clock, delta = "Trying." })
      exits()
      assert.same({ "▸ add a retry", EXITED, "Claude: Trying." }, texts(buf))
    end)

    it("takes everything the request set back, and stops looking", function()
      ask("add a retry")
      exits()
      assert.is_false(session.inline_active())
      local seen = ticks
      vim.wait(600)
      assert.equals(seen, ticks)
      session.inject({ event = "Stop", at = clock, message = "Late." })
      assert.same({ "▸ add a retry", EXITED }, texts(buf))
    end)

    it("lets the next request go", function()
      ask("add a retry")
      exits()
      notes = {}
      ask("add a retry again")
      assert.same({}, notes)
      assert.equals(2, #pasted)
    end)

    it("keeps <CR> on the lines, which still open Claude", function()
      ask("add a retry")
      exits()
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      assert.equals(1, restored)
    end)

    it("is nothing to a Claude with no request in flight", function()
      assert.has_no.errors(exits)
      ask("add a retry")
      session.inject(submitted())
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      exits()
      assert.same({ "▸ add a retry", "Claude: Added a retry." }, texts(buf))
    end)
  end)

  describe("a turn", function()
    it("shows the instruction and then what Claude says, once the turn is over", function()
      ask("add a retry")
      session.inject(submitted())
      assert.same({ "▸ add a retry" }, texts(buf))
      session.inject({
        event = "PreToolUse",
        at = clock,
        tool_name = "Read",
        tool_input = { file_path = "/x/net.lua" },
      })
      assert.same({ "▸ add a retry", "Read net.lua" }, texts(buf))
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      assert.same({ "▸ add a retry", "Claude: Added a retry." }, texts(buf))
    end)

    it("lets go of the place when it ends, and the lines stay", function()
      ask("add a retry")
      session.inject(submitted())
      assert.is_true(session.inline_active())
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      assert.is_false(session.inline_active())
      assert.same({ "▸ add a retry", "Claude: Added a retry." }, texts(buf))
      notes = {}
      ask("and a timeout")
      assert.same({}, notes)
      assert.equals(2, #pasted)
    end)

    it("shows Claude's question in full view, and not as a request to type", function()
      ask("add a retry")
      session.inject(submitted())
      permission()
      local _, items = shown(buf)
      assert.same({ "▸ add a retry", ASKING }, items)
    end)

    it("keeps the lines where edits moved them, and draws on from there", function()
      ask("add a retry")
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "a new first line" })
      session.inject(submitted())
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      local row, items = shown(buf)
      assert.equals(4, row)
      assert.same({ "▸ add a retry", "Claude: Added a retry." }, items)
    end)

    it("does not mind the buffer being wiped under it", function()
      ask("add a retry")
      session.inject(submitted())
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.has_no.errors(function()
        session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      end)
      assert.is_false(session.inline_active())
    end)

    it("is not touched by the turns after its own", function()
      ask("add a retry")
      session.inject(submitted())
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      turn_ahead()
      session.inject({ event = "MessageDisplay", at = clock, delta = "Something else." })
      assert.same({ "▸ add a retry", "Claude: Added a retry." }, texts(buf))
    end)

    it("ends as failed, saying so, when the session ends", function()
      ask("add a retry")
      session.inject(submitted())
      session.inject({ event = "SessionEnd", at = clock })
      assert.same({ "▸ add a retry", EXITED }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("is let go of by clear, though Claude goes on", function()
      ask("add a retry")
      session.inject(submitted())
      inline.clear(buf)
      assert.is_nil(shown(buf))
      assert.is_false(session.inline_active())
      assert.has_no.errors(function()
        session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      end)
      assert.is_nil(shown(buf))
    end)

    it("is not let go of by clearing another buffer's lines", function()
      ask("add a retry")
      local other = vim.api.nvim_create_buf(false, true)
      inline.clear(other)
      vim.api.nvim_buf_delete(other, { force = true })
      assert.is_true(session.inline_active())
    end)
  end)

  describe("the <CR> on the lines", function()
    local function press_on(row)
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    end

    it("opens Claude, from anywhere in the range", function()
      ask("add a retry")
      press_on(2)
      press_on(4)
      assert.equals(2, restored)
    end)

    it("leaves <CR> alone elsewhere in the buffer", function()
      ask("add a retry")
      press_on(1)
      assert.equals(0, restored)
    end)

    it("still opens Claude once the request is over", function()
      ask("add a retry")
      session.inject(submitted())
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      press_on(3)
      assert.equals(1, restored)
    end)

    it("opens Claude from the line of a request that was dropped", function()
      permission()
      ask("add a retry")
      press_on(3)
      assert.equals(1, restored)
    end)
  end)

  describe("the clock and the screen", function()
    it("gives up on a prompt Claude never took, after 5 s, and says so", function()
      ask("add a retry")
      at(clock + 6000)
      assert.is_true(vim.wait(2000, function()
        return texts(buf)[2] ~= nil
      end))
      assert.same(
        { "▸ add a retry", "Claude didn't take the prompt · <CR> to open Claude" },
        texts(buf)
      )
      assert.is_false(session.inline_active())
      assert.same({}, notes)
    end)

    it("calls a turn interrupted once its status line has been seen to go", function()
      ask("add a retry")
      session.inject(submitted())
      working = true
      next_tick()
      at(clock + 3000)
      working = false
      next_tick()
      assert.same({ "▸ add a retry", "interrupted" }, texts(buf))
      assert.is_false(session.inline_active())
    end)

    it("sees the input box come back where a dialog was, once it has been gone", function()
      ask("add a retry")
      session.inject(submitted())
      permission()
      box = nil
      next_tick()
      box = ""
      at(clock + 100)
      next_tick()
      assert.same({ "▸ add a retry", ASKING }, texts(buf))
      at(clock + 2000)
      next_tick()
      assert.same({ "▸ add a retry", "interrupted" }, texts(buf))
    end)

    it("stops looking once the request is over", function()
      ask("add a retry")
      session.inject(submitted())
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      local seen = ticks
      vim.wait(600)
      assert.equals(seen, ticks)
    end)

    it("ends a request as failed when Claude exits without a word", function()
      ask("add a retry")
      session.inject(submitted())
      session.stop()
      state.buf = -1
      assert.is_true(vim.wait(2000, function()
        return not session.inline_active() and texts(buf)[2] ~= nil
      end))
      assert.same({ "▸ add a retry", EXITED }, texts(buf))
      notes = {}
      state.buf = claude
      session.start_scripted()
      ask("add a retry again")
      assert.same({}, notes)
    end)

    it("ends a request as failed when Claude is no longer heard through its hooks", function()
      ask("add a retry")
      session.inject(submitted())
      session.stop()
      assert.is_true(vim.wait(2000, function()
        return texts(buf)[2] ~= nil
      end))
      assert.same({
        "▸ add a retry",
        "Inline mode needs Claude's hooks: this Claude is not heard through them",
      }, texts(buf))
    end)
  end)

  describe("the float", function()
    local calls

    before_each(function()
      calls = { restore = 0 }
      session.attach({
        restore = function()
          calls.restore = calls.restore + 1
        end,
        show = function() end,
        fallback = function() end,
      })
      config.setup({ auto = { restore_idle_ms = 20 } })
      -- Claude minimized to the corner.
      state.mini_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 10,
        height = 1,
      })
    end)

    after_each(function()
      if state.mini_win ~= -1 and vim.api.nvim_win_is_valid(state.mini_win) then
        vim.api.nvim_win_close(state.mini_win, true)
      end
      state.mini_win = -1
    end)

    it("stays away for an inline turn, and comes back for the next prompt's", function()
      ask("add a retry")
      session.inject(submitted())
      permission()
      session.inject({ event = "Stop", at = clock, message = "Added a retry." })
      vim.wait(100)
      assert.equals(0, calls.restore)
      -- Over: Claude is the float's again.
      turn_ahead()
      session.inject({ event = "Stop", at = clock, message = "Done." })
      assert.is_true(vim.wait(500, function()
        return calls.restore == 1
      end))
    end)
  end)

  describe("headless", function()
    it("is not session mode's to send: it shows the instruction, and takes no place", function()
      ask("add a retry", 2, 4, "headless")
      assert.same({ "▸ add a retry" }, texts(buf))
      assert.equals(0, #pasted)
      assert.is_false(session.inline_active())
    end)
  end)
end)
