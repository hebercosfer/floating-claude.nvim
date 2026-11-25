-- The inline lines: what an inline request shows under the code it is about.
--
-- One extmark per buffer, hung from the last row of the range, with the
-- exchange as its `virt_lines`. An extmark rather than text in the buffer, so
-- the lines follow the code as it moves, never enter the file or its undo
-- history, and go when the buffer does. A later render replaces the extmark in
-- place, so there is never more than one.
--
-- The caller owns what the lines say and the order they are in: they are
-- capped at `inline.lines` from the top, so the most important item goes
-- first -- except an item marked `ask`, which Claude needs you to see and which
-- the cap never cuts. This module only draws them, and lets <CR> act on them --
-- through a buffer-local mapping that exists while there is something to act
-- on, and hands the key straight back to whatever <CR> was everywhere else.
--
-- The extmark moves with the code, so a caller that renders again as the
-- request goes on gives no row and keeps the lines where the edits left them.

local config = require("floating-claude.config")
local highlights = require("floating-claude.highlights")

local M = {}

--- The namespace the extmark lives in, for anything that needs to look at it.
M.ns = vim.api.nvim_create_namespace("floating-claude-inline")

local ENTER = vim.keycode("<CR>")

---@class floating_claude.InlineShown
---@field id integer the extmark
---@field span integer rows the range has above the row the lines hang from
---@field on_enter fun()|nil
---@field mapped boolean whether our <CR> is in the buffer
---@field prev table|nil the <CR> mapping we covered, as maparg() describes it

---@type table<integer, floating_claude.InlineShown>
local shown = {}

-- Buffer numbers are never reused, so a wiped buffer's entry would only sit
-- there; but it holds on_enter, and what that closes over.
vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("FloatingClaudeInline", { clear = true }),
  desc = "Forget the inline lines of a wiped buffer",
  callback = function(ev)
    shown[ev.buf] = nil
  end,
})

-- The window to read the cursor and the width from: the one you are in if it
-- shows the buffer, else the first that does.
local function window_of(buf)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == buf then
    return current
  end
  local win = vim.fn.bufwinid(buf)
  return win ~= -1 and win or nil
end

local function text_width(buf)
  local win = window_of(buf) or vim.api.nvim_get_current_win()
  local info = vim.fn.getwininfo(win)[1]
  return math.max(1, info.width - info.textoff)
end

-- Cut to `cells` display columns, marking the cut. Virtual lines are not
-- wrapped, so what does not fit would be lost without a word.
local function fit(text, cells)
  if vim.fn.strdisplaywidth(text) <= cells then
    return text
  end
  local room = cells - 1
  local width, stop = 0, 0
  local starts = vim.str_utf_pos(text)
  for i, from in ipairs(starts) do
    local to = (starts[i + 1] or (#text + 1)) - 1
    local w = vim.fn.strdisplaywidth(text:sub(from, to))
    if width + w > room then
      break
    end
    width = width + w
    stop = to
  end
  return text:sub(1, stop) .. "…"
end

---@alias floating_claude.InlineItem string|{ text: string, ask: boolean|nil }

-- The items to draw, in order, within `cap`: the first ones, except that an ask
-- item always makes it -- it takes the place of the item just before it, and so
-- on up, rather than being the one that is cut.
---@param items floating_claude.InlineItem[]
---@param cap integer
---@return { text: string, ask: boolean }[]
local function pick(items, cap)
  local all = {}
  for i, item in ipairs(items) do
    all[i] = type(item) == "table" and { text = item.text, ask = item.ask == true }
      or { text = item, ask = false }
  end
  if #all <= cap then
    return all
  end
  local keep, n = {}, 0
  for i, item in ipairs(all) do
    if item.ask and n < cap then
      keep[i] = true
      n = n + 1
    end
  end
  for i = 1, #all do
    if n >= cap then
      break
    end
    if not keep[i] then
      keep[i] = true
      n = n + 1
    end
  end
  local picked = {}
  for i, item in ipairs(all) do
    if keep[i] then
      table.insert(picked, item)
    end
  end
  return picked
end

-- Where the extmark is now, 0-based, or nil when there is none.
---@return integer|nil
local function mark_row(buf, st)
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns, st.id, {})
  return mark[1]
end

-- What <CR> was in the buffer before our map: another plugin's, or yours.
local function enter_mapping(buf)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("<CR>", "n", false, true)
  end)
end

