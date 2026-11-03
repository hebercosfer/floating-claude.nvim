-- The wire format between Claude Code and the listener thread (HTTP request
-- heads), and between the thread and the main loop (length-prefixed frames).
-- Both are read by the thread, so neither may lean on vim.api.

local frame = require("floating-claude.hooks.frame")
local http = require("floating-claude.hooks.http")

describe("frames", function()
  it("round-trip when fed one byte at a time", function()
    local wire = frame.encode("record", 'a\nb "é"') .. frame.encode("port", "41234")
    local decode, got = frame.decoder(), {}
    for i = 1, #wire do
      vim.list_extend(got, decode(wire:sub(i, i)))
    end
    assert.same({
      { kind = "record", payload = 'a\nb "é"' },
      { kind = "port", payload = "41234" },
    }, got)
  end)

  it("hand back several frames from one chunk", function()
    local decode = frame.decoder()
    local got = decode(frame.encode("a", "1") .. frame.encode("b", "") .. frame.encode("c", "333"))
    assert.same({
      { kind = "a", payload = "1" },
      { kind = "b", payload = "" },
      { kind = "c", payload = "333" },
    }, got)
  end)
end)

describe("http heads", function()
  it("wait for the blank line", function()
    assert.is_nil(http.head("POST /hook HTTP/1.1\r\nHost: x\r\n"))
  end)

  it("read the method, path, lower-cased headers, length and size", function()
    local raw = "POST /hook HTTP/1.1\r\nX-Floating-Claude: t0k\r\nContent-Length: 12\r\n\r\n{...}"
    assert.same({
      method = "POST",
      path = "/hook",
      headers = { ["x-floating-claude"] = "t0k", ["content-length"] = "12" },
      length = 12,
      size = #raw - 5,
    }, http.head(raw))
  end)

  it("treat a missing Content-Length as an empty body", function()
    assert.equals(0, http.head("GET / HTTP/1.1\r\n\r\n").length)
  end)

  it("answer with empty bodies", function()
    assert.equals(
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
      http.response(200)
    )
    assert.equals(
      "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
      http.response(403)
    )
  end)
end)
