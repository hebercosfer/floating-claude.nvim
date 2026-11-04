-- The keys floating-claude puts down for claudecode.nvim's commands: by
-- default the example list from claudecode's own README, and otherwise
-- whatever you give it -- any key, any command or function, in any mode or
-- file type -- merged over those defaults.

local keys = require("floating-claude.keys")

local function find(list, lhs, mode)
  for _, entry in ipairs(list) do
    if entry[1] == lhs and (entry.mode or "n") == (mode or "n") and not entry.ft then
      return entry
    end
  end
end

describe("keys", function()
  after_each(function()
    keys.apply({})
    pcall(vim.keymap.del, "n", "<leader>ac")
    pcall(vim.keymap.del, "n", "<leader>zz")
  end)

  describe("resolve", function()
    it("takes claudecode.nvim's own example keys when you give none", function()
      local list = keys.resolve(nil)
      assert.equals("<cmd>ClaudeCode<cr>", find(list, "<leader>ac")[2])
      assert.equals("<cmd>ClaudeCodeSend<cr>", find(list, "<leader>as", "v")[2])
      assert.equals("<cmd>ClaudeCodeDiffAccept<cr>", find(list, "<leader>aa")[2])
      assert.equals("<cmd>ClaudeCodeDiffDeny<cr>", find(list, "<leader>ad")[2])
      assert.equals(10, #list)
    end)

    it("takes the same with keys = true", function()
      assert.same(keys.resolve(nil), keys.resolve(true))
    end)

    it("takes none with keys = false", function()
      assert.same({}, keys.resolve(false))
    end)

    it("starts from nothing with defaults = false", function()
      local list = keys.resolve({ defaults = false, { "<leader>cc", "<cmd>ClaudeCode<cr>" } })
      assert.same({ { "<leader>cc", "<cmd>ClaudeCode<cr>" } }, list)
    end)

    it("takes an entry for several modes one mode at a time", function()
      local list = keys.resolve({ { "<leader>as", "<cmd>Mine<cr>", mode = { "n", "v" } } })
      assert.equals("<cmd>Mine<cr>", find(list, "<leader>as", "v")[2])
      assert.equals("<cmd>Mine<cr>", find(list, "<leader>as", "n")[2])
      assert.equals(11, #list)
    end)

    it("lets your entry replace the default on the same key and mode", function()
      local list = keys.resolve({ { "<leader>ac", "<cmd>ClaudeCodeFocus<cr>", desc = "Mine" } })
      assert.same(
        { "<leader>ac", "<cmd>ClaudeCodeFocus<cr>", desc = "Mine" },
        find(list, "<leader>ac")
      )
      assert.equals(10, #list)
    end)

    it("drops a default you set to false", function()
      local list = keys.resolve({ { "<leader>aa", false } })
      assert.is_nil(find(list, "<leader>aa"))
      assert.equals(9, #list)
    end)

    it("adds keys of your own, commands or functions", function()
      local fn = function() end
      local list = keys.resolve({ { "<leader>zz", fn, desc = "Anything" } })
      assert.equals(fn, find(list, "<leader>zz")[2])
      assert.equals(11, #list)
    end)

    it("tells a file-tree key from the same key elsewhere", function()
      local list = keys.resolve({ { "<leader>as", "<cmd>Mine<cr>" } })
      local tree
      for _, entry in ipairs(list) do
        if entry[1] == "<leader>as" and entry.ft then
          tree = entry
        end
      end
      assert.equals("<cmd>ClaudeCodeTreeAdd<cr>", tree[2])
      assert.equals("<cmd>Mine<cr>", find(list, "<leader>as")[2])
    end)
  end)

  describe("apply", function()
    it("maps each key with its description", function()
      keys.apply({ { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" } })
      local map = vim.fn.maparg("<leader>ac", "n", false, true)
      assert.equals("Toggle Claude", map.desc)
      assert.equals("<cmd>ClaudeCode<cr>", map.rhs)
    end)

    it("maps in the modes asked for", function()
      keys.apply({ { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send" } })
      assert.equals("Send", vim.fn.maparg("<leader>as", "v", false, true).desc)
      assert.same({}, vim.fn.maparg("<leader>as", "n", false, true))
    end)

    it("maps a file-tree key in those buffers only", function()
      keys.apply({
        { "<leader>as", "<cmd>ClaudeCodeTreeAdd<cr>", desc = "Add file", ft = { "oil" } },
      })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      vim.bo[buf].filetype = "oil"
      local map = vim.fn.maparg("<leader>as", "n", false, true)
      assert.equals("Add file", map.desc)
      assert.equals(1, map.buffer)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("leaves a mapping of your own alone", function()
      vim.keymap.set("n", "<leader>zz", "<Nop>", { desc = "mine" })
      keys.apply({ { "<leader>zz", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" } })
      assert.equals("mine", vim.fn.maparg("<leader>zz", "n", false, true).desc)
    end)

    it("takes back exactly what it put down when applied again", function()
      keys.apply({ { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" } })
      keys.apply({})
      assert.same({}, vim.fn.maparg("<leader>ac", "n", false, true))
    end)
  end)
end)
