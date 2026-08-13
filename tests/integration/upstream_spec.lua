-- The half of the suite that talks to a real claudecode.nvim.
--
-- Everything under tests/ stubs it into package.loaded, and minimal_init.lua
-- keeps it off the runtimepath on purpose so the "not installed" path stays
-- reachable. That is the right call for the unit suite, and it has a cost: no
-- spec in tests/ can go red because coder/claudecode.nvim moved underneath us.
-- A renamed ensure_visible would sail through CI and only surface in an editor.
--
-- So this file asserts the contract against the real thing, and the Compat
-- workflow runs it on a schedule against claudecode.nvim main and the latest
-- Claude Code CLI.
--
-- Skipped unless FLOATING_CLAUDE_INTEGRATION=1: PlenaryBustedDirectory finds
-- specs with `find -name '*_spec.lua'`, so `make test` recurses in here and
-- would otherwise run these with no claudecode.nvim in sight.
--
--   make test-compat

if os.getenv("FLOATING_CLAUDE_INTEGRATION") ~= "1" then
  describe("upstream", function()
    pending("compatibility specs are off; run `make test-compat`")
  end)
  return
end

local compat = require("floating-claude.compat")
local parser = require("floating-claude.parser")
local provider = require("floating-claude.provider")

local CLAUDECODE_DIR = os.getenv("CLAUDECODE_DIR")
local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

