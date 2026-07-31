local config = require("floating-claude.config")

-- compat.check() warns once per session, so specs that exercise it need a fresh
-- copy of the module.
local function fresh_compat()
  package.loaded["floating-claude.compat"] = nil
  return require("floating-claude.compat")
end

-- A stand-in for the CLI, so version checks never depend on what is installed.
local function stub_cli(output, exit_code)
  local path = vim.fn.tempname()
  vim.fn.writefile(
    { "#!/bin/sh", ("echo '%s'"):format(output), ("exit %d"):format(exit_code or 0) },
    path
  )
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path
end

local function stub_claudecode(overrides)
  overrides = overrides or {}
  package.loaded["claudecode"] = {
    get_version = function()
      return { version = overrides.version or "0.2.0" }
    end,
  }
  package.loaded["claudecode.terminal"] = {
    ensure_visible = overrides.ensure_visible ~= false and function() end or nil,
  }
  if overrides.diff ~= false then
    package.loaded["claudecode.diff"] = {}
  end
end

local function unstub_claudecode()
  package.loaded["claudecode"] = nil
  package.loaded["claudecode.terminal"] = nil
  package.loaded["claudecode.diff"] = nil
end

describe("compat", function()
  local compat = require("floating-claude.compat")

  after_each(function()
    unstub_claudecode()
    config.setup({})
  end)

  describe("older", function()
    it("compares by component, not lexically", function()
      assert.is_true(compat.older("2.0.9", "2.1.0"))
      assert.is_true(compat.older("1.99.99", "2.0.0"))
      assert.is_false(compat.older("2.1.220", "2.1.0"))
      assert.is_false(compat.older("2.1.0", "2.1.0"))
    end)

    it("reads a version out of decorated output", function()
      assert.is_false(compat.older("2.1.220 (Claude Code)", "2.1.0"))
      assert.is_true(compat.older("v0.1.0-53-gabc1234", "0.2.0"))
    end)

    it("treats a two-component version as x.y.0", function()
      assert.is_true(compat.older("0.1", "0.2.0"))
      assert.is_false(compat.older("0.2", "0.2.0"))
    end)

    it("never reports unparseable input as too old", function()
      assert.is_false(compat.older(nil, "2.1.0"))
      assert.is_false(compat.older("unknown", "2.1.0"))
      assert.is_false(compat.older(42, "2.1.0"))
    end)
  end)

  describe("the pinned pair", function()
    it("is at least the minimum it demands", function()
      assert.is_false(compat.older(compat.tested.claude_code, compat.minimum.claude_code))
      assert.is_false(compat.older(compat.tested.claudecode.version, compat.minimum.claudecode))
    end)
  end)

  describe("claudecode", function()
    it("reports a missing claudecode.nvim", function()
      local report = compat.claudecode()
      assert.is_false(report.installed)
      assert.equals(1, #report.problems)
    end)

    it("is happy with a current claudecode.nvim", function()
      stub_claudecode()
      local report = compat.claudecode()
      assert.is_true(report.installed)
      assert.equals("0.2.0", report.version)
      assert.same({}, report.problems)
    end)

    it("flags a version below the floor", function()
      stub_claudecode({ version = "0.1.0" })
      local problems = compat.claudecode().problems
      assert.equals(1, #problems)
      assert.is_not_nil(problems[1]:find("older than", 1, true))
    end)

    -- The version field lags the tags, so the features are what really matter.
    it("flags a missing ensure_visible even on a current version", function()
      stub_claudecode({ ensure_visible = false })
      local problems = compat.claudecode().problems
      assert.equals(1, #problems)
      assert.is_not_nil(problems[1]:find("ensure_visible", 1, true))
    end)

    it("flags a missing diff module", function()
      stub_claudecode({ diff = false })
      local problems = compat.claudecode().problems
      assert.equals(1, #problems)
      assert.is_not_nil(problems[1]:find("claudecode.diff", 1, true))
    end)
  end)

  describe("cli_version", function()
    it("reads the version the CLI prints", function()
      assert.equals("2.1.220", compat.cli_version(stub_cli("2.1.220 (Claude Code)")))
    end)

    it("takes the binary from a command with arguments", function()
      assert.equals("2.1.220", compat.cli_version(stub_cli("2.1.220 (Claude Code)") .. " --resume"))
    end)

    it("is nil when the CLI fails or is absent", function()
      assert.is_nil(compat.cli_version(stub_cli("boom", 1)))
      assert.is_nil(compat.cli_version("/nonexistent/claude"))
    end)
  end)

  describe("check", function()
    local notified

    before_each(function()
      notified = nil
      stub_claudecode()
    end)

    local function capture(cmd_string)
      local original = vim.notify
      vim.notify = function(msg, level)
        notified = { msg = msg, level = level }
      end
      fresh_compat().check(cmd_string)
      vim.wait(3000, function()
        return notified ~= nil
      end)
      vim.notify = original
    end

    it("stays quiet on a supported pair", function()
      capture(stub_cli(compat.tested.claude_code))
      assert.is_nil(notified)
    end)

    it("warns once about an old CLI", function()
      capture(stub_cli("1.9.3 (Claude Code)"))
      assert.is_not_nil(notified)
      assert.equals(vim.log.levels.WARN, notified.level)
      assert.is_not_nil(notified.msg:find("1.9.3", 1, true))
      assert.is_not_nil(notified.msg:find(tostring(require("floating-claude.version")), 1, true))
    end)

    it("reports both sides in one warning", function()
      stub_claudecode({ version = "0.1.0" })
      capture(stub_cli("1.9.3 (Claude Code)"))
      assert.is_not_nil(notified)
      assert.is_not_nil(notified.msg:find("claudecode.nvim 0.1.0", 1, true))
      assert.is_not_nil(notified.msg:find("Claude Code 1.9.3", 1, true))
    end)

    it("says nothing when version_check is off", function()
      config.setup({ version_check = false })
      capture(stub_cli("1.9.3 (Claude Code)"))
      assert.is_nil(notified)
    end)
  end)
end)
