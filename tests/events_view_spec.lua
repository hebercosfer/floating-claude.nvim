-- The events view: the latest events the listener heard from Claude, shown
-- as Claude sent them, so anyone can see what the plugin listens to -- and
-- that the session's token is never among it.

local config = require("floating-claude.config")
local events_view = require("floating-claude.events_view")
local keymaps = require("floating-claude.keymaps")
local record = require("floating-claude.hooks.record")
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")

local function text(lines)
  return table.concat(lines, "\n")
end

local LISTENING = {
  active = true,
  running = true,
  port = 41234,
  settings_path = "/run/user/1000/nvim/floating-claude-1-1.json",
  events = record.SUBSCRIBED,
  keep = 50,
}

describe("the events view", function()
  after_each(function()
    session.stop()
    state.buf = -1
    config.setup({})
  end)

  it("states what is heard, where, and for how long", function()
    local shown = text(events_view.lines(LISTENING, { received = 3, rejected = 1, entries = {} }))
    assert.truthy(shown:find("Floating Claude — what the plugin heard from Claude Code", 1, true))
    assert.truthy(
      shown:find(
        "Listening on 127.0.0.1:41234 for: UserPromptSubmit, PreToolUse, PermissionRequest",
        1,
        true
      )
    )
    assert.truthy(
      shown:find(
        "Settings file: /run/user/1000/nvim/floating-claude-1-1.json (it holds this session's token; the token is not shown here)",
        1,
        true
      )
    )
    assert.truthy(shown:find("Kept in memory only: the last 50 events, long values cut.", 1, true))
    assert.truthy(shown:find("Received 3, rejected 1.", 1, true))
  end)

  it("never prints the session's token", function()
    local compat = require("floating-claude.compat")
    local hooks_ready = compat.hooks_ready
    compat.hooks_ready = function()
      return true
    end
    local args = session.prepare({ "claude" }, "claude")
    compat.hooks_ready = hooks_ready
    local token =
      vim.json.decode(table.concat(vim.fn.readfile(args[3]), "\n")).hooks.Stop[1].hooks[1].headers["X-Floating-Claude"]

    local info = session.info()
    info.running = true
    local log = {
      received = 1,
      rejected = 0,
      entries = {
        {
          at = 0,
          event = "Stop",
          fate = "kept",
          size = 40,
          payload = { hook_event_name = "Stop" },
        },
      },
    }
    assert.falsy(text(events_view.lines(info, log)):find(token, 1, true))
  end)

  it("says why it is not listening", function()
    local info =
      vim.tbl_extend("force", LISTENING, { active = false, reason = "hooks = false in setup()" })
    info.port = nil
    assert.truthy(
      text(events_view.lines(info, nil)):find(
        "Not listening: hooks = false in setup(). The plugin reads Claude's screen instead.",
        1,
        true
      )
    )
  end)

  -- Falling back to the screen leaves the listener up -- Claude was started
  -- pointing at it -- so what it hears is still there to see.
  it("still shows what the listener hears after falling back to the screen", function()
    local info = vim.tbl_extend("force", LISTENING, {
      active = false,
      reason = "no hook events arrived although Claude is working",
    })
    local shown = text(events_view.lines(info, { received = 2, rejected = 0, entries = {} }))
    assert.truthy(
      shown:find(
        "Reading Claude's screen: no hook events arrived although Claude is working.",
        1,
        true
      )
    )
    assert.truthy(shown:find("The listener on 127.0.0.1:41234 is still up", 1, true))
    assert.truthy(shown:find("Received 2, rejected 0.", 1, true))
  end)

  it("says when Claude is not running", function()
    local info = vim.tbl_extend("force", LISTENING, { running = false, active = false })
    assert.truthy(text(events_view.lines(info, nil)):find("Claude Code is not running.", 1, true))
  end)

  it("shows an event as Claude sent it, with a cut value's byte count", function()
    local at = os.time({ year = 2026, month = 11, day = 4, hour = 9, min = 5, sec = 7 }) * 1000 + 42
    local lines = events_view.lines(LISTENING, {
      received = 1,
      rejected = 0,
      entries = {
        {
          at = at,
          event = "UserPromptSubmit",
          fate = "forwarded",
          size = 3100,
          payload = { hook_event_name = "UserPromptSubmit", prompt = "yy… [1000 bytes more]" },
        },
      },
    })
    local shown = text(lines)
    assert.truthy(shown:find("09:05:07.042  UserPromptSubmit  forwarded  3100 bytes", 1, true))
    assert.truthy(shown:find('"prompt": "yy… [1000 bytes more]"', 1, true))
  end)

  it("lists a rejected request without a body", function()
    local lines = events_view.lines(LISTENING, {
      received = 0,
      rejected = 1,
      entries = { { at = 0, fate = "rejected", size = 12 } },
    })
    assert.truthy(lines[#lines]:find("rejected  wrong or missing token  12 bytes", 1, true))
  end)

  it("says it keeps nothing with keep = 0", function()
    local info = vim.tbl_extend("force", LISTENING, { keep = 0 })
    local shown = text(events_view.lines(info, { received = 2, rejected = 0, entries = {} }))
    assert.truthy(
      shown:find("Kept in memory only: nothing (keep = 0); only the counts below.", 1, true)
    )
    assert.truthy(shown:find("Received 2, rejected 0.", 1, true))
  end)

  it("pretty-prints with sorted keys", function()
    assert.same(
      { "{", '  "a": 1,', '  "b": {', '    "c": "x"', "  }", "}" },
      events_view.pretty({ b = { c = "x" }, a = 1 }, "  ")
    )
    assert.same({ "[", '  "a\\nb",', "  true", "]" }, events_view.pretty({ "a\nb", true }, "  "))
  end)

  it("opens a read-only buffer that q closes", function()
    events_view.open()
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("floating-claude://events", vim.api.nvim_buf_get_name(buf))
    assert.is_false(vim.bo[buf].modifiable)
    assert.equals("nofile", vim.bo[buf].buftype)
    assert.equals(vim.api.nvim_buf_line_count(buf), vim.api.nvim_win_get_cursor(0)[1])
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("closes with q when it is the last window, too", function()
    events_view.open()
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("only")
    vim.v.errmsg = ""
    vim.api.nvim_feedkeys("q", "x", false)
    assert.equals("", vim.v.errmsg)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  -- Floats belong to a tabpage: a view opened in a new tab left the corner
  -- behind in the old one, and it seemed to vanish.
  it("keeps the corner in view", function()
    state.buf = vim.api.nvim_create_buf(false, true)
    state.mini_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 10,
      height = 1,
    })
    local tab = vim.api.nvim_get_current_tabpage()

    events_view.open()

    assert.equals(tab, vim.api.nvim_get_current_tabpage())
    assert.equals(tab, vim.api.nvim_win_get_tabpage(state.mini_win))
    assert.equals("floating-claude://events", vim.api.nvim_buf_get_name(0))
    vim.api.nvim_win_close(state.mini_win, true)
    vim.cmd("silent! only")
    state.mini_win = -1
  end)

  it("reuses the view when opened again, leaving no empty tab behind", function()
    local tabs = #vim.api.nvim_list_tabpages()
    events_view.open()
    events_view.open()
    assert.equals(tabs, #vim.api.nvim_list_tabpages())
    local showing = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == "floating-claude://events" then
        showing = showing + 1
      end
    end
    assert.equals(1, showing)
    vim.cmd("silent! only")
  end)

  describe("keymap", function()
    local function mapped(lhs)
      return vim.fn.maparg(lhs, "n", false, true)
    end

    after_each(function()
      config.setup({})
      keymaps.apply()
      pcall(vim.keymap.del, "n", "<leader>ae")
    end)

    it("maps <leader>ae out of the box", function()
      config.setup({})
      keymaps.apply()
      assert.equals("Show what floating-claude heard from Claude", mapped("<leader>ae").desc)
      assert.equals("Hide Claude", mapped("<leader>aq").desc)
    end)

    it("leaves a mapping of your own alone", function()
      config.setup({ keymaps = { events = false } })
      keymaps.apply()
      vim.keymap.set("n", "<leader>ae", "<Nop>", { desc = "mine" })
      config.setup({})
      keymaps.apply()
      assert.equals("mine", mapped("<leader>ae").desc)
    end)
  end)
end)
