local version = require("floating-claude.version")

describe("version", function()
  it("formats as major.minor.patch", function()
    assert.equals(
      string.format("%d.%d.%d", version.major, version.minor, version.patch),
      tostring(version)
    )
  end)

  it("is reachable both ways", function()
    assert.equals(tostring(version), version:string())
    assert.equals(tostring(version), tostring(require("floating-claude").version))
  end)

  it("exposes numeric components", function()
    assert.equals("number", type(version.major))
    assert.equals("number", type(version.minor))
    assert.equals("number", type(version.patch))
  end)

  it("parses as a semver version", function()
    local parsed = vim.version.parse(tostring(version))
    assert.is_not_nil(parsed)
    assert.equals(version.major, parsed.major)
    assert.equals(version.minor, parsed.minor)
    assert.equals(version.patch, parsed.patch)
  end)

  -- A release whose changelog does not mention it is a release nobody can read
  -- about, so keep the two in step.
  it("matches the newest released entry in CHANGELOG.md", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local changelog = table.concat(vim.fn.readfile(root .. "/CHANGELOG.md"), "\n")
    local newest = changelog:match("##%s*%[(%d+%.%d+%.%d+)%]")
    assert.is_not_nil(newest, "CHANGELOG.md has no released version heading")
    assert.equals(tostring(version), newest)
  end)
end)
