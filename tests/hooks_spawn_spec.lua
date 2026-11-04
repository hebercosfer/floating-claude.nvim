-- Spawning Claude with the listener: the command gains `--settings <file>`,
-- the window layer tells the listener where Claude is, and Claude's exit takes
-- the port and the file with it. A shell script stands in for `claude`,
-- writing the arguments it was given to a file.

local config = require("floating-claude.config")
local post = dofile(vim.fn.fnamemodify("tests/helpers/post.lua", ":p"))
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")
local terminal = require("floating-claude.terminal")

describe("spawning Claude", function()
  local compat, hooks_ready, script, argv_out

  before_each(function()
    config.setup({ version_check = false })
    compat = require("floating-claude.compat")
    hooks_ready = compat.hooks_ready
    compat.hooks_ready = function()
      return true
    end
    script, argv_out = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.writefile({ "#!/bin/sh", 'printf "%s\\n" "$@" > "$ARGV_OUT"', "sleep 30" }, script)
    vim.fn.setfperm(script, "rwxr-xr-x")
    state.announced = nil
  end)

  after_each(function()
    terminal.close()
    state.subscribe("spy", nil)
    compat.hooks_ready = hooks_ready
    vim.cmd("silent! only")
    config.setup({})
  end)

  local function spawn()
    terminal.spawn(script, { ARGV_OUT = argv_out }, nil, false)
    assert.is_true(vim.wait(3000, function()
      return vim.uv.fs_stat(argv_out) ~= nil and #vim.fn.readfile(argv_out) > 0
    end))
    return vim.fn.readfile(argv_out)
  end

  it("passes --settings <file> to Claude", function()
    local argv = spawn()
    assert.equals("--settings", argv[1])
    assert.truthy(vim.uv.fs_stat(argv[2]))
    assert.is_true(session.active())
  end)

  it("removes the file and closes the port when Claude exits", function()
    spawn()
    local info = session.info()
    vim.fn.jobstop(state.jobid)
    assert.is_true(vim.wait(3000, function()
      return vim.uv.fs_stat(info.settings_path) == nil
    end))
    assert.equals(0, post.sync(info.port, "t", "{}").code)
  end)

  it("passes the command untouched on the fallback", function()
    config.setup({ version_check = false, hooks = false })
    local argv = spawn()
    assert.is_nil(vim.tbl_contains(argv, "--settings") or nil)
    assert.is_false(session.active())
  end)

  -- :q, <C-w>c or :only on the float bypass the plugin's own moves.
  it("tells the listener when the float is closed by hand", function()
    spawn()
    local seen = {}
    state.subscribe("spy", function(mode)
      table.insert(seen, mode)
    end)
    vim.api.nvim_win_close(state.win, true)
    assert.is_true(vim.wait(500, function()
      return seen[1] == "hidden"
    end))
  end)

  -- Claude's dialog takes Enter, 1 or y: a float that came back on its own
  -- must not hand it the keys you were typing elsewhere.
  it("brings the float back on a request without entering insert mode", function()
    spawn()
    terminal.minimize()
    -- Headless Neovim never applies a pending :startinsert, so watch for it.
    local inserted, cmd = false, vim.cmd
    vim.cmd = setmetatable({}, {
      __call = function(_, c, ...)
        inserted = inserted or c == "startinsert"
        return cmd(c, ...)
      end,
      __index = cmd,
    })
    session.inject({
      event = "PermissionRequest",
      at = require("floating-claude.hooks.record").now_ms(),
      tool_name = "Bash",
      tool_input = { command = "rm -rf build" },
    })
    vim.wait(50)
    vim.cmd = cmd
    assert.equals("float", state.mode())
    assert.is_false(inserted, "an automatic restore entered insert mode")
  end)

  it("tells the listener when Claude is minimized", function()
    spawn()
    local seen = {}
    state.subscribe("spy", function(mode)
      table.insert(seen, mode)
    end)
    terminal.minimize()
    assert.same({ "corner" }, seen)
  end)
end)
