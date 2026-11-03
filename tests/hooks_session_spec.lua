-- The session: deciding at spawn whether Claude is heard through its hooks,
-- and then turning what it hears into the corner's state and into restores
-- and shows -- with the screen kept for one line, as the safety net for the
-- interrupts no hook reports.

local config = require("floating-claude.config")
local record = require("floating-claude.hooks.record")
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")

local RULE = string.rep("─", 40)
local IDLE = { "● Done.", "", "✻ Cooked for 3s", RULE, "❯ ", RULE }
local WORKING =
  { "● Reading the parser.", "", "✽ Infusing… (12s · ↓ 1.2k tokens)", RULE, "❯ ", RULE }

describe("the hooks session", function()
  local compat, hooks_ready, now_ms, calls, buffers, windows, clock

  local function handlers()
    calls = { restore = 0, show = 0, fallback = 0 }
    session.attach({
      restore = function()
        calls.restore = calls.restore + 1
      end,
      show = function()
        calls.show = calls.show + 1
      end,
      fallback = function()
        calls.fallback = calls.fallback + 1
      end,
    })
  end

  local function terminal(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    table.insert(buffers, buf)
    state.buf = buf
  end

  local function window()
    local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 10,
      height = 1,
    })
    table.insert(windows, win)
    return win
  end

  -- Put Claude in one of its three places, and announce it the way the window
  -- layer will.
  local function go(mode)
    for _, w in ipairs({ state.win, state.mini_win }) do
      if w ~= -1 and vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
      end
    end
    state.win, state.mini_win = -1, -1
    if mode == "float" then
      state.win = window()
    elseif mode == "corner" then
      state.mini_win = window()
    end
    state.changed()
  end

  before_each(function()
    compat = require("floating-claude.compat")
    hooks_ready = compat.hooks_ready
    compat.hooks_ready = function()
      return true
    end
    now_ms, clock = record.now_ms, nil
    buffers, windows = {}, {}
    state.announced = nil
    handlers()
  end)

  after_each(function()
    session.stop()
    compat.hooks_ready = hooks_ready
    record.now_ms = now_ms
    for _, w in ipairs(windows) do
      if vim.api.nvim_win_is_valid(w) then
        vim.api.nvim_win_close(w, true)
      end
    end
    for _, b in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    state.buf, state.win, state.mini_win, state.announced = -1, -1, -1, nil
    config.setup({})
  end)

  local function at(ms)
    clock = ms
    record.now_ms = function()
      return clock
    end
  end

  describe("at spawn", function()
    it("appends --settings and a private file", function()
      local args = session.prepare({ "claude" }, "claude")
      assert.equals("--settings", args[2])
      assert.truthy(vim.uv.fs_stat(args[3]))
      assert.is_true(session.active())
      assert.equals(args[3], session.info().settings_path)
    end)

    -- Review Focus 2.
    it("leaves a command with its own --settings alone", function()
      assert.same(
        { "claude", "--settings", "x.json" },
        session.prepare({ "claude", "--settings", "x.json" }, "claude --settings x.json")
      )
      assert.is_false(session.active())
      assert.equals("the claude command already passes --settings", session.reason())
    end)

    it("honours hooks = false", function()
      config.setup({ hooks = false })
      assert.same({ "claude" }, session.prepare({ "claude" }, "claude"))
      assert.equals("hooks = false in setup()", session.reason())
    end)

    it("passes the version check's reason on", function()
      compat.hooks_ready = function()
        return false,
          "Claude Code 2.1.296 is older than 2.1.301, the first with the hooks this plugin uses"
      end
      assert.same({ "claude" }, session.prepare({ "claude" }, "claude"))
      assert.equals(
        "Claude Code 2.1.296 is older than 2.1.301, the first with the hooks this plugin uses",
        session.reason()
      )
    end)

    -- Review Focus 1.
    it("gives a restarted Claude a fresh port, token and file", function()
      session.prepare({ "claude" }, "claude")
      local first = session.info()
      session.stop()
      assert.is_nil(vim.uv.fs_stat(first.settings_path))
      session.prepare({ "claude" }, "claude")
      local second = session.info()
      assert.are_not.equals(first.port, second.port)
      assert.are_not.equals(first.settings_path, second.settings_path)
      local token =
        vim.json.decode(table.concat(vim.fn.readfile(second.settings_path), "\n")).hooks.Stop[1].hooks[1].headers["X-Floating-Claude"]
      assert.equals(32, #token)
    end)
  end)

  describe("attention", function()
    before_each(function()
      config.setup({ auto = { restore_idle_ms = 50 } })
      session.start_scripted()
      handlers()
      go("corner")
    end)

    it(
      "brings the float back on a request at once, and on a finished turn after the debounce",
      function()
        session.inject({
          event = "PermissionRequest",
          at = 1,
          tool_name = "Bash",
          tool_input = { command = "x" },
        })
        assert.equals(1, calls.restore)
        session.inject({ event = "Stop", at = 2, message = "Done." })
        vim.wait(20)
        assert.equals(1, calls.restore)
        assert.is_true(vim.wait(500, function()
          return calls.restore == 2
        end))
      end
    )

    it("does not restore when a new turn starts inside the debounce", function()
      session.inject({ event = "Stop", at = 1, message = "Done." })
      vim.wait(10)
      session.inject({ event = "UserPromptSubmit", at = 2, prompt = "more", synthetic = false })
      vim.wait(200)
      assert.equals(0, calls.restore)
    end)

    it("never restores from a ring replay", function()
      terminal(IDLE)
      session.receive_ring({ { event = "Stop", at = 1, message = "Done." } }, 1)
      vim.wait(200)
      assert.equals(0, calls.restore)
      assert.equals("idle", session.state().phase)
    end)
  end)

  describe("settling as the corner opens", function()
    before_each(function()
      session.start_scripted()
      handlers()
      at(10000)
      go("float")
    end)

    it("drops an interrupted turn to idle without restoring", function()
      terminal(IDLE)
      session.inject({ event = "UserPromptSubmit", at = 10000, prompt = "go", synthetic = false })
      go("corner")
      session.receive_ring(
        { { event = "UserPromptSubmit", at = 10000, prompt = "go", synthetic = false } },
        1
      )
      assert.equals("idle", session.state().phase)
      assert.equals(0, calls.restore)
    end)

    it("drops a request you saw in the float", function()
      terminal(IDLE)
      local rec = {
        event = "PermissionRequest",
        at = 11000,
        tool_name = "Bash",
        tool_input = { command = "x" },
      }
      session.inject(rec)
      go("corner")
      session.receive_ring({ rec }, 1)
      assert.equals("idle", session.state().phase)
      assert.is_nil(session.state().body, "the request's question outlived it")
    end)

    -- A request that brought the float back was stamped a few ms before the
    -- float opened; declined there, it is over all the same.
    it("drops a request that brought the float back", function()
      terminal(IDLE)
      go("corner")
      local rec = {
        event = "PermissionRequest",
        at = 10000,
        tool_name = "Bash",
        tool_input = { command = "x" },
      }
      session.inject(rec)
      at(10003)
      go("float")
      go("corner")
      session.receive_ring({ rec }, 1)
      assert.equals("idle", session.state().phase)
    end)

    it("takes a live status line as working, request or not", function()
      terminal(WORKING)
      local rec = {
        event = "PermissionRequest",
        at = 11000,
        tool_name = "Bash",
        tool_input = { command = "x" },
      }
      go("corner")
      session.receive_ring({ rec }, 1)
      assert.equals("working", session.state().phase)
    end)

    it("falls back when Claude works but nothing arrived", function()
      terminal(WORKING)
      go("corner")
      session.receive_ring({}, 0)
      assert.equals(1, calls.fallback)
      assert.is_false(session.active())
      assert.equals("no hook events arrived although Claude is working", session.reason())
    end)
  end)

  -- Spawn announces the float before the session starts, so the first float
  -- of every session is announced to a session that has since been reset.
  it("drops a request declined in the session's first float", function()
    terminal(IDLE)
    go("float")
    session.start_scripted()
    handlers()
    local rec = {
      event = "PermissionRequest",
      at = 20000,
      tool_name = "Bash",
      tool_input = { command = "x" },
    }
    session.inject(rec)
    go("corner")
    session.receive_ring({ rec }, 1)
    assert.equals("idle", session.state().phase)
  end)

  it("deletes the settings file when Neovim quits", function()
    local args = session.prepare({ "claude" }, "claude")
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    assert.is_nil(vim.uv.fs_stat(args[3]))
  end)

  describe("the safety net", function()
    before_each(function()
      session.start_scripted()
      handlers()
      at(0)
      session.inject({ event = "UserPromptSubmit", at = 0, prompt = "go", synthetic = false })
    end)

    it("trusts a missing status line only after seeing one", function()
      at(5000)
      session.tick({ working = false })
      assert.equals("working", session.state().phase)
      at(6000)
      session.tick({ working = true })
      at(6500)
      session.tick({ working = false })
      assert.equals("working", session.state().phase)
      at(7000)
      session.tick({ working = false })
      assert.equals("idle", session.state().phase)
    end)

    it("leaves a compacting turn alone", function()
      at(100)
      session.tick({ working = true })
      session.inject({ event = "PreCompact", at = 200, trigger = "auto" })
      at(5000)
      session.tick({ working = false })
      assert.equals("working", session.state().phase)
    end)
  end)
end)
