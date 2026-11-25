-- Getting an inline request into Claude: whether now is a good time, how it
-- goes in, and whether the text sitting in Claude's input box is something you
-- typed.

local M = {}

--- Whether to send now, given how inline.when_busy is set and what Claude is
--- doing. Pure.
---
---   "send"   -- send now, and let Claude Code queue it.
---   "asking" -- Claude is waiting on you: a dialog, a question, a failure.
---   "draft"  -- there is text in the input box that a paste would mix with.
---   "wait"   -- Claude is mid-turn: send on Stop.
---
--- `draft` is parser.input_draft(): "" for an empty box, nil when it could not
--- be read -- which counts as a draft, since pasting over one is the one thing
--- that cannot be taken back. Claude Code also fills an empty box with a
--- suggested next prompt, which reads exactly like a draft on the screen. A paste
--- replaces that, so it is safe, and it would otherwise refuse after nearly every
--- turn. So text in the box is only a draft if you put it there: `typed` is
--- send.typed() (see watch_typing), and with no word on it (nil) the text is
--- taken as typed.
---@param when_busy "wait"|"send"
---@param session_phase "idle"|"working"|"request"
---@param draft string|nil
---@param typed boolean|nil
---@return "send"|"wait"|"draft"|"asking"
function M.gate(when_busy, session_phase, draft, typed)
  if when_busy == "send" then
    return "send"
  end
  if session_phase == "request" then
    return "asking"
  end
  if draft == nil or (draft ~= "" and typed ~= false) then
    return "draft"
  end
  if session_phase == "working" then
    return "wait"
  end
  return "send"
end

--- Type the text into Claude's terminal and press Enter. It goes in as one
--- bracketed paste, so a line break in it is a line break in the prompt and not
--- a submit. The Enter is a write of its own: it submitted the paste whether it
--- came with it or after it (the spike's finding), and this way it never has to
--- be waited for.
---@param jobid integer
---@param text string
function M.paste(jobid, text)
  -- An escape would close the paste early and leave the rest to be read as keys.
  text = text:gsub("\27", "")
  vim.fn.chansend(jobid, "\27[200~" .. text .. "\27[201~")
  vim.fn.chansend(jobid, "\r")
end

local ns = vim.api.nvim_create_namespace("floating-claude-inline-typing")
local typed = false
-- The buffer being watched, and our hold on vim.paste while it is.
local watched = nil
local original_paste, wrapper = nil, nil

--- Whether a key counts as typing into the terminal of `buf`: one that reaches
--- the terminal, so with that buffer current and in terminal mode, as you typed
--- it and not as a mapping or a macro made it. A mapping hands over its own
--- result as `key`, with the key you pressed as `pressed`; a key that goes on
--- to the terminal is the same in both. (That keeps the key that minimizes the
--- float from counting as a word to Claude.)
---
--- A put (`p`, `P`) in terminal-normal mode counts as well: it sends the
--- register to the terminal.
---@param buf integer
---@param key string
---@param pressed string
---@param mode string
---@param current integer
---@return boolean
function M.is_typing(buf, key, pressed, mode, current)
  if current ~= buf or pressed == "" or pressed ~= key then
    return false
  end
  return mode == "t" or (mode == "nt" and (key == "p" or key == "P"))
end

local function has_text(lines)
  for _, line in ipairs(lines) do
    if line ~= "" then
      return true
    end
  end
  return false
end

-- A paste from outside (the terminal's bracketed paste, which Neovim hands to
-- vim.paste) puts text in Claude's box without a key being read. Count it, and
-- go on to the paste that would have happened.
local function wrap_paste()
  if wrapper and vim.paste == wrapper then
    return
  end
  -- Held by the wrapper itself, which may outlive our hold on it (see
  -- unwatch_typing).
  local inner = vim.paste
  original_paste = inner
  wrapper = function(lines, ...)
    if watched and vim.api.nvim_get_current_buf() == watched and has_text(lines) then
      typed = true
    end
    return inner(lines, ...)
  end
  vim.paste = wrapper
end

--- Start watching for text put into the terminal in `buf` -- keys typed into
--- it, a paste, a put -- in place of any watch before it. What was typed before
--- is forgotten.
---@param buf integer
function M.watch_typing(buf)
  typed, watched = false, buf
  vim.on_key(nil, ns)
  vim.on_key(function(key, pressed)
    if
      not typed
      and M.is_typing(
        buf,
        key,
        pressed,
        vim.api.nvim_get_mode().mode,
        vim.api.nvim_get_current_buf()
      )
    then
      typed = true
    end
  end, ns)
  wrap_paste()
end

--- Stop watching, and put vim.paste back as it was -- unless something wrapped
--- it since, which stays where it is and passes through ours, now quiet. For
--- when the terminal is gone, and for specs.
function M.unwatch_typing()
  vim.on_key(nil, ns)
  typed, watched = false, nil
  if wrapper and vim.paste == wrapper then
    vim.paste = original_paste
  end
  original_paste, wrapper = nil, nil
end

--- Whether anything has been put into the watched terminal since the last
--- reset_typed() (or since the watch began).
---@return boolean
function M.typed()
  return typed
end

--- Forget what was typed: Claude has taken the prompt, and the box is its own.
function M.reset_typed()
  typed = false
end

--- Forget what was typed when the box reads empty: there is nothing left of it
--- to be a draft, and what shows there next is Claude's suggestion again. Call
--- it with each read of parser.input_draft(); a box that could not be read (nil)
--- or holds text changes nothing.
---@param draft string|nil
function M.clear_typed_if_empty(draft)
  if draft == "" then
    typed = false
  end
end

return M
