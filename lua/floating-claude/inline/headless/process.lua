-- One `claude -p` process for one headless inline request: the prompt goes in
-- as a single stream-json line, the reply's text comes back as it is written,
-- and the process ends with it.
--
--   process.start(opts) -> { stop = fun() }
--
-- Exactly one of on_done / on_error is called, once, unless stop() was called
-- first, in which case neither is. Every callback runs on the main loop.
--
-- stdout is stream-json, one object a line. Two of them matter:
--
--   {"type":"stream_event","event":{"type":"content_block_delta",
--      "delta":{"type":"text_delta","text":"..."}}}   -> on_delta(text)
--   {"type":"result","is_error":false,...}             -> on_done()
--
-- Everything else (system, assistant, user, other deltas) is ignored.
--
-- No tools and no MCP servers: Claude answers from what it is sent, so nothing
-- it does can touch a file or wait on an approval. No settings either (and so
-- none of the user's hooks) and no slash commands: a hook that adds context to
-- every call would cost tokens on each request and could break the reply's
-- format.

local M = {}

--- The first line of `text` that is not blank, or nil.
---@param text string
---@return string|nil
local function first_line(text)
  for line in text:gmatch("[^\r\n]+") do
    if line:match("%S") then
      return line
    end
  end
end

---@class floating_claude.HeadlessOpts
---@field cmd string[] The claude command, e.g. { "claude" }.
---@field model string|false
---@field system string
---@field prompt string
---@field on_delta fun(text: string)
---@field on_done fun()
---@field on_error fun(msg: string)

---@param opts floating_claude.HeadlessOpts
---@return { stop: fun() }
function M.start(opts)
  local name = opts.cmd[1]

  local argv = vim.list_extend({}, opts.cmd)
  vim.list_extend(argv, {
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
    "--setting-sources",
    "",
    "--disable-slash-commands",
    "--system-prompt",
    opts.system,
  })
  if opts.model then
    vim.list_extend(argv, { "--model", opts.model })
  end

  -- Over: a result came, the process failed, or stop() was called. What is
  -- still queued on the main loop from before then is dropped.
  local over = false
  local stdin_open = true
  local proc
  local out_buf = ""
  local stderr = {}

  local function finish(report)
    if over then
      return
    end
    over = true
    report()
  end

  local function fail(msg)
    finish(function()
      opts.on_error(msg)
    end)
  end

  local function on_line(line)
    if over or line == "" then
      return
    end
    local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(msg) ~= "table" then
      return
    end
    if msg.type == "stream_event" then
      local event = msg.event
      local delta = type(event) == "table" and event.type == "content_block_delta" and event.delta
      if type(delta) == "table" and delta.type == "text_delta" and type(delta.text) == "string" then
        opts.on_delta(delta.text)
      end
    elseif msg.type == "result" then
      if msg.is_error then
        local why = type(msg.result) == "string" and first_line(msg.result)
        fail(why or (type(msg.subtype) == "string" and msg.subtype) or "claude reported an error")
      else
        finish(opts.on_done)
      end
    end
  end

  local function on_stdout(_, data)
    if not data then
      return
    end
    out_buf = out_buf .. data
    while true do
      local nl = out_buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = out_buf:sub(1, nl - 1)
      out_buf = out_buf:sub(nl + 1)
      on_line(line)
    end
  end

  local function on_stderr(_, data)
    if data then
      stderr[#stderr + 1] = data
    end
  end

  local function on_exit(res)
    -- The last line may have no newline after it.
    if out_buf ~= "" then
      local rest = out_buf
      out_buf = ""
      on_line(rest)
    end
    if over then
      return
    end
    local why = first_line(table.concat(stderr))
    if res.code ~= 0 then
      fail(why or ("%s exited with code %d"):format(name, res.code))
    else
      fail(why or ("%s ended without a reply"):format(name))
    end
  end

  local ok, obj = pcall(vim.system, argv, {
    stdin = true,
    text = true,
    stdout = vim.schedule_wrap(on_stdout),
    stderr = vim.schedule_wrap(on_stderr),
  }, vim.schedule_wrap(on_exit))
  if not ok then
    -- Not started, so nothing will call back: report it from the main loop,
    -- after the caller has the handle in hand.
    vim.schedule(function()
      fail(("cannot run %s"):format(name))
    end)
    return {
      stop = function()
        over = true
      end,
    }
  end
  proc = obj

  local function close_stdin()
    if stdin_open then
      stdin_open = false
      pcall(proc.write, proc, nil)
    end
  end

  local line =
    vim.json.encode({ type = "user", message = { role = "user", content = opts.prompt } })
  pcall(proc.write, proc, line .. "\n")
  close_stdin()

  return {
    stop = function()
      over = true
      close_stdin()
      pcall(proc.kill, proc, "sigterm")
    end,
  }
end

return M
