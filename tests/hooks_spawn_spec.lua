-- Spawning Claude with the listener: the command gains `--settings <file>`,
-- the window layer tells the listener where Claude is, and Claude's exit takes
-- the port and the file with it. A shell script stands in for `claude`,
-- writing the arguments it was given to a file.

local config = require("floating-claude.config")
local post = dofile(vim.fn.fnamemodify("tests/helpers/post.lua", ":p"))
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")
local terminal = require("floating-claude.terminal")

describe("spawning Claude", function()
  local compat, hooks_ready, script, argv_out

  before_each(function()
    config.setup({ version_check = false })
    compat = require("floating-claude.compat")
    hooks_ready = compat.hooks_ready
    compat.hooks_ready = function()
      return true
    end
    script, argv_out = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.writefile({ "#!/bin/sh", 'printf "%s\\n" "$@" > "$ARGV_OUT"', "sleep 30" }, script)
    vim.fn.setfperm(script, "rwxr-xr-x")
    state.announced = nil
  end)

  after_each(function()
    terminal.close()
    state.subscribe("spy", nil)
    compat.hooks_ready = hooks_ready
    vim.cmd("silent! only")
    config.setup({})
  end)

  local function spawn()
    terminal.spawn(script, { ARGV_OUT = argv_out }, nil, false)
    assert.is_true(vim.wait(3000, function()
      return vim.uv.fs_stat(argv_out) ~= nil and #vim.fn.readfile(argv_out) > 0
    end))
    return vim.fn.readfile(argv_out)
  end

  it("passes --settings <file> to Claude", function()
    local argv = spawn()
    assert.equals("--settings", argv[1])
    assert.truthy(vim.uv.fs_stat(argv[2]))
    assert.is_true(session.active())
  end)

  it("removes the file and closes the port when Claude exits", function()
    spawn()
    local info = session.info()
    vim.fn.jobstop(state.jobid)
    assert.is_true(vim.wait(3000, function()
      return vim.uv.fs_stat(info.settings_path) == nil
    end))
    assert.equals(0, post.sync(info.port, "t", "{}").code)
  end)

  it("passes the command untouched on the fallback", function()
    config.setup({ version_check = false, hooks = false })
    local argv = spawn()
    assert.is_nil(vim.tbl_contains(argv, "--settings") or nil)
    assert.is_false(session.active())
  end)

  -- :q, <C-w>c or :only on the float bypass the plugin's own moves.
  it("tells the listener when the float is closed by hand", function()
    spawn()
    local seen = {}
    state.subscribe("spy", function(mode)
      table.insert(seen, mode)
    end)
    vim.api.nvim_win_close(state.win, true)
    assert.is_true(vim.wait(500, function()
      return seen[1] == "hidden"
    end))
  end)

  -- Claude's dialog takes Enter, 1 or y: a float that came back on its own
  -- must not hand it the keys you were typing elsewhere.
  it("brings the float back on a request without entering insert mode", function()
    spawn()
    terminal.minimize()
    -- Headless Neovim never applies a pending :startinsert, so watch for it.
    local inserted, cmd = false, vim.cmd
    vim.cmd = setmetatable({}, {
      __call = function(_, c, ...)
        inserted = inserted or c == "startinsert"
        return cmd(c, ...)
      end,
      __index = cmd,
    })
    session.inject({
      event = "PermissionRequest",
      at = require("floating-claude.hooks.record").now_ms(),
      tool_name = "Bash",
      tool_input = { command = "rm -rf build" },
    })
    vim.wait(50)
    vim.cmd = cmd
    assert.equals("float", state.mode())
    assert.is_false(inserted, "an automatic restore entered insert mode")
  end)

  -- Inline mode must not paste over a draft of yours, and the screen cannot
  -- tell one from the prompt Claude Code suggests: what you typed can.
  describe("watching what is typed into Claude", function()
    local send = require("floating-claude.inline.send")
    local record = require("floating-claude.hooks.record")
    local paste, box_readable

    before_each(function()
      paste = vim.paste
      -- The script that stands in for Claude draws no input box.
      box_readable = send.box_readable
      send.box_readable = function()
        return true
      end
    end)

    after_each(function()
      send.box_readable = box_readable
      send.unwatch_typing()
      vim.paste = paste
    end)

    local function type_into_claude()
      vim.api.nvim_set_current_win(state.win)
      vim.paste({ "a draft" }, -1)
    end

    local function submit(extra)
      session.inject(vim.tbl_extend("force", {
        event = "UserPromptSubmit",
        at = record.now_ms(),
        prompt = "go",
        synthetic = false,
      }, extra or {}))
    end

    it("starts when Claude does, and forgets the draft once Claude takes a prompt", function()
      spawn()
      assert.is_false(send.typed())
      type_into_claude()
      assert.is_true(send.typed())
      submit()
      assert.is_false(send.typed())
      assert.is_nil(send.typed_at())
    end)

    it("does not take a prompt Claude Code submitted itself for the draft's", function()
      spawn()
      type_into_claude()
      submit({ synthetic = true })
      assert.is_true(send.typed())
    end)

    it("stops when Claude does", function()
      spawn()
      vim.fn.jobstop(state.jobid)
      assert.is_true(vim.wait(3000, function()
        return not state.buf_valid()
      end))
      assert.equals(paste, vim.paste)
    end)

    it("stops when Claude is closed", function()
      spawn()
      assert.is_not.equals(paste, vim.paste)
      terminal.close()
      assert.equals(paste, vim.paste)
    end)

    it("is not started with inline mode turned off", function()
      config.setup({ version_check = false, inline = { enabled = false } })
      spawn()
      assert.equals(paste, vim.paste)
      type_into_claude()
      assert.is_false(send.typed())
    end)
  end)

  -- Nothing is left to say how an inline request ends once the Claude it went to
  -- has gone, and it would hold the one place for good.
  describe("an inline request in flight", function()
    local inline = require("floating-claude.inline")
    local input = require("floating-claude.inline.input")
    local lines = require("floating-claude.inline.lines")
    local send = require("floating-claude.inline.send")
    local parser = require("floating-claude.parser")
    local file, buf, open, paste, notify, notes, parser_draft

    local function shown()
      local found = vim.api.nvim_buf_get_extmarks(buf, lines.ns, 0, -1, { details = true })
      return found[1]
          and vim.tbl_map(function(chunks)
            return chunks[1][1]
          end, found[1][4].virt_lines)
        or nil
    end

    local function ask()
      inline.ask({ line1 = 1, line2 = 2, mode = "session" })
    end

    before_each(function()
      file = vim.fn.tempname() .. ".lua"
      vim.fn.writefile({ "one", "two" }, file)
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      buf = vim.api.nvim_get_current_buf()
      open, paste, notify, notes = input.open, send.paste, vim.notify, {}
      input.open = function(opts)
        opts.on_submit("add a retry")
      end
      send.paste = function() end
      vim.notify = function(msg)
        -- Not the editor's own chatter (an LSP client attaching to the temp file).
        if not msg:find("^Attached to LSP") then
          table.insert(notes, msg)
        end
      end
      -- The script that stands in for Claude draws no input box, which the gate
      -- reads as a draft: give it an empty one.
      parser_draft = parser.input_draft
      parser.input_draft = function()
        return ""
      end
    end)

    after_each(function()
      inline.clear(buf)
      parser.input_draft = parser_draft
      input.open, send.paste, vim.notify = open, paste, notify
      vim.cmd("enew")
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.fn.delete(file)
    end)

    it("ends as failed when Claude exits, and lets the next one go", function()
      spawn()
      ask()
      assert.is_true(session.inline_active())
      vim.fn.jobstop(state.jobid)
      assert.is_true(vim.wait(3000, function()
        return not state.buf_valid()
      end))
      assert.same({ "▸ add a retry", "Claude exited · start it with :ClaudeCode" }, shown())
      assert.is_false(session.inline_active())
      assert.same({}, notes)
    end)

    it("ends as failed when Claude is closed", function()
      spawn()
      ask()
      terminal.close()
      assert.same({ "▸ add a retry", "Claude exited · start it with :ClaudeCode" }, shown())
      assert.is_false(session.inline_active())
    end)
  end)

  it("tells the listener when Claude is minimized", function()
    spawn()
    local seen = {}
    state.subscribe("spy", function(mode)
      table.insert(seen, mode)
    end)
    terminal.minimize()
    assert.same({ "corner" }, seen)
  end)
end)
