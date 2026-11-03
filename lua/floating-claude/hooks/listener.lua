-- The main loop's handle on the listener thread (thread.lua): start it, tell
-- it which window mode Claude is in, ask it for its log, stop it.
--
-- Two pipes connect them, one each way, carrying length-prefixed frames
-- (frame.lua). Frames from the thread are read in a fast callback and handed
-- to the main loop with vim.schedule, so on_record and on_ring may call into
-- the editor.
--
-- The port must stay open for as long as Claude runs: Claude acts on what a
-- hook replies, so a released port that another process took could answer for
-- it. stop() belongs to the moment Claude's job exits, nowhere earlier.

local frame = require("floating-claude.hooks.frame")

local M = {}

-- The plugin's lua/ directory, where the thread must look for its modules.
local LUA_DIR = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

---@class floating_claude.Log
---@field received integer
---@field rejected integer
---@field entries { at: integer, event: string|nil, fate: string, size: integer, payload: table|nil }[]

---@class floating_claude.Listener
---@field port integer
---@field received integer The thread's count, as of its last ring or log.
---@field set_mode fun(mode: "float"|"corner"|"hidden")
---@field set_show_hidden fun(value: "request"|"idle"|false)
---@field log fun(cb: fun(log: floating_claude.Log))
---@field stop fun()

---@param opts { token: string, keep: integer, show_hidden: "request"|"idle"|false, on_record: fun(rec: floating_claude.Record), on_ring: fun(records: floating_claude.Record[], received: integer) }
---@return floating_claude.Listener|nil, string|nil
function M.start(opts)
  local uv = vim.uv
  local down = uv.pipe({ nonblock = true }, { nonblock = true })
  local up = uv.pipe({ nonblock = true }, { nonblock = true })
  if not down or not up then
    return nil, "could not open its pipes"
  end
  local lua_path = LUA_DIR .. "/?.lua;" .. LUA_DIR .. "/?/init.lua"
  local opts_json = vim.json.encode({
    keep = opts.keep,
    show_hidden = opts.show_hidden or false,
    -- Knobs for the specs; the thread has its own defaults.
    idle_ms = opts.idle_ms,
    max_connections = opts.max_connections,
  })

  local reader, writer = uv.new_pipe(), uv.new_pipe()
  reader:open(down.read)
  writer:open(up.write)

  local thread = uv.new_thread(function(write_fd, read_fd, token, json, path)
    package.path = path .. ";" .. package.path
    require("floating-claude.hooks.thread").run(write_fd, read_fd, token, json)
  end, down.write, up.read, opts.token, opts_json, lua_path)

  local self = { received = 0 }
  local port, stopped, log_waiters = nil, false, {}
  local decoded = { luanil = { object = true } }

  local function dispatch(f)
    if f.kind == "record" then
      opts.on_record(vim.json.decode(f.payload, decoded))
    elseif f.kind == "ring" then
      local ring = vim.json.decode(f.payload, decoded)
      self.received = ring.received
      opts.on_ring(ring.records or {}, ring.received)
    elseif f.kind == "log" then
      local log = vim.json.decode(f.payload, decoded)
      log.entries = log.entries or {}
      self.received = log.received
      local cb = table.remove(log_waiters, 1)
      if cb then
        cb(log)
      end
    end
  end

  local decode = frame.decoder()
  reader:read_start(function(err, chunk)
    if err or not chunk then
      return
    end
    for _, f in ipairs(decode(chunk)) do
      if f.kind == "port" then
        port = tonumber(f.payload)
      else
        vim.schedule(function()
          if not stopped then
            dispatch(f)
          end
        end)
      end
    end
  end)

  local function send(kind, payload)
    if not stopped and not writer:is_closing() then
      writer:write(frame.encode(kind, payload))
    end
  end

  function self.stop()
    if stopped then
      return
    end
    stopped = true
    -- Synchronously: join() blocks the main loop, so a queued write would
    -- never go out and the thread would never hear it.
    writer:try_write(frame.encode("stop", ""))
    thread:join()
    reader:close()
    writer:close()
  end

  if not vim.wait(2000, function()
    return port ~= nil
  end, 5) then
    self.stop()
    return nil, "it never reported a port"
  end

  self.port = port --[[@as integer]]
  function self.set_mode(mode)
    send("mode", mode)
  end
  function self.set_show_hidden(value)
    send("show_hidden", value or "false")
  end
  function self.log(cb)
    table.insert(log_waiters, cb)
    send("log", "")
  end
  return self
end

return M
