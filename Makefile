PROJECT := core
SIM_TOP := top

FILELIST := $(PROJECT).f
TB := src/tb_verilator.cpp
OBJ_DIR := obj_dir
SIM := sim

VERILATOR_FLAGS ?= -DTEST_MODE
VERILATOR_CPPFLAGS := $(filter -D%,$(VERILATOR_FLAGS))
VERYL_SRCS := $(wildcard src/*.veryl)

SYNTH_TOP ?= core
TIMING_PATHS ?= 10

RV_TEST_DIR ?= test/share/riscv-tests
RV_TEST_FILTER ?= rv64ui-p- rv64um-p-

COREMARK_DIR ?= test/share/coremark
COREMARK_ITERATIONS ?= 1
COREMARK_CYCLES ?= 0
COREMARK_RESULT ?= results/coremark.txt
COREMARK_HEX ?= $(COREMARK_DIR)/build/coremark.riscv.bin.hex

.DEFAULT_GOAL := help

.PHONY: help build clean sim test bench synth fmax

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: $(FILELIST) ## Format and build Veryl sources

$(FILELIST): $(VERYL_SRCS) Veryl.toml Veryl.lock
	veryl fmt
	veryl build

clean: ## Clean generated files
	veryl clean
	rm -rf $(OBJ_DIR)

$(OBJ_DIR)/$(SIM): $(FILELIST) $(VERYL_SRCS) $(TB) Makefile
	verilator --cc $(VERILATOR_FLAGS) \
		$(if $(VERILATOR_CPPFLAGS),-CFLAGS "$(VERILATOR_CPPFLAGS)") \
		-f $(FILELIST) \
		--exe $(TB) \
		--top-module $(PROJECT)_$(SIM_TOP) \
		--Mdir $(OBJ_DIR)
	$(MAKE) -C $(OBJ_DIR) -f V$(PROJECT)_$(SIM_TOP).mk
	mv $(OBJ_DIR)/V$(PROJECT)_$(SIM_TOP) $(OBJ_DIR)/$(SIM)

sim: $(OBJ_DIR)/$(SIM) ## Build the Verilator simulator

test: $(OBJ_DIR)/$(SIM) ## Run tests with the built simulator
	@status=0; \
	for filter in $(RV_TEST_FILTER); do \
		echo "== $$filter =="; \
		python3 test/test.py -r -o results/$$filter $(OBJ_DIR)/$(SIM) $(RV_TEST_DIR) $$filter || status=$$?; \
	done; \
	exit $$status

bench: $(OBJ_DIR)/$(SIM) ## Build and run CoreMark
	@test -f "$(COREMARK_DIR)/core_main.c" || { \
		echo "CoreMark submodule is missing. Run: git submodule update --init --recursive"; \
		exit 1; \
	}
	$(MAKE) -C $(COREMARK_DIR) coremark COREMARK_ITERATIONS=$(COREMARK_ITERATIONS)
	@mkdir -p $(dir $(COREMARK_RESULT))
	@$(OBJ_DIR)/$(SIM) $(COREMARK_HEX) $(COREMARK_CYCLES) > $(COREMARK_RESULT); \
	status=$$?; \
	tail -n 5 $(COREMARK_RESULT); \
	exit $$status

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
