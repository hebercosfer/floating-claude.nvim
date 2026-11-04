-- floating-claude as the plugin you set up: it sets claudecode.nvim up for
-- you, with the float as its terminal and the diff options the float needs,
-- unless claudecode is set up some other way -- already, by its own lazy.nvim
-- spec, or by you with claudecode = false.

describe("setup", function()
  local plugin = require("floating-claude")
  local calls, claudecode, notified, notify, lazy_config

  before_each(function()
    calls = {}
    -- Stands in for claudecode.nvim, down to the flag its setup() raises.
    claudecode = { state = { initialized = false } }
    function claudecode.setup(opts)
      table.insert(calls, opts)
      claudecode.state.initialized = true
    end
    package.loaded["claudecode"] = claudecode
    lazy_config = package.loaded["lazy.core.config"]
    package.loaded["lazy.core.config"] = { plugins = {} }
    notified, notify = nil, vim.notify
    vim.notify = function(msg, level)
      notified = { msg = msg, level = level }
    end
  end)

  after_each(function()
    vim.notify = notify
    package.loaded["claudecode"] = nil
    package.loaded["lazy.core.config"] = lazy_config
    require("floating-claude.config").setup({})
    require("floating-claude.keys").apply({})
  end)

  it("sets claudecode up with the float and the diff options it needs", function()
    plugin.setup({})
    assert.equals(1, #calls)
    assert.equals(plugin.provider, calls[1].terminal.provider)
    assert.is_true(calls[1].diff_opts.open_in_new_tab)
    assert.is_true(calls[1].diff_opts.hide_terminal_in_new_tab)
  end)

  it("passes your claudecode options on top, leaving your table alone", function()
    local terminal = { split_side = "left" }
    plugin.setup({ claudecode = { terminal = terminal, diff_opts = { open_in_new_tab = false } } })
    assert.equals("left", calls[1].terminal.split_side)
    assert.equals(plugin.provider, calls[1].terminal.provider)
    assert.is_false(calls[1].diff_opts.open_in_new_tab)
    assert.same({ split_side = "left" }, terminal)
  end)

  it("keeps a terminal provider you name", function()
    plugin.setup({ claudecode = { terminal = { provider = "native" } } })
    assert.equals("native", calls[1].terminal.provider)
  end)

  it("leaves claudecode to you with claudecode = false", function()
    plugin.setup({ claudecode = false })
    assert.equals(0, #calls)
  end)

  it("sets claudecode up once, however often it is set up itself", function()
    plugin.setup({})
    plugin.setup({ float = { width = 0.5 } })
    assert.equals(1, #calls)
    assert.equals(0.5, require("floating-claude.config").options.float.width)
  end)

  it("leaves a claudecode that is set up already alone", function()
    claudecode.state.initialized = true
    plugin.setup({})
    assert.equals(0, #calls)
  end)

  -- floating-claude as a dependency of claudecode.nvim: lazy.nvim sets the
  -- dependency up first, then claudecode from its own spec's opts.
  it("leaves claudecode to a lazy.nvim spec of its own with opts or config", function()
    package.loaded["lazy.core.config"].plugins["claudecode.nvim"] = { opts = {} }
    plugin.setup({})
    package.loaded["lazy.core.config"].plugins["claudecode.nvim"] = { config = true }
    plugin.setup({})
    assert.equals(0, #calls)
  end)

  it("sets claudecode up when its lazy.nvim spec only names it", function()
    package.loaded["lazy.core.config"].plugins["claudecode.nvim"] = {}
    plugin.setup({})
    assert.equals(1, #calls)
  end)

  it("says so when claudecode.nvim is missing", function()
    package.loaded["claudecode"] = nil
    plugin.setup({})
    assert.is_not_nil(notified)
    assert.equals(vim.log.levels.WARN, notified.level)
    assert.truthy(notified.msg:find("not installed", 1, true))
  end)

  it("puts claudecode.nvim's example keys down when you give none", function()
    plugin.setup({})
    assert.equals("Toggle Claude", vim.fn.maparg("<leader>ac", "n", false, true).desc)
  end)

  it("puts none down with keys = false", function()
    plugin.setup({ keys = false })
    assert.same({}, vim.fn.maparg("<leader>ac", "n", false, true))
  end)
end)
