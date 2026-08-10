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

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.11+ is required (vim.system, float titles, jobstart's term option)")
  end

  -- claudecode.nvim ------------------------------------------------------------
  local cc = compat.claudecode()
  if not cc.installed then
    health.error("claudecode.nvim is not installed", {
      "Install coder/claudecode.nvim and pass require('floating-claude').provider as its terminal provider",
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
        "terminal = { provider = require('floating-claude').provider }",
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
end

return M
