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
