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
cmd("FloatingClaudeHide", "hide", "Take Claude off the screen, float and notification both")
cmd("FloatingClaudeEvents", "events", "Show what floating-claude heard from Claude")

require("floating-claude.keymaps").apply()

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

-- Ask Claude about the lines the command is given, or the cursor line: the
-- same as the inline key. The argument sends this one request the other way
-- from `inline.mode`, or takes the inline lines down.
local INLINE_ARGS = { "clear", "headless", "session" }

vim.api.nvim_create_user_command("FloatingClaudeInline", function(opts)
  local inline = require("floating-claude.inline")
  local what = vim.trim(opts.args)
  if what == "clear" then
    inline.clear()
  elseif what == "" or what == "session" or what == "headless" then
    inline.ask({ line1 = opts.line1, line2 = opts.line2, mode = what ~= "" and what or nil })
  else
    vim.notify(
      ("FloatingClaudeInline: unknown argument '%s' (one of %s)"):format(
        what,
        table.concat(INLINE_ARGS, ", ")
      ),
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "?",
  range = true,
  desc = "Ask Claude about the selected lines, or the cursor line",
  complete = function(lead)
    return vim.tbl_filter(function(candidate)
      return vim.startswith(candidate, lead)
    end, INLINE_ARGS)
  end,
})