--- The names in a `required_functions = { … }` table literal, read out of Lua
--- source. Upstream keeps its copy as a local inside terminal.lua's provider
--- validation, so there is nothing to require() -- reading the file is the only
--- way to see it, and a parse failure is itself the news worth reporting.
---@param path string
---@return string[]
local function required_functions_in(path)
  local fd = io.open(path, "r")
  assert(fd, "cannot read " .. path)
  local src = fd:read("*a")
  fd:close()

  local block = src:match("required_functions%s*=%s*{(.-)}") or src:match("REQUIRED%s*=%s*{(.-)}")
  assert(block, "no required_functions/REQUIRED table found in " .. path)

  local names = {}
  for name in block:gmatch('"([%w_]+)"') do
    names[#names + 1] = name
  end
  assert(#names > 0, "the provider function list in " .. path .. " parsed as empty")
  table.sort(names)
  return names
end

local function upstream_contract()
  return required_functions_in(CLAUDECODE_DIR .. "/lua/claudecode/terminal.lua")
end

describe("upstream claudecode.nvim", function()
  it("is on the runtimepath", function()
    -- A failed checkout must not be able to look like a green run.
    local ok = pcall(require, "claudecode")
    assert.is_true(ok, "claudecode.nvim did not load from " .. tostring(CLAUDECODE_DIR))
  end)

  it("still exports terminal.ensure_visible", function()
    local ok, terminal = pcall(require, "claudecode.terminal")
    assert.is_true(ok, "claudecode.terminal did not load")
    assert.equals(
      "function",
      type(terminal.ensure_visible),
      "upstream dropped or renamed terminal.ensure_visible; a minimized Claude will pop back over the diff you are reading"
    )
  end)

  it("still ships claudecode.diff", function()
    assert.is_true(
      pcall(require, "claudecode.diff"),
      "upstream dropped claudecode.diff; parser.diff_pending() keys off the buffers it names, so auto-minimize stops firing"
    )
  end)

  it("requires no provider function we do not implement", function()
    local absent = {}
    for _, name in ipairs(upstream_contract()) do
      if type(provider[name]) ~= "function" then
        absent[#absent + 1] = name
      end
    end
    assert.same(
      {},
      absent,
      "claudecode.nvim would reject our provider outright at setup(); implement these in provider.lua"
    )
  end)

  it("has not moved the contract provider_spec.lua mirrors by hand", function()
    -- tests/provider_spec.lua keeps its own copy of this list, which is what
    -- lets the unit suite run without claudecode.nvim. Copies rot; this is the
    -- only place the two can be compared.
    assert.same(
      upstream_contract(),
      required_functions_in(PLUGIN_ROOT .. "/tests/provider_spec.lua"),
      "the REQUIRED list in tests/provider_spec.lua no longer matches claudecode.nvim's required_functions"
    )
  end)

  it("satisfies compat.claudecode() with nothing stubbed", function()
    local report = compat.claudecode()
    assert.is_true(report.installed)
    assert.same({}, report.problems)
  end)
end)

-- parser.lua asks two questions about a diff -- does a proposed buffer exist,
-- and is one on screen -- and the split is only worth its weight because of how
-- upstream ends a denied diff. So drive a real one and watch what it leaves.
--
-- This reaches for diff._setup_blocking_diff, an internal: the public
-- open_diff_blocking wants a coroutine and the MCP deferred-response plumbing
-- around it. A rename would break this spec, which is the kind of news the
-- Compat workflow is for.
describe("a denied diff", function()
  local diff = require("claudecode.diff")
  local target, proposed, resolution

  before_each(function()
    -- Same layout as the same-tab default; where the diff lives does not change
    -- what is left behind, and this needs no terminal to move around.
    diff.setup({ diff_opts = { open_in_new_tab = false } })

    target = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local x = 1", "return x" }, target)
    vim.cmd.edit(vim.fn.fnameescape(target))

    resolution = nil
    diff._setup_blocking_diff({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "local x = 2\nreturn x\n",
      tab_name = "✻ [Claude Code] " .. vim.fn.fnamemodify(target, ":t") .. " (a1b2c3) ⧉",
    }, function(result)
      resolution = result.content and result.content[1] and result.content[1].text
    end)

    proposed = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):find("(proposed)", 1, true) then
        proposed = buf
      end
    end
    assert.is_not_nil(proposed, "upstream created no (proposed) buffer; the diff never opened")
  end)

  after_each(function()
    vim.cmd("silent! tabonly | silent! only")
    if proposed and vim.api.nvim_buf_is_valid(proposed) then
      vim.api.nvim_buf_delete(proposed, { force = true })
    end
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(target)
  end)

  it("is what ClaudeCodeDiffDeny resolves it to", function()
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(proposed)[1])
    diff.deny_current_diff()
    assert.equals("DIFF_REJECTED", resolution)
  end)

  it("stays on screen, so the float stays out of the way", function()
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(proposed)[1])
    diff.deny_current_diff()

    -- deny_current_diff: "Do not close windows/tabs here; just mark as
    -- rejected." Teardown waits for the CLI's close_tab, which may never come.
    assert.is_true(
      parser.diff_visible(),
      "upstream now closes the diff on deny; check the watcher still minimizes"
    )
  end)

  it("leaves its buffer loaded when the user closes it by hand", function()
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(proposed)[1])
    diff.deny_current_diff()
    for _, win in ipairs(vim.fn.win_findbuf(proposed)) do
      vim.api.nvim_win_close(win, true)
    end

    -- The bug this split fixes: scratch + bufhidden="hide" means the buffer
    -- outlives its window, and treating that as a live diff pinned the float in
    -- the corner forever.
    assert.is_true(
      vim.api.nvim_buf_is_loaded(proposed),
      "upstream now deletes the proposed buffer on deny; parser.diff_visible() may have outlived its reason"
    )
    assert.is_true(
      parser.diff_pending(),
      "diff_pending() must still see it -- provider.ensure_visible leans on that"
    )
    assert.is_false(
      parser.diff_visible(),
      "nothing is on screen, so nothing should keep Claude minimized"
    )
  end)

  it("is cleaned up whole once close_tab arrives", function()
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(proposed)[1])
    local tab_name = vim.b[proposed].claudecode_diff_tab_name
    diff.deny_current_diff()
    diff.close_diff_by_tab_name(tab_name)

    assert.is_false(vim.api.nvim_buf_is_loaded(proposed))
    assert.is_false(parser.diff_pending())
    assert.is_false(parser.diff_visible())
  end)
end)

describe("the Claude Code CLI", function()
  it("is on PATH", function()
    assert.equals(1, vim.fn.executable("claude"), "no claude binary; the install step did not take")
  end)

  it("is at or above the floor compat.lua declares", function()
    local version = compat.cli_version("claude")
    assert.is_not_nil(version, "could not read a version out of `claude --version`")
    assert.is_false(
      compat.older(version, compat.minimum.claude_code),
      ("Claude Code %s is below the %s minimum parser.lua targets"):format(
        tostring(version),
        compat.minimum.claude_code
      )
    )
  end)
end)
