-- :checkhealth floating-claude
--
-- Everything this plugin scrapes depends on versions it cannot negotiate, so
-- the health check reports the pair actually installed next to the pair we are
-- tested against.

local compat = require("floating-claude.compat")
local config = require("floating-claude.config")

local M = {}

local health = vim.health

-- The command claudecode.nvim starts Claude with, which is what the CLI checks
-- must ask about: `terminal_cmd` in its config, or "claude" when it names none
-- (or is not set up yet).
---@return string
local function launch_command()
  local cmd = vim.tbl_get(package.loaded, "claudecode", "state", "config", "terminal_cmd")
  return (type(cmd) == "string" and cmd ~= "") and cmd or "claude"
end

-- Inline mode: what it leans on, and what you lose without each. The hooks are
-- what a request is followed by; the unified diff is how its edit reaches your
-- window; the key is how you ask.
---@param cmd string|nil the command Claude is started with; read from claudecode.nvim when left out
---@param cli string|false|nil that CLI's version, when the caller has asked already: false for one it could not read
function M.inline(cmd, cli)
  health.start("floating-claude.nvim: inline mode")
  local options = config.options.inline
  if not options.enabled then
    health.info("turned off (inline.enabled = false): no key, and the command does nothing")
    return
  end

  -- Claude's hooks ---------------------------------------------------------------
  local function without_hooks(why)
    health.warn(
      ("Claude is not heard through its hooks (%s), so inline mode refuses every request until it is"):format(
        why or "no reason given"
      ),
      {
        ("Use Claude Code %s or newer, leave hooks on (not `hooks = false`), start claude without a --settings of your own, then restart Claude"):format(
          compat.minimum.hooks
        ),
      }
    )
  end

  local session = require("floating-claude.hooks.session")
  if require("floating-claude.state").buf_valid() then
    local info = session.info()
    if info.active then
      health.ok(
        "Claude is heard through its hooks, so a request is followed to the end of its turn"
      )
    else
      without_hooks(info.reason)
    end
  elseif not config.options.hooks.enabled then
    without_hooks("hooks = false in setup()")
  else
    -- Claude is not running, so nothing has been decided yet: ask what the start
    -- will decide, as session.prepare does and in its order -- a command with a
    -- --settings of its own, then the CLI's version.
    cmd = cmd or launch_command()
    if cli == nil then
      cli = compat.cli_version(cmd)
    end
    if cmd:find("--settings", 1, true) then
      without_hooks("the claude command already passes --settings")
    elseif not cli then
      -- As the CLI check does: the command may start by a path we cannot see.
      health.warn(
        ("could not read the Claude Code version from `%s`, so it is not known whether inline mode will hear Claude through its hooks"):format(
          cmd
        ),
        {
          "Install the Claude Code CLI, or ignore this if claudecode.nvim launches it by another path",
        }
      )
    elseif compat.older(cli, compat.minimum.hooks) then
      without_hooks(
        ("Claude Code %s is older than %s, the first with the hooks this plugin uses"):format(
          cli,
          compat.minimum.hooks
        )
      )
    else
      health.ok("Claude Code carries the hooks; they are set up when Claude starts")
    end
  end

  -- The unified diff -------------------------------------------------------------
  if not compat.claudecode().installed then
    health.info("claudecode.nvim is not installed, so there is no edit to show (see above)")
  elseif options.diff_in_window == false then
    health.info("inline.diff_in_window = false: an edit opens in a new tab, as other diffs do")
  elseif compat.unified_diff() then
    if options.diff_layout == false then
      health.info(
        "inline.diff_layout = false keeps your own layout: an edit shows in your window only if that is unified"
      )
    else
      health.ok("claudecode.nvim can show an edit as a unified diff in your window")
    end
  else
    health.warn(
      "this claudecode.nvim cannot show an edit as a unified diff in your window: it opens in claudecode.nvim's own layout, in a new tab, as other diffs do",
      {
        ("Update claudecode.nvim; this plugin is tested against %s (%s)"):format(
          compat.tested.claudecode.version,
          compat.tested.claudecode.commit
        ),
      }
    )
  end

  -- The key ----------------------------------------------------------------------
  local lhs = config.options.keymaps.inline
  if not lhs then
    health.info(
      "not mapped (keymaps.inline = false); :FloatingClaudeInline asks about the cursor line or a range"
    )
    return
  end
  local mapped = require("floating-claude.keymaps").mapped("inline")
  local missing = {}
  for _, mode in ipairs({ { "n", "normal" }, { "x", "visual" } }) do
    if mapped[mode[1]] ~= lhs then
      table.insert(missing, mode[2])
    end
  end
  if #missing == 0 then
    health.ok(("%s asks Claude about the code, in normal and visual mode"):format(lhs))
  else
    health.warn(("%s is not mapped in %s mode"):format(lhs, table.concat(missing, " and ")), {
      "A mapping of your own on the key is left alone: remap one of them, or pick a free key with keymaps.inline",
      "Or call require('floating-claude').setup(), which maps it; :FloatingClaudeInline asks without a key",
    })
  end
end

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
  local cmd = launch_command()
  local cli = compat.cli_version(cmd)
  if not cli then
    health.warn(("could not run `%s --version`"):format(vim.split(vim.trim(cmd), "%s+")[1]), {
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
    end, { counts = true })
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
    if info.port then
      health.info(
        ("the listener on 127.0.0.1:%d is still up, since Claude was started pointing at it (:FloatingClaudeEvents shows what it hears)"):format(
          info.port
        )
      )
    end
  end

  M.inline(cmd, cli or false)
end

return M
