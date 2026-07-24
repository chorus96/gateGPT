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
#  PERIPHERALS (KR260) -- SOM240 user-PL I/O:
#  The KR260 carrier has no onboard switches/LEDs/16x2-LCD/rotary-encoder. All 28
#  of this design's signals are placed on confirmed PL user-I/O balls taken from
#  the KR260 I/O map (kr260_iomap.xdc): SOM240_1 bank 45 (16 pins) and SOM240_2
#  bank 43 (16 pins). The PACKAGE_PIN values below are the REAL xck26-sfvc784 balls
#  from that map -- each line is annotated with its SOM240 connector pin, bank, and
#  native IO_ name. Wire your peripherals to the matching SOM240 pins (these surface
#  on the KR260 Pmod / Raspberry Pi 40-pin header per the carrier schematic).
#
#  Assignment is in the map's pin order: SOM240_1 (bank 45) first, then SOM240_2
#  (bank 43). 28 of the 32 mapped pins are used; the last 4 (som240_2_b44/b45/b46/b48
#  = AD11/AD10/AA11/AA10) are left free.
#
#  All KR260 SOM240 HD-bank user I/O are 1.8 V -> IOSTANDARD LVCMOS18.

# ---- clock: 100 MHz from PS pl_clk0 (no package pin; PS-sourced net) ----
create_clock -period 10.000 -name clk_100 [get_ports clk_100]
# The 80 MHz core clock is auto-derived by Vivado from the MMCME4 output.

# ============================================================================
#  SOM240_1  (Bank 45), in I/O-map order
# ============================================================================

# ---- reset / start push buttons (active high in RTL) ----
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS18} [get_ports rst_btn]      ;# som240_1_a17  Bank45  IO_L4N_AD12N_45
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS18} [get_ports start_btn]    ;# som240_1_d20  Bank45  IO_L7P_HDGC_45

# ---- rotary encoder (async; synchronized in RTL) ----
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS18} [get_ports rot_a]        ;# som240_1_d21  Bank45  IO_L7N_HDGC_45
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS18} [get_ports rot_b]        ;# som240_1_d22  Bank45  IO_L9P_AD11P_45
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS18} [get_ports rot_push]     ;# som240_1_b20  Bank45  IO_L9N_AD11N_45

# ---- 8 DIP switches (dip_sw[0..7]) ----
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS18} [get_ports {dip_sw[0]}]  ;# som240_1_b21  Bank45  IO_L8P_HDGC_45
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS18} [get_ports {dip_sw[1]}]  ;# som240_1_b22  Bank45  IO_L8N_HDGC_45
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS18} [get_ports {dip_sw[2]}]  ;# som240_1_c22  Bank45  IO_L10P_AD10P_45
set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS18} [get_ports {dip_sw[3]}]  ;# som240_1_d18  Bank45  IO_L1P_AD15P_45
set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS18} [get_ports {dip_sw[4]}]  ;# som240_1_b16  Bank45  IO_L1N_AD15N_45
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS18} [get_ports {dip_sw[5]}]  ;# som240_1_b17  Bank45  IO_L2P_AD14P_45
set_property -dict {PACKAGE_PIN K12 IOSTANDARD LVCMOS18} [get_ports {dip_sw[6]}]  ;# som240_1_b18  Bank45  IO_L2N_AD14N_45
set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS18} [get_ports {dip_sw[7]}]  ;# som240_1_c18  Bank45  IO_L3P_AD13P_45

# ---- status LEDs led[0..2] (rest continue on SOM240_2 below) ----
set_property -dict {PACKAGE_PIN G10 IOSTANDARD LVCMOS18} [get_ports {led[0]}]     ;# som240_1_c19  Bank45  IO_L3N_AD13N_45
set_property -dict {PACKAGE_PIN F12 IOSTANDARD LVCMOS18} [get_ports {led[1]}]     ;# som240_1_c20  Bank45  IO_L6P_HDGC_45
set_property -dict {PACKAGE_PIN F11 IOSTANDARD LVCMOS18} [get_ports {led[2]}]     ;# som240_1_a15  Bank45  IO_L6N_HDGC_45

# ============================================================================
#  SOM240_2  (Bank 43), in I/O-map order
# ============================================================================

# ---- status LEDs led[3..7] ----
set_property -dict {PACKAGE_PIN AE12 IOSTANDARD LVCMOS18} [get_ports {led[3]}]    ;# som240_2_d44  Bank43  IO_L5P_HDGC_AD7P_43
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS18} [get_ports {led[4]}]    ;# som240_2_d45  Bank43  IO_L5N_HDGC_AD7N_43
set_property -dict {PACKAGE_PIN AG10 IOSTANDARD LVCMOS18} [get_ports {led[5]}]    ;# som240_2_d46  Bank43  IO_L1P_AD11P_43
set_property -dict {PACKAGE_PIN AH10 IOSTANDARD LVCMOS18} [get_ports {led[6]}]    ;# som240_2_d48  Bank43  IO_L1N_AD11N_43
set_property -dict {PACKAGE_PIN AF11 IOSTANDARD LVCMOS18} [get_ports {led[7]}]    ;# som240_2_d49  Bank43  IO_L2P_AD10P_43

# ---- 16x2 character LCD (HD44780, 4-bit; lcd_db[3:0] = DB[7:4]) ----
set_property -dict {PACKAGE_PIN AG11 IOSTANDARD LVCMOS18} [get_ports lcd_rs]      ;# som240_2_d50  Bank43  IO_L2N_AD10N_43
set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS18} [get_ports lcd_rw]      ;# som240_2_c46  Bank43  IO_L3P_AD9P_43
set_property -dict {PACKAGE_PIN AH11 IOSTANDARD LVCMOS18} [get_ports lcd_e]       ;# som240_2_c47  Bank43  IO_L3N_AD9N_43
set_property -dict {PACKAGE_PIN AC12 IOSTANDARD LVCMOS18} [get_ports {lcd_db[0]}] ;# som240_2_c48  Bank43  IO_L6P_HDGC_AD6P_43
set_property -dict {PACKAGE_PIN AD12 IOSTANDARD LVCMOS18} [get_ports {lcd_db[1]}] ;# som240_2_c50  Bank43  IO_L6N_HDGC_AD6N_43
set_property -dict {PACKAGE_PIN AE10 IOSTANDARD LVCMOS18} [get_ports {lcd_db[2]}] ;# som240_2_c51  Bank43  IO_L4P_AD8P_43
set_property -dict {PACKAGE_PIN AF10 IOSTANDARD LVCMOS18} [get_ports {lcd_db[3]}] ;# som240_2_c52  Bank43  IO_L4N_AD8N_43

# ---- free / unused mapped pins (available for expansion) ----
# som240_2_b44 = AD11  (IO_L7P_HDGC_AD5P_43)
# som240_2_b45 = AD10  (IO_L7N_HDGC_AD5N_43)
# som240_2_b46 = AA11  (IO_L9P_AD3P_43)
# som240_2_b48 = AA10  (IO_L9N_AD3N_43)

# ---- async inputs are synchronized in RTL (2-FF); slow human-visible outputs ----
set_false_path -from [get_ports {rot_a rot_b rot_push rst_btn start_btn dip_sw[*]}]
set_false_path -to   [get_ports {led[*] lcd_rs lcd_rw lcd_e lcd_db[*]}]
