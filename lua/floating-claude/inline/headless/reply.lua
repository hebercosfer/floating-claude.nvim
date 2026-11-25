-- What a headless inline request says to Claude, and how Claude's reply is
-- read back. Pure: no vim.api, so the specs can feed it a reply a piece at a
-- time, the way the stream delivers it.
--
-- The reply's first word is the protocol: `EDIT` is followed by the lines that
-- replace the selection, `ANSWER` by prose. A reply that starts with neither is
-- an answer, since a model that ignored the protocol was most likely talking.

local M = {}

--- The system prompt. Kept short: the reply is parsed, so every sentence here
--- is one more way for the format to drift.
M.SYSTEM = [[
You are a code assistant inside Neovim. You are given a selection from a file, the lines around it, and an instruction. Do not use tools: answer from what you are given.
Start your reply with one word, alone on the first line: EDIT or ANSWER.
Use EDIT when the instruction asks you to change the selection. After it, reply with exactly the lines that replace the selection, in its indentation and style, and nothing else: no prose before or after, no code fences, no line numbers.
Use ANSWER when the instruction asks a question or needs no change. After it, reply in plain prose, short and direct.]]

--- The user message for one request.
---
--- The surrounding lines are shown with a marker where the selection sits, so
--- that "the lines above" and "the lines below" need no line numbers: numbers
--- in the code would be copied back into the replacement.
---@param ctx { file: string, filetype: string, line1: integer, line2: integer, lines: string[], before: string[], after: string[], diagnostics: string[], instruction: string }
---@return string
function M.prompt(ctx)
  local out = {
    ("File: %s"):format(ctx.file),
    ("Filetype: %s"):format(ctx.filetype ~= "" and ctx.filetype or "none"),
    ("Selection: lines %d-%d"):format(ctx.line1, ctx.line2),
    "",
    "<selection>",
  }
  vim.list_extend(out, ctx.lines)
  out[#out + 1] = "</selection>"

  if #ctx.before > 0 or #ctx.after > 0 then
    vim.list_extend(out, { "", "The lines around it, for context only:", "<context>" })
    vim.list_extend(out, ctx.before)
    out[#out + 1] = "[the selection goes here]"
    vim.list_extend(out, ctx.after)
    out[#out + 1] = "</context>"
  end

  if #ctx.diagnostics > 0 then
    vim.list_extend(out, { "", "Diagnostics in the selection:" })
    for _, d in ipairs(ctx.diagnostics) do
      out[#out + 1] = "- " .. d
    end
  end

  vim.list_extend(out, { "", "Instruction:", ctx.instruction })
  return table.concat(out, "\n")
end

--- The code of an edit with one surrounding fence taken off, if there is one.
--- It works on a reply still arriving: the opening line is gone as soon as it
--- is whole, and a closing fence is gone while it is still being typed, so a
--- stream never shows a stray backtick on the last line.
---@param body string
---@return string
local function unfence(body)
  if body:match("^``?$") then
    -- Perhaps the start of a fence.
    return ""
  end
  if body:sub(1, 3) ~= "```" then
    return body
  end
  local _, rest = body:match("^(```[^\n]*)\n(.*)$")
  if not rest then
    -- Still on the opening line: nothing of the code has arrived.
    return ""
  end
  if rest:match("^[ \t]*`+[ \t]*\n*$") then
    return ""
  end
  return (rest:match("^(.*)\n[ \t]*`+[ \t]*\n*$")) or rest
end

---@param word string
---@return boolean
local function could_become_tag(word)
  return ("EDIT"):sub(1, #word) == word or ("ANSWER"):sub(1, #word) == word
end

--- Read a reply, or the start of one.
---
---   "pending"  the first word is not complete yet, and could still be a tag: the
---              reply so far is "", "ED", "ANSWER". Nothing to show.
---   "edit"     `body` is the replacement lines so far.
---   "answer"   `body` is the prose so far; the whole text when untagged.
---
--- The first word is complete once whitespace follows it, so "EDIT" alone is
--- pending (it may be "EDITING ...") and "Hello" is an answer at once, since no
--- more letters can turn it into a tag.
---@param text string
---@return { kind: "edit"|"answer"|"pending", body: string }
function M.parse(text)
  local word, after = text:match("^%s*(%S+)()")
  if not word then
    return { kind = "pending", body = "" }
  end
  if after > #text then
    if could_become_tag(word) then
      return { kind = "pending", body = "" }
    end
    return { kind = "answer", body = text }
  end
  if word ~= "EDIT" and word ~= "ANSWER" then
    return { kind = "answer", body = text }
  end

  -- What follows the tag on its line, and the line break itself, is not text.
  local body = text:sub(after):gsub("^[ \t]*\r?\n?", "")
  if word == "EDIT" then
    return { kind = "edit", body = unfence(body) }
  end
  return { kind = "answer", body = body }
end

return M
