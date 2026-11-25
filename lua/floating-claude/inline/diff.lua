-- An inline request's edit, as claudecode.nvim's diff: unified, and in the
-- window you asked from.
--
-- Two things, for the length of one request.
--
-- The layout swap. claudecode.nvim reads `diff_opts` each time a diff opens,
-- from one table it keeps. begin() sets `layout` to `inline.diff_layout` there
-- and, to hand the diff over, `open_in_new_tab = false`; finish() puts back
-- exactly what was there, unset included, once the request is over AND no diff
-- handed to your window is still open -- whichever comes last.
--
-- The handoff. claudecode.nvim opens the unified diff in a split of its own (or
-- a tab) and, when it cleans up, deletes the diff's buffer -- and Neovim
-- closes every window showing a buffer that is deleted, unless it is the last
-- one. So the order below is what a spike against the real claudecode.nvim
-- found to hold (the spec's "Diff in your window" results); each step is there
-- for a reason given where it is done:
--
--   1. begin() notes your window and your file's buffer.
--   2. On ClaudeCodeDiffOpened for that file: your window shows the diff
--      buffer, then claudecode.nvim's window goes.
--   3. The diff's resolution_callback is wrapped: when the diff is answered,
--      your window gets your file back, at once and once more on the next
--      tick, before claudecode.nvim's cleanup can take the window with the
--      buffer.
--   4. On ClaudeCodeDiffClosed: :checktime, the cursor on the change, and the
--      caller is told, so it can put its lines back where the code now is.
--
-- Step 3 reaches into claudecode.nvim's internals: `_get_active_diffs()` and a
-- diff's `resolution_callback`, for it has no event for an answered diff.
-- compat.unified_diff() checks what can be checked up front; when it fails, or
-- a diff turns up without a callback to wrap, the diff opens as any other does
-- -- in a tab when compat says no, and where claudecode.nvim put it when only
-- the callback is missing.
--
-- A diff for any file other than the request's is never handed to your window.
-- It does take the swap, though: claudecode.nvim reads diff_opts as each diff
-- opens, with no hook before that, so during the turn it opens unified, where
-- claudecode.nvim then puts it (a split in the current tab, with diff_in_window).

local compat = require("floating-claude.compat")
local config = require("floating-claude.config")
local lines = require("floating-claude.inline.lines")

local M = {}

local GROUP = "FloatingClaudeInlineDiff"

---@class floating_claude.InlineDiffContext
---@field file string the file the request is about
---@field win integer the window it was asked from
---@field buf integer that file's buffer
---@field on_change fun() called once a handed diff has closed and the file is reloaded
---@field items (fun(): floating_claude.InlineItem[])|nil what the inline lines say, to
---  draw them in the diff buffer too

-- What begin() changed in claudecode.nvim's diff_opts, and what was there.
---@class floating_claude.InlineDiffSwap
---@field opts table claudecode.nvim's own diff_opts table
---@field was table<string, any>
---@field set table<string, boolean>
---@field in_window boolean whether diffs are handed to your window

-- A diff handed to your window.
---@class floating_claude.InlineHandoff
---@field ctx floating_claude.InlineDiffContext
---@field diff_buf integer
---@field first_row integer 0-based: the first changed row (the same in the diff and the file)
---@field row integer 0-based: the first hunk's last row in the diff, where the lines hang
---@field answered boolean the diff has its answer, and your window its file back
---@field settled boolean and the second look at the window, a tick later, is done

---@type floating_claude.InlineDiffSwap|nil
local swap = nil
---@type floating_claude.InlineDiffContext|nil
local ctx = nil
---@type table<string, floating_claude.InlineHandoff>
local handed = {}
---@type integer|nil
local group = nil

-- claudecode.nvim's diff_opts: the very table it reads at each diff.
---@return table|nil
local function claudecode_opts()
  local ok, cc = pcall(require, "claudecode")
  if not ok or type(cc) ~= "table" then
    return nil
  end
  local opts = vim.tbl_get(cc, "state", "config", "diff_opts")
  return type(opts) == "table" and opts or nil
end

---@param path string
---@return string
local function same_file_key(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  return vim.uv.fs_realpath(abs) or vim.fs.normalize(abs)
end

---@param s floating_claude.InlineDiffSwap
local function set(s, key, value)
  if not s.set[key] then
    s.set[key] = true
    s.was[key] = s.opts[key]
  end
  s.opts[key] = value
end

local function open_claude()
  require("floating-claude").restore()
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

---@param h floating_claude.InlineHandoff
local function cursor_to_change(h)
  local c = h.ctx
  if not (valid_win(c.win) and valid_buf(c.buf)) or vim.api.nvim_win_get_buf(c.win) ~= c.buf then
    return
  end
  local row = math.min(h.first_row + 1, vim.api.nvim_buf_line_count(c.buf))
  pcall(vim.api.nvim_win_set_cursor, c.win, { row, 0 })
end

-- Draw the inline lines in the diff buffer: your file's buffer, which carries
-- them, is out of sight while the diff holds the window. `at` hangs them anew
-- under the first hunk; without it they stay put and only their text changes.
---@param h floating_claude.InlineHandoff
---@param at boolean
local function draw(h, at)
  local items = h.ctx.items
  if not items or not valid_buf(h.diff_buf) then
    return
  end
  lines.render(h.diff_buf, at and h.row or nil, items(), {
    first_row = at and h.first_row or nil,
    on_enter = open_claude,
  })
end

-- Your window gets your file back. The diff buffer is made `bufhidden=hide`
-- first: claudecode.nvim gives it `wipe` (and, at the tested pin, leaves it
-- modified, so switching away fails with E37); hidden instead, it is still
-- there for the cleanup to delete, and that leaves your window alone. Done
-- only while the window still shows the diff: if you put something else there,
-- that stays.
---@param h floating_claude.InlineHandoff
local function give_back(h)
  if valid_buf(h.diff_buf) then
    vim.bo[h.diff_buf].bufhidden = "hide"
  end
  local c = h.ctx
  if not (valid_win(c.win) and valid_buf(c.buf)) then
    return
  end
  if vim.api.nvim_win_get_buf(c.win) ~= h.diff_buf then
    return
  end
  vim.api.nvim_win_set_buf(c.win, c.buf)
  cursor_to_change(h)
end

local function unlisten()
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
end

-- Put claudecode.nvim's options back once nothing needs them: the request is
-- over and no handed diff is on screen. Stop listening once no handed diff is
-- left to close.
local function maybe_done()
  if ctx or M.active() then
    return
  end
  if swap then
    for key in pairs(swap.set) do
      swap.opts[key] = swap.was[key]
    end
    swap = nil
  end
  if next(handed) == nil then
    unlisten()
  end
end

-- Step 3: wrap the diff's resolution_callback, so the answer -- `:w`, a deny,
-- or Claude's own prompt -- gives your window back before claudecode.nvim's
-- cleanup runs.
--
-- At once, inside the callback: for an answer in Claude's prompt, the CLI's
-- close_tab answers the still-pending diff (as rejected, even for a "yes": the
-- CLI writes the file itself) and deletes its buffer in the same call, so
-- anything later is too late. Then once more on the next tick: after a `:w`,
-- Neovim puts the diff buffer back in the window once BufWriteCmd returns.
--
-- The switch is guarded and in a pcall, and claudecode.nvim's own callback is
-- always called after it, whatever happened: that callback is what answers
-- Claude, whose edit would otherwise hang.
---@param entry table claudecode.nvim's active-diff entry
---@param h floating_claude.InlineHandoff
local function wrap(entry, h)
  local original = entry.resolution_callback
  entry.resolution_callback = function(...)
    h.answered = true
    local ok, err = pcall(give_back, h)
    vim.schedule(function()
      if not ok then
        vim.notify(
          "floating-claude: couldn't give your window its file back: " .. tostring(err),
          vim.log.levels.WARN
        )
      end
      pcall(give_back, h)
      h.settled = true
      maybe_done()
    end)
    return original(...)
  end
end

-- The first hunk, 0-based: its first and last rows. Rows above the first change
-- are unchanged on both sides, so the first is also the change's row in the
-- file. claudecode.nvim's `line_types` says where the hunk ends; without it,
-- the row it put the cursor on is the first change, and the hunk is that row.
---@param entry table
---@param cursor integer[]
---@return integer first, integer last
local function first_hunk(entry, cursor)
  local types = entry.line_types
  if type(types) == "table" then
    local first, last
    for i, kind in ipairs(types) do
      if kind ~= "unchanged" then
        first = first or i
        last = i
      elseif first then
        break
      end
    end
    if first then
      return first - 1, last - 1
    end
  end
  return cursor[1] - 1, cursor[1] - 1
end

-- Close what claudecode.nvim opened for the diff: its tab, when it made one,
-- or its split. Never `keep`, your window.
local function close_view(data, keep)
  local tab = data.tab_number
  if
    type(tab) == "number"
    and vim.api.nvim_tabpage_is_valid(tab)
    and tab ~= vim.api.nvim_win_get_tabpage(keep)
  then
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if w ~= keep and vim.api.nvim_win_get_config(w).relative == "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  elseif valid_win(data.diff_window) and data.diff_window ~= keep then
    pcall(vim.api.nvim_win_close, data.diff_window, true)
  end
end

-- Steps 2 and 3, and the lines.
---@param c floating_claude.InlineDiffContext
---@param data table ClaudeCodeDiffOpened's payload
---@param entry table claudecode.nvim's active-diff entry
local function hand_over(c, data, entry)
  local dwin = data.diff_window
  local dbuf = vim.api.nvim_win_get_buf(dwin)
  local first, last = first_hunk(entry, vim.api.nvim_win_get_cursor(dwin))
  ---@type floating_claude.InlineHandoff
  local h = {
    ctx = c,
    diff_buf = dbuf,
    first_row = first,
    row = last,
    answered = false,
    settled = false,
  }
  -- Your window first: closing claudecode.nvim's window while it is the only
  -- one showing the buffer wipes it (bufhidden=wipe), leaving the diff pending
  -- with nothing on screen.
  vim.api.nvim_win_set_buf(c.win, dbuf)
  handed[data.tab_name] = h
  close_view(data, c.win)
  pcall(vim.api.nvim_win_set_cursor, c.win, { first + 1, 0 })
  pcall(vim.api.nvim_set_current_tabpage, vim.api.nvim_win_get_tabpage(c.win))
  pcall(vim.api.nvim_set_current_win, c.win)
  wrap(entry, h)
  draw(h, true)
end

---@param ev { data: table|nil }
local function on_opened(ev)
  local data = ev.data or {}
  local c = ctx
  if not c or not swap or not swap.in_window then
    return
  end
  -- Another file's diff stays where claudecode.nvim opened it (Review Focus 4).
  if type(data.file_path) ~= "string" or same_file_key(data.file_path) ~= same_file_key(c.file) then
    return
  end
  if not (valid_win(c.win) and valid_buf(c.buf) and valid_win(data.diff_window)) then
    return
  end
  if type(data.tab_name) ~= "string" or handed[data.tab_name] then
    return
  end
  local ok_diff, cc_diff = pcall(require, "claudecode.diff")
  local entry = ok_diff
    and type(cc_diff._get_active_diffs) == "function"
    and cc_diff._get_active_diffs()[data.tab_name]
  -- Nothing to wrap: without the answer, the window could not be given back
  -- in time, so the diff stays where claudecode.nvim opened it.
  if type(entry) ~= "table" or type(entry.resolution_callback) ~= "function" then
    return
  end
  local ok, err = pcall(hand_over, c, data, entry)
  if not ok then
    vim.notify(
      "floating-claude: couldn't show the diff in your window: " .. tostring(err),
      vim.log.levels.WARN
    )
  end
end

-- Step 4.
---@param ev { data: table|nil }
local function on_closed(ev)
  local data = ev.data or {}
  local h = data.tab_name and handed[data.tab_name]
  if not h then
    return
  end
  handed[data.tab_name] = nil
  local c = h.ctx
  if valid_win(c.win) and valid_buf(c.buf) then
    local now = vim.api.nvim_win_get_buf(c.win)
    -- Closed with no answer (a shutdown): the cleanup left the window on some
    -- other buffer, or on the diff's.
    if now ~= c.buf and (now == h.diff_buf or not h.answered) then
      pcall(vim.api.nvim_win_set_buf, c.win, c.buf)
    end
  end
  if valid_buf(c.buf) then
    pcall(vim.cmd, "checktime " .. c.buf)
  end
  cursor_to_change(h)
  local ok, err = pcall(c.on_change)
  if not ok then
    vim.notify("floating-claude: " .. tostring(err), vim.log.levels.WARN)
  end
  maybe_done()
end

local function listen()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeCodeDiffOpened",
    desc = "Show an inline request's diff in the window it was asked from",
    callback = on_opened,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ClaudeCodeDiffClosed",
    desc = "Give an inline request's window its file back",
    callback = on_closed,
  })
