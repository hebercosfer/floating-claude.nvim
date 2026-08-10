-- Init for the compatibility specs: everything minimal_init.lua sets up, plus
-- the *real* claudecode.nvim from CLAUDECODE_DIR.
--
-- This has to be a separate file rather than a flag on minimal_init.lua. The
-- unit suite depends on claudecode.nvim being absent -- compat_spec's "reports
-- a missing claudecode.nvim" asserts installed == false -- so a real checkout
-- on the runtimepath would turn it red. The two inits want opposite worlds.
--
--   make test-compat

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

-- Reuse the plenary discovery and runtimepath setup rather than restating them.
dofile(here .. "/minimal_init.lua")

local claudecode = os.getenv("CLAUDECODE_DIR")

if not claudecode or claudecode == "" then
  error(
    "CLAUDECODE_DIR is not set; point it at a claudecode.nvim checkout (or run `make test-compat`)"
  )
end

if vim.fn.isdirectory(claudecode .. "/lua/claudecode") ~= 1 then
  error("CLAUDECODE_DIR does not look like a claudecode.nvim checkout: " .. claudecode)
end

vim.opt.runtimepath:prepend(claudecode)
