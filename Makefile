.PHONY: test test-file test-compat lint format clean

# plenary.nvim drives the specs. Point PLENARY_DIR at an existing checkout, or
# let the `.tests/` target clone one.
PLENARY_DIR ?= $(firstword $(wildcard \
	$(HOME)/.local/share/nvim/lazy/plenary.nvim \
	$(HOME)/.local/share/nvim/site/pack/vendor/start/plenary.nvim \
	.tests/plenary.nvim))

# Not NVIM: inside a :terminal that variable already holds the server socket.
NVIM_BIN ?= nvim
INIT := tests/minimal_init.lua

test: $(if $(PLENARY_DIR),,.tests/plenary.nvim)
	PLENARY_DIR=$(PLENARY_DIR) $(NVIM_BIN) --headless --noplugin -u $(INIT) \
		-c "PlenaryBustedDirectory tests/ { minimal_init = '$(INIT)', sequential = true }"

# make test-file FILE=tests/parser_spec.lua
test-file:
	PLENARY_DIR=$(PLENARY_DIR) $(NVIM_BIN) --headless --noplugin -u $(INIT) \
		-c "PlenaryBustedFile $(FILE)"

# The compatibility suite, against a real claudecode.nvim instead of the stubs
# the unit specs use. Point CLAUDECODE_DIR at a checkout, or let the target
# clone one into .tests/. Nothing here runs during `make test`.
CLAUDECODE_DIR ?= .tests/claudecode.nvim
INTEGRATION_INIT := tests/integration_init.lua

test-compat: $(if $(PLENARY_DIR),,.tests/plenary.nvim) $(CLAUDECODE_DIR)
	PLENARY_DIR=$(PLENARY_DIR) \
	CLAUDECODE_DIR=$(abspath $(CLAUDECODE_DIR)) \
	FLOATING_CLAUDE_INTEGRATION=1 \
	$(NVIM_BIN) --headless --noplugin -u $(INTEGRATION_INIT) \
		-c "PlenaryBustedDirectory tests/integration/ { minimal_init = '$(INTEGRATION_INIT)', sequential = true }"

.tests/plenary.nvim:
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

.tests/claudecode.nvim:
	git clone --depth 1 https://github.com/coder/claudecode.nvim $@

lint:
	stylua --check .

format:
	stylua .

clean:
	rm -rf .tests