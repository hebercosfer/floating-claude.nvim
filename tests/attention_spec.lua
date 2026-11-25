-- When Claude may interrupt you: bring the float back from the corner, or the
-- corner back from hidden, in answer to what Claude just did -- asked for
-- something, finished a turn, or started new work.

local attention = require("floating-claude.attention")

describe("attention", function()
  -- Not `where == "corner" and setting or ...`: that turns a `false` setting
  -- into the fallback.
  local function opts(where, setting)
    local o = { restore_on_input = "idle", show_hidden = "request" }
    if where == "corner" then
      o.restore_on_input = setting
    elseif where == "hidden" then
      o.show_hidden = setting
    end
    return o
  end

  -- where,    setting,   on a request,   on a finished turn
  local cases = {
    { "corner", "idle", "restore_now", "restore_later" },
    { "corner", "request", "restore_now", nil },
    { "corner", false, nil, nil },
    { "hidden", "request", "show_now", nil },
    { "hidden", "idle", "show_now", "show_later" },
    { "hidden", false, nil, nil },
  }

  for _, case in ipairs(cases) do
    local where, setting, on_request, on_finished = case[1], case[2], case[3], case[4]
    it(
      ("%s with %s: %s on a request, %s on a finished turn"):format(
        where,
        tostring(setting),
        tostring(on_request),
        tostring(on_finished)
      ),
      function()
        assert.equals(on_request, attention.decide(where, "request", opts(where, setting), false))
        assert.equals(on_finished, attention.decide(where, "finished", opts(where, setting), false))
      end
    )
  end

  it("never acts while a diff is visible", function()
    for _, where in ipairs({ "corner", "hidden" }) do
      assert.is_nil(attention.decide(where, "request", opts(where, "idle"), true))
      assert.is_nil(attention.decide(where, "finished", opts(where, "idle"), true))
    end
  end)

  it("cancels on new work anywhere", function()
    for _, where in ipairs({ "float", "corner", "hidden" }) do
      assert.equals("cancel", attention.decide(where, "activity", opts(where, "idle"), false))
    end
  end)

  it("leaves the float alone", function()
    assert.is_nil(attention.decide("float", "request", opts("float", "idle"), false))
    assert.is_nil(attention.decide("float", "finished", opts("float", "idle"), false))
  end)

  it("has nothing to do without an effect", function()
    assert.is_nil(attention.decide("corner", nil, opts("corner", "idle"), false))
  end)

  -- An inline request is Claude working on the code in front of you: the float
  -- coming back over it is what inline mode is there to avoid.
  describe("for an inline request", function()
    it("never brings the float back from the corner", function()
      for _, setting in ipairs({ "idle", "request" }) do
        assert.is_nil(attention.decide("corner", "request", opts("corner", setting), false, true))
        assert.is_nil(attention.decide("corner", "finished", opts("corner", setting), false, true))
      end
    end)

    it("is no different from any other request when it is not one", function()
      assert.equals(
        "restore_now",
        attention.decide("corner", "request", opts("corner", "idle"), false, false)
      )
      assert.equals(
        "restore_later",
        attention.decide("corner", "finished", opts("corner", "idle"), false, nil)
      )
    end)

    it("still cancels a pending restore on new work", function()
      assert.equals(
        "cancel",
        attention.decide("corner", "activity", opts("corner", "idle"), false, true)
      )
    end)

    it("still brings a hidden Claude back as the corner", function()
      assert.equals(
        "show_now",
        attention.decide("hidden", "request", { show_hidden = "request" }, false, true)
      )
      assert.equals(
        "show_later",
        attention.decide("hidden", "finished", { show_hidden = "idle" }, false, true)
      )
    end)

    it("leaves the float alone, as ever", function()
      assert.is_nil(attention.decide("float", "request", opts("float", "idle"), false, true))
    end)
  end)
end)
