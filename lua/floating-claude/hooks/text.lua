-- The corner's words, made from what Claude's hooks carry.
--
-- Hooks hand over Claude's own text -- markdown, one logical line per
-- paragraph, never wrapped to the terminal -- so there is nothing to undo
-- here, unlike the screen. What is left is choosing: the newest paragraph
-- worth reading, a tool call in a handful of words, the question a request
-- puts to you, and which "prompts" are not something you typed.
--
-- Runs inside the listener thread as well as on the main loop: plain Lua and
-- the vim.* string helpers only.

local M = {}

-- Tools whose calls are Claude's own bookkeeping, not work worth a line.
M.PLUMBING = {
  ToolSearch = true,
  TodoWrite = true,
  TaskCreate = true,
  TaskUpdate = true,
  TaskGet = true,
  TaskList = true,
  TaskOutput = true,
  TaskStop = true,
}

-- What Claude Code wraps around prompts it submits on its own behalf -- a
-- background task finishing, a slash command, a `!` shell line.
local SYNTHETIC = {
  ["task-notification"] = true,
  ["command-name"] = true,
  ["command-message"] = true,
  ["local-command-caveat"] = true,
  ["local-command-stdout"] = true,
  ["bash-input"] = true,
  ["bash-stdout"] = true,
  ["bash-stderr"] = true,
}

-- Tools that ask you something. Their request says what they are about;
-- naming the tool before or after it is plumbing in the corner.
local ASKS = { AskUserQuestion = true, ExitPlanMode = true }

local FILE_TOOLS = { Read = true, Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

local VERB = {
  Read = "Read ",
  Edit = "Edit ",
  MultiEdit = "Edit ",
  NotebookEdit = "Edit ",
  Write = "Write ",
  Grep = "Search ",
  Glob = "Find ",
  WebFetch = "Fetch ",
  WebSearch = "Search the web: ",
}

-- Markup off one line of prose. Underscore emphasis only counts between
-- spaces or punctuation, so snake_case names come through whole.
local function strip(line)
  line = line:gsub("^>%s?", ""):gsub("^[-*+]%s+", ""):gsub("^%d+[.)]%s+", "")
  line = line:gsub("`([^`]*)`", "%1")
  line = line:gsub("%[([^%]]+)%]%([^%)]*%)", "%1")
  line = line:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
  line = line:gsub("%*([^%s*][^*]-)%*", "%1")
  line = (" " .. line .. " "):gsub("([%s%(])_([^_%s][^_]-)_([%s%.,;:!%?%)])", "%1%2%3")
  return vim.trim((line:gsub("%s+", " ")))
end

local function is_rule(trimmed)
  return trimmed:match("^[-*_][-*_%s]*$") ~= nil and #trimmed:gsub("%s", "") >= 3
end

--- The newest paragraph of prose in a message, its markup taken off. Code,
--- tables, rules and headings are not prose; nil when nothing else is left.
---@param markdown string|nil
---@return string|nil
function M.prose(markdown)
  if type(markdown) ~= "string" then
    return nil
  end
  local paragraphs, current, fenced = {}, {}, false
  local function close()
    if #current > 0 then
      table.insert(paragraphs, table.concat(current, " "))
      current = {}
    end
  end
  for line in (markdown .. "\n"):gmatch("(.-)\r?\n") do
    local trimmed = vim.trim(line)
    if trimmed:sub(1, 3) == "```" then
      fenced = not fenced
      close()
    elseif fenced then
      -- Code is never the sentence worth reading.
    elseif
      trimmed == ""
      or trimmed:sub(1, 1) == "|"
      or trimmed:match("^#+%s")
      or is_rule(trimmed)
    then
      close()
    else
      local words = strip(trimmed)
      if words ~= "" then
        table.insert(current, words)
      end
    end
  end
  close()
  return paragraphs[#paragraphs]
end

local function first_line(s)
  if type(s) ~= "string" then
    return nil
  end
  s = vim.trim(s:match("^[^\n]*"))
  return s ~= "" and s or nil
end

local function basename(path)
  return type(path) == "string" and path:match("([^/\\]+)$") or nil
end

local function host(url)
  return type(url) == "string" and url:match("^%a[%w+.-]*://([^/:?#]+)") or nil
end

--- What a tool call is about, in a few words: the description Claude gave a
--- command, a file's name, a pattern, a host. nil when the tool says nothing
--- worth repeating.
---@param name string
---@param input table|nil
---@return string|nil
function M.detail(name, input)
  input = input or {}
  if name == "Bash" then
    return first_line(input.description) or first_line(input.command)
  elseif FILE_TOOLS[name] then
    return basename(input.file_path or input.notebook_path)
  elseif name == "Grep" or name == "Glob" then
    return first_line(input.pattern)
  elseif name == "WebFetch" then
    return host(input.url)
  elseif name == "WebSearch" then
    return first_line(input.query)
  elseif name == "Agent" or name == "Task" then
    return first_line(input.description)
  end
  return nil
end

--- One line for a tool call in progress; nil for Claude's own plumbing.
---@param name string
---@param input table|nil
---@return string|nil
function M.tool_line(name, input)
  if M.PLUMBING[name] or ASKS[name] then
    return nil
  end
  local server, tool = name:match("^mcp__(.-)__(.+)$")
  if server then
    return server .. ": " .. tool
  end
  local detail = M.detail(name, input)
  if not detail then
    return name
  end
  if name == "Bash" or name == "Agent" or name == "Task" then
    return detail
  end
  return VERB[name] and (VERB[name] .. detail) or name
end

--- What a request asks of you: Claude's own question, the plan it wants
--- approved, or the tool it wants to run.
---@param name string
---@param input table|nil
---@return string
function M.request_line(name, input)
  input = input or {}
  if name == "AskUserQuestion" then
    local first = type(input.questions) == "table" and input.questions[1] or nil
    local question = type(first) == "table" and first_line(first.question) or nil
    if question then
      return question
    end
  elseif name == "ExitPlanMode" then
    return "Plan ready for review"
  end
  local detail = M.detail(name, input)
  local server, tool = name:match("^mcp__(.-)__(.+)$")
  if server then
    name = server .. ": " .. tool
  end
  return detail and ("Allow " .. name .. ": " .. detail .. "?") or ("Allow " .. name .. "?")
end

--- Whether a submitted prompt is one Claude Code wrote itself.
---@param prompt string|nil
---@return boolean
function M.is_synthetic(prompt)
  if type(prompt) ~= "string" then
    return false
  end
  local tag = prompt:match("^%s*<([%w%-]+)>")
  return tag ~= nil and SYNTHETIC[tag] == true
end

return M
