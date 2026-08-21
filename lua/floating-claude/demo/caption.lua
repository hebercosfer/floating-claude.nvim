-- The tour's narration: a small unfocusable window in the top-left corner,
-- saying what the beat on screen is showing.
--
-- Top-left rather than top-centre so it never covers the float's own title,
-- and unfocusable so a click meant for the float or the corner passes straight
-- through it -- the demo asks you to click things, and a caption that swallowed
-- those clicks would break the very behaviour it is narrating. It carries no
-- highlight groups of its own: the tour is not part of the plugin's public
-- surface, so it paints with built-ins and with the notification's own groups.

local M = {}

local ns = vim.api.nvim_create_namespace("floating-claude.demo.caption")

-- What the hint line is marked with, and what the body's `code spans` become.
local ARROW = "▸ "

M.win = -1
M.buf = -1
M.tab = nil

--- Strip the `code spans` out of a line, remembering where they landed so they
--- can be painted. Backticks read as noise in a window this small; the colour
--- is what marks a key or an option name.
---@return string, integer[][]
local function markup(line)
  local out, spans, i = "", {}, 1
  while true do
    local first, last = line:find("`[^`]+`", i)
    if not first then
      return out .. line:sub(i), spans
    end
    out = out .. line:sub(i, first - 1)
    local inner = line:sub(first + 1, last - 1)
    table.insert(spans, { #out, #out + #inner })
    out = out .. inner
    i = last + 1
  end
end

--- Greedy wrap on display width.
local function wrap(text, width)
  local rows, current = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      current = candidate
    else
      if current ~= "" then
        table.insert(rows, current)
      end
      current = word
    end
  end
  table.insert(rows, current)
  return rows
end

--- Lay the beat out as rows carrying what to paint them with.
local function lay_out(beat, width)
  local rows = {}

  local function add(text, group, indent)
    local stripped, spans = markup(text)
    -- Carried as text rather than as offsets: the wrap below moves every
    -- column, so each row finds its own spans again.
    local codes = {}
    for _, span in ipairs(spans) do
      table.insert(codes, stripped:sub(span[1] + 1, span[2]))
    end
    for i, row in ipairs(wrap(stripped, width - #indent)) do
      table.insert(rows, {
        text = (i == 1 and indent or string.rep(" ", #indent)) .. row,
        group = group,
        codes = codes,
      })
    end
  end

  add(beat.title, "Title", " ")
  for _, line in ipairs(beat.lines or {}) do
    table.insert(rows, { text = "" })
    add(line, nil, " ")
  end
  if beat.hint then
    table.insert(rows, { text = "" })
    add(beat.hint, "DiagnosticOk", " " .. ARROW)
  end
  return rows
end

local function paint(buf, rows)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, row in ipairs(rows) do
    local function mark(col, end_col, group)
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, col, { end_col = end_col, hl_group = group })
    end
    if row.group and #row.text > 0 then
      mark(0, #row.text, row.group)
    end
    -- A code span is painted wherever it turns up on this row. One broken
    -- across the wrap simply loses its colour, which is cheaper than tracking
    -- offsets through a re-flow for the sake of a two-line caption.
    for _, code in ipairs(row.codes or {}) do
      local at = row.text:find(code, 1, true)
      while at do
        mark(at - 1, at - 1 + #code, "Special")
        at = row.text:find(code, at + #code, true)
      end
    end
  end
end

--- Show one beat. Reopens the window when the tour has moved to another
--- tabpage -- the stand-in diff opens in its own tab, and an editor-relative
--- window belongs to the tab it was created in.
---@param beat { title: string, lines: string[]|nil, hint: string|nil, foot: boolean|nil, index: integer, total: integer }
function M.show(beat)
  -- Narrow enough to leave the float's own centred title showing next to it,
  -- on a terminal wide enough for that to be possible.
  local width = math.min(72, math.max(30, vim.o.columns - 6))
  local rows = lay_out(beat, width - 2)

  if M.buf == -1 or not vim.api.nvim_buf_is_valid(M.buf) then
    M.buf = vim.api.nvim_create_buf(false, true)
  end
  vim.bo[M.buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    M.buf,
    0,
    -1,
    false,
    vim.tbl_map(function(row)
      return row.text
    end, rows)
  )
  vim.bo[M.buf].modifiable = false
  paint(M.buf, rows)

  local cfg = {
    relative = "editor",
    width = width,
    height = #rows,
    col = 2,
    -- Top-left, over the blank the stand-in keeps up there -- except on a beat
    -- that fills the screen with something else, and says so.
    row = beat.foot and math.max(1, vim.o.lines - #rows - 3) or 0,
    style = "minimal",
    border = "rounded",
    title = (" floating-claude · %d/%d "):format(beat.index, beat.total),
    title_pos = "center",
    focusable = false,
    zindex = 200,
  }

  if
    M.win ~= -1
    and vim.api.nvim_win_is_valid(M.win)
    and M.tab == vim.api.nvim_get_current_tabpage()
  then
    vim.api.nvim_win_set_config(M.win, cfg)
  else
    M.close()
    M.win = vim.api.nvim_open_win(M.buf, false, cfg)
    M.tab = vim.api.nvim_get_current_tabpage()
    vim.wo[M.win].winblend = 0
  end
end

--- Has the caption fallen off the screen the tour is now on? The stand-in diff
--- opens in its own tab, and an editor-relative window belongs to the tab it
--- was created in, so a beat that changes tabs has to be re-shown.
function M.stale()
  if M.win == -1 or not vim.api.nvim_win_is_valid(M.win) then
    return true
  end
  return M.tab ~= vim.api.nvim_get_current_tabpage()
end

--- Close the window, keeping the buffer for the next beat.
function M.close()
  if M.win ~= -1 and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = -1
  M.tab = nil
end

function M.hide()
  M.close()
  if M.buf ~= -1 and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.buf = -1
end

return M
