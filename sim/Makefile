# Verilator simulation for gateGPT
#
# Usage (from anywhere):
#   make -C sim            # build + run every testbench
#   make -C sim tb_core    # build + run one testbench (unit or the board top)
#   make -C sim tb_top     # board-level (xupv5_microgpt_top) simulation
#   make -C sim clean
#
# Requires Verilator >= 5.006 (needs --binary and --timing). Install on Debian/Ubuntu:
#   sudo apt-get install verilator
#
# The compiled binaries are run from the repo ROOT so that the testbenches'
# `$readmemh("generated/*.hex", ...)` paths resolve, and the core's
# `` `include "*.vh" `` files are found via  -I<ROOT>/core .

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
VERILATOR ?= verilator
# -Wno-WIDTH/PINMISSING: the RTL uses wider intermediate expressions on purpose and
# leaves udiv.rem_out unconnected where the remainder is unused; both are benign here
# (every testbench is bit-exact against the Python golden). -Wno-fatal catches the rest.
VFLAGS    := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-PINMISSING -I$(ROOT)/core
CORE      := $(wildcard $(ROOT)/core/*.v)
BOARD     := $(wildcard $(ROOT)/board/*.v)
STUBS     := $(ROOT)/sim/xilinx_stubs.v
OBJDIR    := $(ROOT)/sim/obj

# Unit / core testbenches (need only core/*.v).
UNIT  := tb_mathops tb_exp tb_matvec tb_norm tb_attn tb_core
# Board-level top testbench (needs core + board + Xilinx primitive stubs).
TOP   := tb_top
TESTS := $(UNIT) $(TOP)

# Extra Verilog sources (besides sim/<tb>.v) each testbench elaborates.
$(foreach t,$(UNIT),$(eval SRCS_$(t) := $(CORE)))
SRCS_$(TOP) := $(CORE) $(BOARD) $(STUBS)

.PHONY: all clean $(TESTS)

all: $(TESTS)

# For each testbench: a build rule (Verilator -> native binary) and a run rule.
# We hand Verilator every source module; ones the top does not instantiate are pruned.
define RUN_TB
$(1): $(OBJDIR)/$(1)/$(1)_sim
	@cd $(ROOT) && $(OBJDIR)/$(1)/$(1)_sim

$(OBJDIR)/$(1)/$(1)_sim: $(ROOT)/sim/$(1).v $(SRCS_$(1))
	@mkdir -p $(OBJDIR)/$(1)
	$(VERILATOR) $(VFLAGS) --top-module $(1) --Mdir $(OBJDIR)/$(1) -o $(1)_sim \
	    $(ROOT)/sim/$(1).v $(SRCS_$(1))
endef

$(foreach t,$(TESTS),$(eval $(call RUN_TB,$(t))))

clean:
	rm -rf $(OBJDIR)
