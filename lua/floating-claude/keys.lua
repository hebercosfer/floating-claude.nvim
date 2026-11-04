-- The keys setup() puts down for claudecode.nvim's commands.
--
-- Left alone, they are the example list from claudecode.nvim's own README.
-- `keys` in setup() changes that list with lazy.nvim-style entries --
--   { lhs, rhs, mode = "n" | { ... }, ft = "oil" | { ... }, desc = "...", ... }
-- -- where rhs is a command string or a function, and any other field is a
-- vim.keymap.set() option. An entry replaces the default on the same key and
-- mode, `rhs = false` drops that default, anything else is added. An entry
-- with `ft` is mapped only in buffers of those file types, and stands in for
-- the default file-tree entry on its key. `defaults = false` in the list starts
-- from nothing instead; `keys = false` puts no keys down at all.
--
-- A key you have mapped yourself is left alone, so these never take one over.

local M = {}

local TREES = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw", "snacks_picker_list" }

-- claudecode.nvim's README example, less the which-key group label.
M.DEFAULTS = {
  { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
  { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
  { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
  { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
  { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
  { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
  { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
  { "<leader>as", "<cmd>ClaudeCodeTreeAdd<cr>", desc = "Add file", ft = TREES },
  { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
  { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
}

-- Fields of an entry that are not vim.keymap.set() options.
local OWN = { [1] = true, [2] = true, mode = true, ft = true }

local function list_of(value)
  return type(value) == "table" and value or { value }
end

-- What makes two entries the same key: the keys they press, the mode, and
-- whether they belong to file-type buffers.
local function id(entry)
  return table.concat({ vim.keycode(entry[1]), entry.mode or "n", entry.ft and "ft" or "" }, "\0")
end

-- An entry for several modes, as one entry per mode, so each can be replaced
-- on its own.
local function per_mode(entry)
  if type(entry.mode) ~= "table" then
    return { entry }
  end
  local each = {}
  for _, mode in ipairs(entry.mode) do
    local copy = vim.deepcopy(entry)
    copy.mode = mode
    table.insert(each, copy)
  end
  return each
end

---@param user table|boolean|nil setup()'s `keys`
---@return table[] The entries to map.
function M.resolve(user)
  if user == false then
    return {}
  end
  local changes = type(user) == "table" and user or {}
  local list = changes.defaults == false and {} or vim.deepcopy(M.DEFAULTS)
  for _, given in ipairs(changes) do
    for _, entry in ipairs(per_mode(given)) do
      local at
      for i, have in ipairs(list) do
        if id(have) == id(entry) then
          at = i
          break
        end
      end
      if entry[2] == false then
        if at then
          table.remove(list, at)
        end
      elseif at then
        list[at] = entry
      else
        table.insert(list, entry)
      end
    end
  end
  return list
end

-- What apply() put down, so the next apply() takes exactly that back.
local placed = { global = {}, local_ = {} }
local GROUP = "FloatingClaudeKeys"

local function options(entry)
  local opts = {}
  for k, v in pairs(entry) do
    if not OWN[k] then
      opts[k] = v
    end
  end
  return opts
end

local function map_in(buf, entry)
  vim.api.nvim_buf_call(buf, function()
    for _, mode in ipairs(list_of(entry.mode or "n")) do
      -- maparg() prefers the buffer's own mapping; only that one is in the way.
      if vim.fn.maparg(entry[1], mode, false, true).buffer ~= 1 then
        local opts = options(entry)
        opts.buffer = buf
        vim.keymap.set(mode, entry[1], entry[2], opts)
        table.insert(placed.local_, { buf = buf, mode = mode, lhs = entry[1] })
      end
    end
  end)
end

---@param list table[] Entries from resolve().
function M.apply(list)
  for _, m in ipairs(placed.global) do
    pcall(vim.keymap.del, m.mode, m.lhs)
  end
  for _, m in ipairs(placed.local_) do
    if vim.api.nvim_buf_is_valid(m.buf) then
      pcall(vim.keymap.del, m.mode, m.lhs, { buffer = m.buf })
    end
  end
  placed = { global = {}, local_ = {} }
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

  for _, entry in ipairs(list) do
    -- An entry without a right-hand side only names a key, as a which-key
    -- group label does; there is nothing to map.
    if entry[2] then
      if entry.ft then
        local types = list_of(entry.ft)
        vim.api.nvim_create_autocmd("FileType", {
          group = group,
          pattern = types,
          callback = function(ev)
            map_in(ev.buf, entry)
          end,
        })
        -- Buffers that were already open, a file tree among them, before setup().
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(types, vim.bo[buf].filetype) then
            map_in(buf, entry)
          end
        end
      else
        for _, mode in ipairs(list_of(entry.mode or "n")) do
          if vim.fn.maparg(entry[1], mode) == "" then
            vim.keymap.set(mode, entry[1], entry[2], options(entry))
            table.insert(placed.global, { mode = mode, lhs = entry[1] })
          end
        end
      end
    end
  end
end

return M
