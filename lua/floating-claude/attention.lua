-- When Claude may interrupt you.
--
-- The hooks tell "Claude finished" apart from "Claude needs a response",
-- which the screen never could, and the settings choose which of the two may
-- pull Claude back into view:
--
--   minimized  auto.restore_on_input  "idle": a request or a finished turn
--                                      brings the float back; "request": only
--                                      a request; false: nothing
--   hidden     auto.show_hidden       the same choices, bringing the corner
--
-- A request acts at once -- it is certain. A finished turn waits out
-- restore_idle_ms, which new work cancels. Nothing moves while a diff is on
-- screen (you are reviewing it, and it is its own notification), and the
-- float is never interrupted at all.
--
-- Pure: the session calls it and does the moving.

local M = {}

local NOW, LATER =
  { corner = "restore_now", hidden = "show_now" }, {
    corner = "restore_later",
    hidden = "show_later",
  }

---@param where "float"|"corner"|"hidden"
---@param effect "activity"|"request"|"finished"|nil
---@param opts { restore_on_input: "idle"|"request"|false, show_hidden: "request"|"idle"|false }
---@param diff_visible boolean
---@return "restore_now"|"restore_later"|"show_now"|"show_later"|"cancel"|nil
function M.decide(where, effect, opts, diff_visible)
  if effect == "activity" then
    return "cancel"
  end
  if where == "float" or diff_visible or (effect ~= "request" and effect ~= "finished") then
    return nil
  end
  -- Not `where == "corner" and ... or ...`: a corner set to false would fall
  -- through to the hidden setting.
  local setting
  if where == "corner" then
    setting = opts.restore_on_input
  else
    setting = opts.show_hidden
  end
  if not setting then
    return nil
  end
  if effect == "request" then
    return NOW[where]
  end
  return setting == "idle" and LATER[where] or nil
end

return M
