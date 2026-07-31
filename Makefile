.PHONY: test test-file lint format clean

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

.tests/plenary.nvim:
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

lint:
	stylua --check .

format:
	stylua .

clean:
	rm -rf .tests