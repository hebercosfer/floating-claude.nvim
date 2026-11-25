-- Inline mode: ask Claude about the code in front of you.
--
-- This is the entry. The key and the command land in ask(), which opens the
-- input under the range and, once you submit, hands the instruction to
-- submit(). That is the seam: session mode (typed into the Claude the float is
-- running) and headless mode (a `claude -p` of its own) each start from there,
-- by `ctx.mode`, and until headless does, it only shows the instruction back
-- as the first inline line.
--
-- Session mode is wired here. A request goes out as a paste into Claude's
-- terminal -- at once, or once its turn is over, by inline.when_busy -- and is
-- followed from then on by the session's hook records and by a regular look at
-- the clock and the screen, for the things no hook reports (an Esc, a dialog
-- declined, a prompt Claude never took). request.lua decides what each means;
-- this file feeds it and draws what it says, as the lines under the code.
--
-- One request is in flight at a time, across both modes: `current`. It is taken
-- when a request goes out or waits, and let go when it ends -- whichever way --
-- or when its lines are cleared. The lines stay after it.

local config = require("floating-claude.config")
local input = require("floating-claude.inline.input")
local lines = require("floating-claude.inline.lines")
local parser = require("floating-claude.parser")
local record = require("floating-claude.hooks.record")
local request = require("floating-claude.inline.request")
local send = require("floating-claude.inline.send")
local session = require("floating-claude.hooks.session")
local state = require("floating-claude.state")

local M = {}

-- How often, in ms, a request in flight looks at the clock and the screen.
local TICK_MS = 250
-- How long, in ms, after something was put into Claude's terminal an empty
-- input box is not believed: the screen may not have been redrawn yet.
local TYPED_SETTLE_MS = 500

local EXITED = "Claude exited · start it with :ClaudeCode"

---@class floating_claude.InlineContext
---@field buf integer the buffer the request is about
---@field win integer the window it was asked from
---@field first_row integer 0-based first row of the range
---@field row integer 0-based last row of the range, where the lines hang from
---@field mode "session"|"headless"

-- The request in flight, and what is following it.
---@class floating_claude.InlineRun
---@field req floating_claude.InlineRequest
---@field buf integer
---@field timer uv.uv_timer_t|nil

---@type floating_claude.InlineRun|nil
local current = nil

-- <CR> on the lines: the float, focused on Claude's prompt.
local function open_claude()
  require("floating-claude").restore()
end

-- Draw the request as it stands. With `at`, where the range is; without it, the
-- lines stay where the code has moved them to.
---@param run floating_claude.InlineRun
---@param at { row: integer, first_row: integer }|nil
local function draw(run, at)
  lines.render(run.buf, at and at.row, request.items(run.req), {
    first_row = at and at.first_row,
    -- On every render: the <CR> exists only while it is passed.
    on_enter = open_claude,
  })
end

-- Let go of the request: nothing follows it any more, and the float may come
-- back for Claude as it does for anything else.
---@param run floating_claude.InlineRun
local function finish(run)
  if current ~= run then
    return
  end
  current = nil
  if run.timer then
    run.timer:stop()
    if not run.timer:is_closing() then
      run.timer:close()
    end
    run.timer = nil
  end
  session.on_record("inline", nil)
  session.set_inline(false)
end

-- Draw what changed, and let go of the request once it is over.
---@param run floating_claude.InlineRun
---@param changed boolean
---@param at { row: integer, first_row: integer }|nil
local function settle(run, changed, at)
  if changed then
    draw(run, at)
  end
  if request.ended(run.req) then
    finish(run)
  end
end

-- What Claude's input box holds, and whether you typed it, for the gate.
--
-- An empty box a moment after you typed is not believed -- the screen may not
-- have caught up with the key -- and counts as a draft, which is the side to
-- err on: pasting into a half-typed prompt cannot be taken back. Nor does it
-- forget what was typed.
---@return string|nil draft
---@return boolean typed
local function read_box()
  local draft = parser.input_draft()
  if draft == "" then
    local at = send.typed_at()
    if at and record.now_ms() - at < TYPED_SETTLE_MS then
      return nil, true
    end
  end
  send.clear_typed_if_empty(draft)
  return draft, send.typed()
end

