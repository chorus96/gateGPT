# Genera microgpt_fpga_board.xise para construir el BITSTREAM de placa en ISE 14.7.
# Dispositivo: XC5VLX110T-1 FF1136 (placa XUPV5-LX110T)
# Top: xupv5_microgpt_top (board top: core pipelined + name_generator + LCD + DCM@100MHz)
#
# Uso:   xtclsh build_board_ise_project.tcl
# (a diferencia de build_ise_project.tcl, este arma el flujo COMPLETO de placa:
#  todos los fuentes RTL + los modulos de board/ + el UCF de pines de la XUPV5.)

# base = carpeta donde vive este script (robusto, no hardcodea el path del repo)
set base [file dirname [file normalize [info script]]]

project new $base/microgpt_fpga_board.xise

# --- dispositivo ---
project set family  "Virtex5"
project set device  "xc5vlx110t"
project set package "ff1136"
project set speed   "-1"

# --- fuentes RTL del core INDEPENDIENTE (microcode-ROM + actuadores datapath) ---
xfile add $base/core/vmem2.sv
xfile add $base/core/wrom.sv
xfile add $base/core/grom.sv
xfile add $base/core/udiv.sv
xfile add $base/core/isqrt.sv
xfile add $base/core/exp_unit.sv
xfile add $base/core/matvec.sv
xfile add $base/core/norm.sv
xfile add $base/core/attn.sv
xfile add $base/core/embed.sv
xfile add $base/core/vecop.sv
xfile add $base/core/sampler.sv
xfile add $base/core/microgpt_core.sv

# --- modulos de placa ---
xfile add $base/board/name_generator.sv
xfile add $base/board/lcd_hd44780.sv
xfile add $base/board/rotary_throttle.sv
xfile add $base/board/tok_meter.sv
xfile add $base/board/xupv5_microgpt_top.sv

# --- constraints de placa (pines + reloj 100 MHz). OJO: llenar los LOC de pines
#     reales desde el UCF maestro ML509 (UG347) antes de map/par/bitgen. ---
xfile add $base/board/xupv5_microgpt.ucf

# --- modulo top de placa ---
project set top "xupv5_microgpt_top"

# --- propiedades de XST (esfuerzo BAJO: evita el cuelgue de opt_level 2) ---
project set "Optimization Goal"   "Speed"  -process "Synthesize - XST"
project set "Optimization Effort" "Normal" -process "Synthesize - XST"
project set "Keep Hierarchy"      "Yes"    -process "Synthesize - XST"
project set "Verilog Include Directories" "$base/core" -process "Synthesize - XST"

# --- ChipScope VIO sobre JTAG: OFF por defecto (demo LCD standalone). Para verlo
#     desde el PC: generar chipscope_icon/chipscope_vio con CORE Generator, anadir
#     sus .ngc, y descomentar la macro de abajo (-DCHIPSCOPE_VIO). ---
# project set "Verilog Macros" "CHIPSCOPE_VIO" -process "Synthesize - XST"

project close
puts "=== microgpt_fpga_board.xise creado en $base (top=xupv5_microgpt_top, 100 MHz) ==="
