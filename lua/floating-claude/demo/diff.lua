-- The stand-in edit approval: two scratch buffers in their own tab, diffed
-- against each other.
--
-- claudecode.nvim shows an edit approval as a native Neovim diff, and names the
-- proposed side "✻ [Claude Code] <file> ⧉ (proposed)" -- which is the name
-- parser.is_diff_name() matches, and the only thing about a diff this plugin
-- actually knows. So a stand-in with that name in a window is, as far as the
-- watcher is concerned, the real thing: it minimizes on sight and stays in the
-- corner until the diff leaves the screen. Nothing here writes a file, and both
-- buffers are `nofile`, so accepting one changes nothing on disk.

local provider = require("floating-claude.provider")

local M = {}

-- A real change from this plugin's own history: the watcher used to ask only
-- whether Claude was working, and had to learn that a diff on screen counts as
-- busy too.
local BEFORE = {
  "      if not state.buf_valid() then",
  "        M.stop()",
  "        return",
  "      end",
  "",
  "      local busy = parser.is_working()",
  "      if state.win_valid() then",
  "        -- The float is up and Claude is working in it.",
  "      elseif opts.restore_on_input then",
  "        if busy then",
  "          state.idle_since = nil",
  "        elseif state.idle_since == nil then",
  "          state.idle_since = uv.now()",
  "        elseif (uv.now() - state.idle_since) >= opts.restore_idle_ms then",
  "          state.idle_since = nil",
  "          handlers.restore()",
  "        end",
  "      end",
  "      state.was_busy = busy",
}

local AFTER = {
  "      if not state.buf_valid() then",
  "        M.stop()",
  "        return",
  "      end",
  "",
  "      local has_diff = parser.diff_visible()",
  "      local busy = has_diff or parser.is_working()",
  "      if state.win_valid() then",
  "        if opts.minimize_on_diff and has_diff and not state.diff_seen then",
  "          state.diff_seen = true",
  "          handlers.minimize()",
  "        end",
  "      elseif opts.restore_on_input then",
  "        if busy then",
  "          state.idle_since = nil",
  "        elseif state.idle_since == nil then",
  "          state.idle_since = uv.now()",
  "        elseif (uv.now() - state.idle_since) >= opts.restore_idle_ms then",
  "          state.idle_since = nil",
  "          handlers.restore()",
  "        end",
  "      end",
  "      state.was_busy = busy",
}

local FILE = "demo/watcher.lua"
local PROPOSED = "✻ [Claude Code] " .. FILE .. " ⧉ (proposed)"

M.tab = nil
M.buffers = {}
M.outcome = nil
M.on_resolve = nil

--- One side of the diff. `bufhidden = "hide"` for the same reason upstream's
--- proposed buffer has it: closing its window has to leave the buffer loaded,
--- or parser.diff_pending() stops being true at the one moment provider.lua
--- leans on it. Deleting them is close()'s job, in close()'s order.
local function scratch(name, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lua"
  vim.bo[buf].modifiable = false
  return buf
end

--- Settle the diff. The first answer wins, whether it came from a key or from
--- the tour making the move itself.
---@param outcome "accepted"|"rejected"
function M.resolve(outcome)
  if M.outcome or not M.pending() then
    return
  end
  M.outcome = outcome
  if M.on_resolve then
    M.on_resolve(outcome)
  end
end

--- What claudecode.nvim binds as <leader>da / <leader>dd, on one key each so
--- the tour does not have to know your leader.
local function keys(buf)
  local function press(outcome)
    return function()
      M.resolve(outcome)
    end
  end
  vim.keymap.set("n", "a", press("accepted"), { buffer = buf, desc = "Accept the proposed edit" })
  vim.keymap.set("n", "r", press("rejected"), { buffer = buf, desc = "Reject the proposed edit" })
  vim.keymap.set("n", "q", press("rejected"), { buffer = buf, desc = "Reject the proposed edit" })
end

--- Open the diff in its own tab, the way claudecode.nvim's
--- `diff_opts.open_in_new_tab` does. `on_resolve` is called with "accepted" or
--- "rejected" once the key is pressed.
function M.open(on_resolve)
  M.outcome = nil
  M.on_resolve = on_resolve
  vim.cmd("tabnew")
  M.tab = vim.api.nvim_get_current_tabpage()
  -- The empty buffer :tabnew made for the window we are about to fill. Nothing
  -- else will ever delete it, and a stray [No Name] left in the buffer list is
  -- not something a tour gets to leave behind.
  local blank = vim.api.nvim_get_current_buf()

  local original = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(original, scratch(FILE, BEFORE))
  vim.cmd("belowright vsplit")
  local proposed = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(proposed, scratch(PROPOSED, AFTER))
  M.buffers = { vim.api.nvim_win_get_buf(original), vim.api.nvim_win_get_buf(proposed) }

  for win, label in pairs({ [original] = FILE, [proposed] = PROPOSED }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
    vim.wo[win].winbar = "  " .. label
    vim.wo[win].number = true
    vim.wo[win].foldenable = false
    keys(vim.api.nvim_win_get_buf(win))
  end

  vim.api.nvim_set_current_win(proposed)

  if vim.api.nvim_buf_is_valid(blank) and vim.api.nvim_buf_get_name(blank) == "" then
    pcall(vim.api.nvim_buf_delete, blank, { force = true })
  end
end

--- Is the diff still on screen? The user can always close the tab themselves,
--- which is a rejection by another name.
function M.pending()
  return M.tab ~= nil and vim.api.nvim_tabpage_is_valid(M.tab)
end

--- Has the diff been answered -- by a key, by the tour making the move itself,
--- or by the tab being closed out from under it? Never true before one has
--- opened, which is what keeps the beat that waits for this from being over
--- before it has begun.
function M.settled()
  return M.tab ~= nil and (M.outcome ~= nil or not M.pending())
end

--- Tear the diff down the way claudecode.nvim tears one down, because the
--- order is the whole point: close the tab, ask the provider to put Claude
--- back on screen (upstream's terminal.ensure_visible, from its diff cleanup),
--- and only then delete the proposed buffer.
---
--- In between those last two the buffer is hidden but still loaded, so
--- parser.diff_pending() is still true, so provider.ensure_visible() brings
--- back the corner notification rather than the float -- and the float's
--- return stays where it belongs, with the watcher and its restore_idle_ms
--- debounce. Wiping the buffer with the tab would skip all of that, and the
--- float would snap back over the review you had just finished reading.
function M.close()
  local buffers = M.buffers
  if #buffers == 0 then
    M.tab = nil
    return
  end
  -- Only ours: the caption is a floating window in this tab too, and the tab
  -- closes with its last ordinary window anyway. Collected before closing any
  -- of them, because closing the first takes the tab -- and every other handle
  -- in it -- with it.
  local targets = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.tbl_contains(buffers, vim.api.nvim_win_get_buf(win)) then
      table.insert(targets, win)
    end
  end
  for _, win in ipairs(targets) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  provider.ensure_visible()

  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  M.tab = nil
  M.buffers = {}
  M.outcome = nil
  M.on_resolve = nil
end

return M
