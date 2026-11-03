-- Just enough HTTP/1.1 for Claude Code's hooks: read a request's head, and
-- answer with an empty response.
--
-- Claude posts each event as a JSON body with a Content-Length (it uses axios),
-- and an empty 200 means "no decision" -- which is the only answer the plugin
-- ever gives. A reply with a body could approve a tool call or rewrite its
-- input, so there is deliberately no way to send one from here.
--
-- Runs inside the listener thread: plain Lua only.

local M = {}

-- The biggest body kept. Larger ones are read and thrown away -- a Read of a
-- huge file comes back in PostToolUse's tool_response -- but still answered.
M.MAX_BODY = 16 * 1024 * 1024

-- The biggest request head read before giving up on it. Claude's are a few
-- hundred bytes; anything that runs on past this is not Claude.
M.MAX_HEAD = 16 * 1024

--- The request's head, once all of it has arrived; nil until then.
---@param buf string Everything read from the connection so far.
---@return { method: string, path: string, headers: table<string, string>, length: integer, size: integer }|nil
function M.head(buf)
  local blank = buf:find("\r\n\r\n", 1, true)
  if not blank then
    return nil
  end
  local lines = vim.split(buf:sub(1, blank - 1), "\r\n", { plain = true })
  local method, path = lines[1]:match("^(%u+) (%S+)")
  local headers = {}
  for i = 2, #lines do
    local name, value = lines[i]:match("^([^:]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return {
    method = method or "",
    path = path or "",
    headers = headers,
    length = tonumber(headers["content-length"]) or 0,
    size = blank + 3,
  }
end

local STATUS = { [200] = "200 OK", [403] = "403 Forbidden" }

--- An empty response; the connection closes after it.
---@param status 200|403
---@return string
function M.response(status)
  return "HTTP/1.1 " .. STATUS[status] .. "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
end

return M
