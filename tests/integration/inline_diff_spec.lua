-- An inline request's diff handed to the window it was asked from, against the
-- real claudecode.nvim: its unified layout, its cleanup, and the internals the
-- handoff reaches into (`_get_active_diffs()` and a diff's
-- `resolution_callback`). A rename upstream turns this red.
--
-- No Claude Code here: each spec drives open_diff_blocking from a coroutine,
-- as claudecode.nvim's openDiff tool does, and plays the CLI's part after the
-- answer -- it writes the accepted text, then calls close_diff_by_tab_name, as
-- the CLI's close_tab does.
--
--   make test-compat

if os.getenv("FLOATING_CLAUDE_INTEGRATION") ~= "1" then
  describe("inline diff (upstream)", function()
    pending("compatibility specs are off; run `make test-compat`")
  end)
  return
end

local compat = require("floating-claude.compat")
local diff = require("floating-claude.inline.diff")

local OLD = { "local function fetch(url)", "  return http.get(url)", "end", "", "return fetch" }
local NEW = {
  "local function fetch(url)",
  "  for attempt = 1, 4 do",
  "    local ok, res = pcall(http.get, url)",
  "    if ok then return res end",
  "  end",
  "end",
  "",
  "return fetch",
}

local function joined(lines)
  return table.concat(lines, "\n") .. "\n"
end

