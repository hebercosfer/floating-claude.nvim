-- The notification's own highlight groups.
--
-- Claude's TUI colours its status line, its bullets and its tool results, and
-- none of that survives the trip into the notification: Neovim keeps a terminal
-- buffer's cell attributes inside libvterm's screen state rather than in the
-- buffer, so nvim_buf_get_lines() hands back plain text and there is no
-- extmark, no property, nothing to read the colour back off. What we can colour
-- is what the parser already identified -- the verb, the timer, the markers --
-- which lands close to the TUI because it is the same decomposition.
--
-- Every group is a `default` link, so a colourscheme that defines one wins and
-- `:highlight FloatingClaudeDetail ...` in your config wins over both.

local M = {}

-- Linked to what a colourscheme is most likely to have an opinion about, and
-- what most schemes colour the way Claude does: an amber status, a dim detail.
local GROUPS = {
  FloatingClaudeStatus = "DiagnosticWarn", -- the spinner glyph and Claude's verb
  FloatingClaudeDetail = "Comment", -- the elapsed timer and the token counter
  FloatingClaudeDone = "DiagnosticOk", -- the ✓ and a finished turn's marker
  FloatingClaudeTool = "Comment", -- the ⎿ in front of a running tool call
  FloatingClaudeBullet = "Title", -- Claude's ● in front of a message
  FloatingClaudePrompt = "Comment", -- the echo of what you typed
  FloatingClaudeMore = "Comment", -- the … marking what did not fit
}

local function define()
  for group, link in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local defined = false

--- Define the groups, once, and again after every colourscheme change --
--- `:colorscheme` clears the lot, default links included.
function M.ensure()
  if defined then
    return
  end
  defined = true
  define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("FloatingClaudeHighlights", { clear = true }),
    desc = "Re-apply floating-claude's notification highlights",
    callback = define,
  })
end

return M
