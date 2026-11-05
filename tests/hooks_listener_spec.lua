-- The listener: a thread of its own that answers every hook Claude posts at
-- once, keeps a short memory of them, and passes to the main loop only what
-- the window mode lets through. Driven with curl in its own process, so a
-- spec can hold the main loop down while a request is in flight.

local listener = require("floating-claude.hooks.listener")
local post = dofile(vim.fn.fnamemodify("tests/helpers/post.lua", ":p"))

local UPS = '{"hook_event_name":"UserPromptSubmit","prompt":"%s"}'
local PRE = '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
local STOP = '{"hook_event_name":"Stop","last_assistant_message":"Done."}'
local PERMISSION =
  '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm x"}}'

describe("the hooks listener", function()
  local l, got, rings

  local function start(opts)
    got, rings = {}, {}
    l = assert(listener.start(vim.tbl_extend("force", {
      token = "t",
      keep = 50,
      on_record = function(rec)
        table.insert(got, rec)
      end,
      on_ring = function(records, received)
        table.insert(rings, { records = records, received = received })
      end,
    }, opts or {})))
    return l
  end

  local function fetch_log()
    local log
    l.log(function(result)
      log = result
    end)
    assert.is_true(vim.wait(2000, function()
      return log ~= nil
    end))
    return log
  end

  after_each(function()
    if l then
      l.stop()
      l = nil
    end
  end)

  it("answers 200 and forwards in corner mode", function()
    start().set_mode("corner")
    assert.equals(200, post.sync(l.port, "t", UPS:format("hi")).code)
    assert.is_true(vim.wait(2000, function()
      return #got == 1
    end))
    assert.equals("hi", got[1].prompt)
  end)

  -- The corner must be current the moment it opens, so nothing waits for it.
  it("forwards every event while maximized, and replays the turn on minimize", function()
    start()
    post.sync(l.port, "t", UPS:format("go"))
    post.sync(l.port, "t", PRE)
    assert.is_true(
      vim.wait(2000, function()
        return #got == 2
      end),
      "events were held back while maximized"
    )
    l.set_mode("corner")
    assert.is_true(vim.wait(2000, function()
      return #rings == 1
    end))
    assert.same({ "UserPromptSubmit", "PreToolUse" }, {
      rings[1].records[1].event,
      rings[1].records[2].event,
    })
    assert.equals(2, rings[1].received)
  end)

  it("rejects a wrong token with 403 and never forwards it", function()
    start().set_mode("corner")
    assert.equals(403, post.sync(l.port, "nope", UPS:format("forged")).code)
    vim.wait(200)
    assert.equals(0, #got)
    local log = fetch_log()
    assert.equals(1, log.rejected)
    assert.equals(0, log.received)
    assert.equals("rejected", log.entries[1].fate)
    assert.is_nil(log.entries[1].payload)
  end)

  it("keeps order across rapid posts", function()
    start().set_mode("corner")
    for i = 1, 20 do
      post.sync(l.port, "t", UPS:format(tostring(i)))
    end
    assert.is_true(vim.wait(3000, function()
      return #got == 20
    end))
    for i = 1, 20 do
      assert.equals(tostring(i), got[i].prompt)
    end
  end)

  it("answers within 500ms while the main loop is blocked", function()
    start().set_mode("corner")
    local job = post.async(l.port, "t", UPS:format("x"), 0.2)
    local stop_at = vim.uv.hrtime() + 1.5e9
    while vim.uv.hrtime() < stop_at do
    end
    local result = post.parse(job:wait(10000).stdout)
    assert.equals(200, result.code)
    assert.is_true(result.time < 0.5, "took " .. result.time .. "s")
  end)

  -- Review Focus 4: a Read of a huge file comes back in PostToolUse.
  it("answers an oversized body with 200 and logs it as too large", function()
    start().set_mode("corner")
    local huge = '{"hook_event_name":"PostToolUse","tool_response":"'
      .. string.rep("x", 17 * 1024 * 1024)
      .. '"}'
    assert.equals(200, post.sync(l.port, "t", huge).code)
    local log = fetch_log()
    assert.equals("dropped: too large", log.entries[#log.entries].fate)
    assert.is_nil(log.entries[#log.entries].payload)
    assert.equals(0, #got)
  end)

  it("forwards every event while hidden", function()
    start().set_mode("hidden")
    post.sync(l.port, "t", STOP)
    post.sync(l.port, "t", PERMISSION)
    assert.is_true(
      vim.wait(2000, function()
        return #got == 2
      end),
      "events were held back while hidden"
    )
    assert.same({ "Stop", "PermissionRequest" }, { got[1].event, got[2].event })
  end)

  it("keeps the newest entries, with long values cut", function()
    start({ keep = 3 })
    for i = 1, 4 do
      post.sync(l.port, "t", UPS:format(tostring(i)))
    end
    post.sync(l.port, "t", UPS:format(string.rep("y", 3000)))
    local log = fetch_log()
    assert.equals(3, #log.entries)
    assert.equals("3", log.entries[1].payload.prompt)
    assert.equals(string.rep("y", 2000) .. "… [1000 bytes more]", log.entries[3].payload.prompt)
    assert.equals("forwarded", log.entries[3].fate)
  end)

  it("keeps nothing with keep = 0 but still counts", function()
    start({ keep = 0 })
    post.sync(l.port, "t", UPS:format("a"))
    post.sync(l.port, "t", UPS:format("b"))
    local log = fetch_log()
    assert.equals(0, #log.entries)
    assert.equals(2, log.received)
  end)

  -- Review Focus 5: hours maximized must not grow anything.
  it("stays bounded over a long maximized session", function()
    start()
    post.sync(l.port, "t", UPS:format("long"))
    for _ = 1, 99 do
      post.sync(l.port, "t", PRE)
    end
    assert.is_true(vim.wait(2000, function()
      return #got == 100
    end))
    local log = fetch_log()
    assert.equals(50, #log.entries)
    assert.equals(100, log.received)
    l.set_mode("corner")
    assert.is_true(vim.wait(2000, function()
      return #rings == 1
    end))
    assert.equals(64, #rings[1].records)
    assert.equals("UserPromptSubmit", rings[1].records[1].event)
    assert.equals("long", rings[1].records[1].prompt)
  end)

  -- :checkhealth wants the count, not the payloads.
  it("answers a count without the events themselves", function()
    start()
    for _ = 1, 3 do
      post.sync(l.port, "t", PRE)
    end
    assert.is_true(vim.wait(2000, function()
      return #got == 3
    end))
    local log
    l.log(function(result)
      log = result
    end, { counts = true })
    assert.is_true(vim.wait(2000, function()
      return log ~= nil
    end))
    assert.equals(3, log.received)
    assert.same({}, log.entries)
    assert.equals(3, #fetch_log().entries)
  end)

  it("keeps an event with a null inside a list", function()
    start()
    local body =
      '{"hook_event_name":"PreToolUse","tool_name":"mcp__db__query","tool_input":{"rows":[null,null,null,null,null,null,null,null,null,null,null,1]}}'
    assert.equals(200, post.sync(l.port, "t", body).code)
    l.set_mode("corner")
    assert.is_true(vim.wait(2000, function()
      return #rings == 1
    end))
    assert.equals("mcp__db__query", rings[1].records[1].tool_name)
    local log = fetch_log()
    assert.equals("forwarded", log.entries[1].fate)
  end)

  -- A raw client: connects, optionally writes, and notes when the listener
  -- hangs up on it.
  local function raw(port, payload)
    local tcp, seen = vim.uv.new_tcp(), { closed = false }
    tcp:connect("127.0.0.1", port, function(err)
      if err then
        seen.closed = true
        return
      end
      tcp:read_start(function(rerr, chunk)
        if rerr or not chunk then
          seen.closed = true
          if not tcp:is_closing() then
            tcp:close()
          end
        end
      end)
      if payload then
        tcp:write(payload)
      end
    end)
    return seen
  end

  -- Any local user can reach 127.0.0.1: a head that never ends must not grow
  -- the listener's memory or stall Claude's hooks behind it.
  it("hangs up on a request head that never ends", function()
    start()
    local head = "POST /hook HTTP/1.1\r\n"
      .. string.rep("X-Filler: " .. string.rep("a", 40) .. "\r\n", 600)
    local seen = raw(l.port, head)
    assert.is_true(
      vim.wait(2000, function()
        return seen.closed
      end),
      "the listener kept reading an endless head"
    )
    local log = fetch_log()
    assert.equals(1, log.rejected)
    assert.equals("dropped: head too large", log.entries[#log.entries].fate)
    assert.equals(200, post.sync(l.port, "t", UPS:format("still here")).code)
  end)

  it("hangs up on a connection that goes quiet", function()
    start({ idle_ms = 200 })
    local seen = raw(l.port, "POST /hook HTTP/1.1\r\n")
    assert.is_true(
      vim.wait(2000, function()
        return seen.closed
      end),
      "an idle connection was held open"
    )
  end)

  it("turns away connections over its limit", function()
    start({ max_connections = 3 })
    local held = { raw(l.port), raw(l.port), raw(l.port) }
    vim.wait(200)
    local extra = raw(l.port)
    assert.is_true(
      vim.wait(1000, function()
        return extra.closed
      end),
      "a fourth connection was accepted"
    )
    for _, seen in ipairs(held) do
      assert.is_false(seen.closed)
    end
  end)

  it("closes the port on stop", function()
    local port = start().port
    l.stop()
    l = nil
    assert.equals(0, post.sync(port, "t", STOP).code)
  end)
end)