describe("an inline diff with the real claudecode.nvim", function()
  local cc_diff = require("claudecode.diff")
  local tab_name = "✻ [Claude Code] fetch.lua (inline) ⧉"
  local file, buf, win, other_win, result, changes
  local diff_opts, before

  local done = false
  before_each(function()
    if not done then
      require("floating-claude").setup({ claudecode = { auto_start = false, log_level = "warn" } })
      done = true
    end
    diff_opts = require("claudecode").state.config.diff_opts
    before = { layout = diff_opts.layout, open_in_new_tab = diff_opts.open_in_new_tab }

    file = vim.fn.tempname() .. "-fetch.lua"
    vim.fn.writefile(OLD, file)
    vim.cmd.edit(vim.fn.fnameescape(file))
    buf = vim.api.nvim_get_current_buf()
    win = vim.api.nvim_get_current_win()
    -- Two windows: with one, claudecode.nvim's cleanup would leave yours open
    -- whatever the handoff did.
    vim.cmd("vnew")
    other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)

    result, changes = nil, 0
    diff.begin({
      file = file,
      win = win,
      buf = buf,
      on_change = function()
        changes = changes + 1
      end,
      items = function()
        return { "▸ add a retry" }
      end,
    })

    local co = coroutine.create(function()
      result = cc_diff.open_diff_blocking(file, file, joined(NEW), tab_name)
    end)
    _G.claude_deferred_responses = _G.claude_deferred_responses or {}
    _G.claude_deferred_responses[tostring(co)] = function() end
    local ok, err = coroutine.resume(co)
    assert(ok, vim.inspect(err))
    -- What claudecode.nvim schedules after a diff opens (a hidden-buffer reject
    -- on later revisions) has run.
    vim.wait(100)
  end)

  after_each(function()
    pcall(cc_diff.close_diff_by_tab_name, tab_name)
    diff.finish()
    vim.cmd("silent! tabonly | silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(file)
  end)

  local function status()
    local entry = cc_diff._get_active_diffs()[tab_name]
    return entry and entry.status or "gone"
  end

  local function answer_text()
    return result and result.content and result.content[1] and result.content[1].text
  end

  -- The CLI's part once Neovim has its answer: write the file if it was
  -- accepted, then close_tab, then claudecode.nvim's 100 ms reload. close_tab
  -- comes back over the WebSocket after the answer went out, so never in the
  -- same tick as a Neovim answer: the wait stands in for that round trip,
  -- which the `:w` path relies on (the window is given back a second time on
  -- the next tick, after Neovim puts the diff back once BufWriteCmd returns).
  local function cli_closes(text)
    vim.wait(50)
    if text then
      vim.fn.writefile(vim.split(text, "\n", { plain = true, trimempty = true }), file)
      vim.uv.fs_utime(file, os.time() + 5, os.time() + 5)
    end
    cc_diff.close_diff_by_tab_name(tab_name)
    vim.wait(200)
  end

  it("passes the capability check", function()
    assert.is_true(compat.unified_diff())
  end)

  it("is handed to the window it was asked from, still pending", function()
    assert.equals("pending", status())
    assert.equals("unified", diff_opts.layout)
    local shows = vim.api.nvim_win_get_buf(win)
    assert.is_true(
      vim.b[shows].claudecode_inline_diff == true,
      "the origin window shows no unified diff"
    )
    assert.equals(1, #vim.api.nvim_list_tabpages())
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.equals(2, vim.api.nvim_win_get_cursor(win)[1], "the cursor is not on the first change")
    assert.is_true(diff.active())
  end)

  it("writes the file on :w, and your window shows it", function()
    vim.api.nvim_set_current_win(win)
    vim.cmd("write")
    assert.equals("FILE_SAVED", answer_text())
    cli_closes(result.content[2].text)

    assert.is_true(vim.api.nvim_win_is_valid(win), "the origin window was closed")
    assert.is_true(vim.api.nvim_win_is_valid(other_win))
    assert.equals(buf, vim.api.nvim_win_get_buf(win))
    assert.same(NEW, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.same(NEW, vim.fn.readfile(file))
    assert.equals(1, changes)
    assert.is_false(diff.active())
  end)

  it("leaves the file as it was on ClaudeCodeDiffDeny, with your window intact", function()
    vim.api.nvim_set_current_win(win)
    vim.cmd("ClaudeCodeDiffDeny")
    assert.equals("DIFF_REJECTED", answer_text())
    cli_closes(nil)

    assert.is_true(vim.api.nvim_win_is_valid(win), "the origin window was closed")
    assert.is_true(vim.api.nvim_win_is_valid(other_win))
    assert.equals(buf, vim.api.nvim_win_get_buf(win))
    assert.same(OLD, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.same(OLD, vim.fn.readfile(file))
  end)

  it("keeps your window when the answer comes from Claude's own prompt", function()
    -- A "yes" there: the CLI writes the file and closes a diff still pending,
    -- which claudecode.nvim answers as rejected and deletes in the same call.
    vim.fn.writefile(NEW, file)
    vim.uv.fs_utime(file, os.time() + 5, os.time() + 5)
    cli_closes(nil)
    assert.equals("DIFF_REJECTED", answer_text())

    assert.is_true(vim.api.nvim_win_is_valid(win), "the origin window was closed")
    assert.equals(buf, vim.api.nvim_win_get_buf(win))
    assert.same(NEW, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it(
    "leaves another file's diff out of your window, unified where claudecode.nvim puts it",
    function()
      local other = vim.fn.tempname() .. "-other.lua"
      vim.fn.writefile({ "return 1" }, other)
      local other_tab = "✻ [Claude Code] other.lua (inline) ⧉"
      local co = coroutine.create(function()
        cc_diff.open_diff_blocking(other, other, "return 2\n", other_tab)
      end)
      _G.claude_deferred_responses[tostring(co)] = function() end
      assert(coroutine.resume(co))
      vim.wait(100)

      local entry = cc_diff._get_active_diffs()[other_tab]
      assert.is_not_nil(entry, "the second diff never opened")
      assert.equals("pending", entry.status)
      -- The turn's layout, in the current tab: the swap is global.
      assert.equals("unified", entry.layout)
      assert.equals(1, #vim.api.nvim_list_tabpages())
      assert.is_true(vim.api.nvim_win_is_valid(entry.new_window))
      assert.are_not.equal(win, entry.new_window)
      -- Your window still holds the request's own diff, not this one.
      assert.are_not.equal(entry.new_buffer, vim.api.nvim_win_get_buf(win))
      assert.is_true(vim.b[vim.api.nvim_win_get_buf(win)].claudecode_inline_diff == true)
      assert.is_true(diff.active())

      cc_diff.close_diff_by_tab_name(other_tab)
      vim.fn.delete(other)
    end
  )

  it(
    "puts claudecode.nvim's diff options back once the diff is closed and the request over",
    function()
      diff.finish()
      assert.equals("unified", diff_opts.layout)
      cli_closes(nil)
      assert.equals(before.layout, diff_opts.layout)
      assert.equals(before.open_in_new_tab, diff_opts.open_in_new_tab)
    end
  )
end)
