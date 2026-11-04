-- The global mappings the plugin owns. Applied when the plugin loads, and again
-- by setup(), so a remap or `false` there replaces what loading put down.

local config = require("floating-claude.config")

local M = {}

local ACTIONS = {
  {
    name = "hide",
    desc = "Hide Claude",
    fn = function()
      require("floating-claude").hide()
    end,
  },
  {
    name = "events",
    desc = "Show what floating-claude heard from Claude",
    fn = function()
      require("floating-claude").events()
    end,
  },
}

-- The lhs we mapped last, per action, so a re-apply removes exactly those and
-- nothing else.
local mapped = {}

function M.apply()
  for _, lhs in pairs(mapped) do
    pcall(vim.keymap.del, "n", lhs)
  end
  mapped = {}
  for _, action in ipairs(ACTIONS) do
    local lhs = config.options.keymaps[action.name]
    -- A default the user never asked for has no business replacing a mapping
    -- they made themselves.
    if lhs and vim.fn.maparg(lhs, "n") == "" then
      vim.keymap.set("n", lhs, action.fn, { desc = action.desc })
      mapped[action.name] = lhs
    end
  end
end

return M
