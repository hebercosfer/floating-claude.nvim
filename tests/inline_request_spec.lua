-- An inline request in session mode: what gets pasted into Claude, and how the
-- session's hook records and the screen's status line carry it from "sent" to
-- its end. Pure: records in, phase and words out.

local record = require("floating-claude.hooks.record")
local request = require("floating-claude.inline.request")
local text = require("floating-claude.hooks.text")

local ASKING = "Claude is asking you something · <CR> to open Claude"
local DIDNT_TAKE = "Claude didn't take the prompt · <CR> to open Claude"
local COULDNT_TELL = "couldn't tell which reply is this one · <CR> to open Claude"

-- Words that differ from one another, past what the cap on a prompt keeps: a
-- repeated word would let any text match any other.
local function long_instruction(replace)
  local words = {}
  for i = 1, 700 do
    words[i] = i == replace and "CHANGED" or ("w" .. i)
  end
  return table.concat(words, " ")
end

-- A request that has been sent at `at`.
local function sent(opts, at)
  local req = request.new(vim.tbl_extend("force", {
    file = vim.fn.getcwd() .. "/lua/net.lua",
    line1 = 12,
    line2 = 14,
    instruction = "add a retry with backoff",
    mention = "at",
  }, opts or {}))
  req.phase, req.sent_at = "sent", at or 1000
  return req
end

-- A request whose turn has begun, with its prompt submitted at `at`.
local function running(opts, at)
  local req = sent(opts, at)
  assert.is_true(
    request.on_record(req, { event = "UserPromptSubmit", at = at or 1000, prompt = req.prompt })
  )
  return req
end

