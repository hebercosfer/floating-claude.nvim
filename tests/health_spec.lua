-- :checkhealth floating-claude, the inline mode section: what it tells you
-- about the three things inline mode leans on (Claude's hooks, a claudecode.nvim
-- that can show an edit unified, and the key), and what it says when one is
-- missing. Everything the section asks is stubbed, so the specs say what it
-- reports, not what happens to be installed.

local compat = require("floating-claude.compat")
local config = require("floating-claude.config")
local health = require("floating-claude.health")
local keymaps = require("floating-claude.keymaps")
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")

describe("health: inline mode", function()
  local reported, saved, buffers, answers, asked, claudecode

  -- What the section said, in order.
  local function say(level)
    return function(msg, advice)
      table.insert(reported, { level = level, msg = msg, advice = advice })
    end
  end

  local function lines(level)
    return vim.tbl_filter(function(r)
      return r.level == level
    end, reported)
  end

  local function mentions(entries, needle)
    for _, r in ipairs(entries) do
      if r.msg:find(needle, 1, true) then
        return r
      end
    end
  end

  local function claude_running()
    local buf = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, buf)
    state.buf = buf
  end

  before_each(function()
    reported, buffers = {}, {}
    saved = {
      start = vim.health.start,
      ok = vim.health.ok,
      warn = vim.health.warn,
      info = vim.health.info,
      error = vim.health.error,
      unified_diff = compat.unified_diff,
      cli_version = compat.cli_version,
      claudecode = compat.claudecode,
      info_fn = session.info,
    }
    for _, level in ipairs({ "start", "ok", "warn", "info", "error" }) do
      vim.health[level] = say(level)
    end
    -- What the CLI says its version is, and the command it was asked about.
    answers, asked = { cli = "2.1.318", unified = true }, {}
    claudecode = package.loaded["claudecode"]
    compat.unified_diff = function()
      return answers.unified
    end
    compat.cli_version = function(cmd)
      table.insert(asked, cmd)
      return answers.cli
    end
    compat.claudecode = function()
      return { installed = true, problems = {} }
    end
    session.info = function()
      return { active = true, port = 40321 }
    end
    config.setup({})
    keymaps.apply()
  end)

  after_each(function()
    for _, level in ipairs({ "start", "ok", "warn", "info", "error" }) do
      vim.health[level] = saved[level]
    end
    compat.unified_diff, compat.cli_version, compat.claudecode =
      saved.unified_diff, saved.cli_version, saved.claudecode
    package.loaded["claudecode"] = claudecode
    session.info = saved.info_fn
    for _, b in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    state.buf = -1
    config.setup({})
    keymaps.apply()
  end)

  it("is asked once by :checkhealth, which uses the answer for both of its checks", function()
    package.loaded["claudecode"] = { state = { config = { terminal_cmd = "mine" } } }
    health.check()
    assert.same({ "mine" }, asked)
    assert.truthy(mentions(lines("ok"), "Claude Code 2.1.318"))
    assert.truthy(mentions(lines("ok"), "carries the hooks"))
  end)

  it("is a section of its own", function()
    health.inline()
    assert.equals("start", reported[1].level)
    assert.equals("floating-claude.nvim: inline mode", reported[1].msg)
  end)

  it("reports nothing wrong when everything is there", function()
    claude_running()
    health.inline()
    assert.same({}, lines("warn"))
    assert.same({}, lines("error"))
    assert.truthy(mentions(lines("ok"), "hooks"))
    assert.truthy(mentions(lines("ok"), "unified diff"))
    assert.truthy(mentions(lines("ok"), "<leader>ai"))
  end)

  it("says it is off, and asks nothing else, with inline.enabled = false", function()
    config.setup({ inline = { enabled = false } })
    compat.unified_diff = function()
      error("asked")
    end
    health.inline()
    assert.equals(1, #lines("info"))
    assert.truthy(lines("info")[1].msg:find("inline.enabled = false", 1, true))
    assert.same({}, lines("warn"))
  end)

  describe("hooks", function()
    it("warns, with the reason, when this Claude is read off the screen", function()
      claude_running()
      session.info = function()
        return { active = false, reason = "hooks = false in setup()" }
      end
      health.inline()
      local warn = mentions(lines("warn"), "hooks = false in setup()")
      assert.truthy(warn, "the reason was not given")
      assert.truthy(warn.msg:find("refuse", 1, true), "what you lose was not said")
      assert.truthy(warn.advice and #warn.advice > 0, "no way back was given")
      -- The floor is read from compat, never repeated in the section.
      assert.truthy(table.concat(warn.advice, " "):find(compat.minimum.hooks, 1, true))
    end)

    it("asks the CLI when Claude is not running yet, and warns when it is too old", function()
      -- Older than any floor there will be.
      answers.cli = "2.0.0"
      health.inline()
      local warn = mentions(lines("warn"), "Claude Code 2.0.0 is older than")
      assert.truthy(warn)
      assert.truthy(warn.msg:find(compat.minimum.hooks, 1, true))
      assert.truthy(warn.msg:find("refuse", 1, true))
    end)

    it("asks about the command claudecode.nvim launches, not about `claude`", function()
      package.loaded["claudecode"] =
        { state = { config = { terminal_cmd = "~/.claude/local/claude" } } }
      health.inline()
      assert.same({ "~/.claude/local/claude" }, asked)
    end)

    it("asks about `claude` when claudecode.nvim names no command", function()
      package.loaded["claudecode"] = { state = { config = { terminal_cmd = "" } } }
      health.inline()
      assert.same({ "claude" }, asked)
    end)

    it("takes the version it is given instead of asking again", function()
      compat.cli_version = function()
        error("asked again")
      end
      health.inline("claude", "2.1.318")
      assert.truthy(mentions(lines("ok"), "hooks"))
      assert.same({}, lines("warn"))
    end)

    it("does not ask again about a version the caller could not read", function()
      compat.cli_version = function()
        error("asked again")
      end
      health.inline("claude", false)
      assert.truthy(mentions(lines("warn"), "could not read"))
    end)

    it("warns that a command with its own --settings turns it off", function()
      package.loaded["claudecode"] =
        { state = { config = { terminal_cmd = "claude --settings /tmp/mine.json" } } }
      health.inline()
      local warn = mentions(lines("warn"), "--settings")
      assert.truthy(warn, "the command's own --settings was not named")
      assert.truthy(warn.msg:find("refuse", 1, true))
      assert.truthy(warn.advice and #warn.advice > 0)
      assert.is_nil(mentions(lines("ok"), "hooks"))
    end)

    it("hedges when the version cannot be read, rather than say it refuses", function()
      answers.cli = nil
      health.inline()
      local warn = mentions(lines("warn"), "could not read")
      assert.truthy(warn)
      assert.is_nil(warn.msg:find("refuse", 1, true))
      assert.truthy(table.concat(warn.advice, " "):find("another path", 1, true))
      assert.is_nil(mentions(lines("ok"), "hooks"))
    end)

    it("is satisfied by a CLI that carries them, while Claude is not running", function()
      health.inline()
      assert.truthy(mentions(lines("ok"), "hooks"))
      assert.same({}, lines("warn"))
    end)

    it("warns about hooks = false before Claude has started", function()
      config.setup({ hooks = false })
      health.inline()
      assert.truthy(mentions(lines("warn"), "hooks = false"))
    end)
  end)

  describe("the unified diff", function()
    it("warns that edits open in claudecode.nvim's own layout, in a new tab", function()
      answers.unified = false
      health.inline()
      local warn = mentions(lines("warn"), "unified diff")
      assert.truthy(warn)
      assert.truthy(warn.msg:find("own layout", 1, true))
      assert.truthy(warn.msg:find("new tab", 1, true))
      assert.truthy(warn.advice and #warn.advice > 0)
    end)

    it("leaves it to the claudecode.nvim error when it is not installed", function()
      answers.unified = false
      compat.claudecode = function()
        return { installed = false, problems = {} }
      end
      health.inline()
      assert.is_nil(mentions(lines("warn"), "unified diff"))
    end)

    it("says so, without a warning, when you asked for a tab", function()
      config.setup({ inline = { diff_in_window = false } })
      health.inline()
      assert.same({}, lines("warn"))
      assert.truthy(mentions(lines("info"), "inline.diff_in_window = false"))
    end)
  end)

  it("does not promise your window when inline.diff_layout = false", function()
    config.setup({ inline = { diff_layout = false } })
    health.inline()
    assert.same({}, lines("warn"))
    assert.is_nil(mentions(lines("ok"), "unified diff"))
    assert.truthy(mentions(lines("info"), "inline.diff_layout = false"))
  end)

  describe("the key", function()
    it("names it, in both modes", function()
      health.inline()
      local ok = mentions(lines("ok"), "<leader>ai")
      assert.truthy(ok)
      assert.truthy(ok.msg:find("visual", 1, true))
    end)

    it("says not mapped when keymaps.inline = false", function()
      config.setup({ keymaps = { inline = false } })
      keymaps.apply()
      health.inline()
      local info = mentions(lines("info"), "not mapped")
      assert.truthy(info)
      assert.truthy(info.msg:find(":FloatingClaudeInline", 1, true))
      assert.same({}, lines("warn"))
    end)

    it("warns when a mapping of your own holds the key", function()
      -- Ours off first, or the mapping of your own would replace ours instead
      -- of being there before it.
      config.setup({ keymaps = { inline = false } })
      keymaps.apply()
      vim.keymap.set("n", "<leader>ai", "<Nop>", { desc = "mine" })
      config.setup({})
      keymaps.apply()
      health.inline()
      vim.keymap.del("n", "<leader>ai")
      local warn = mentions(lines("warn"), "<leader>ai")
      assert.truthy(warn)
      assert.truthy(warn.msg:find("not mapped", 1, true))
      assert.truthy(warn.msg:find("normal", 1, true))
      assert.is_nil(warn.msg:find("visual", 1, true), "the visual mapping is ours and was set")
    end)

    it("warns when setup() has not mapped it", function()
      keymaps.apply()
      -- A re-apply with the feature off leaves nothing of ours behind.
      config.options.inline.enabled = false
      keymaps.apply()
      config.options.inline.enabled = true
      health.inline()
      assert.truthy(mentions(lines("warn"), "not mapped"))
    end)
  end)
end)
