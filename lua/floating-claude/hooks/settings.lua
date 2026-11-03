-- The settings handed to Claude with `--settings <file>`: one HTTP hook per
-- event the plugin reads, each pointing at the listener and carrying the
-- session's token.
--
-- A file rather than a JSON string on the command line, because argv is
-- readable by every user on the machine and this holds the token. It lives in
-- Neovim's private run directory, mode 0600, and goes away with Claude.
-- Claude adds these hooks to your own; nothing of yours is replaced.

local record = require("floating-claude.hooks.record")

local M = {}

M.HEADER = "X-Floating-Claude"
-- Seconds Claude waits on one hook. The listener answers in a millisecond or
-- two from its own thread, so this only bounds what a wedged listener costs.
M.TIMEOUT_S = 2

---@param port integer
---@param token string
---@return table
function M.build(port, token)
  local hooks = {}
  for _, name in ipairs(record.SUBSCRIBED) do
    hooks[name] = {
      {
        hooks = {
          {
            type = "http",
            url = ("http://127.0.0.1:%d/hook"):format(port),
            headers = { [M.HEADER] = token },
            timeout = M.TIMEOUT_S,
          },
        },
      },
    }
  end
  return { hooks = hooks }
end

local written = 0

--- Write the settings for this listener; the path, or nil and why not.
---@param port integer
---@param token string
---@return string|nil, string|nil
function M.write(port, token)
  local dir = vim.fn.stdpath("run") --[[@as string]]
  pcall(vim.fn.mkdir, dir, "p", tonumber("700", 8))
  written = written + 1
  local path = ("%s/floating-claude-%d-%d.json"):format(dir, vim.fn.getpid(), written)
  local fd, err = vim.uv.fs_open(path, "w", tonumber("600", 8))
  if not fd then
    return nil, err
  end
  local ok, werr = vim.uv.fs_write(fd, vim.json.encode(M.build(port, token)))
  vim.uv.fs_close(fd)
  if not ok then
    os.remove(path)
    return nil, werr
  end
  return path, nil
end

---@param path string|nil
function M.remove(path)
  if path then
    os.remove(path)
  end
end

return M
