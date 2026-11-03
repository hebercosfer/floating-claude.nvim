-- Posting to the hooks listener the way Claude Code does -- a JSON body, the
-- session's token in a header -- through curl in its own process, so a spec
-- can block the main loop while a request is in flight.

local M = {}

local function body_file(body)
  local path = vim.fn.tempname()
  local file = assert(io.open(path, "wb"))
  file:write(body)
  file:close()
  return path
end

local function argv(port, token, body, path)
  return {
    "curl",
    "-s",
    "-o",
    "/dev/null",
    "-w",
    "%{http_code} %{time_total}",
    "-m",
    "20",
    "-H",
    "Content-Type: application/json",
    "-H",
    "X-Floating-Claude: " .. token,
    "--data-binary",
    "@" .. body_file(body),
    "http://127.0.0.1:" .. port .. (path or "/hook"),
  }
end

--- curl's `-w` line as numbers. A refused connection is code 0.
---@param out string|nil
---@return { code: integer, time: number }
function M.parse(out)
  local code, time = (out or ""):match("(%d+) ([%d%.]+)")
  return { code = tonumber(code) or 0, time = tonumber(time) or 0 }
end

---@return { code: integer, time: number }
function M.sync(port, token, body, path)
  return M.parse(vim.system(argv(port, token, body, path), { text = true }):wait(30000).stdout)
end

--- Start a post after `delay_s` seconds and return the running job.
---@return vim.SystemObj
function M.async(port, token, body, delay_s)
  local words = vim.tbl_map(vim.fn.shellescape, argv(port, token, body))
  return vim.system(
    { "sh", "-c", "sleep " .. delay_s .. "; exec " .. table.concat(words, " ") },
    { text = true }
  )
end

return M
