PROJECT := core
SIM_TOP := top

FILELIST := $(PROJECT).f
TB := src/tb_verilator.cpp
OBJ_DIR := obj_dir
SIM := sim

VERILATOR_FLAGS ?=
VERILATOR_CPPFLAGS := $(filter -D%,$(VERILATOR_FLAGS))

SYNTH_TOP ?= core
TIMING_PATHS ?= 10

TEST_DIR ?= test/share
TEST_FILTER ?= rv64ui-p-

.DEFAULT_GOAL := help

.PHONY: help build clean sim test synth fmax

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Format and build Veryl sources
	veryl fmt
	veryl build

clean: ## Clean generated files
	veryl clean
	rm -rf $(OBJ_DIR)

sim: ## Build the Verilator simulator
	verilator --cc $(VERILATOR_FLAGS) \
		$(if $(VERILATOR_CPPFLAGS),-CFLAGS "$(VERILATOR_CPPFLAGS)") \
		-f $(FILELIST) \
		--exe $(TB) \
		--top-module $(PROJECT)_$(SIM_TOP) \
		--Mdir $(OBJ_DIR)
	$(MAKE) -C $(OBJ_DIR) -f V$(PROJECT)_$(SIM_TOP).mk
	mv $(OBJ_DIR)/V$(PROJECT)_$(SIM_TOP) $(OBJ_DIR)/$(SIM)

test: ## Run tests with the built simulator
	python3 test/test.py -r $(OBJ_DIR)/$(SIM) $(TEST_DIR) $(TEST_FILTER)

synth: ## Run synthesis and dump timing/area reports
	veryl synth --top $(SYNTH_TOP) \
		--timing-paths $(TIMING_PATHS) \
		--dump-timing \
		--dump-area

fmax: ## Estimate fmax from the critical path
	@veryl synth --top $(SYNTH_TOP) --timing-paths 1 2>/dev/null | \
	awk '/^  timing:/ { \
		delay = $$2; \
		printf "critical_path: %.3f ns\nfmax: %.2f MHz\n", delay, 1000.0 / delay; \
		found = 1 \
	} END { exit found ? 0 : 1 }'
