-- Inline mode: ask Claude about the code in front of you.
--
-- This is the entry. The key and the command land in ask(), which opens the
-- input under the range and, once you submit, hands the instruction to
-- submit(). That is the seam: session mode (typed into the Claude the float is
-- running) and headless mode (a `claude -p` of its own) each dispatch from
-- there, by `ctx.mode`. Until they do, submit() only shows the instruction
-- back as the first inline line.

local config = require("floating-claude.config")
local input = require("floating-claude.inline.input")
local lines = require("floating-claude.inline.lines")

local M = {}

---@class floating_claude.InlineContext
---@field buf integer the buffer the request is about
---@field win integer the window it was asked from
---@field first_row integer 0-based first row of the range
---@field row integer 0-based last row of the range, where the lines hang from
---@field mode "session"|"headless"

---@param ctx floating_claude.InlineContext
---@param instruction string
local function submit(ctx, instruction)
  lines.render(ctx.buf, ctx.row, { "▸ " .. instruction }, { first_row = ctx.first_row })
end

--- Open the input under the range, and dispatch what you type.
---@param opts { line1: integer, line2: integer, mode: "session"|"headless"|nil }
---  `line1`/`line2`: the 1-based lines, as a command's range gives them.
---  `mode`: for this request only; otherwise `inline.mode`.
function M.ask(opts)
  if not config.options.inline.enabled then
    vim.notify("Inline mode is turned off (inline.enabled = false)", vim.log.levels.INFO)
    return
  end
  local ctx = {
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    first_row = math.min(opts.line1, opts.line2) - 1,
    row = math.max(opts.line1, opts.line2) - 1,
    mode = opts.mode or config.options.inline.mode,
  }
  input.open({
    win = ctx.win,
    row = ctx.row,
    on_submit = function(text)
      submit(ctx, text)
    end,
  })
end

--- Take the inline lines down from a buffer.
---@param buf integer|nil defaults to the current buffer
function M.clear(buf)
  lines.clear(buf or vim.api.nvim_get_current_buf())
end

return M