-- Whether to send now, from what the box holds and what Claude is doing.
--
-- Claude is busy when the session says so OR the screen does: the session can
-- say idle while Claude works (the corner opening a moment after a prompt, before
-- its status line is drawn, settles the phase to idle), and a prompt sent then is
-- queued mid-turn and its reply cannot be told from the turn's own. A live status
-- line means working, whatever the records say -- the session's own rule when the
-- corner opens (hooks/session.lua). A waiting request is sent only when both agree
-- Claude is idle. `when_busy = "send"` never waits, so it skips the screen's say;
-- the box is read for it all the same, for a draft is never sent over.
---@return "send"|"wait"|"draft"|"asking"
local function verdict()
  local when_busy = config.options.inline.when_busy
  local draft, typed = read_box()
  local phase = session.state().phase
  if when_busy ~= "send" and phase == "idle" and parser.status().working then
    phase = "working"
  end
  return send.gate(when_busy, phase, draft, typed)
end

-- Do what the gate said.
---@param run floating_claude.InlineRun
---@param what "send"|"wait"|"draft"|"asking"
local function apply(run, what)
  local req = run.req
  if what == "send" then
    send.paste(state.jobid, req.prompt)
    req.phase, req.sent_at = "sent", record.now_ms()
  elseif what == "wait" then
    req.phase = "waiting"
  else
    -- Dropped, never retried: your text is not touched, and nothing sent.
    req.phase = "dropped"
    req.note = what == "asking" and request.ASKING or request.DRAFT
  end
end

-- Claude's turn is over, so a waiting request is gated again: sent if the box
-- is still clear, dropped with the reason if not.
---@param run floating_claude.InlineRun
local function resume(run)
  local what = verdict()
  if what == "wait" then
    return
  end
  apply(run, what)
  settle(run, true)
end

-- A live record, after the session has taken it in.
---@param rec floating_claude.Record
local function on_record(rec)
  local run = current
  if not run then
    return
  end
  local req = run.req
  if req.phase == "waiting" then
    if rec.event == "SessionEnd" then
      req.phase, req.note = "failed", EXITED
      settle(run, true)
    elseif session.state().phase == "idle" or rec.event == "StopFailure" then
      resume(run)
    end
    return
  end
  local changed = request.on_record(req, rec)
  if rec.event == "SessionEnd" and req.phase == "failed" and not req.note then
    req.note = EXITED
  end
  settle(run, changed)
end

local function hooks_needed()
  return "Inline mode needs Claude's hooks: "
    .. (session.reason() or "this Claude is not heard through them")
end

-- Why a request in flight can never hear the end of its turn: Claude is gone,
-- or no longer reports.
---@return string|nil
local function lost()
  if not state.buf_valid() then
    return EXITED
  end
  if not session.active() then
    return hooks_needed()
  end
end

-- The clock and the screen's say, while the request is out.
---@param run floating_claude.InlineRun
local function tick(run)
  if current ~= run then
    return
  end
  local req = run.req
  local gone = lost()
  if gone then
    req.phase, req.note = "failed", gone
    settle(run, true)
    return
  end
  if req.phase == "waiting" then
    -- The turn ahead settled with no record to say so: an Esc the session's
    -- safety net has found, or the status line leaving the screen after a Stop.
    -- The design says an interrupt DROPS a waiting request; this sends it
    -- instead: Claude is idle and the box clear, which is what it waited for.
    -- The gate looks at the screen too, and sends only when both agree.
    if session.state().phase == "idle" then
      resume(run)
    end
    return
  end
  local status = parser.status()
  settle(
    run,
    request.on_tick(req, record.now_ms(), {
      working = status.working,
      box = parser.input_draft() ~= nil,
    })
  )
end

-- Take the one place in flight.
---@param buf integer
---@param req floating_claude.InlineRequest
---@return floating_claude.InlineRun
local function acquire(buf, req)
  local run = { req = req, buf = buf }
  current = run
  -- From here Claude works on the code in front of you, which the float would
  -- cover: it does not come back for this (attention.lua).
  session.set_inline(true)
  session.on_record("inline", on_record)
  run.timer = vim.uv.new_timer()
  run.timer:start(
    TICK_MS,
    TICK_MS,
    vim.schedule_wrap(function()
      tick(run)
    end)
  )
  return run
end

