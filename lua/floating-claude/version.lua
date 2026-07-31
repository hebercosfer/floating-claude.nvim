-- This plugin's own version.
--
-- Semver over the surface you touch: setup() options, the provider table, the
-- commands and the Lua API. What the plugin reads is deliberately NOT part of
-- that surface -- see compat.lua for the claudecode.nvim / Claude Code pair a
-- given release is built against. Moving that pair is a minor bump, because a
-- new Claude UI can change what the auto-minimize does without a line of the
-- API changing.

---@param v { major: integer, minor: integer, patch: integer, prerelease: string|nil }
---@return string
local function to_string(v)
  local s = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  if v.prerelease then
    s = s .. "-" .. v.prerelease
  end
  return s
end

local M = {
  major = 0,
  minor = 1,
  patch = 0,
  prerelease = nil,
}

--- "0.1.0". Also available as tostring(require("floating-claude").version).
---@return string
function M:string()
  return to_string(self)
end

return setmetatable(M, { __tostring = to_string })
