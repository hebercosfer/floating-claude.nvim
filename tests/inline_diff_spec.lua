-- An inline request's diffs: claudecode.nvim's layout swapped for the turn, and
-- a diff for the request's file handed to the window you asked from.
--
-- claudecode.nvim is a stub here: its config table, a validator that knows the
-- unified layout, and the active-diffs table the handoff reaches into. A diff
-- "opens" the way claudecode.nvim's unified layout opens one in the current tab
-- -- a vsplit showing a scratch buffer that is wiped once hidden -- and fires
-- the same User events. tests/integration/inline_diff_spec.lua runs the same
-- handoff against the real claudecode.nvim.

local config = require("floating-claude.config")
local diff = require("floating-claude.inline.diff")
local lines = require("floating-claude.inline.lines")

local STUBBED = { "claudecode", "claudecode.config", "claudecode.diff", "claudecode.diff_inline" }

-- What the lines say in a buffer, and the row they hang from.
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

describe("inline diffs", function()
  local diff_opts, active_diffs, resolved, seen
  local file, buf, win, other_win, changes, restored
  local saved_restore

  -- claudecode.nvim with the unified layout and the internals the handoff uses.
  local function install(opts)
    opts = opts or {}
    package.loaded["claudecode"] = { state = { config = { diff_opts = diff_opts } } }
    package.loaded["claudecode.config"] = {
      apply = function(user)
        local layout = vim.tbl_get(user, "diff_opts", "layout")
        assert(
          layout == nil
            or layout == "vertical"
            or layout == "horizontal"
            or (layout == "unified" and not opts.no_unified),
          "diff_opts.layout must be 'vertical' or 'horizontal'"
        )
        return user
      end,
    }
    package.loaded["claudecode.diff"] = {
      _get_active_diffs = function()
        return active_diffs
      end,
    }
    package.loaded["claudecode.diff_inline"] = {}
  end

  local function ctx()
    return {
      file = file,
      win = win,
      buf = buf,
      on_change = function()
        changes = changes + 1
      end,
      items = function()
        return { "▸ add a retry", "Claude: on it" }
      end,
    }
  end

  -- Open a diff the way claudecode.nvim's unified layout does, in a vsplit of
  -- the current tab, and fire ClaudeCodeDiffOpened. Rows 2-3 are the change.
  local function open(tab_name, path)
    local prev = vim.api.nvim_get_current_win()
    local dbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(dbuf, tab_name .. " (unified diff)")
    vim.bo[dbuf].buftype = "acwrite"
    vim.bo[dbuf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, { "one", "two", "TWO", "three" })
    vim.bo[dbuf].modifiable = false
    vim.b[dbuf].claudecode_inline_diff = true
    vim.cmd("rightbelow vsplit")
    local dwin = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(dwin, dbuf)
    vim.api.nvim_win_set_cursor(dwin, { 2, 0 })
    vim.api.nvim_set_current_win(prev)
    active_diffs[tab_name] = {
      new_buffer = dbuf,
      new_window = dwin,
      status = "pending",
      line_types = { "unchanged", "removed", "added", "unchanged" },
      resolution_callback = function(result)
        resolved = result.content[1].text
        seen = vim.api.nvim_win_get_buf(win)
      end,
    }
    vim.api.nvim_exec_autocmds("User", {
      pattern = "ClaudeCodeDiffOpened",
      data = {
        tab_name = tab_name,
        file_path = path or file,
        new_file_path = path or file,
        diff_window = dwin,
        target_window = prev,
      },
    })
    return dbuf, dwin
  end

  -- Answer a diff as claudecode.nvim does: the status, then the callback.
  local function answer(tab_name, text)
    local entry = active_diffs[tab_name]
    entry.status = text == "FILE_SAVED" and "saved" or "rejected"
    entry.resolution_callback({ content = { { type = "text", text = text } } })
  end

  -- close_tab's cleanup: the diff's window and buffer go, then the event.
  local function close(tab_name)
    local entry = active_diffs[tab_name]
    if vim.api.nvim_win_is_valid(entry.new_window) then
      vim.api.nvim_win_close(entry.new_window, true)
    end
    if vim.api.nvim_buf_is_valid(entry.new_buffer) then
      vim.api.nvim_buf_delete(entry.new_buffer, { force = true })
    end
    active_diffs[tab_name] = nil
    vim.api.nvim_exec_autocmds("User", {
      pattern = "ClaudeCodeDiffClosed",
      data = { tab_name = tab_name, file_path = file, reason = "closed" },
    })
  end

  before_each(function()
    config.setup({})
    diff_opts = { layout = "vertical", open_in_new_tab = true }
    active_diffs, resolved, seen, changes, restored = {}, nil, nil, 0, 0
    install()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    file = dir .. "/net.lua"
    vim.fn.writefile({ "one", "two", "three" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    buf = vim.api.nvim_get_current_buf()
    win = vim.api.nvim_get_current_win()
    -- Two windows in the tab: the case where claudecode.nvim's cleanup would
    -- close the one showing its buffer.
    vim.cmd("vsplit")
    other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(other_win, vim.api.nvim_create_buf(true, false))
    vim.api.nvim_set_current_win(win)
    saved_restore = require("floating-claude").restore
    require("floating-claude").restore = function()
      restored = restored + 1
    end
  end)

  after_each(function()
    diff.finish()
    -- Every diff a spec left open, so none of it is still handed over.
    for _, name in ipairs(vim.tbl_keys(active_diffs)) do
      close(name)
    end
    require("floating-claude").restore = saved_restore
    for _, name in ipairs(STUBBED) do
      package.loaded[name] = nil
    end
    vim.cmd("silent! tabonly | silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(vim.fn.fnamemodify(file, ":h"), "rf")
    config.setup({})
  end)

  describe("the layout swap", function()
    it("makes an inline turn's diffs unified, in the current tab", function()
      diff.begin(ctx())
      assert.equals("unified", diff_opts.layout)
      assert.is_false(diff_opts.open_in_new_tab)
    end)

    it("puts both back when the request ends", function()
      diff.begin(ctx())
      diff.finish()
      assert.equals("vertical", diff_opts.layout)
      assert.is_true(diff_opts.open_in_new_tab)
    end)

    it("puts back a value that was never set as unset", function()
      diff_opts.layout, diff_opts.open_in_new_tab = nil, nil
      diff.begin(ctx())
      diff.finish()
      assert.is_nil(diff_opts.layout)
      assert.is_nil(diff_opts.open_in_new_tab)
    end)

    it("does it once, however often it is asked to finish", function()
      diff.begin(ctx())
      diff.finish()
      diff_opts.layout = "horizontal"
      diff.finish()
      assert.equals("horizontal", diff_opts.layout)
    end)

    it("keeps your layout with diff_layout = false, and the tab with it", function()
      config.setup({ inline = { diff_layout = false } })
      diff.begin(ctx())
      assert.equals("vertical", diff_opts.layout)
      -- Only a unified diff can be handed to your window.
      assert.is_true(diff_opts.open_in_new_tab)
    end)

    it("keeps the tab with diff_in_window = false", function()
      config.setup({ inline = { diff_in_window = false } })
      diff.begin(ctx())
      assert.equals("unified", diff_opts.layout)
      assert.is_true(diff_opts.open_in_new_tab)
    end)

    it("changes nothing for a claudecode.nvim without the unified layout", function()
      install({ no_unified = true })
      diff.begin(ctx())
      assert.equals("vertical", diff_opts.layout)
      assert.is_true(diff_opts.open_in_new_tab)
    end)

    it("is not done without claudecode.nvim", function()
      for _, name in ipairs(STUBBED) do
        package.loaded[name] = nil
      end
      diff.begin(ctx())
      diff.finish()
      assert.is_false(diff.active())
    end)
  end)

  describe("a diff for the request's file", function()
    it("is shown in the window you asked from, and claudecode.nvim's is closed", function()
      diff.begin(ctx())
      local dbuf, dwin = open("a")
      assert.equals(dbuf, vim.api.nvim_win_get_buf(win))
      assert.is_false(vim.api.nvim_win_is_valid(dwin))
      assert.equals(win, vim.api.nvim_get_current_win())
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
      assert.equals("pending", active_diffs.a.status)
      assert.is_true(diff.active())
    end)

    it("puts the cursor on the first change", function()
      diff.begin(ctx())
      open("a")
      assert.equals(2, vim.api.nvim_win_get_cursor(win)[1])
    end)

    it("carries the inline lines under its first hunk, with <CR> to open Claude", function()
      diff.begin(ctx())
      local dbuf = open("a")
      local row, texts = shown(dbuf)
      assert.equals(2, row)
      assert.same({ "▸ add a retry", "Claude: on it" }, texts)
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      assert.equals(1, restored)
    end)

    it("redraws those lines when the request's change", function()
      local c = ctx()
      local said = "Claude: on it"
      c.items = function()
        return { "▸ add a retry", said }
      end
      diff.begin(c)
      local dbuf = open("a")
      said = "Claude: done"
      diff.redraw()
      local _, texts = shown(dbuf)
      assert.same({ "▸ add a retry", "Claude: done" }, texts)
    end)

    it("gives your file back the moment it is answered, then answers claudecode.nvim", function()
      diff.begin(ctx())
      local dbuf = open("a")
      answer("a", "DIFF_REJECTED")
      -- Synchronously: close_tab answers a pending diff and deletes its buffer
      -- in one call, so a scheduled switch would come too late.
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
      assert.equals("DIFF_REJECTED", resolved)
      assert.equals(buf, seen, "claudecode.nvim's callback ran before the switch")
      assert.is_true(vim.api.nvim_buf_is_valid(dbuf), "the hidden diff buffer must not be wiped")
      assert.equals("hide", vim.bo[dbuf].bufhidden)
    end)

    it("still answers claudecode.nvim when giving the window back fails", function()
      diff.begin(ctx())
      open("a")
      local set_buf = vim.api.nvim_win_set_buf
      vim.api.nvim_win_set_buf = function()
        error("boom")
      end
      local ok = pcall(answer, "a", "FILE_SAVED")
      vim.api.nvim_win_set_buf = set_buf
      assert.is_true(ok)
      assert.equals("FILE_SAVED", resolved)
    end)

    it("is given back again after a :w, which puts the diff back in its window", function()
      diff.begin(ctx())
      local dbuf = open("a")
      answer("a", "FILE_SAVED")
      -- What Neovim does once a BufWriteCmd returns.
      vim.api.nvim_win_set_buf(win, dbuf)
      vim.wait(50)
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
    end)

    it("leaves your window and the other one open when claudecode.nvim cleans up", function()
      diff.begin(ctx())
      open("a")
      answer("a", "FILE_SAVED")
      vim.fn.writefile({ "one", "TWO", "three" }, file)
      close("a")
      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.is_true(vim.api.nvim_win_is_valid(other_win))
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
    end)

    it("reloads your file once closed, with the cursor on the change, and says so", function()
      diff.begin(ctx())
      open("a")
      answer("a", "FILE_SAVED")
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      -- A file written within the same second can look unchanged to :checktime.
      vim.fn.writefile({ "one", "TWO", "three", "four" }, file)
      vim.uv.fs_utime(file, os.time() + 5, os.time() + 5)
      close("a")
      assert.same({ "one", "TWO", "three", "four" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.equals(2, vim.api.nvim_win_get_cursor(win)[1])
      assert.equals(1, changes)
      assert.is_false(diff.active())
    end)

    it("gives your file back when closed without an answer, as at shutdown", function()
      -- With one window: with two, Neovim closes the one showing a buffer that
      -- is deleted, and only an answer comes early enough to prevent it.
      vim.api.nvim_win_close(other_win, true)
      diff.begin(ctx())
      open("a")
      close("a")
      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
    end)

    describe("and the watcher", function()
      local state = require("floating-claude.state")
      local watcher = require("floating-claude.watcher")
      local mode, moves

      local handlers = {
        minimize = function()
          table.insert(moves, "minimize")
        end,
        restore = function()
          table.insert(moves, "restore")
        end,
      }

      before_each(function()
        mode, moves = state.mode, {}
        state.mode = function()
          return "float"
        end
        state.before_diff, state.last_mode = nil, "float"
      end)

      after_each(function()
        state.mode = mode
        state.before_diff, state.last_mode = nil, nil
      end)

      it("leaves the float alone while the diff is in your window, and after", function()
        diff.begin(ctx())
        open("✻ [Claude Code] net.lua ⧉")
        watcher.diff_step(handlers, false)
        assert.same({}, moves)
        assert.is_nil(state.before_diff)
        answer("✻ [Claude Code] net.lua ⧉", "FILE_SAVED")
        close("✻ [Claude Code] net.lua ⧉")
        watcher.diff_step(handlers, false)
        assert.same({}, moves)
      end)

      it("still minimizes for a diff it was not handed", function()
        config.setup({ inline = { diff_in_window = false } })
        diff.begin(ctx())
        local _, dwin = open("✻ [Claude Code] net.lua ⧉")
        watcher.diff_step(handlers, false)
        assert.same({ "minimize" }, moves)
        vim.api.nvim_win_close(dwin, true)
        active_diffs["✻ [Claude Code] net.lua ⧉"] = nil
      end)
    end)

    it("is left where it opened with diff_in_window = false", function()
      config.setup({ inline = { diff_in_window = false } })
      diff.begin(ctx())
      local dbuf, dwin = open("a")
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
      assert.equals(dbuf, vim.api.nvim_win_get_buf(dwin))
      assert.is_false(diff.active())
    end)

    it("is left where it opened when claudecode.nvim hands back no callback to wrap", function()
      diff.begin(ctx())
      local prev = vim.api.nvim_get_current_win()
      local dbuf = vim.api.nvim_create_buf(false, true)
      vim.cmd("rightbelow vsplit")
      local dwin = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(dwin, dbuf)
      vim.api.nvim_set_current_win(prev)
      active_diffs.a = { new_buffer = dbuf, new_window = dwin, status = "pending" }
      vim.api.nvim_exec_autocmds("User", {
        pattern = "ClaudeCodeDiffOpened",
        data = { tab_name = "a", file_path = file, diff_window = dwin },
      })
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
      assert.equals(dbuf, vim.api.nvim_win_get_buf(dwin))
      assert.is_false(diff.active())
    end)

    it("is left where it opened once the request is over", function()
      diff.begin(ctx())
      diff.finish()
      local dbuf, dwin = open("a")
      assert.equals(dbuf, vim.api.nvim_win_get_buf(dwin))
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
    end)
  end)

  describe("a diff for another file", function()
    it("is not handed to your window: it stays where claudecode.nvim opened it", function()
      diff.begin(ctx())
      local dbuf, dwin = open("a", vim.fn.fnamemodify(file, ":h") .. "/other.lua")
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
      assert.equals(dbuf, vim.api.nvim_win_get_buf(dwin))
      assert.is_false(diff.active())
    end)

    it("does not stop the next diff for the request's file from being handed over", function()
      diff.begin(ctx())
      open("a", vim.fn.fnamemodify(file, ":h") .. "/other.lua")
      local dbuf = open("b")
      assert.equals(dbuf, vim.api.nvim_win_get_buf(win))
    end)
  end)

  describe("finishing while a handed diff is open", function()
    it("waits for the diff to close before putting the layout back", function()
      diff.begin(ctx())
      open("a")
      diff.finish()
      assert.equals("unified", diff_opts.layout)
      assert.is_true(diff.active())
      close("a")
      assert.equals("vertical", diff_opts.layout)
      assert.is_true(diff_opts.open_in_new_tab)
      assert.is_false(diff.active())
    end)

    it("does not hand over a later diff in the meantime", function()
      diff.begin(ctx())
      open("a")
      diff.finish()
      local dbuf, dwin = open("b")
      assert.equals(dbuf, vim.api.nvim_win_get_buf(dwin))
    end)

    it("puts the layout back once it is answered, if claudecode.nvim never closes it", function()
      diff.begin(ctx())
      open("a")
      diff.finish()
      answer("a", "FILE_SAVED")
      vim.wait(50)
      assert.equals("vertical", diff_opts.layout)
      assert.is_false(diff.active())
    end)
  end)

  -- The diff, wired into a session-mode request.
  describe("of a session-mode request", function()
    local inline = require("floating-claude.inline")
    local input = require("floating-claude.inline.input")
    local parser = require("floating-claude.parser")
    local record = require("floating-claude.hooks.record")
    local send = require("floating-claude.inline.send")
    local session = require("floating-claude.hooks.session")
    local state = require("floating-claude.state")

    local claude, pasted
    local saved = {}

    local function stub(tbl, name, fn)
      table.insert(saved, { tbl, name, tbl[name] })
      tbl[name] = fn
    end

    before_each(function()
      session.start_scripted()
      claude = vim.api.nvim_create_buf(false, true)
      state.buf = claude
      state.jobid = vim.fn.jobstart({ "cat" })
      pasted = {}
      stub(send, "paste", function(_, text)
        table.insert(pasted, text)
      end)
      stub(input, "open", function(opts)
        opts.on_submit("add a retry")
      end)
      stub(parser, "input_draft", function()
        return ""
      end)
      stub(parser, "status", function()
        return { working = false }
      end)
      stub(vim, "notify", function() end)
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
      if vim.api.nvim_buf_is_valid(claude) then
        vim.api.nvim_buf_delete(claude, { force = true })
      end
    end)

    local function ask()
      inline.ask({ line1 = 2, line2 = 2, mode = "session" })
    end

    local function submitted()
      session.inject({
        event = "UserPromptSubmit",
        at = record.now_ms(),
        prompt = pasted[1],
        synthetic = false,
      })
    end

    it("swaps the layout once the request is sent", function()
      ask()
      assert.equals(1, #pasted)
      assert.equals("unified", diff_opts.layout)
    end)

    it("does not swap it for a request that waits behind another turn", function()
      session.inject({
        event = "UserPromptSubmit",
        at = record.now_ms(),
        prompt = "something else",
        synthetic = false,
      })
      ask()
      assert.equals(0, #pasted)
      assert.equals("vertical", diff_opts.layout)
    end)

    it("hands the request's diff to the window it was asked from", function()
      ask()
      submitted()
      local dbuf = open("a")
      assert.equals(dbuf, vim.api.nvim_win_get_buf(win))
      local _, texts = shown(dbuf)
      assert.same({ "▸ add a retry" }, texts)
    end)

    it("puts the layout back when the turn ends", function()
      ask()
      submitted()
      session.inject({ event = "Stop", at = record.now_ms(), message = "done" })
      assert.equals("vertical", diff_opts.layout)
      assert.is_true(diff_opts.open_in_new_tab)
    end)

    it("puts it back when Claude's session ends during the diff, once the diff goes", function()
      ask()
      submitted()
      open("a")
      session.inject({ event = "SessionEnd", at = record.now_ms() })
      -- claudecode.nvim closes a gone client's pending diffs: rejected, then cleaned up.
      answer("a", "DIFF_REJECTED")
      close("a")
      assert.equals("vertical", diff_opts.layout)
      assert.is_true(diff_opts.open_in_new_tab)
      assert.is_true(vim.api.nvim_win_is_valid(win))
      assert.equals(buf, vim.api.nvim_win_get_buf(win))
    end)

    it("puts it back when Claude's job exits", function()
      ask()
      inline.claude_exited()
      assert.equals("vertical", diff_opts.layout)
    end)

    it("puts it back when the lines are cleared", function()
      ask()
      inline.clear(buf)
      assert.equals("vertical", diff_opts.layout)
    end)

    it("redraws the lines in your file once the diff has changed it", function()
      ask()
      submitted()
      open("a")
      answer("a", "FILE_SAVED")
      vim.fn.writefile({ "zero", "one", "two", "TWO", "three" }, file)
      vim.uv.fs_utime(file, os.time() + 5, os.time() + 5)
      close("a")
      local row, texts = shown(buf)
      -- Two lines more above or in the range: the lines move down with it.
      assert.equals(3, row)
      assert.same({ "▸ add a retry" }, texts)
    end)
  end)
end)
