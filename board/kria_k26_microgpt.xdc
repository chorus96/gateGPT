# ============================================================================
#  Vivado 24.2 constraints for xupv5_microgpt_top on a Kria K26 SOM
#  (Zynq UltraScale+ MPSoC, part xck26-sfvc784-2LV-c; KV260 / KR260 carrier).
# ============================================================================
#
#  IMPORTANT -- Kria clocking:
#  The K26 SOM has NO free-running PL oscillator pin. The 100 MHz PL clock must be
#  sourced from the Processing System (PS): enable PL fabric clock pl_clk0 = 100 MHz
#  on the Zynq UltraScale+ block and connect it to this design's clk_100 in a block
#  design (see build_kria_bd.tcl). Therefore clk_100 gets NO PACKAGE_PIN here -- only
#  a create_clock so timing is defined on the PS-driven net.
#
#  IMPORTANT -- peripherals:
#  Kria SOMs are headless compute modules: there are NO onboard DIP switches, LEDs,
#  push buttons, rotary encoder or 16x2 LCD. This demo's I/O (8 sw + 8 led + LCD +
#  rotary + buttons = ~29 pins) must be wired to the carrier's PMOD / expansion
#  header. The KV260 exposes one Pmod (J2, 8 pins) + some HD-bank pins; the KR260
#  exposes 4 Pmods. The <FILL_ME> LOCs below MUST be assigned from your carrier's
#  board file to the pins you actually wire to -- the design will not implement until
#  every port has a real PACKAGE_PIN. All HD/HP bank I/O on Kria are 1.8 V (LVCMOS18).

# ---- clock: 100 MHz from PS pl_clk0 (no package pin; PS-sourced net) ----
create_clock -period 10.000 -name clk_100 [get_ports clk_100]
# The 80 MHz core clock is auto-derived by Vivado from the MMCME4 output.

# ---- peripherals -> carrier PMOD / expansion (assign PACKAGE_PIN per your wiring) ----
# Example skeleton; replace <FILL_ME> with real pins from the KV260/KR260 board file.
# (LVCMOS18 because Kria PL HD/HP banks are 1.8 V.)

# reset / start push buttons (active high in RTL)
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rst_btn]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports start_btn]

# rotary encoder (async; synchronized in RTL)
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rot_a]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rot_b]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports rot_push]

# 8 DIP switches
# foreach i {0 1 2 3 4 5 6 7} {
#     set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports dip_sw[$i]]
# }

# 8 status LEDs
# foreach i {0 1 2 3 4 5 6 7} {
#     set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports led[$i]]
# }

# 16x2 character LCD (HD44780, 4-bit; lcd_db[3:0] = DB[7:4])
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_rs]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_rw]
# set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_e]
# foreach i {0 1 2 3} {
#     set_property -dict {PACKAGE_PIN <FILL_ME> IOSTANDARD LVCMOS18} [get_ports lcd_db[$i]]
# }

# ---- async inputs are synchronized in RTL (2-FF); slow human-visible outputs ----
set_false_path -from [get_ports {rot_a rot_b rot_push rst_btn start_btn dip_sw[*]}]
set_false_path -to   [get_ports {led[*] lcd_rs lcd_rw lcd_e lcd_db[*]}]
