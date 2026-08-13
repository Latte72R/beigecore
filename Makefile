PROJECT := core
SIM_TOP := top

FILELIST := $(PROJECT).f
TB := src/tb_verilator.cpp
OBJ_DIR := obj_dir
SIM := sim

VERILATOR_FLAGS ?= -DTEST_MODE
VERILATOR_CPPFLAGS := $(filter -D%,$(VERILATOR_FLAGS))
VERYL_SRCS := $(wildcard src/*.veryl)

DEBUG_SIM_DIR := $(OBJ_DIR)_debug
DEBUG_SIM := $(DEBUG_SIM_DIR)/V$(PROJECT)_$(SIM_TOP)
DEBUG_VERILATOR_FLAGS ?= $(VERILATOR_FLAGS) -DENABLE_DEBUG_INPUT
DEBUG_VERILATOR_CPPFLAGS := $(filter -D%,$(DEBUG_VERILATOR_FLAGS))

KONATA_SIM_DIR := $(OBJ_DIR)_konata
KONATA_SIM := $(KONATA_SIM_DIR)/konata-sim
KONATA_VERILATOR_FLAGS ?= -DLOG_PIPELINE -DVL_USER_FINISH
KONATA_VERILATOR_CPPFLAGS := $(filter -D%,$(KONATA_VERILATOR_FLAGS))
KONATA_RAM ?= test/sample.hex
KONATA_CYCLES ?= 1000
KONATA_LOG ?= results/konata.log
KONATA_RAW ?= results/konata.raw

SYNTH_TOP ?= top
TIMING_PATHS ?= 10

RV_TEST_DIR ?= test/share/riscv-tests
RV_TEST_FILTER ?= rv64ui-p- rv64um-p- rv64ua-p- rv64uc-p-
RV_TEST_EXCLUDE ?= ma_data

BOOTROM_HEX := bootrom.hex

RISCV_CC ?= riscv64-unknown-elf-gcc
RISCV_OBJCOPY ?= riscv64-unknown-elf-objcopy
DEBUG_ADDR ?= 0x40000000
DEBUG_DIR ?= $(OBJ_DIR)/debug
DEBUG_NAME := $(basename $(notdir $(FILE)))
DEBUG_SOURCE = $(wildcard $(FILE))
DEBUG_ELF := $(DEBUG_DIR)/$(DEBUG_NAME).elf
DEBUG_BIN := $(DEBUG_DIR)/$(DEBUG_NAME).bin
DEBUG_HEX := $(DEBUG_BIN).hex

COREMARK_DIR ?= test/share/coremark
COREMARK_ITERATIONS ?= 1
COREMARK_CYCLES ?= 0
COREMARK_DBG_ADDR ?= 0x80001000
COREMARK_RESULT ?= results/coremark.txt
COREMARK_HEX ?= $(COREMARK_DIR)/build/coremark.riscv.bin.hex

VERTOS_DIR ?= ../vertos

VERTOS_BIN := $(abspath \
	$(VERTOS_DIR)/target/riscv64imac-unknown-none-elf/release/vertos.bin)

BOOTROM_SOURCE := $(VERTOS_DIR)/boot/bootrom.S
BOOTROM_LINKER := $(VERTOS_DIR)/boot/bootrom.ld
BEIGECORE_DTS := $(VERTOS_DIR)/platform/beigecore.dts
BIN2HEX := $(VERTOS_DIR)/tools/bin2hex.py

BOOT_DIR := $(OBJ_DIR)/boot
BOOTROM_ELF := $(BOOT_DIR)/bootrom.elf
BOOTROM_BIN := $(BOOT_DIR)/bootrom.bin

DTC ?= dtc
BEIGECORE_DTB := $(OBJ_DIR)/beigecore.dtb

OPENSBI_DIR := $(VERTOS_DIR)/third_party/opensbi
OPENSBI_TOOLCHAIN := LLVM=-22 \
	CC=$(abspath $(VERTOS_DIR)/tools/opensbi-clang)

OPENSBI_OS_BUILD := $(abspath $(OBJ_DIR)/opensbi-os)
OPENSBI_OS_BIN := \
	$(OPENSBI_OS_BUILD)/platform/generic/firmware/fw_payload.bin
OPENSBI_OS_HEX := $(OBJ_DIR)/vertos.bin.hex

OS_SIM_DIR := $(OBJ_DIR)_os
OS_SIM := $(OS_SIM_DIR)/sim

OPENSBI_ARGS := PLATFORM=generic \
	PLATFORM_RISCV_XLEN=64 \
	PLATFORM_RISCV_ABI=lp64 \
	PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei \
	FW_TEXT_START=0x80000000 \
	FW_PAYLOAD=y \
	FW_PAYLOAD_OFFSET=0x200000 \
	FW_PAYLOAD_FDT_OFFSET=0x600000 \
	FW_FDT_PATH=$(abspath $(BEIGECORE_DTB))

.DEFAULT_GOAL := help

.PHONY: help build clean sim test debug konata bench synth fmax

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: $(FILELIST) ## Format and build Veryl sources

$(FILELIST): $(VERYL_SRCS) Veryl.toml Veryl.lock
	veryl fmt
	veryl build

clean: ## Clean generated files
	veryl clean
	rm -rf $(OBJ_DIR) $(DEBUG_SIM_DIR) $(KONATA_SIM_DIR)

$(OBJ_DIR)/$(SIM): $(FILELIST) $(VERYL_SRCS) $(TB) Makefile
	verilator --cc $(VERILATOR_FLAGS) \
		$(if $(VERILATOR_CPPFLAGS),-CFLAGS "$(VERILATOR_CPPFLAGS)") \
		-f $(FILELIST) \
		--exe $(TB) \
		--top-module $(PROJECT)_$(SIM_TOP) \
		--Mdir $(OBJ_DIR)
	$(MAKE) -C $(OBJ_DIR) -f V$(PROJECT)_$(SIM_TOP).mk
	mv $(OBJ_DIR)/V$(PROJECT)_$(SIM_TOP) $(OBJ_DIR)/$(SIM)

$(DEBUG_SIM): $(FILELIST) $(VERYL_SRCS) $(TB) Makefile
	verilator --cc $(DEBUG_VERILATOR_FLAGS) \
		$(if $(DEBUG_VERILATOR_CPPFLAGS),-CFLAGS "$(DEBUG_VERILATOR_CPPFLAGS)") \
		-f $(FILELIST) \
		--exe $(TB) \
		--top-module $(PROJECT)_$(SIM_TOP) \
		--Mdir $(DEBUG_SIM_DIR)
	$(MAKE) -C $(DEBUG_SIM_DIR) -f V$(PROJECT)_$(SIM_TOP).mk

$(KONATA_SIM): $(FILELIST) $(VERYL_SRCS) $(TB) Makefile
	verilator --cc $(KONATA_VERILATOR_FLAGS) \
		$(if $(KONATA_VERILATOR_CPPFLAGS),-CFLAGS "$(KONATA_VERILATOR_CPPFLAGS)") \
		-f $(FILELIST) \
		--exe $(TB) \
		--top-module $(PROJECT)_$(SIM_TOP) \
		--Mdir $(KONATA_SIM_DIR)
	$(MAKE) -C $(KONATA_SIM_DIR) -f V$(PROJECT)_$(SIM_TOP).mk
	mv $(KONATA_SIM_DIR)/V$(PROJECT)_$(SIM_TOP) $(KONATA_SIM)

$(OS_SIM): $(FILELIST) $(VERYL_SRCS) $(TB) Makefile
	verilator --cc \
			-f $(FILELIST) \
			--exe $(TB) \
			--top-module $(PROJECT)_$(SIM_TOP) \
			--Mdir $(OS_SIM_DIR)
	$(MAKE) -C $(OS_SIM_DIR) \
			-f V$(PROJECT)_$(SIM_TOP).mk
	mv $(OS_SIM_DIR)/V$(PROJECT)_$(SIM_TOP) $(OS_SIM)

sim: $(OBJ_DIR)/$(SIM) ## Build the Verilator simulator

test: $(OBJ_DIR)/$(SIM) ## Run tests with the built simulator
	@status=0; \
	for filter in $(RV_TEST_FILTER); do \
		echo "== $$filter =="; \
		python3 test/test.py -r $(foreach pattern,$(RV_TEST_EXCLUDE),--exclude $(pattern)) \
			-o results/$$filter $(OBJ_DIR)/$(SIM) $(RV_TEST_DIR) $$filter || status=$$?; \
	done; \
	exit $$status

debug: $(DEBUG_SIM) ## Build and run FILE (for example: make debug FILE=debug_output.c)
	@test -n "$(FILE)" || { \
		echo "Usage: make debug FILE=<source file>"; \
		exit 2; \
	}
	@test -f "$(DEBUG_SOURCE)" || { \
		echo "Source file not found: $(FILE)"; \
		exit 2; \
	}
	@mkdir -p $(DEBUG_DIR)
	$(RISCV_CC) -nostartfiles -nostdlib -fno-builtin -mcmodel=medany \
		-T test/link.ld -march=rv64imad "$(DEBUG_SOURCE)" test/entry.S -o $(DEBUG_ELF)
	$(RISCV_OBJCOPY) $(DEBUG_ELF) -O binary $(DEBUG_BIN)
	python3 test/bin2hex.py 8 $(DEBUG_BIN) > $(DEBUG_HEX)
	DBG_ADDR=$(DEBUG_ADDR) $(DEBUG_SIM) $(BOOTROM_HEX) $(DEBUG_HEX)

konata: $(KONATA_SIM) ## Generate a Konata pipeline trace
	@mkdir -p $(dir $(KONATA_LOG)) $(dir $(KONATA_RAW))
	@DBG_ADDR=$(DEBUG_ADDR) $(KONATA_SIM) \
		$(BOOTROM_HEX) $(KONATA_RAM) $(KONATA_CYCLES) > $(KONATA_RAW)
	@python3 test/konata.py $(KONATA_RAW) > $(KONATA_LOG)
	@echo "Konata trace: $(KONATA_LOG)"

bench: $(KONATA_SIM) ## Build and run CoreMark with a Konata trace
	@test -f "$(COREMARK_DIR)/core_main.c" || { \
		echo "CoreMark submodule is missing. Run: git submodule update --init --recursive"; \
		exit 1; \
	}
	$(MAKE) -C $(COREMARK_DIR) coremark COREMARK_ITERATIONS=$(COREMARK_ITERATIONS)
	@mkdir -p $(dir $(COREMARK_RESULT)) $(dir $(KONATA_LOG)) $(dir $(KONATA_RAW))
	@DBG_ADDR=$(COREMARK_DBG_ADDR) $(KONATA_SIM) \
		$(BOOTROM_HEX) $(COREMARK_HEX) $(COREMARK_CYCLES) \
		> $(KONATA_RAW) 2> $(COREMARK_RESULT); \
	status=$$?; \
	python3 test/konata.py $(KONATA_RAW) > $(KONATA_LOG) || status=$$?; \
	tail -n 5 $(COREMARK_RESULT); \
	echo "Konata trace: $(KONATA_LOG)"; \
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

$(BOOTROM_ELF): $(BOOTROM_SOURCE) $(BOOTROM_LINKER)
	@mkdir -p $(BOOT_DIR)
	$(RISCV_CC) -nostartfiles -nostdlib -mabi=lp64 \
			-march=rv64imac_zicsr_zifencei \
			-T $(BOOTROM_LINKER) \
			$(BOOTROM_SOURCE) \
			-o $@

$(BOOTROM_BIN): $(BOOTROM_ELF)
	$(RISCV_OBJCOPY) $< -O binary $@

$(BOOTROM_HEX): $(BOOTROM_BIN) $(BIN2HEX)
	python3 $(BIN2HEX) 8 $< > $@

$(BEIGECORE_DTB): $(BEIGECORE_DTS)
	@mkdir -p $(dir $@)
	$(DTC) -I dts -O dtb -o $@ $<

.PHONY: vertos-kernel

vertos-kernel:
	$(MAKE) -C $(VERTOS_DIR) build

$(OPENSBI_OS_BIN): vertos-kernel $(BEIGECORE_DTB) \
					$(OPENSBI_DIR)/Makefile
	$(MAKE) -C $(OPENSBI_DIR) \
			O=$(OPENSBI_OS_BUILD) \
			$(OPENSBI_TOOLCHAIN) \
			$(OPENSBI_ARGS) \
			FW_PAYLOAD_PATH=$(VERTOS_BIN)

$(OPENSBI_OS_HEX): $(OPENSBI_OS_BIN) $(BIN2HEX)
	python3 $(BIN2HEX) 8 $< > $@

.PHONY: vertos-kernel os-image run-os

os-image: $(BOOTROM_HEX) $(OPENSBI_OS_HEX)

run-os: $(OS_SIM) os-image
	$(OS_SIM) $(BOOTROM_HEX) $(OPENSBI_OS_HEX)
