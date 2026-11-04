-- :checkhealth floating-claude
--
-- Everything this plugin scrapes depends on versions it cannot negotiate, so
-- the health check reports the pair actually installed next to the pair we are
-- tested against.

local compat = require("floating-claude.compat")

local M = {}

local health = vim.health

function M.check()
  health.start("floating-claude.nvim")

  health.ok("floating-claude.nvim " .. tostring(require("floating-claude.version")))

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required (vim.system, float titles)")
  end

  -- claudecode.nvim ------------------------------------------------------------
  local cc = compat.claudecode()
  if not cc.installed then
    health.error("claudecode.nvim is not installed", {
      "Install coder/claudecode.nvim; require('floating-claude').setup() sets it up to use this provider",
    })
  else
    local reported = cc.version and ("claudecode.nvim " .. cc.version)
      or "claudecode.nvim (version unknown)"
    health.ok(reported .. " -- note its version field lags its tags")
    for _, problem in ipairs(cc.problems) do
      health.warn(problem)
    end
    if #cc.problems == 0 then
      health.ok("terminal.ensure_visible and claudecode.diff are present")
    end
  end

  -- Only meaningful once claudecode.setup() has run; before that its state
  -- still holds the stock defaults.
  local state = vim.tbl_get(package.loaded, "claudecode", "state") or {}
  if state.initialized then
    local provider = vim.tbl_get(state, "config", "terminal", "provider")
    if
      type(provider) == "table"
      and provider.ensure_visible == require("floating-claude.provider").ensure_visible
    then
      health.ok("claudecode.nvim is configured to use this provider")
    else
      health.warn("claudecode.nvim is not using this provider", {
        "Let require('floating-claude').setup() set claudecode.nvim up, with no opts or config in a claudecode.nvim spec of its own",
        "or pass terminal = { provider = require('floating-claude').provider } to require('claudecode').setup()",
      })
    end
  end

  -- Claude Code CLI ------------------------------------------------------------
  local cli = compat.cli_version("claude")
  if not cli then
    health.warn("could not run `claude --version`", {
      "Install the Claude Code CLI, or ignore this if claudecode.nvim launches it by another path",
    })
  elseif compat.older(cli, compat.minimum.claude_code) then
    health.warn(
      ("Claude Code %s is older than the required %s"):format(cli, compat.minimum.claude_code),
      {
        "The status-line/diff scraping targets the newer UI; auto-minimize may not fire",
      }
    )
  else
    health.ok("Claude Code " .. cli)
  end

  -- What we are pinned to ------------------------------------------------------
  local t = compat.tested
  health.info(
    ("Tested against claudecode.nvim %s (%s, %s) and Claude Code %s. Minimum: claudecode.nvim %s, Claude Code %s."):format(
      t.claudecode.version,
      t.claudecode.commit,
      t.claudecode.date,
      t.claude_code,
      compat.minimum.claudecode,
      compat.minimum.claude_code
    )
  )

  -- How Claude is heard ---------------------------------------------------------
  health.start("floating-claude.nvim: hooks")
  local info = require("floating-claude.hooks.session").info()
  if not require("floating-claude.state").buf_valid() then
    health.info("Claude Code is not running")
  elseif info.active and info.port then
    local listener_received, answered = 0, false
    require("floating-claude.hooks.session").log(function(log)
      listener_received, answered = log and log.received or 0, true
    end)
    vim.wait(500, function()
      return answered
    end, 10)
    health.ok(
      ("reading Claude through its hooks on 127.0.0.1:%d; %d events received (:FloatingClaudeEvents shows them)"):format(
        info.port,
        listener_received
      )
    )
  elseif info.active then
    health.info("hearing the tour's scripted events")
  else
    health.warn(("reading Claude's screen: %s"):format(info.reason or "no reason given"))
  end
end

return M
