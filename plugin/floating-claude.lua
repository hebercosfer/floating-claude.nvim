if vim.g.loaded_floating_claude then
  return
end
vim.g.loaded_floating_claude = true

local function cmd(name, fn, desc)
  vim.api.nvim_create_user_command(name, function()
    require("floating-claude")[fn]()
  end, { desc = desc })
end

cmd("FloatingClaudeMinimize", "minimize", "Collapse Claude into the corner notification")
cmd("FloatingClaudeRestore", "restore", "Bring the Claude float back")
cmd("FloatingClaudeToggle", "toggle_mini", "Toggle between the Claude float and the notification")
