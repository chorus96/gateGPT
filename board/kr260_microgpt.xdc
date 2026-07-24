# ============================================================================
#  Vivado 24.2 constraints for xupv5_microgpt_top on a Kria KR260 (Robotics Kit)
#  K26 SOM: Zynq UltraScale+ MPSoC, part xck26-sfvc784-2LV-c.
# ============================================================================
#
#  CLOCK (Kria):
#  The K26 SOM has NO free-running PL oscillator pin. The 100 MHz PL clock must be
#  sourced from the PS: enable PL fabric clock pl_clk0 = 100 MHz on the Zynq
#  UltraScale+ block and connect it to clk_100 in a block design (see
#  build_board_vivado_project.tcl). So clk_100 gets NO PACKAGE_PIN -- only a
#  create_clock so timing is defined on the PS-driven net.
#
#  PERIPHERALS (KR260):
#  The KR260 carrier has no onboard switches/LEDs/16x2-LCD/rotary-encoder. Its
#  user PL I/O is on the *Pmod* connector(s) and the *Raspberry Pi 40-pin GPIO*
#  header. Wire your HD44780 LCD, rotary encoder, switches and LEDs to those, then
#  fill each <FILL_ME> below with the matching PACKAGE_PIN.
#
#  Get the exact PACKAGE_PINs from the AMD KR260 master constraints (the KR260
#  board files / kria-vitis-platforms KR260 XDC): each Pmod / RPi header pin maps to
#  a SOM240 connector pin and thus to an xck26-sfvc784 ball. Do NOT guess the balls.
#  (Or paste your KR260 master XDC and these can be filled in for you.)
#
#  All KR260 PL HD/HP bank user I/O are 1.8 V -> IOSTANDARD LVCMOS18.

# ---- clock: 100 MHz from PS pl_clk0 (no package pin; PS-sourced net) ----
create_clock -period 10.000 -name clk_100 [get_ports clk_100]
# The 80 MHz core clock is auto-derived by Vivado from the MMCME4 output.

# ---- reset / start push buttons (active high in RTL) -> RPi header / Pmod ----
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rst_btn]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports start_btn]

# ---- rotary encoder (async; synchronized in RTL) -> Pmod ----
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rot_a]     ;# Pmod pin 1
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rot_b]     ;# Pmod pin 2
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rot_push]  ;# Pmod pin 3

# ---- 8 DIP switches -> RPi header / Pmod ----
# foreach i {0 1 2 3 4 5 6 7} {
#     set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports dip_sw[$i]]
# }

# ---- 8 status LEDs -> RPi header / Pmod ----
# foreach i {0 1 2 3 4 5 6 7} {
#     set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports led[$i]]
# }

# ---- 16x2 character LCD (HD44780, 4-bit; lcd_db[3:0] = DB[7:4]) -> Pmod ----
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_rs]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_rw]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_e]
# foreach i {0 1 2 3} {
#     set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_db[$i]]
# }

# ---- async inputs are synchronized in RTL (2-FF); slow human-visible outputs ----
set_false_path -from [get_ports {rot_a rot_b rot_push rst_btn start_btn dip_sw[*]}]
set_false_path -to   [get_ports {led[*] lcd_rs lcd_rw lcd_e lcd_db[*]}]