-- Why this request cannot go, if it cannot.
---@param mode "session"|"headless"
---@return string|nil
local function refusal(mode)
  if current then
    return "An inline request is already running"
  end
  if mode ~= "session" then
    return nil
  end
  if not require("floating-claude").is_running() then
    return "Claude isn't running · start it with :ClaudeCode"
  end
  if not session.active() then
    return hooks_needed()
  end
end

-- Whether the request was refused, and said so.
---@param mode "session"|"headless"
---@return boolean
local function refused(mode)
  local why = refusal(mode)
  if why then
    vim.notify(why, vim.log.levels.WARN)
  end
  return why ~= nil
end

-- Write the buffer, since Claude reads the file on disk and would otherwise be
-- asked about lines that are not in it. nil when it was written (or needed no
-- writing), else why not.
---@param buf integer
---@return string|nil
local function save(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return "Inline mode needs a file: this buffer is not one on disk"
  end
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent update")
  end)
  if not ok then
    err = tostring(err):match("Vim%(update%):(.*)$") or tostring(err)
    return ("Inline mode couldn't save %s for Claude: %s"):format(
      vim.fn.fnamemodify(name, ":~:."),
      vim.trim(err)
    )
  end
end

-- Session mode: type the request into the Claude the float is running.
---@param ctx floating_claude.InlineContext
---@param instruction string
local function start_session(ctx, instruction)
  local unsaved = save(ctx.buf)
  if unsaved then
    vim.notify(unsaved, vim.log.levels.WARN)
    return
  end
  local req = request.new({
    file = vim.api.nvim_buf_get_name(ctx.buf),
    line1 = ctx.first_row + 1,
    line2 = ctx.row + 1,
    instruction = instruction,
  })
  local run = acquire(ctx.buf, req)
  apply(run, verdict())
  settle(run, true, { row = ctx.row, first_row = ctx.first_row })
end

-- Headless mode is a `claude -p` of its own, and starts here once it exists.
-- Until then the instruction is only shown back.
---@param ctx floating_claude.InlineContext
---@param instruction string
local function start_headless(ctx, instruction)
  lines.render(ctx.buf, ctx.row, { "▸ " .. instruction }, { first_row = ctx.first_row })
end

---@param ctx floating_claude.InlineContext
---@param instruction string
local function submit(ctx, instruction)
  -- Asked again, for the input stayed open while things may have changed.
  if refused(ctx.mode) then
    return
  end
  if ctx.mode == "headless" then
    start_headless(ctx, instruction)
  else
    start_session(ctx, instruction)
  end
end

--- Open the input under the range, and dispatch what you type.
---@param opts { line1: integer, line2: integer, mode: "session"|"headless"|nil }
---  `line1`/`line2`: the 1-based lines, as a command's range gives them.
---  `mode`: for this request only; otherwise `inline.mode`.
function M.ask(opts)
  if not config.options.inline.enabled then
    vim.notify("Inline mode is turned off (inline.enabled = false)", vim.log.levels.INFO)
    return
  end
  local ctx = {
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    first_row = math.min(opts.line1, opts.line2) - 1,
    row = math.max(opts.line1, opts.line2) - 1,
    mode = (opts.mode or config.options.inline.mode) == "headless" and "headless" or "session",
  }
  -- Before the input, so you are not asked to type what cannot go.
  if refused(ctx.mode) then
    return
  end
  input.open({
    win = ctx.win,
    row = ctx.row,
    on_submit = function(text)
      submit(ctx, text)
    end,
  })
end

--- Claude's job is gone (it exited, or was closed): a request in flight can
--- never hear its end, so it ends as failed, saying so, and lets go of the place
--- and of what it set (the timer, its listener, the session's inline flag). The
--- lines stay, and so does <CR> on them.
function M.claude_exited()
  local run = current
  if not run then
    return
  end
  run.req.phase, run.req.note = "failed", EXITED
  settle(run, true)
end

--- Take the inline lines down from a buffer, and let go of the request they
--- belong to, if one is in flight: it goes on in Claude, but nothing follows it
--- here, and the next request is free to go (waiting its turn if Claude is busy).
--- This is a choice beyond the spec, for a request stuck for any reason has no
--- other way out, in any phase.
---@param buf integer|nil defaults to the current buffer
function M.clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if current and current.buf == buf then
    finish(current)
  end
  lines.clear(buf)
end

return M
