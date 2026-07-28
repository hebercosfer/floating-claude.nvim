-- The corner notification: a small, unfocusable window that tails Claude's
-- latest output while the big float is hidden.

local config = require("floating-claude.config")
local parser = require("floating-claude.parser")
local state = require("floating-claude.state")

local uv = vim.uv or vim.loop

local M = {}

local function stop_timer()
  if state.mini_timer then
    state.mini_timer:stop()
    if not state.mini_timer:is_closing() then
      state.mini_timer:close()
    end
    state.mini_timer = nil
  end
end

function M.hide()
  stop_timer()
  if state.mini_win_valid() then
    vim.api.nvim_win_close(state.mini_win, true)
  end
  state.mini_win = -1
end

-- Render (creating or resizing) the corner notification.
local function render()
  local opts = config.options.notification
  local content = parser.status_lines()

  if not state.mini_buf_valid() then
    state.mini_buf = vim.api.nvim_create_buf(false, true)
  end
  vim.bo[state.mini_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.mini_buf, 0, -1, false, content)
  vim.bo[state.mini_buf].modifiable = false

  local width = math.min(opts.width, vim.o.columns - 4)

  -- Height has to account for lines that wrap at `width`.
  local rows = 0
  for _, line in ipairs(content) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  local height = math.max(1, math.min(opts.max_height, rows))

  local col = math.max(1, vim.o.columns - width - 2)
  local row = math.max(1, vim.o.lines - height - 3)

  local cfg = {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = opts.border,
    title = opts.title,
    title_pos = opts.title_pos,
    focusable = false,
    zindex = opts.zindex,
  }

  if state.mini_win_valid() then
    vim.api.nvim_win_set_config(state.mini_win, cfg)
  else
    state.mini_win = vim.api.nvim_open_win(state.mini_buf, false, cfg)
    vim.wo[state.mini_win].wrap = true
  end

  -- Keep the newest line (status/spinner) in view if the block overflows.
  pcall(vim.api.nvim_win_set_cursor, state.mini_win, { #content, 0 })
end

function M.show()
  if not state.buf_valid() then
    vim.notify("Claude Code is not running.", vim.log.levels.WARN)
    return false
  end
  local refresh_ms = config.options.notification.refresh_ms
  render()
  stop_timer()
  state.mini_timer = uv.new_timer()
  state.mini_timer:start(
    refresh_ms,
    refresh_ms,
    vim.schedule_wrap(function()
      if not state.mini_win_valid() then
        stop_timer()
        return
      end
      if not state.buf_valid() then
        M.hide()
        return
      end
      render()
    end)
  )
  return true
end

return M
