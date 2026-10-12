-- The global mappings the plugin owns. Applied when the plugin loads, and again
-- by setup(), so a remap or `false` there replaces what loading put down.

local config = require("floating-claude.config")

local M = {}

-- The lhs we mapped last, so a re-apply removes exactly that and nothing else.
local mapped

function M.apply()
  if mapped then
    pcall(vim.keymap.del, "n", mapped)
    mapped = nil
  end
  local lhs = config.options.keymaps.hide
  -- A default the user never asked for has no business replacing a mapping
  -- they made themselves.
  if not lhs or vim.fn.maparg(lhs, "n") ~= "" then
    return
  end
  vim.keymap.set("n", lhs, function()
    require("floating-claude").hide()
  end, { desc = "Hide Claude" })
  mapped = lhs
end

return M
