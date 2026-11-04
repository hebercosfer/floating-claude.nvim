-- The listener thread: the only code that talks to Claude Code's hooks.
--
-- It runs on a libuv loop of its own (vim.uv.new_thread), so it answers every
-- hook within a millisecond or two however busy Neovim's main loop is --
-- Claude awaits each hook, and a listener on the main loop stalled a 1.6s turn
-- to 11.7s in the spike. It answers first and thinks second: the reply goes
-- out before the body is even decoded.
--
-- What it keeps, all in memory and all bounded:
--   * a ring of the records since the last prompt you typed, replayed to the
--     main loop whenever the corner opens, so it is right from the first frame;
--   * the transparency log the events view shows -- the newest `keep` events
--     as Claude sent them, long values cut.
--
-- Every record reaches the main loop as it arrives, whatever the window mode:
-- the corner must be current the moment it opens, so nothing waits for it.
-- The mode the main loop sets only says when to replay the turn -- on entering
-- the corner, where the session settles the state against the screen.
--
-- Started by listener.lua with package.path pointing at the plugin's lua/
-- directory: a thread's Lua state cannot find plugin modules otherwise.
-- No vim.api, vim.fn or vim.schedule here; they do not exist in a thread.

local frame = require("floating-claude.hooks.frame")
local http = require("floating-claude.hooks.http")
local record = require("floating-claude.hooks.record")

local M = {}

-- Object nulls become nil; array nulls stay vim.NIL, because an array with
-- holes in it cannot be encoded again (the ring, the log).
local DECODE = { luanil = { object = true } }

---@param write_fd integer The pipe end frames to the main loop go to.
---@param read_fd integer The pipe end control frames come from.
---@param token string The session's token; anything without it gets a 403.
---@param opts_json string { keep: integer, idle_ms: integer|nil, max_connections: integer|nil }
function M.run(write_fd, read_fd, token, opts_json)
  local uv = vim.uv
  local opts = vim.json.decode(opts_json, DECODE)
  local keep = opts.keep or 50
  -- Any local user can reach 127.0.0.1, token or not. Claude's hooks connect,
  -- send a few hundred bytes at once and are answered within milliseconds, so
  -- a connection that goes quiet, or one too many, is not Claude's.
  local idle_ms = opts.idle_ms or 5000
  local max_connections = opts.max_connections or 64
  local connections = 0
  local mode = "float"
  local ring, log, received, rejected = {}, {}, 0, 0

  local out = uv.new_pipe()
  out:open(write_fd)
  local control = uv.new_pipe()
  control:open(read_fd)

  local function send(kind, payload)
    if not out:is_closing() then
      out:write(frame.encode(kind, payload))
    end
  end

  local function note(entry)
    if keep <= 0 then
      return
    end
    table.insert(log, entry)
    while #log > keep do
      table.remove(log, 1)
    end
  end

  -- One request's body, decoded, kept and maybe forwarded. The reply has
  -- already gone out by the time this runs.
  local function take(body, size)
    received = received + 1
    local at = record.now_ms()
    if not body then
      note({ at = at, fate = "dropped: too large", size = size })
      return
    end
    local ok, event = pcall(vim.json.decode, body, DECODE)
    if not ok or type(event) ~= "table" then
      note({ at = at, fate = "dropped: unreadable", size = size })
      return
    end
    local rec, fate = record.compact(event, at), nil
    if not rec then
      fate = event.agent_id ~= nil and "dropped: subagent" or "dropped: unsubscribed"
    else
      if rec.event == "UserPromptSubmit" and not rec.synthetic then
        ring = {}
      end
      table.insert(ring, rec)
      while #ring > record.RING_MAX do
        table.remove(ring, 1)
      end
      send("record", vim.json.encode(rec))
      fate = "forwarded"
    end
    note({
      at = at,
      event = event.hook_event_name,
      fate = fate,
      size = size,
      payload = record.cap(event, record.TEXT_CAP),
    })
  end

  local server = uv.new_tcp()
  assert(server:bind("127.0.0.1", 0))
  assert(server:listen(64, function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    server:accept(client)
    if connections >= max_connections then
      client:close()
      return
    end
    connections = connections + 1

    local timer, done = uv.new_timer(), false
    local function hang_up()
      if done then
        return
      end
      done = true
      connections = connections - 1
      timer:stop()
      timer:close()
      if not client:is_closing() then
        client:close()
      end
    end
    local function still_talking()
      timer:stop()
      timer:start(idle_ms, 0, hang_up)
    end
    still_talking()

    local function reply(status)
      client:read_stop()
      timer:stop()
      client:write(http.response(status), hang_up)
    end

    -- Chunks are kept in a table and joined once: concatenating on every read
    -- costs time in the square of the body's size.
    local parts, have, head, oversized, discarded = {}, 0, nil, false, 0
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        hang_up()
        return
      end
      still_talking()
      if not head then
        table.insert(parts, chunk)
        have = have + #chunk
        local buf = table.concat(parts)
        parts = { buf }
        head = http.head(buf)
        if not head then
          if have > http.MAX_HEAD then
            rejected = rejected + 1
            note({ at = record.now_ms(), fate = "dropped: head too large", size = have })
            hang_up()
          end
          return
        end
        if head.headers["x-floating-claude"] ~= token then
          rejected = rejected + 1
          note({ at = record.now_ms(), fate = "rejected", size = head.length })
          reply(403)
          return
        end
        local rest = buf:sub(head.size + 1)
        oversized = head.length > http.MAX_BODY
        parts, have = {}, 0
        if oversized then
          discarded = #rest
        elseif #rest > 0 then
          parts[1], have = rest, #rest
        end
      elseif oversized then
        discarded = discarded + #chunk
      else
        table.insert(parts, chunk)
        have = have + #chunk
      end
      if (oversized and discarded or have) < head.length then
        return
      end
      reply(200)
      take(not oversized and table.concat(parts):sub(1, head.length) or nil, head.length)
    end)
  end))

  local decode = frame.decoder()
  control:read_start(function(err, chunk)
    if err or not chunk then
      return
    end
    for _, f in ipairs(decode(chunk)) do
      if f.kind == "mode" then
        local was = mode
        mode = f.payload
        if mode == "corner" and was ~= "corner" then
          send("ring", vim.json.encode({ records = ring, received = received }))
        end
      elseif f.kind == "log" then
        send("log", vim.json.encode({ received = received, rejected = rejected, entries = log }))
      elseif f.kind == "stop" then
        -- Everything this loop owns: the server, any connection still open,
        -- both pipes. uv.run() returns once they are closed.
        uv.walk(function(handle)
          if not handle:is_closing() then
            handle:close()
          end
        end)
        return
      end
    end
  end)

  send("port", tostring(server:getsockname().port))
  uv.run()
end

return M
