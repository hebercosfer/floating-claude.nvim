-- The settings file handed to Claude with --settings: one HTTP hook per event
-- the plugin reads, pointing at the listener, carrying the session's token --
-- written where only you can read it, since argv is world-readable and this
-- is not.

local record = require("floating-claude.hooks.record")
local settings = require("floating-claude.hooks.settings")

describe("the hook settings", function()
  it("register one HTTP hook per subscribed event and nothing else", function()
    local built = settings.build(41234, "t0k")
    local events = vim.tbl_keys(built.hooks)
    local expected = vim.deepcopy(record.SUBSCRIBED)
    table.sort(events)
    table.sort(expected)
    assert.same(expected, events)
    for _, name in ipairs(record.SUBSCRIBED) do
      assert.same({
        {
          hooks = {
            {
              type = "http",
              url = "http://127.0.0.1:41234/hook",
              headers = { ["X-Floating-Claude"] = "t0k" },
              timeout = 2,
            },
          },
        },
      }, built.hooks[name])
    end
  end)

  it("are written to a private file, and removed", function()
    local path = assert(settings.write(41234, "t0k"))
    assert.equals(384, vim.uv.fs_stat(path).mode % 512) -- 0600
    assert.is_true(vim.startswith(path, vim.fn.stdpath("run")))
    assert.same(
      settings.build(41234, "t0k"),
      vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    )
    settings.remove(path)
    assert.is_nil(vim.uv.fs_stat(path))
  end)

  it("get a fresh file each time", function()
    local a = assert(settings.write(1, "a"))
    local b = assert(settings.write(2, "b"))
    assert.are_not.equals(a, b)
    settings.remove(a)
    settings.remove(b)
  end)

  it("report a run directory they cannot write to", function()
    local stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(what)
      return what == "run" and "/nonexistent/run" or stdpath(what)
    end
    local path, err = settings.write(41234, "t0k")
    vim.fn.stdpath = stdpath
    assert.is_nil(path)
    assert.is_string(err)
  end)
end)