end

--- A request is going out: its diffs open unified, and the one for its file in
--- its window. Called again while a diff from the last request is still open,
--- it keeps the options that request saved.
---@param c floating_claude.InlineDiffContext
function M.begin(c)
  ctx = c
  if not swap then
    local opts = claudecode_opts()
    if not opts then
      return
    end
    swap = { opts = opts, was = {}, set = {}, in_window = false }
    if compat.unified_diff() then
      local o = config.options.inline
      if o.diff_layout then
        set(swap, "layout", o.diff_layout)
      end
      -- Only the unified layout's one buffer can be handed over.
      swap.in_window = o.diff_in_window == true and swap.opts.layout == "unified"
      if swap.in_window then
        set(swap, "open_in_new_tab", false)
      end
    end
  end
  if swap.in_window then
    listen()
  end
end

--- The request is over. claudecode.nvim's options go back now, or once a diff
--- still in your window is answered or closed. Safe to call any number of times.
function M.finish()
  ctx = nil
  maybe_done()
end

--- Whether a diff handed to your window is on screen there.
---@return boolean
function M.active()
  for _, h in pairs(handed) do
    if not h.settled then
      return true
    end
  end
  return false
end

--- Redraw the inline lines in a handed diff, for the request has moved on.
function M.redraw()
  for _, h in pairs(handed) do
    if not h.answered then
      draw(h, false)
    end
  end
end

return M
