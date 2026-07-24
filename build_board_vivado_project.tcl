# ============================================================================
#  Vivado 24.2 project build for gateGPT (board top: core + name_generator + LCD +
#  rotary + tok/s meter + MMCME4 clocking).
#
#  Device: xck26-sfvc784-2LV-c  (Kria K26 SOM, Zynq UltraScale+ MPSoC; KR260 carrier).
#  Top:    xupv5_microgpt_top    (retargeted from Virtex-5/ISE; Vivado has no Virtex-5).
#
#  Usage:
#     vivado -mode batch -source build_board_vivado_project.tcl
#   or, to just create the project (no runs), pass -tclargs noflow:
#     vivado -mode batch -source build_board_vivado_project.tcl -tclargs noflow
#
#  KRIA NOTES:
#   1. Clock: the K26 has no free PL oscillator pin -- clk_100 must be driven by the
#      PS fabric clock pl_clk0 (100 MHz). For a real bitstream, wrap this RTL top in a
#      block design that instantiates zynq_ultra_ps_e and connects pl_clk0 -> clk_100
#      (a helper is sketched at the bottom of this file). This project-mode script
#      builds the PL logic standalone (synth checks out; clk_100 is a create_clock net).
#   2. Peripherals: Kria SOMs have no onboard switches/LEDs/LCD/rotary. All 28 of
#      this design's signals are pinned in board/kr260_microgpt.xdc to KR260 SOM240
#      user-PL I/O (SOM240_1 bank 45 + SOM240_2 bank 43, LVCMOS18) using real
#      xck26-sfvc784 balls from the KR260 I/O map -- each line is annotated with its
#      SOM240 pin, bank, and native IO_ name. Wire your switches/LEDs/LCD/rotary to
#      those SOM240 pins (they surface on the carrier Pmod / RPi 40-pin header).
#
#  Replaces the ISE flow (build_board_ise_project.tcl / run_board_bitgen.tcl / *.ucf).
# ============================================================================

set root [file dirname [file normalize [info script]]]
set part xck26-sfvc784-2LV-c
set top  xupv5_microgpt_top
set prj  $root/vivado_prj

create_project -force gategpt $prj -part $part
# Kria KR260 board part (optional, if the KR260 board files are installed; adjust the
# version suffix to the one you have, e.g. via `get_board_parts *kr260*`):
# set_property board_part xilinx.com:kr260_som:part0:1.1 [current_project]

# --- RTL sources (SystemVerilog) ---
# NOTE: sim/xilinx_stubs.sv is intentionally NOT added -- Vivado uses the real UNISIM
# MMCME4_BASE/BUFG. The generated ROM includes (core/*.vh) are found via include_dirs.
add_files -norecurse [glob $root/core/*.sv]
add_files -norecurse [glob $root/board/*.sv]
set_property file_type SystemVerilog [get_files -filter {FILE_TYPE == Verilog}]
set_property include_dirs $root/core [get_filesets sources_1]
set_property top $top [current_fileset]

# --- constraints ---
add_files -fileset constrs_1 -norecurse $root/board/kr260_microgpt.xdc

# --- optional ChipScope/ILA VIO macro (off by default; standalone LCD demo) ---
# set_property verilog_define {CHIPSCOPE_VIO} [current_fileset]

puts "=== gategpt Vivado project created at $prj (part=$part, top=$top) ==="

# --- run synthesis + implementation + bitstream (skip with -tclargs noflow) ---
# NOTE: the XDC already carries real PACKAGE_PIN LOCs; for a full bitstream clk_100
# still needs to be driven by the PS pl_clk0 via a block design (see KRIA NOTES).
if {[lsearch -exact $argv "noflow"] >= 0} {
    puts "=== noflow: project created, skipping synth/impl ==="
} else {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    set bit [glob -nocomplain [get_property DIRECTORY [get_runs impl_1]]/*.bit]
    puts "=== bitstream: $bit ==="
}

# ---------------------------------------------------------------------------
#  OPTIONAL Kria block-design sketch (clk_100 from PS pl_clk0). Uncomment and run
#  in place of the project flow above once you have the KR260 board part.
# ---------------------------------------------------------------------------
# create_bd_design "gategpt_bd"
# set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
# apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} $ps
# set_property -dict {CONFIG.PSU__FPGA_PL0_ENABLE 1 CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 100} $ps
# set top_cell [create_bd_cell -type module -reference $top u_top]
# connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins u_top/clk_100]
# # ... make peripheral ports external and constrain in the XDC ...
# make_wrapper -files [get_files gategpt_bd.bd] -top
