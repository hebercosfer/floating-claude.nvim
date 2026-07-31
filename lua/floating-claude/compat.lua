-- Version compatibility with the two moving targets underneath this plugin.
--
-- We sit between claudecode.nvim -- whose terminal provider interface we
-- implement -- and the Claude Code CLI, whose TUI we scrape (see parser.lua).
-- Neither is a stable API: a renamed diff buffer or a redrawn status line is
-- enough to stop the auto-minimize from tracking. So we pin the pair this
-- release is tested against, check it once when Claude is spawned, and say so
-- rather than degrading silently.

local M = {}

-- The versions this release is developed and tested against.
M.tested = {
  claudecode = { version = "0.3.0", commit = "2390c6e", date = "2026-06-25" },
  claude_code = "2.1.220",
}

-- The oldest versions we run against without complaining.
M.minimum = {
  -- claudecode.nvim reports its version from a literal in its source tree, and
  -- that literal lags its tags -- the v0.3.0 tree still reports 0.2.0. Treat
  -- this as a floor only; the real requirement is the interface check below.
  claudecode = "0.2.0",
  -- The Claude Code UI line parser.lua targets: a rule-framed input prompt with
  -- the live "✶ … 17s … (esc to interrupt)" status line above it. Older CLIs
  -- render a different prompt area and the heuristics stop tracking.
  claude_code = "2.1.0",
}

--- "2.1.220 (Claude Code)" / "v0.3.0" -> { 2, 1, 220 }
---@param s string|nil
---@return integer[]|nil
local function parse(s)
  if type(s) ~= "string" then
    return nil
  end
  local major, minor, patch = s:match("(%d+)%.(%d+)%.(%d+)")
  if not major then
    major, minor = s:match("(%d+)%.(%d+)")
  end
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor or 0), tonumber(patch or 0) }
end

--- Whether `version` is strictly below `floor`. Unparseable input is never
--- reported as too old -- we would rather miss a mismatch than cry wolf.
---@param version string|nil
---@param floor string
---@return boolean
function M.older(version, floor)
  local v, f = parse(version), parse(floor)
  if not v or not f then
    return false
  end
  for i = 1, 3 do
    if v[i] ~= f[i] then
      return v[i] < f[i]
    end
  end
  return false
end

--- What claudecode.nvim we are talking to, and whether it carries the pieces we
--- lean on beyond the documented provider contract.
---@return { installed: boolean, version: string|nil, problems: string[] }
function M.claudecode()
  local ok, claudecode = pcall(require, "claudecode")
  if not ok then
    return {
      installed = false,
      problems = { "claudecode.nvim is not installed (or not on the runtimepath)" },
    }
  end

  local report = { installed = true, problems = {} }

  local ok_version, version = pcall(function()
    if type(claudecode.get_version) == "function" then
      return claudecode.get_version().version
    end
    return claudecode.version:string()
  end)
  report.version = ok_version and version or nil

  if M.older(report.version, M.minimum.claudecode) then
    table.insert(
      report.problems,
      ("claudecode.nvim %s is older than the required %s"):format(
        report.version,
        M.minimum.claudecode
      )
    )
  end

  -- ensure_visible is what keeps a minimized Claude minimized while a diff is
  -- resolved; without it claudecode.nvim reopens the float over your review.
  local ok_terminal, terminal = pcall(require, "claudecode.terminal")
  if not ok_terminal or type(terminal.ensure_visible) ~= "function" then
    table.insert(
      report.problems,
      "this claudecode.nvim has no terminal.ensure_visible; the float will pop back over edit-approval diffs"
    )
  end

  -- parser.diff_pending() keys off the diff buffers this module names.
  if not pcall(require, "claudecode.diff") then
    table.insert(
      report.problems,
      "this claudecode.nvim has no claudecode.diff module; auto-minimize on diffs will not fire"
    )
  end

  return report
end

--- The command claudecode.nvim launches ("claude", "claude --resume", a path).
---@param cmd_string string|nil
---@return string|nil
local function cli_binary(cmd_string)
  if type(cmd_string) ~= "string" then
    return nil
  end
  local bin = vim.split(vim.trim(cmd_string), "%s+")[1]
  return bin ~= "" and bin or nil
end

--- `claude --version` prints "2.1.220 (Claude Code)".
---@param out string|nil
---@return string|nil
local function parse_cli_output(out)
  return out and out:match("%d+%.%d+%.%d+") or nil
end

--- Ask the CLI its version without blocking the spawn.
---@param cmd_string string|nil
---@param cb fun(version: string|nil)
function M.cli_version_async(cmd_string, cb)
  local bin = cli_binary(cmd_string)
  if not bin then
    return cb(nil)
  end
  local ok = pcall(vim.system, { bin, "--version" }, { text = true }, function(res)
    local version = res.code == 0 and parse_cli_output(res.stdout) or nil
    vim.schedule(function()
      cb(version)
    end)
  end)
  if not ok then
    cb(nil)
  end
end

--- Blocking variant, for :checkhealth.
---@param cmd_string string|nil
---@param timeout_ms integer|nil
---@return string|nil
function M.cli_version(cmd_string, timeout_ms)
  local bin = cli_binary(cmd_string or "claude")
  if not bin or vim.fn.executable(bin) ~= 1 then
    return nil
  end
  local ok, res = pcall(function()
    return vim.system({ bin, "--version" }, { text = true }):wait(timeout_ms or 3000)
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return parse_cli_output(res.stdout)
end

local function tested_line()
  local t = M.tested
  return ("Tested against claudecode.nvim %s (%s) and Claude Code %s."):format(
    t.claudecode.version,
    t.claudecode.commit,
    t.claude_code
  )
end

local checked = false

--- One warning per session about a claudecode.nvim / Claude Code combination
--- this plugin was not built for. Silenced with `version_check = false`.
---@param cmd_string string|nil The command claudecode.nvim is spawning.
function M.check(cmd_string)
  if checked or require("floating-claude.config").options.version_check == false then
    return
  end
  checked = true

  local problems = M.claudecode().problems

  M.cli_version_async(cmd_string, function(version)
    if M.older(version, M.minimum.claude_code) then
      table.insert(
        problems,
        ("Claude Code %s is older than the required %s; the auto-minimize parser targets the %s UI"):format(
          version,
          M.minimum.claude_code,
          M.tested.claude_code
        )
      )
    end
    if #problems == 0 then
      return
    end
    local lines = { "floating-claude.nvim " .. tostring(require("floating-claude.version")) .. ":" }
    for _, p in ipairs(problems) do
      table.insert(lines, "  - " .. p)
    end
    table.insert(lines, tested_line() .. " Set version_check = false to silence this.")
    vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
  end)
end

return M
