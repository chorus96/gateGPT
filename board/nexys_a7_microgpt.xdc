# ============================================================================
#  Vivado 24.2 constraints for xupv5_microgpt_top  (Nexys A7-100T, xc7a100tcsg324-1)
# ============================================================================
#
#  The design originally targeted a Virtex-5 XUPV5 board under ISE 14.7. Vivado does
#  NOT support Virtex-5, so it is retargeted here to a Digilent Nexys A7-100T (Artix-7).
#  Pin LOCs below are the Nexys A7-100T master constraints (Digilent).
#
#  Board fit:
#   - clk_100 / reset / start use the onboard 100 MHz clock and push buttons.
#   - 8 DIP switches -> SW0..SW7, 8 status LEDs -> LED0..LED7 (the board has 16 of each).
#   - The Nexys A7 has NO onboard 16x2 character LCD or rotary encoder, so lcd_* and
#     rot_* are routed to the Pmod headers (JA/JB). WIRE YOUR HD44780 LCD and encoder
#     to those Pmod pins, or edit the LOCs to match your wiring.
#   - All I/O here are LVCMOS33 (Nexys A7 banks for these peripherals are 3.3 V).

# ---- clock: onboard 100 MHz oscillator (drives the MMCME2 -> 80 MHz core) ----
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk_100]
create_clock -period 10.000 -name clk_100 [get_ports clk_100]
# The 80 MHz core clock is auto-derived by Vivado from the MMCME2 output.

# ---- push buttons (active high) ----
# RTL uses active-high reset/start. BTNC = center, BTNU = up.
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports rst_btn]     ;# BTNC
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports start_btn]   ;# BTNU

# ---- rotary encoder (throttle) -> Pmod JA (async; synchronized in RTL) ----
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports rot_a]       ;# JA1
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports rot_b]       ;# JA2
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports rot_push]    ;# JA3

# ---- 8 DIP switches (active high) -> SW0..SW7 ----
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports {dip_sw[0]}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports {dip_sw[1]}]
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports {dip_sw[2]}]
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVCMOS33} [get_ports {dip_sw[3]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {dip_sw[4]}]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports {dip_sw[5]}]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {dip_sw[6]}]
set_property -dict {PACKAGE_PIN R13 IOSTANDARD LVCMOS33} [get_ports {dip_sw[7]}]

# ---- 8 status LEDs -> LED0..LED7 ----
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[7]}]

# ---- 16x2 character LCD (HD44780, 4-bit) -> Pmod JB. lcd_db[3:0] = DB[7:4]. ----
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports lcd_rs]      ;# JB1
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports lcd_rw]      ;# JB2
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports lcd_e]       ;# JB3
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {lcd_db[0]}] ;# JB4  (DB4)
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {lcd_db[1]}] ;# JB7  (DB5)
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports {lcd_db[2]}] ;# JB8  (DB6)
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33} [get_ports {lcd_db[3]}] ;# JB9  (DB7)

# ---- async inputs: synchronized in RTL (2-FF), so exclude from input timing ----
set_false_path -from [get_ports {rot_a rot_b rot_push rst_btn start_btn dip_sw[*]}]
# LEDs / LCD are slow, human-visible outputs; relax their output timing too.
set_false_path -to   [get_ports {led[*] lcd_rs lcd_rw lcd_e lcd_db[*]}]

# ---- config ----
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
