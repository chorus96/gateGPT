# Verilator simulation for gateGPT
#
# Usage (from anywhere):
#   make -C sim            # build + run every testbench
#   make -C sim tb_core    # build + run one testbench (unit or the board top)
#   make -C sim tb_top     # board-level (xupv5_microgpt_top) simulation
#   make -C sim lint       # static lint only (-Wall), no build/run
#   make -C sim clean
#
# Each run is echoed to the terminal AND saved to sim/logs/<testbench>.log
# (tee), so the full transcript of every simulation is kept on disk.
#
# Requires Verilator >= 5.006 (needs --binary and --timing). Install on Debian/Ubuntu:
#   sudo apt-get install verilator
#
# The compiled binaries are run from the repo ROOT so that the testbenches'
# `$readmemh("generated/*.hex", ...)` paths resolve, and the core's
# `` `include "*.vh" `` files are found via  -I<ROOT>/core .

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
VERILATOR ?= verilator
# gategpt.vlt waives the reviewed, intentional lint categories (wide fixed-point
# intermediates, unconnected spare pins, etc.) so -Wall stays clean without any
# ad-hoc -Wno flags and without touching the bit-exact RTL. See the file header.
WAIVER    := $(ROOT)/sim/gategpt.vlt
VFLAGS    := --binary --timing -Wall $(WAIVER) -I$(ROOT)/core
LINTFLAGS := --lint-only --timing -Wall $(WAIVER) -I$(ROOT)/core
CORE      := $(wildcard $(ROOT)/core/*.v)
BOARD     := $(wildcard $(ROOT)/board/*.v)
STUBS     := $(ROOT)/sim/xilinx_stubs.v
OBJDIR    := $(ROOT)/sim/obj
# per-testbench run logs land in LOGDIR (keep the value free of trailing spaces)
LOGDIR    := $(ROOT)/sim/logs
STAMP     := $(shell date '+%Y-%m-%d %H:%M:%S')

# Unit / core testbenches (need only core/*.v).
UNIT  := tb_mathops tb_exp tb_matvec tb_norm tb_attn tb_core
# Board-level top testbench (needs core + board + Xilinx primitive stubs).
TOP   := tb_top
TESTS := $(UNIT) $(TOP)

# Extra Verilog sources (besides sim/<tb>.v) each testbench elaborates.
$(foreach t,$(UNIT),$(eval SRCS_$(t) := $(CORE)))
SRCS_$(TOP) := $(CORE) $(BOARD) $(STUBS)

.PHONY: all clean lint $(TESTS)

all: $(TESTS)

# Static lint (no build/run): the synthesizable board top plus every testbench
# top, at -Wall. gategpt.vlt waives the reviewed intentional categories, so a
# clean tree reports zero warnings; any NEW warning fails the target (set -e).
lint:
	@set -e; \
	for spec in "xupv5_microgpt_top:$(BOARD) $(CORE) $(STUBS)" \
	            $(foreach t,$(TESTS),"$(t):$(ROOT)/sim/$(t).v $(SRCS_$(t))"); do \
	  top=$${spec%%:*}; srcs=$${spec#*:}; \
	  printf '== lint %-22s ' "$$top"; \
	  $(VERILATOR) $(LINTFLAGS) --top-module $$top $$srcs && echo "clean"; \
	done; \
	echo "LINT CLEAN: board top + all testbenches (-Wall)"

# For each testbench: a build rule (Verilator -> native binary) and a run rule.
# We hand Verilator every source module; ones the top does not instantiate are pruned.
define RUN_TB
$(1): $(OBJDIR)/$(1)/$(1)_sim
	@mkdir -p $(LOGDIR)
	@cd $(ROOT) && { echo "### $(1)  $(STAMP)"; $(OBJDIR)/$(1)/$(1)_sim; } 2>&1 | tee $(LOGDIR)/$(1).log
	@echo "  -> log saved to sim/logs/$(1).log"

$(OBJDIR)/$(1)/$(1)_sim: $(ROOT)/sim/$(1).v $(SRCS_$(1)) $(WAIVER)
	@mkdir -p $(OBJDIR)/$(1)
	$(VERILATOR) $(VFLAGS) --top-module $(1) --Mdir $(OBJDIR)/$(1) -o $(1)_sim \
	    $(ROOT)/sim/$(1).v $(SRCS_$(1))
endef

$(foreach t,$(TESTS),$(eval $(call RUN_TB,$(t))))

clean:
	rm -rf $(OBJDIR) $(LOGDIR)
