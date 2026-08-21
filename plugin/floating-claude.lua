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

-- The guided tour. `auto` runs it hands-free rather than asking you to click;
-- `stop` ends one early.
vim.api.nvim_create_user_command("FloatingClaudeDemo", function(opts)
  local what = vim.trim(opts.args)
  if what == "stop" then
    require("floating-claude").demo_stop()
  else
    require("floating-claude").demo({ auto = what == "auto" })
  end
end, {
  nargs = "?",
  desc = "Run a guided tour of the float and the corner notification",
  complete = function(lead)
    return vim.tbl_filter(function(candidate)
      return vim.startswith(candidate, lead)
    end, { "auto", "stop" })
  end,
})
