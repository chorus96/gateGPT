# ============================================================================
#  Vivado 24.2 project build for gateGPT (board top: core + name_generator + LCD +
#  rotary + tok/s meter + MMCME2 clocking).
#
#  Device: xc7a100tcsg324-1 (Artix-7, Digilent Nexys A7-100T).
#  Top:    xupv5_microgpt_top   (retargeted from Virtex-5/ISE; Vivado has no Virtex-5).
#
#  Usage:
#     vivado -mode batch -source build_board_vivado_project.tcl
#   or, to just create the project (no runs), pass -tclargs noflow:
#     vivado -mode batch -source build_board_vivado_project.tcl -tclargs noflow
#
#  Replaces the ISE flow (build_board_ise_project.tcl / run_board_bitgen.tcl / *.ucf).
# ============================================================================

set root [file dirname [file normalize [info script]]]
set part xc7a100tcsg324-1
set top  xupv5_microgpt_top
set prj  $root/vivado_prj

create_project -force gategpt $prj -part $part

# --- RTL sources (SystemVerilog) ---
# NOTE: sim/xilinx_stubs.sv is intentionally NOT added -- Vivado uses the real UNISIM
# MMCME2_BASE/BUFG. The generated ROM includes (core/*.vh) are found via include_dirs.
add_files -norecurse [glob $root/core/*.sv]
add_files -norecurse [glob $root/board/*.sv]
set_property file_type SystemVerilog [get_files -filter {FILE_TYPE == Verilog}]
set_property include_dirs $root/core [get_filesets sources_1]
set_property top $top [current_fileset]

# --- constraints ---
add_files -fileset constrs_1 -norecurse $root/board/nexys_a7_microgpt.xdc

# --- optional ChipScope/ILA VIO macro (off by default; standalone LCD demo) ---
# set_property verilog_define {CHIPSCOPE_VIO} [current_fileset]

puts "=== gategpt Vivado project created at $prj (part=$part, top=$top) ==="

# --- run synthesis + implementation + bitstream (skip with -tclargs noflow) ---
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
