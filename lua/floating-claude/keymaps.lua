-- The global mappings the plugin owns. Applied when the plugin loads, and again
-- by setup(), so a remap or `false` there replaces what loading put down.

local config = require("floating-claude.config")

local M = {}

-- `modes` is where the key is mapped (normal only, when left out), and `fn` is
-- given the mode it was pressed in. `enabled` keeps a key off the map while
-- the feature behind it is off.
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
  {
    name = "inline",
    desc = "Ask Claude about this code",
    modes = { "n", "x" },
    enabled = function()
      return config.options.inline.enabled
    end,
    fn = function(mode)
      local line1, line2
      if mode == "x" then
        -- Leave visual mode first: the marks only describe the selection once
        -- it is over.
        vim.cmd("normal! \27")
        line1, line2 = vim.fn.line("'<"), vim.fn.line("'>")
      else
        line1 = vim.fn.line(".")
        line2 = line1
      end
      require("floating-claude.inline").ask({ line1 = line1, line2 = line2 })
    end,
  },
}

-- The lhs we mapped last, per action and mode, so a re-apply removes exactly
-- those and nothing else.
---@type table<string, table<string, string>>
local mapped = {}

function M.apply()
  for _, by_mode in pairs(mapped) do
    for mode, lhs in pairs(by_mode) do
      pcall(vim.keymap.del, mode, lhs)
    end
  end
  mapped = {}
  for _, action in ipairs(ACTIONS) do
    local lhs = config.options.keymaps[action.name]
    if lhs and (not action.enabled or action.enabled()) then
      for _, mode in ipairs(action.modes or { "n" }) do
        -- A default the user never asked for has no business replacing a
        -- mapping they made themselves, mode by mode.
        if vim.fn.maparg(lhs, mode) == "" then
          vim.keymap.set(mode, lhs, function()
            action.fn(mode)
          end, { desc = action.desc })
          mapped[action.name] = mapped[action.name] or {}
          mapped[action.name][mode] = lhs
        end
      end
    end
  end
end

return M