-- Do what <CR> would have done without our map.
local function pass_through(prev)
  if not prev or vim.tbl_isempty(prev) then
    -- A count is the one thing a mapping's callback loses on the way.
    local count = vim.v.count > 0 and tostring(vim.v.count) or ""
    vim.api.nvim_feedkeys(count .. ENTER, "nt", false)
    return
  end
  local keys
  if prev.callback then
    keys = prev.callback()
    if prev.expr ~= 1 then
      return
    end
    if prev.replace_keycodes == 1 then
      keys = vim.keycode(keys)
    end
  elseif prev.expr == 1 then
    keys = vim.api.nvim_eval(prev.rhs)
  else
    keys = vim.keycode(prev.rhs)
  end
  vim.api.nvim_feedkeys(keys, prev.noremap == 1 and "nt" or "mt", false)
end

local function map_enter(buf, st)
  if st.mapped then
    return
  end
  st.prev = enter_mapping(buf)
  vim.keymap.set("n", "<CR>", function()
    if st.on_enter and M.at_cursor(buf) then
      st.on_enter()
    else
      pass_through(st.prev)
    end
  end, { buffer = buf, desc = "Act on the inline lines under the code" })
  st.mapped = true
end

local function unmap_enter(buf, st)
  if not st.mapped then
    return
  end
  st.mapped = false
  pcall(vim.keymap.del, "n", "<CR>", { buffer = buf })
  -- A <CR> the buffer had of its own comes back as it was. A global one was
  -- never covered, only passed through to.
  if st.prev and st.prev.buffer == 1 then
    vim.api.nvim_buf_call(buf, function()
      vim.fn.mapset("n", false, st.prev)
    end)
  end
  st.prev = nil
end

--- Show `items` as virtual lines under `row`, in place of what was there.
---
--- With no `row`, the lines stay where they are -- where the code has moved
--- them to, with the range they were drawn for -- and only their text changes:
--- what a caller that renders on every event wants. If there are none to keep,
--- nothing is drawn and the result is nil.
---@param buf integer
---@param row integer|nil 0-based, the last row of the range the lines are about
---@param items floating_claude.InlineItem[] a string, or `{ text, ask }` for a
---  line Claude needs you to see: drawn to be noticed, and kept by the cap
---@param opts { first_row: integer|nil, on_enter: fun()|nil }|nil
---  `first_row`: the first row of the range, so <CR> acts anywhere in it and
---  not only on its last row (ignored when `row` is nil: the range is kept).
---  `on_enter`: what <CR> does there; without it there is no <CR> map.
---@return integer|nil id the extmark
function M.render(buf, row, items, opts)
  opts = opts or {}
  local st = shown[buf]
  local span
  if row == nil then
    row = mark_row(buf, st)
    if not row then
      return nil
    end
    span = st.span
  else
    -- The buffer may have shrunk since the row was read: hang the lines from
    -- the last line rather than past it.
    row = math.min(row, vim.api.nvim_buf_line_count(buf) - 1)
    span = opts.first_row and math.max(0, row - opts.first_row) or 0
  end
  highlights.ensure()

  local width = text_width(buf)
  local virt = {}
  for _, item in ipairs(pick(items, math.max(1, config.options.inline.lines))) do
    local text = fit((item.text:gsub("[\r\n\t]+", " ")), width)
    table.insert(
      virt,
      { { text, item.ask and "FloatingClaudeInlineAsk" or "FloatingClaudeInline" } }
    )
  end

  if not st then
    st = { mapped = false }
    shown[buf] = st
  end
  st.id = vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
    id = st.id,
    virt_lines = virt,
  })
  st.span = span
  st.on_enter = opts.on_enter
  if st.on_enter then
    map_enter(buf, st)
  else
    unmap_enter(buf, st)
  end
  return st.id
end

--- Take the lines down, and the <CR> with them.
---@param buf integer
function M.clear(buf)
  local st = shown[buf]
  shown[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if st then
    unmap_enter(buf, st)
  end
end

--- The range the lines are about as it is now, 0-based and inclusive: the row
--- they hang from, and the rows above it that they were drawn for. It follows
--- the code as it moves. nil when nothing is shown.
---@param buf integer
---@return integer|nil first_row
---@return integer|nil last_row
function M.range(buf)
  local st = shown[buf]
  local row = mark_row(buf, st)
  if not row then
    return nil
  end
  return math.max(0, row - st.span), row
end

--- Whether the cursor is on the code the lines are about: the row they hang
--- from, or anywhere in the range above it when render() was given one.
---@param buf integer
---@return boolean
function M.at_cursor(buf)
  local first, last = M.range(buf)
  local win = first and window_of(buf)
  if not win then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(win)[1] - 1
  return cursor >= first and cursor <= last
end

return M
