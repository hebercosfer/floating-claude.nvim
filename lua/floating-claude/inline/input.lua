-- The input under the code: a small float, anchored to a buffer row, where
-- you type what to ask Claude.
--
-- It is a float over the window rather than a prompt() or a cmdline so it sits
-- where the code is, takes more than one line, and leaves the buffer alone.
-- It is one row high while you type one row, grows with what you type -- a
-- line that wraps, a new line -- up to `inline.max_input_height`, and scrolls
-- after that. <CR> hands the text back; <S-CR> and <C-j> add a line instead
-- (<S-CR> only reaches Neovim from a terminal that tells it apart from <CR>,
-- so <C-j> is the one that always works).

local config = require("floating-claude.config")

local M = {}

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

--- Open the input and focus it, in insert mode. One of `on_submit` and
--- `on_cancel` is called, once, when it ends; the input is closed by then and
--- you are back in `win`, unless you left it by going somewhere else.
---@param opts { win: integer, row: integer, on_submit: fun(text: string), on_cancel: fun()|nil }
---  `win`: the window the code is in. `row`: 0-based, the buffer row the input
---  goes under. `on_submit`: gets the trimmed text. `on_cancel`: <Esc> or `q`
---  in normal mode, an empty <CR>, or leaving the input.
---@return integer win the input's window
function M.open(opts)
  local origin = opts.win
  local info = vim.fn.getwininfo(origin)[1]
  -- Under the last screen row of the line, which is not the next row when the
  -- line wraps.
  local below =
    vim.api.nvim_win_text_height(origin, { start_row = opts.row, end_row = opts.row }).all

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = origin,
    bufpos = { opts.row, 0 },
    row = below,
    col = 0,
    -- The border is part of what has to fit in the text area.
    width = math.max(1, info.width - info.textoff - 2),
    height = 1,
    style = "minimal",
    border = "rounded",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local finished = false
  -- `left`: you went to another window yourself, so nothing pulls you back.
  local function finish(text, left)
    if finished then
      return
    end
    finished = true
    if not left then
      vim.cmd.stopinsert()
      if valid(origin) then
        vim.api.nvim_set_current_win(origin)
      end
    end
    if valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if text then
      opts.on_submit(text)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    finish(text ~= "" and text or nil)
  end

  local function resize()
    if valid(win) then
      local rows = vim.api.nvim_win_text_height(win, {}).all
      vim.api.nvim_win_set_height(
        win,
        math.max(1, math.min(rows, config.options.inline.max_input_height))
      )
    end
  end

  local function bind(modes, lhs, rhs, desc, extra)
    local map = { buffer = buf, nowait = true, desc = desc }
    vim.keymap.set(modes, lhs, rhs, vim.tbl_extend("force", map, extra or {}))
  end
  local function cancel()
    finish(nil)
  end
  bind({ "i", "n" }, "<CR>", submit, "Send")
  bind("n", "<Esc>", cancel, "Cancel")
  bind("n", "q", cancel, "Cancel")
  -- The builtin newline, on the keys that mean "a line, not a send".
  bind("i", "<C-j>", "<C-j>", "New line", { remap = false })
  bind("i", "<S-CR>", "<C-j>", "New line", { remap = false })

  -- Autocmds on a buffer go when the buffer does, so a finished input leaves
  -- nothing behind.
  local group = vim.api.nvim_create_augroup("FloatingClaudeInlineInput", { clear = false })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = buf,
    callback = resize,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    once = true,
    desc = "Close the inline input when you leave it",
    -- Not while the window is being left: closing it then is refused.
    callback = function()
      vim.schedule(function()
        finish(nil, true)
      end)
    end,
  })

  vim.cmd.startinsert()
  return win
end

return M
