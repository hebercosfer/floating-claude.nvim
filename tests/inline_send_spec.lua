-- Getting an inline request into Claude: whether now is a good time (the gate),
-- how it goes in (the paste), and whether anything has been typed into
-- Claude's terminal since its last prompt, which is what tells a draft from the
-- prompt Claude Code suggests.

local send = require("floating-claude.inline.send")

describe("inline send", function()
  describe("gate", function()
    -- when_busy, session phase, draft, typed -> what to do.
    local rows = {
      -- "send" never waits, asks or looks at the box.
      { "send", "idle", "", false, "send" },
      { "send", "working", "", false, "send" },
      { "send", "request", "", false, "send" },
      { "send", "idle", "half a thought", true, "send" },
      { "send", "working", nil, true, "send" },
      -- "wait": a request open is asking, before anything else.
      { "wait", "request", "", false, "asking" },
      { "wait", "request", "half a thought", true, "asking" },
      { "wait", "request", nil, false, "asking" },
      -- then a draft in the box, even while Claude works.
      { "wait", "idle", "half a thought", true, "draft" },
      { "wait", "working", "half a thought", true, "draft" },
      -- a box that cannot be read counts as a draft: do not paste over it.
      { "wait", "idle", nil, false, "draft" },
      { "wait", "idle", nil, true, "draft" },
      { "wait", "working", nil, false, "draft" },
      -- then a turn in progress.
      { "wait", "working", "", false, "wait" },
      { "wait", "working", "", true, "wait" },
      -- else it goes.
      { "wait", "idle", "", false, "send" },
      { "wait", "idle", "", true, "send" },
      -- text nobody typed is Claude's suggestion, and as good as an empty box.
      { "wait", "idle", "In three words, what is Neovim?", false, "send" },
      { "wait", "working", "In three words, what is Neovim?", false, "wait" },
      { "wait", "request", "In three words, what is Neovim?", false, "asking" },
      -- the same text, typed into the terminal, is a draft.
      { "wait", "idle", "In three words, what is Neovim?", true, "draft" },
      { "wait", "working", "In three words, what is Neovim?", true, "draft" },
    }

    for _, row in ipairs(rows) do
      local busy, phase, draft, typed, want = unpack(row, 1, 5)
      local what = ("%s, %s, draft %s, %s"):format(
        busy,
        phase,
        draft == nil and "unreadable" or (draft == "" and "empty" or "text"),
        typed and "typed" or "not typed"
      )
      it(what .. " -> " .. want, function()
        assert.equals(want, send.gate(busy, phase, draft, typed))
      end)
    end

    it("does not paste over text when it cannot tell whether it was typed", function()
      assert.equals("draft", send.gate("wait", "idle", "some text"))
    end)
  end)

  describe("paste", function()
    local calls, chansend

    before_each(function()
      calls = {}
      chansend = vim.fn.chansend
      vim.fn.chansend = function(job, data)
        table.insert(calls, { job, data })
        return #data
      end
    end)

    after_each(function()
      vim.fn.chansend = chansend
    end)

    it("pastes the text in brackets, then presses Enter", function()
      send.paste(7, "@lua/net.lua#L12-14 add a retry")
      assert.same({
        { 7, "\27[200~@lua/net.lua#L12-14 add a retry\27[201~" },
        { 7, "\r" },
      }, calls)
    end)

    it("keeps the line breaks of a multi-line text in the one paste", function()
      send.paste(7, "first\nsecond")
      assert.same({
        { 7, "\27[200~first\nsecond\27[201~" },
        { 7, "\r" },
      }, calls)
    end)

    it("leaves an escape in the text out of the paste, where it could end it early", function()
      send.paste(7, "a\27[201~\rb")
      assert.same({
        { 7, "\27[200~a[201~\rb\27[201~" },
        { 7, "\r" },
      }, calls)
    end)
  end)

  describe("typing", function()
    local buf, other

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      other = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
      send.unwatch_typing()
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.api.nvim_buf_delete(other, { force = true })
      send.reset_typed()
    end)

    it("starts out with nothing typed", function()
      send.watch_typing(buf)
      assert.is_false(send.typed())
    end)

    it("does not take the keys of a buffer that is not a terminal for typing", function()
      vim.api.nvim_set_current_buf(buf)
      send.watch_typing(buf)
      vim.api.nvim_feedkeys(vim.keycode("ix<Esc>"), "tx", false)
      assert.equals("x", vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1])
      assert.is_false(send.typed())
    end)

    describe("a paste", function()
      local original, calls

      before_each(function()
        original, calls = vim.paste, {}
        vim.paste = function(lines, phase)
          table.insert(calls, { lines, phase })
          return true
        end
      end)

      after_each(function()
        send.unwatch_typing()
        vim.paste = original
      end)

      it("into the watched buffer counts as typed, and goes on to the real paste", function()
        vim.api.nvim_set_current_buf(buf)
        send.watch_typing(buf)
        assert.is_true(vim.paste({ "a draft", "of two lines" }, -1))
        assert.same({ { { "a draft", "of two lines" }, -1 } }, calls)
        assert.is_true(send.typed())
      end)

      it("hands the real paste's answer back", function()
        vim.paste = function()
          return false
        end
        vim.api.nvim_set_current_buf(buf)
        send.watch_typing(buf)
        assert.is_false(vim.paste({ "x" }, -1))
        assert.is_true(send.typed())
      end)

      it("into another buffer does not count, though it goes through", function()
        vim.api.nvim_set_current_buf(other)
        send.watch_typing(buf)
        assert.is_true(vim.paste({ "elsewhere" }, -1))
        assert.equals(1, #calls)
        assert.is_false(send.typed())
      end)

      it("of nothing does not count", function()
        vim.api.nvim_set_current_buf(buf)
        send.watch_typing(buf)
        vim.paste({ "" }, -1)
        vim.paste({}, -1)
        assert.is_false(send.typed())
      end)

      it("is not what send.paste makes: that goes to the job, not through vim.paste", function()
        local chansend = vim.fn.chansend
        vim.fn.chansend = function(_, data)
          return #data
        end
        vim.api.nvim_set_current_buf(buf)
        send.watch_typing(buf)
        send.paste(7, "@lua/net.lua#L1 x")
        vim.fn.chansend = chansend
        assert.is_false(send.typed())
        assert.equals(0, #calls)
      end)

      it(
        "is wrapped once however often the watch begins, and put back by unwatch_typing",
        function()
          local before = vim.paste
          send.watch_typing(buf)
          local wrapped = vim.paste
          assert.is_not.equals(before, wrapped)
          send.watch_typing(other)
          send.watch_typing(buf)
          assert.equals(wrapped, vim.paste)
          send.unwatch_typing()
          assert.equals(before, vim.paste)
        end
      )

      it("is no longer seen once the watch is taken down", function()
        vim.api.nvim_set_current_buf(buf)
        send.watch_typing(buf)
        send.unwatch_typing()
        vim.paste({ "x" }, -1)
        assert.is_false(send.typed())
      end)

      it("leaves a wrapper somebody put on top of ours where it is, and goes quiet", function()
        vim.api.nvim_set_current_buf(buf)
        send.watch_typing(buf)
        local ours = vim.paste
        local theirs = function(lines, phase)
          return ours(lines, phase)
        end
        vim.paste = theirs
        send.unwatch_typing()
        assert.equals(theirs, vim.paste)
        vim.paste({ "x" }, -1)
        assert.is_false(send.typed())
        assert.equals(1, #calls)
      end)
    end)

    describe("clear_typed_if_empty", function()
      local original

      before_each(function()
        original = vim.paste
        vim.paste = function()
          return true
        end
        vim.api.nvim_set_current_buf(buf)
        send.watch_typing(buf)
        -- Something typed, in the one way a spec can do here.
        vim.paste({ "a draft" }, -1)
      end)

      after_each(function()
        send.unwatch_typing()
        vim.paste = original
      end)

      it("forgets what was typed when the box reads empty", function()
        assert.is_true(send.typed())
        send.clear_typed_if_empty("")
        assert.is_false(send.typed())
      end)

      it("keeps it while the box holds text", function()
        send.clear_typed_if_empty("a draft")
        assert.is_true(send.typed())
      end)

      it("keeps it when the box could not be read", function()
        send.clear_typed_if_empty(nil)
        assert.is_true(send.typed())
      end)

      it("makes the gate send again over what was typed and then deleted", function()
        assert.equals("draft", send.gate("wait", "idle", "half", send.typed()))
        send.clear_typed_if_empty("")
        assert.equals("send", send.gate("wait", "idle", "Claude's next suggestion", send.typed()))
      end)
    end)

    describe("is_typing", function()
      local function typing(key, typed, mode, current)
        return send.is_typing(buf, key, typed, mode, current or buf)
      end

      it("is a key that reaches the terminal, in terminal mode, in the watched buffer", function()
        assert.is_true(typing("a", "a", "t"))
        assert.is_true(typing("\r", "\r", "t"))
        assert.is_true(typing("\27", "\27", "t"))
      end)

      it("is not a key typed in another buffer", function()
        assert.is_false(typing("a", "a", "t", other))
      end)

      it("is not a key in any mode but terminal mode", function()
        for _, mode in ipairs({ "n", "i", "nt", "c", "v", "no" }) do
          assert.is_false(typing("a", "a", mode), mode)
        end
      end)

      it("is a put in terminal-normal mode, which sends the register to the terminal", function()
        assert.is_true(typing("p", "p", "nt"))
        assert.is_true(typing("P", "P", "nt"))
      end)

      it("is not a put anywhere else, nor another key in terminal-normal mode", function()
        assert.is_false(typing("p", "p", "n"))
        assert.is_false(typing("p", "p", "i"))
        assert.is_false(typing("p", "p", "nt", other))
        assert.is_false(typing("j", "j", "nt"))
        assert.is_false(typing("y", "y", "nt"))
      end)

      it("is not a key a mapping took, which is not text for Claude", function()
        -- <C-q> mapped to x: Neovim hands over the x, and the key as typed.
        assert.is_false(typing("x", "\17", "t"))
      end)

      it("is not a key that was not typed", function()
        assert.is_false(typing("a", "", "t"))
      end)
    end)

    describe("with a real terminal", function()
      -- Terminal mode needs the main loop, which a spec runs inside of, so
      -- this one runs a Neovim of its own and reads what it found.
      local function run(script)
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local out = dir .. "/out.json"
        local file = dir .. "/script.lua"
        vim.fn.writefile(vim.split(script:gsub("OUT", vim.inspect(out)), "\n"), file)
        local done = vim
          .system({
            vim.v.progpath,
            "--headless",
            "--noplugin",
            "-u",
            "NONE",
            "-c",
            "set runtimepath^=" .. vim.fn.fnameescape(vim.fn.getcwd()),
            "-c",
            "luafile " .. file,
          }, { text = true })
          :wait(20000)
        assert.equals(0, done.code, done.stderr)
        local lines = vim.fn.readfile(out)
        vim.fn.delete(dir, "rf")
        return vim.json.decode(table.concat(lines, "\n"))
      end

      it("sees what is typed into Claude's terminal, and nothing else", function()
        local seen = run([[
          local send = require("floating-claude.inline.send")
          vim.keymap.set("t", "<C-q>", "x")
          vim.keymap.set("t", "<F5>", function() end)

          -- Two terminals; Claude's is the first, and you are in the second.
          vim.cmd("enew")
          local claude = vim.api.nvim_get_current_buf()
          vim.fn.jobstart({ "cat" }, { term = true })
          vim.cmd("enew")
          local second = vim.api.nvim_get_current_buf()
          vim.fn.jobstart({ "cat" }, { term = true })

          local seen = {}
          local function note(label)
            table.insert(seen, { label, send.typed() })
            send.reset_typed()
          end
          local function feed(keys, mode)
            vim.api.nvim_feedkeys(vim.keycode(keys), mode or "t", false)
          end

          send.watch_typing(claude)
          vim.cmd("startinsert")

          local steps = {
            function() note("nothing typed yet"); feed("a") end,
            function() note("a typed in the other terminal"); send.watch_typing(second); feed("a") end,
            function() note("a typed in the watched terminal"); feed("<C-q>") end,
            function() note("a key mapped to another key"); feed("<F5>") end,
            function() note("a key mapped to a function"); feed("z", "n") end,
            function() note("a key that was not typed"); feed("a") end,
            function()
              send.watch_typing(second)
              note("a watch that begins afresh")
              feed("a")
            end,
            function() note("typed again, under the new watch") end,
            function() vim.api.nvim_paste("pasted text", false, -1) end,
            function() note("a paste into the watched terminal"); feed("<C-\\><C-n>") end,
            function() send.reset_typed(); vim.fn.setreg('"', "put"); feed("j") end,
            function() note("a motion in terminal-normal mode"); feed("p") end,
            function() note("p in terminal-normal mode"); feed("P") end,
            function() note("P in terminal-normal mode") end,
          }
          local at = 0
          local function step()
            at = at + 1
            if steps[at] then
              steps[at]()
              vim.defer_fn(step, 150)
              return
            end
            local f = assert(io.open(OUT, "w"))
            f:write(vim.json.encode(seen))
            f:close()
            vim.cmd("qa!")
          end
          vim.defer_fn(step, 300)
        ]])
        assert.same({
          { "nothing typed yet", false },
          { "a typed in the other terminal", false },
          { "a typed in the watched terminal", true },
          { "a key mapped to another key", false },
          { "a key mapped to a function", false },
          { "a key that was not typed", false },
          { "a watch that begins afresh", false },
          { "typed again, under the new watch", true },
          { "a paste into the watched terminal", true },
          { "a motion in terminal-normal mode", false },
          { "p in terminal-normal mode", true },
          { "P in terminal-normal mode", true },
        }, seen)
      end)
    end)
  end)
end)