describe("inline request", function()
  describe("new", function()
    it("starts out waiting, holding the instruction as asked", function()
      local req = request.new({
        file = "a.lua",
        line1 = 1,
        line2 = 2,
        instruction = "  add   a retry\n\twith backoff ",
        mention = "at",
      })
      assert.equals("waiting", req.phase)
      assert.equals("add a retry with backoff", req.asked)
      assert.is_nil(req.sent_at)
      assert.is_nil(req.said)
      assert.is_nil(req.activity)
      assert.is_nil(req.asking)
    end)

    it("holds the text that gets pasted", function()
      local req = request.new({
        file = vim.fn.getcwd() .. "/lua/net.lua",
        line1 = 12,
        line2 = 14,
        instruction = "add a retry",
        mention = "at",
      })
      assert.equals("@lua/net.lua#L12-14 add a retry", req.prompt)
    end)
  end)

  describe("prompt", function()
    local function prompt(opts)
      return request.prompt(vim.tbl_extend("force", {
        file = vim.fn.getcwd() .. "/lua/net.lua",
        line1 = 12,
        line2 = 14,
        instruction = "add a retry with backoff",
        mention = "at",
      }, opts or {}))
    end

    it("mentions the range with @, the path relative to the working directory", function()
      assert.equals("@lua/net.lua#L12-14 add a retry with backoff", prompt())
    end)

    it("mentions a single line as #L<n>", function()
      assert.equals(
        "@lua/net.lua#L12 do it",
        prompt({ line1 = 12, line2 = 12, instruction = "do it" })
      )
    end)

    it("puts the lines in order whichever way the range was drawn", function()
      assert.equals("@lua/net.lua#L12-14 x", prompt({ line1 = 14, line2 = 12, instruction = "x" }))
    end)

    it('names the range in words with mention = "words"', function()
      assert.equals(
        "In lua/net.lua, lines 12-14: add a retry with backoff",
        prompt({ mention = "words" })
      )
      assert.equals(
        "In lua/net.lua, line 12: do it",
        prompt({ mention = "words", line1 = 12, line2 = 12, instruction = "do it" })
      )
    end)

    it("takes a path that is already relative as it is", function()
      assert.equals(
        "@lua/net.lua#L1-2 x",
        prompt({ file = "lua/net.lua", line1 = 1, line2 = 2, instruction = "x" })
      )
    end)

    it("leaves a file outside the working directory by its full path", function()
      assert.equals(
        "@/elsewhere/net.lua#L1-2 x",
        prompt({ file = "/elsewhere/net.lua", line1 = 1, line2 = 2, instruction = "x" })
      )
    end)

    it("names the range in words when the path has a space, which a mention cannot hold", function()
      assert.equals(
        "In my notes/net.lua, lines 1-2: x",
        prompt({ file = "my notes/net.lua", line1 = 1, line2 = 2, instruction = "x" })
      )
    end)

    it("keeps a multi-line instruction's line breaks", function()
      assert.equals("@lua/net.lua#L12-14 first\nsecond", prompt({ instruction = "first\nsecond" }))
    end)

    it(
      "takes the escape character out of the instruction, which would end the paste early",
      function()
        assert.equals("@lua/net.lua#L12-14 a[201~b", prompt({ instruction = "a\27[201~b" }))
      end
    )
  end)

  describe("on_record", function()
    describe("while sent", function()
      it("moves to running on a prompt that holds the instruction", function()
        local req = sent()
        assert.is_true(
          request.on_record(req, { event = "UserPromptSubmit", at = 1100, prompt = req.prompt })
        )
        assert.equals("running", req.phase)
      end)

      it("stays sent on a prompt that does not", function()
        local req = sent()
        assert.is_false(
          request.on_record(
            req,
            { event = "UserPromptSubmit", at = 1100, prompt = "something else" }
          )
        )
        assert.equals("sent", req.phase)
      end)

      it("ignores a prompt record with no prompt", function()
        local req = sent()
        assert.is_false(request.on_record(req, { event = "UserPromptSubmit", at = 1100 }))
        assert.equals("sent", req.phase)
      end)

      it("ignores every other event", function()
        local req = sent()
        assert.is_false(request.on_record(req, { event = "Stop", at = 1100, message = "Done." }))
        assert.is_false(
          request.on_record(
            req,
            { event = "PreToolUse", at = 1100, tool_name = "Read", tool_input = {} }
          )
        )
        assert.equals("sent", req.phase)
      end)

      it("matches the instruction whatever the whitespace", function()
        local req = sent({ instruction = "add a retry\n  with   backoff" })
        assert.is_true(request.on_record(req, {
          event = "UserPromptSubmit",
          at = 1100,
          prompt = "@lua/net.lua#L12-14 add a retry with backoff",
        }))
        assert.equals("running", req.phase)
      end)

      it("matches a paste Claude Code collapsed to a placeholder", function()
        -- Five lines or more arrive as the paste wrapped in <pasted_content>,
        -- with blank lines before it; the text itself is verbatim.
        local req = sent({ instruction = "one\ntwo\nthree\nfour" })
        assert.is_true(request.on_record(req, {
          event = "UserPromptSubmit",
          at = 1100,
          prompt = '\n\n<pasted_content id="089a">\n'
            .. req.prompt
            .. '\n</pasted_content id="089a">\n',
        }))
        assert.equals("running", req.phase)
      end)

      it("matches an instruction longer than the cap on the prompt it arrives in", function()
        local long = long_instruction()
        assert.is_true(#long > 3 * record.TEXT_CAP / 2)
        local req = sent({ instruction = long })
        local capped = record.cap(req.prompt, record.TEXT_CAP)
        assert.is_true(#capped < #req.prompt)
        assert.is_true(
          request.on_record(req, { event = "UserPromptSubmit", at = 1100, prompt = capped })
        )
        assert.equals("running", req.phase)
      end)

      it("matches a long instruction in a collapsed paste cut by the cap", function()
        local req = sent({ instruction = long_instruction() })
        local capped = record.cap(
          '\n\n<pasted_content id="089a">\n' .. req.prompt .. '\n</pasted_content id="089a">\n',
          record.TEXT_CAP
        )
        assert.is_true(
          request.on_record(req, { event = "UserPromptSubmit", at = 1100, prompt = capped })
        )
        assert.equals("running", req.phase)
      end)

      it("does not take a long prompt that merely starts alike", function()
        local req = sent({ instruction = long_instruction() })
        local other = record.cap("@lua/net.lua#L12-14 " .. long_instruction(100), record.TEXT_CAP)
        assert.is_false(
          request.on_record(req, { event = "UserPromptSubmit", at = 1100, prompt = other })
        )
      end)
    end)

    describe("while running", function()
      it("shows the tool a PreToolUse names", function()
        local req = running()
        local input = { file_path = "/work/lua/net.lua" }
        assert.is_true(
          request.on_record(
            req,
            { event = "PreToolUse", at = 1200, tool_name = "Read", tool_input = input }
          )
        )
        assert.equals(text.tool_line("Read", input), req.activity)
        assert.equals("Read net.lua", req.activity)
        assert.equals("running", req.phase)
      end)

      it("keeps the last tool when Claude's own bookkeeping runs", function()
        local req = running()
        request.on_record(req, {
          event = "PreToolUse",
          at = 1200,
          tool_name = "Read",
          tool_input = { file_path = "a.lua" },
        })
        assert.is_false(
          request.on_record(
            req,
            { event = "PreToolUse", at = 1300, tool_name = "TodoWrite", tool_input = {} }
          )
        )
        assert.equals("Read a.lua", req.activity)
      end)

      it("keeps what Claude said as the latest MessageDisplay has it", function()
        local req = running()
        assert.is_true(
          request.on_record(req, { event = "MessageDisplay", at = 1200, delta = "I'll wrap it." })
        )
        assert.equals("I'll wrap it.", req.said)
        assert.is_true(
          request.on_record(req, { event = "MessageDisplay", at = 1300, delta = "Then test it." })
        )
        assert.equals("Then test it.", req.said)
      end)

      it("reports no change when what it hears says what it already did", function()
        local req = running()
        request.on_record(req, { event = "MessageDisplay", at = 1200, delta = "Same." })
        assert.is_false(
          request.on_record(req, { event = "MessageDisplay", at = 1300, delta = "Same." })
        )
      end)

      it("is done on Stop, with Claude's last words", function()
        local req = running()
        request.on_record(req, { event = "MessageDisplay", at = 1200, delta = "Working on it." })
        assert.is_true(request.on_record(req, { event = "Stop", at = 1300, message = "Done." }))
        assert.equals("done", req.phase)
        assert.equals("Claude: Done.", request.items(req)[2])
        assert.is_true(request.ended(req))
      end)

      it("keeps its last words when Stop brings none", function()
        local req = running()
        request.on_record(req, { event = "MessageDisplay", at = 1200, delta = "Working on it." })
        request.on_record(req, { event = "Stop", at = 1300 })
        assert.equals("done", req.phase)
        assert.equals("Working on it.", req.said)
      end)

      it("asks you on a PermissionRequest", function()
        local req = running()
        assert.is_true(request.on_record(req, {
          event = "PermissionRequest",
          at = 1200,
          tool_name = "Edit",
          tool_input = { file_path = "a.lua" },
        }))
        assert.equals(ASKING, req.asking)
        assert.same({ text = ASKING, ask = true }, request.items(req)[2])
        assert.equals("running", req.phase)
      end)

      it("asks you on an Elicitation", function()
        local req = running()
        request.on_record(req, { event = "Elicitation", at = 1200, message = "Which one?" })
        assert.equals(ASKING, req.asking)
      end)

      it("stops asking once the tool runs, finishes or fails", function()
        for _, event in ipairs({ "PreToolUse", "PostToolUse", "PostToolUseFailure" }) do
          local req = running()
          request.on_record(
            req,
            { event = "PermissionRequest", at = 1200, tool_name = "Edit", tool_input = {} }
          )
          assert.is_true(
            request.on_record(
              req,
              { event = event, at = 1300, tool_name = "Edit", tool_input = {} }
            ),
            event
          )
          assert.is_nil(req.asking, event)
          assert.equals("running", req.phase, event)
        end
      end)

      it("fails on StopFailure, with what it said or else the error", function()
        local req = running()
        assert.is_true(
          request.on_record(
            req,
            { event = "StopFailure", at = 1200, message = "Out of budget.", error = "billing" }
          )
        )
        assert.equals("failed", req.phase)
        assert.equals("Out of budget.", req.said)
        assert.is_true(request.ended(req))

        req = running()
        request.on_record(req, { event = "StopFailure", at = 1200, error = "rate_limit" })
        assert.equals("failed", req.phase)
        assert.equals("rate_limit", req.said)
      end)

      it("fails on SessionEnd, so a request cannot outlive its Claude", function()
        local req = running()
        assert.is_true(request.on_record(req, { event = "SessionEnd", at = 1200, reason = "exit" }))
        assert.equals("failed", req.phase)
        assert.is_true(request.ended(req))
      end)

      it("ignores events it has no use for", function()
        local req = running()
        assert.is_false(request.on_record(req, { event = "PreCompact", at = 1200 }))
        assert.is_false(
          request.on_record(req, { event = "UserPromptSubmit", at = 1200, prompt = "other" })
        )
        assert.equals("running", req.phase)
      end)
    end)

    describe("once over", function()
      it("ignores the records that follow", function()
        for _, phase in ipairs({ "done", "failed", "interrupted", "dropped", "waiting" }) do
          local req = running()
          req.phase = phase
          assert.is_false(
            request.on_record(req, { event = "MessageDisplay", at = 1300, delta = "late" }),
            phase
          )
          assert.is_false(
            request.on_record(
              req,
              { event = "PreToolUse", at = 1300, tool_name = "Read", tool_input = {} }
            ),
            phase
          )
          assert.is_nil(req.said, phase)
          assert.equals(phase, req.phase)
        end
      end)
    end)
  end)

  describe("on_tick", function()
    local function tick(req, now, status)
      return request.on_tick(req, now, vim.tbl_extend("force", { working = false }, status or {}))
    end

    describe("while sent", function()
      it("fails a prompt Claude never took, 5000 ms after it was sent", function()
        local req = sent({}, 1000)
        assert.is_false(tick(req, 5999))
        assert.equals("sent", req.phase)
        assert.is_true(tick(req, 6000))
        assert.equals("failed", req.phase)
        assert.equals(DIDNT_TAKE, req.note)
        assert.is_nil(req.said)
        assert.is_true(request.ended(req))
      end)

      describe("with Claude busy, so that the prompt is queued", function()
        it("waits for as long as the status line is live", function()
          local req = sent({}, 1000)
          assert.is_false(tick(req, 3000, { working = true }))
          assert.is_true(req.queued)
          assert.is_false(tick(req, 20000, { working = true }))
          assert.equals("sent", req.phase)
        end)

        it("does not queue a prompt that never saw a busy Claude", function()
          local req = sent({}, 1000)
          tick(req, 3000)
          assert.is_nil(req.queued)
        end)

        it("fails once the status line has been gone for 5000 ms with nothing taken", function()
          -- An Esc on the turn ahead fires no hook, and Claude Code may put the
          -- queued prompt back in the box rather than send it.
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          assert.is_false(tick(req, 7999))
          assert.is_true(tick(req, 8000))
          assert.equals("failed", req.phase)
          assert.equals(DIDNT_TAKE, req.note)
        end)

        it("gives a prompt that follows the turn ahead's Stop a fresh 5000 ms", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          request.on_record(req, { event = "Stop", at = 8000, message = "Earlier reply." })
          assert.equals("sent", req.phase)
          assert.is_false(tick(req, 12999))
          assert.equals("sent", req.phase)
          assert.is_true(request.on_record(req, {
            event = "UserPromptSubmit",
            at = 9000,
            prompt = req.prompt,
          }))
          assert.equals("running", req.phase)
        end)

        it("keeps the turn ahead's words out of its own turn", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          request.on_record(req, { event = "Stop", at = 8000, message = "Earlier reply." })
          assert.is_nil(req.said)
          assert.is_true(request.on_record(req, {
            event = "UserPromptSubmit",
            at = 9000,
            prompt = req.prompt,
          }))
          assert.equals("running", req.phase)
          assert.is_nil(req.said)
          assert.same({ "▸ add a retry with backoff" }, request.items(req))
          request.on_record(req, { event = "MessageDisplay", at = 9500, delta = "Mine." })
          assert.same({ "▸ add a retry with backoff", "Claude: Mine." }, request.items(req))
        end)

        it("does not take the turn ahead's words for its own result", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          request.on_record(req, { event = "Stop", at = 8000, message = "Earlier reply." })
          request.on_record(req, { event = "UserPromptSubmit", at = 9000, prompt = req.prompt })
          request.on_record(req, { event = "Stop", at = 12000 })
          assert.equals("done", req.phase)
          assert.is_nil(req.said)
          assert.same({ "▸ add a retry with backoff", "done" }, request.items(req))
        end)

        it("ends done, unable to tell which reply is its own, when none follows", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          assert.is_false(
            request.on_record(req, { event = "Stop", at = 8000, message = "Earlier reply." })
          )
          assert.is_nil(req.said)
          assert.is_true(tick(req, 13000))
          assert.equals("done", req.phase)
          assert.equals(COULDNT_TELL, req.note)
          assert.equals("Earlier reply.", req.said)
          assert.is_true(request.ended(req))
          assert.same(
            { "▸ add a retry with backoff", COULDNT_TELL, "Claude: Earlier reply." },
            request.items(req)
          )
        end)

        it("keeps the last Stop's words when more than one turn was ahead", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          request.on_record(req, { event = "Stop", at = 8000, message = "First." })
          tick(req, 8500, { working = true })
          request.on_record(req, { event = "Stop", at = 12000, message = "Second." })
          assert.is_false(tick(req, 16999))
          assert.is_true(tick(req, 17000))
          assert.equals("Second.", req.said)
        end)

        it("takes the last Stop's words, or none, and not an earlier Stop's", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          request.on_record(req, { event = "Stop", at = 8000, message = "First." })
          tick(req, 8500, { working = true })
          request.on_record(req, { event = "Stop", at = 12000 })
          assert.is_true(tick(req, 17000))
          assert.is_nil(req.said)
          assert.same({ "▸ add a retry with backoff", COULDNT_TELL }, request.items(req))
        end)

        it("is left with no words when that Stop had none", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          request.on_record(req, { event = "Stop", at = 8000 })
          assert.is_true(tick(req, 13000))
          assert.same({ "▸ add a retry with backoff", COULDNT_TELL }, request.items(req))
        end)

        it("waits through the Stop while the status line is still live", function()
          local req = sent({}, 1000)
          tick(req, 3000, { working = true })
          request.on_record(req, { event = "Stop", at = 8000, message = "Earlier reply." })
          assert.is_false(tick(req, 14000, { working = true }))
          assert.equals("sent", req.phase)
          assert.is_false(tick(req, 18999))
          assert.is_true(tick(req, 19000))
        end)
      end)

      it("ignores a Stop when the prompt was not queued", function()
        local req = sent({}, 1000)
        assert.is_false(request.on_record(req, { event = "Stop", at = 2000, message = "Late." }))
        assert.is_nil(req.said)
        assert.is_true(tick(req, 6000))
        assert.equals(DIDNT_TAKE, req.note)
      end)
    end)

    describe("while running", function()
      it(
        "calls the turn interrupted once the status line has been seen, then gone 1000 ms",
        function()
          local req = running({}, 1000)
          assert.is_false(tick(req, 1500, { working = true }))
          assert.is_false(tick(req, 2499))
          assert.equals("running", req.phase)
          assert.is_true(tick(req, 2500))
          assert.equals("interrupted", req.phase)
          assert.same({ "▸ add a retry with backoff", "interrupted" }, request.items(req))
          assert.is_true(request.ended(req))
        end
      )

      it("does not trust a status line it has not seen yet to have gone", function()
        local req = running({}, 1000)
        assert.is_false(tick(req, 9000))
        assert.equals("running", req.phase)
      end)

      it("counts the status line seen while the prompt was still being taken", function()
        local req = sent({}, 1000)
        tick(req, 1200, { working = true })
        request.on_record(req, { event = "UserPromptSubmit", at = 1300, prompt = req.prompt })
        assert.is_true(tick(req, 2300))
        assert.equals("interrupted", req.phase)
      end)

      it("counts the silence from the latest record", function()
        local req = running({}, 1000)
        tick(req, 1100, { working = true })
        request.on_record(req, { event = "MessageDisplay", at = 1900, delta = "Still here." })
        assert.is_false(tick(req, 2800))
        assert.is_true(tick(req, 2900))
        assert.equals("interrupted", req.phase)
      end)

      it("leaves a turn alone while the status line is live", function()
        local req = running({}, 1000)
        assert.is_false(tick(req, 1100, { working = true }))
        assert.is_false(tick(req, 9000, { working = true }))
        assert.equals("running", req.phase)
      end)

      it("starts the 1000 ms again each time the status line is seen", function()
        local req = running({}, 1000)
        tick(req, 1100, { working = true })
        tick(req, 4000, { working = true })
        assert.is_false(tick(req, 4999))
        assert.is_true(tick(req, 5000))
      end)

      it("leaves a compacting turn alone, until the compaction is over", function()
        local req = running({}, 1000)
        tick(req, 1100, { working = true })
        request.on_record(req, { event = "PreCompact", at = 1200, trigger = "auto" })
        assert.is_false(tick(req, 9000))
        assert.equals("running", req.phase)
        request.on_record(req, { event = "PostCompact", at = 9100, trigger = "auto" })
        assert.is_false(tick(req, 9500))
        assert.is_true(tick(req, 10100))
        assert.equals("interrupted", req.phase)
      end)

      describe("while Claude is asking you", function()
        local function asked()
          local req = running({}, 1000)
          tick(req, 1100, { working = true })
          request.on_record(
            req,
            { event = "PermissionRequest", at = 1200, tool_name = "Edit", tool_input = {} }
          )
          return req
        end

        it("waits as long as the dialog is up, with no status line and no input box", function()
          local req = asked()
          assert.is_false(tick(req, 9000, { box = false }))
          assert.is_false(tick(req, 99000, { box = false }))
          assert.equals("running", req.phase)
          assert.equals(ASKING, req.asking)
        end)

        it("waits when the screen says nothing about the box", function()
          local req = asked()
          assert.is_false(tick(req, 99000))
          assert.equals("running", req.phase)
        end)

        -- The record can come well before Claude draws the dialog, with the
        -- input box still on the screen: the rule is not armed until the
        -- dialog has been seen.
        local function drawn(req)
          assert.is_false(tick(req, 2000, { box = false }))
        end

        it("does not take the box still on screen for a dismissed dialog", function()
          local req = asked()
          assert.is_false(tick(req, 1500, { box = true }))
          assert.is_false(tick(req, 2500, { box = true }))
          assert.is_false(tick(req, 3500, { box = true }))
          assert.is_false(tick(req, 99000, { box = true }))
          assert.equals("running", req.phase)
        end)

        it(
          "does not take a box the screen did not report for the dialog having been drawn",
          function()
            local req = asked()
            tick(req, 2000)
            assert.is_false(tick(req, 3000, { box = true }))
            assert.is_false(tick(req, 5000, { box = true }))
            assert.equals("running", req.phase)
          end
        )

        it("wants the dialog drawn again for the next question", function()
          local req = asked()
          drawn(req)
          request.on_record(
            req,
            { event = "PostToolUse", at = 2100, tool_name = "Edit", tool_input = {} }
          )
          request.on_record(
            req,
            { event = "PermissionRequest", at = 2200, tool_name = "Bash", tool_input = {} }
          )
          assert.is_false(tick(req, 3000, { box = true }))
          assert.is_false(tick(req, 6000, { box = true }))
          assert.equals("running", req.phase)
        end)

        it(
          "is interrupted once the input box has been back for 1000 ms with nothing heard",
          function()
            -- An Esc on the dialog fires no hook, and leaves the box where the dialog was.
            local req = asked()
            drawn(req)
            assert.is_false(tick(req, 3000, { box = true }))
            assert.is_false(tick(req, 3999, { box = true }))
            assert.equals("running", req.phase)
            assert.is_true(tick(req, 4000, { box = true }))
            assert.equals("interrupted", req.phase)
          end
        )

        it("counts again from the start when the box goes away in between", function()
          local req = asked()
          drawn(req)
          tick(req, 3000, { box = true })
          tick(req, 3500, { box = false })
          tick(req, 3600, { box = true })
          assert.is_false(tick(req, 4000, { box = true }))
          assert.is_false(tick(req, 4599, { box = true }))
          assert.is_true(tick(req, 4600, { box = true }))
        end)

        it("counts from a record that arrives with the box back", function()
          local req = asked()
          drawn(req)
          tick(req, 3000, { box = true })
          request.on_record(req, { event = "MessageDisplay", at = 3800, delta = "Hm." })
          assert.is_false(tick(req, 4000, { box = true }))
          assert.is_false(tick(req, 4799, { box = true }))
          assert.is_true(tick(req, 4800, { box = true }))
        end)

        it("is not interrupted while the status line is live", function()
          local req = asked()
          drawn(req)
          tick(req, 3000, { box = true })
          assert.is_false(tick(req, 5000, { box = true, working = true }))
          assert.equals("running", req.phase)
          -- And the live line began the count afresh.
          assert.is_false(tick(req, 5500, { box = true }))
          assert.is_true(tick(req, 6500, { box = true }))
        end)
      end)
    end)

    it("has nothing to say about a request that is waiting or over", function()
      for _, phase in ipairs({ "waiting", "done", "failed", "interrupted", "dropped" }) do
        local req = running({}, 1000)
        tick(req, 1100, { working = true })
        req.phase = phase
        assert.is_false(tick(req, 99999, { box = true }), phase)
        assert.equals(phase, req.phase)
      end
    end)
  end)

  describe("items", function()
    it("leads with the instruction, whitespace-normalised", function()
      local req = request.new({
        file = "a.lua",
        line1 = 1,
        line2 = 1,
        instruction = "add a retry\n  with backoff",
        mention = "at",
      })
      assert.same(
        { "▸ add a retry with backoff", "waiting for Claude to finish" },
        request.items(req)
      )
    end)

    it("is the instruction alone once sent, until Claude takes it", function()
      assert.same({ "▸ add a retry with backoff" }, request.items(sent()))
    end)

    it("shows the tool, then what Claude said, while running", function()
      local req = running()
      request.on_record(req, {
        event = "PreToolUse",
        at = 1200,
        tool_name = "Read",
        tool_input = { file_path = "a.lua" },
      })
      request.on_record(req, { event = "MessageDisplay", at = 1300, delta = "I'll wrap it." })
      assert.same({
        "▸ add a retry with backoff",
        "Read a.lua",
        "Claude: I'll wrap it.",
      }, request.items(req))
    end)

    it("shows what Claude said alone when no tool has run", function()
      local req = running()
      request.on_record(req, { event = "MessageDisplay", at = 1300, delta = "Thinking." })
      assert.same({ "▸ add a retry with backoff", "Claude: Thinking." }, request.items(req))
    end)

    it("puts the question in the tool's place, as a line the cap never cuts", function()
      local req = running()
      request.on_record(req, {
        event = "PreToolUse",
        at = 1200,
        tool_name = "Read",
        tool_input = { file_path = "a.lua" },
      })
      request.on_record(req, { event = "MessageDisplay", at = 1250, delta = "Editing." })
      request.on_record(
        req,
        { event = "PermissionRequest", at = 1300, tool_name = "Edit", tool_input = {} }
      )
      assert.same({
        "▸ add a retry with backoff",
        { text = ASKING, ask = true },
        "Claude: Editing.",
      }, request.items(req))
    end)

    it("shows the last words, and not the tool, once done", function()
      local req = running()
      request.on_record(req, {
        event = "PreToolUse",
        at = 1200,
        tool_name = "Read",
        tool_input = { file_path = "a.lua" },
      })
      request.on_record(req, { event = "Stop", at = 1300, message = "Done." })
      assert.same({ "▸ add a retry with backoff", "Claude: Done." }, request.items(req))
    end)

    it("says what failed", function()
      local req = sent({}, 1000)
      request.on_tick(req, 7000, { working = false })
      assert.same({ "▸ add a retry with backoff", DIDNT_TAKE }, request.items(req))
      assert.equals("Claude didn't take the prompt · <CR> to open Claude", request.items(req)[2])
    end)

    it("says so when a turn ends with no words", function()
      local req = running()
      request.on_record(req, { event = "Stop", at = 1300 })
      assert.same({ "▸ add a retry with backoff", "done" }, request.items(req))

      req = running()
      request.on_record(req, { event = "SessionEnd", at = 1300 })
      assert.same({ "▸ add a retry with backoff", "failed" }, request.items(req))
    end)

    it("says why a request was dropped, in the words it was given", function()
      local req =
        request.new({ file = "a.lua", line1 = 1, line2 = 1, instruction = "x", mention = "at" })
      req.phase, req.note = "dropped", "Claude has a draft · <CR> to open Claude"
      assert.same({ "▸ x", "Claude has a draft · <CR> to open Claude" }, request.items(req))
      assert.is_true(request.ended(req))
    end)

    it("has the words for a request dropped for a draft, or for a question", function()
      assert.equals("Claude's prompt has a draft · <CR> to open Claude", request.DRAFT)
      assert.equals("Claude is asking you something · <CR> to open Claude", request.ASKING)
      for _, note in ipairs({ request.DRAFT, request.ASKING }) do
        local req =
          request.new({ file = "a.lua", line1 = 1, line2 = 1, instruction = "x", mention = "at" })
        req.phase, req.note = "dropped", note
        assert.same({ "▸ x", note }, request.items(req))
      end
    end)

    it("keeps what the plugin says apart from what Claude said", function()
      local req = running()
      request.on_record(req, { event = "MessageDisplay", at = 1200, delta = "Trying." })
      req.phase, req.note = "failed", "Something the plugin knows · <CR> to open Claude"
      assert.same({
        "▸ add a retry with backoff",
        "Something the plugin knows · <CR> to open Claude",
        "Claude: Trying.",
      }, request.items(req))
    end)
  end)

  describe("ended", function()
    it("is true for done, interrupted, failed and dropped, and for nothing else", function()
      local ends = { done = true, interrupted = true, failed = true, dropped = true }
      for _, phase in ipairs({
        "waiting",
        "sent",
        "running",
        "done",
        "interrupted",
        "failed",
        "dropped",
      }) do
        local req =
          request.new({ file = "a.lua", line1 = 1, line2 = 1, instruction = "x", mention = "at" })
        req.phase = phase
        assert.equals(ends[phase] == true, request.ended(req), phase)
      end
    end)
  end)
end)
