-- Getting an inline request into Claude: whether now is a good time, how it
-- goes in, and whether the text sitting in Claude's input box is something you
-- typed.

local parser = require("floating-claude.parser")
local record = require("floating-claude.hooks.record")

local M = {}

--- Whether to send now, given how inline.when_busy is set and what Claude is
--- doing. Pure.
---
---   "send"   -- send now (with `send`, mid-turn too: Claude Code queues it).
---   "asking" -- Claude is waiting on you: a dialog, a question, a failure.
---   "draft"  -- there is text in the input box that a paste would mix with.
---   "wait"   -- Claude is mid-turn: send on Stop.
---
--- `when_busy = "send"` skips only the waiting. A half-written prompt is never
--- sent over, nor a question answered, whichever way it is set, so `send` is
--- `wait` that never returns "wait".
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
  if session_phase == "request" then
    return "asking"
  end
  if draft == nil or (draft ~= "" and typed ~= false) then
    return "draft"
  end
  if session_phase == "working" and when_busy ~= "send" then
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
-- When something was last put into the terminal (record.now_ms()); nil with
-- nothing typed.
local typed_at = nil
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
--- Only a text key counts (see is_text_key): the others answer a dialog, move
--- about the box or send it, and none of them leaves a draft behind.
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
  return (mode == "t" and M.is_text_key(key)) or (mode == "nt" and (key == "p" or key == "P"))
end

--- Whether a key is text: one character you could put in a prompt, a space
--- among them. Not Esc, Tab, Enter, Backspace, an arrow or a function key, nor
--- any control or meta chord.
---@param key string
---@return boolean
function M.is_text_key(key)
  if key == "" or key:find("\0", 1, true) then
    return false
  end
  local ok, name = pcall(vim.fn.keytrans, key)
  if not ok then
    return false
  end
  if name == "<Space>" or name == "<lt>" then
    return true
  end
  if vim.fn.strchars(name) ~= 1 then
    return false
  end
  -- A single character that is not a control character (DEL, C1 included).
  local code = vim.fn.char2nr(name)
  return code >= 32 and code ~= 127 and not (code >= 0x80 and code < 0xA0)
end

--- Whether Claude's input box is on the screen now. A key typed while it is
--- not -- a dialog is up, a panel has taken the screen -- is not going into the
--- box, so it is not a draft. A function of its own so a spec can say.
---@return boolean
function M.box_readable()
  return parser.input_draft() ~= nil
end

local function mark_typed()
  typed, typed_at = true, record.now_ms()
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
    if
      watched
      and vim.api.nvim_get_current_buf() == watched
      and has_text(lines)
      and M.box_readable()
    then
      mark_typed()
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
  typed, typed_at, watched = false, nil, buf
  vim.on_key(nil, ns)
  vim.on_key(function(key, pressed)
    -- Every key, not only the first: typed_at is when the last one went in. The
    -- box is looked at last, for it is the one test that reads the screen.
    if
      M.is_typing(buf, key, pressed, vim.api.nvim_get_mode().mode, vim.api.nvim_get_current_buf())
      and M.box_readable()
    then
      mark_typed()
    end
  end, ns)
  wrap_paste()
end

--- Stop watching, and put vim.paste back as it was -- unless something wrapped
--- it since, which stays where it is and passes through ours, now quiet. For
--- when the terminal is gone, and for specs.
function M.unwatch_typing()
  vim.on_key(nil, ns)
  typed, typed_at, watched = false, nil, nil
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

--- When anything was last put into the watched terminal, in record.now_ms()'s
--- time: nil when nothing has been since the last reset_typed() (or since the
--- watch began). Whoever reads the box uses it to tell an empty read that is
--- true from one that is only the screen not yet redrawn after a key.
---@return integer|nil
function M.typed_at()
  return typed_at
end

--- Forget what was typed: Claude has taken the prompt, and the box is its own.
function M.reset_typed()
  typed, typed_at = false, nil
end

--- Forget what was typed when the box reads empty: there is nothing left of it
--- to be a draft, and what shows there next is Claude's suggestion again. Call
--- it with each read of parser.input_draft(); a box that could not be read (nil)
--- or holds text changes nothing.
---@param draft string|nil
function M.clear_typed_if_empty(draft)
  if draft == "" then
    typed, typed_at = false, nil
  end
end

return M
