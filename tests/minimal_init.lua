-- Minimal init for the test runner: this plugin plus plenary, nothing else.
--
--   make test
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/"
--
-- claudecode.nvim is deliberately NOT on the runtimepath: the specs stub it
-- into package.loaded when they need it, so the "not installed" path stays
-- reachable and the suite never depends on which version is checked out.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function find_plenary()
  local candidates = {
    os.getenv("PLENARY_DIR"),
    plugin_root .. "/.tests/plenary.nvim",
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
    vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
  }
  for _, dir in ipairs(candidates) do
    if dir and vim.fn.isdirectory(dir .. "/lua/plenary") == 1 then
      return dir
    end
  end
  return nil
end

local plenary = find_plenary()
if not plenary then
  error(
    "plenary.nvim not found. Install it, set PLENARY_DIR, or run `make test` "
      .. "(which clones it into .tests/)."
  )
end

vim.opt.runtimepath:prepend(plugin_root)
vim.opt.runtimepath:prepend(plenary)
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
