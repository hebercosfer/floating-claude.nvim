-- A stand-in for `claude -p --output-format stream-json`, for the headless
-- inline specs. Run it the way the plugin runs claude, with the arguments it
-- would be given after the script's name:
--
--   nvim -l tests/fixtures/fake_claude.lua -p --input-format stream-json ...
--
-- What it does comes from the FAKE_CLAUDE environment variable, a JSON object
-- (every field is optional):
--
--   events  (string|table)[]  What to print, in order, one line each. A string
--                             is a text delta of that text; a table is printed
--                             as the JSON line it is.
--   result  table|false       The final `result` line: these fields over
--                             {type="result", subtype="success", is_error=false}.
--                             false prints none. Default: a success.
--   stderr  string            Written to stderr, before the exit.
--   exit    integer           The exit code. Default 0.
--   split   boolean           Write each line in two pieces, with a pause, so
--                             that a line arrives over two reads.
--   hang    boolean           After the events and the result, wait until
--                             killed: a request that is still running (with
--                             result = false, one that has not finished).
--   record  string            A file to write {argv, stdin, pid} to, as JSON,
--                             once stdin has closed and before any output.
--
-- Like claude, it takes its prompt from stdin and only starts once stdin is
-- closed, so a caller that leaves stdin open hangs here.

local script = vim.json.decode(os.getenv("FAKE_CLAUDE") or "{}")

local stdin = io.read("*a") or ""

if script.record then
  vim.fn.writefile({
    vim.json.encode({
      argv = { unpack(arg) },
      stdin = stdin,
      pid = vim.uv.os_getpid(),
    }),
  }, script.record)
end

local function emit(obj)
  local line = vim.json.encode(obj) .. "\n"
  if script.split then
    local cut = math.floor(#line / 2)
    io.stdout:write(line:sub(1, cut))
    io.stdout:flush()
    vim.uv.sleep(30)
    io.stdout:write(line:sub(cut + 1))
  else
    io.stdout:write(line)
  end
  io.stdout:flush()
end

local said = {}

emit({ type = "system", subtype = "init" })
for _, event in ipairs(script.events or {}) do
  if type(event) == "string" then
    said[#said + 1] = event
    emit({
      type = "stream_event",
      event = {
        type = "content_block_delta",
        index = 0,
        delta = { type = "text_delta", text = event },
      },
    })
  else
    emit(event)
  end
end

if script.result ~= false then
  emit(vim.tbl_extend("force", {
    type = "result",
    subtype = "success",
    is_error = false,
    result = table.concat(said),
  }, script.result or {}))
end

if script.stderr then
  io.stderr:write(script.stderr .. "\n")
  io.stderr:flush()
end

if script.hang then
  -- The event loop has to run for a SIGTERM to be seen. Bounded, so a caller
  -- that fails to stop it does not leave this behind.
  vim.wait(30000, function()
    return false
  end)
end

os.exit(script.exit or 0)
