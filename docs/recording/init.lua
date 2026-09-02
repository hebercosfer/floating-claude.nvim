-- Minimal Neovim config for recording the tour: this plugin, no colourscheme of
-- your own, and none of the chrome that would date the recording.

-- Resolve the checkout from this file's own path, so the tour runs against the
-- tree it was launched from rather than whatever is installed.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

vim.opt.runtimepath:prepend(root)
vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.showcmd = false
vim.o.number = false
vim.o.signcolumn = "no"
vim.o.fillchars = "eob: "
vim.cmd("runtime! plugin/floating-claude.lua")
