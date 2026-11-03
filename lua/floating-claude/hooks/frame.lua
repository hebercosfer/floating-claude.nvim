-- Length-prefixed frames: how the listener thread and the main loop talk over
-- a uv pipe, in both directions.
--
--   <kind> <#payload>\n<payload>
--
-- A pipe is a byte stream, so a frame can arrive split across reads or several
-- to one read; the length is what lets the reader put them back together. (A
-- uv async handle would have been simpler and is wrong: libuv coalesces sends
-- that land before the other side runs, and events go missing.)
--
-- Runs inside the listener thread as well as on the main loop: plain Lua only.

local M = {}

---@param kind string A word: no spaces.
---@param payload string
---@return string
function M.encode(kind, payload)
  return kind .. " " .. #payload .. "\n" .. payload
end

--- A reader that keeps whatever is left of a split frame between calls.
---@return fun(chunk: string): { kind: string, payload: string }[]
function M.decoder()
  local buf = ""
  return function(chunk)
    buf = buf .. chunk
    local out = {}
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local kind, len = buf:sub(1, nl - 1):match("^(%S+) (%d+)$")
      len = tonumber(len)
      if not kind or #buf - nl < len then
        break
      end
      table.insert(out, { kind = kind, payload = buf:sub(nl + 1, nl + len) })
      buf = buf:sub(nl + len + 1)
    end
    return out
  end
end

return M
