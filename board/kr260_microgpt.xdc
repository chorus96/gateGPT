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
#  PERIPHERALS (KR260) -- Raspberry Pi 40-pin GPIO header assignment:
#  The KR260 carrier has no onboard switches/LEDs/16x2-LCD/rotary-encoder, but it
#  exposes 28 user PL I/O on the Raspberry Pi 40-pin GPIO header (J17). All 28 of
#  this design's signals are assigned below IN PHYSICAL-PIN ORDER of that header,
#  so you can wire peripherals straight down the connector. Each line is annotated
#  with:  RPi physical pin #  ->  BCM GPIO name.
#
#  >>> ACTION REQUIRED before implementation <<<
#  The PACKAGE_PIN on every peripheral line below is the placeholder token
#  <BALL>. It is NOT a real ball -- the exact xck26-sfvc784 ball for each RPi
#  header pin lives in the AMD KR260 master XDC (kria-vitis-platforms KR260 /
#  the KR260 board files), because each RPi pin routes through the SOM240
#  connector to a specific SOM ball. Replace every <BALL> with the ball the
#  KR260 master XDC gives for that RPi pin (they are commented out so the file
#  still loads; uncomment as you fill them). Do NOT guess the balls -- a wrong
#  ball can fail to route or drive the wrong SOM pin. Paste your KR260 master XDC
#  (even a partial RPi-header dump) and these can be filled in for you.
#
#  All KR260 PL HD/HP bank user I/O are 1.8 V -> IOSTANDARD LVCMOS18.

# ---- clock: 100 MHz from PS pl_clk0 (no package pin; PS-sourced net) ----
create_clock -period 10.000 -name clk_100 [get_ports clk_100]
# The 80 MHz core clock is auto-derived by Vivado from the MMCME4 output.

# ============================================================================
#  Raspberry Pi 40-pin GPIO header (J17), in physical-pin order.
#  Pins 1,17 = 3V3 ; 2,4 = 5V ; 6,9,14,20,25,30,34,39 = GND -> not assigned.
#  The 28 usable GPIO pins carry all 28 design signals, top of header to bottom.
# ============================================================================

# ---- reset / start push buttons (active high in RTL) ----
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports rst_btn]    ;# RPi pin 3  -> BCM GPIO2
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports start_btn]  ;# RPi pin 5  -> BCM GPIO3

# ---- rotary encoder (async; synchronized in RTL) ----
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports rot_a]      ;# RPi pin 7  -> BCM GPIO4
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports rot_b]      ;# RPi pin 8  -> BCM GPIO14
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports rot_push]   ;# RPi pin 10 -> BCM GPIO15

# ---- 8 DIP switches (dip_sw[0..7]) ----
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[0]}]  ;# RPi pin 11 -> BCM GPIO17
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[1]}]  ;# RPi pin 12 -> BCM GPIO18
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[2]}]  ;# RPi pin 13 -> BCM GPIO27
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[3]}]  ;# RPi pin 15 -> BCM GPIO22
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[4]}]  ;# RPi pin 16 -> BCM GPIO23
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[5]}]  ;# RPi pin 18 -> BCM GPIO24
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[6]}]  ;# RPi pin 19 -> BCM GPIO10
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {dip_sw[7]}]  ;# RPi pin 21 -> BCM GPIO9

# ---- 8 status LEDs (led[0..7]) ----
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[0]}]  ;# RPi pin 22 -> BCM GPIO25
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[1]}]  ;# RPi pin 23 -> BCM GPIO11
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[2]}]  ;# RPi pin 24 -> BCM GPIO8
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[3]}]  ;# RPi pin 26 -> BCM GPIO7
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[4]}]  ;# RPi pin 27 -> BCM GPIO0
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[5]}]  ;# RPi pin 28 -> BCM GPIO1
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[6]}]  ;# RPi pin 29 -> BCM GPIO5
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {led[7]}]  ;# RPi pin 31 -> BCM GPIO6

# ---- 16x2 character LCD (HD44780, 4-bit; lcd_db[3:0] = DB[7:4]) ----
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports lcd_rs]      ;# RPi pin 32 -> BCM GPIO12
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports lcd_rw]      ;# RPi pin 33 -> BCM GPIO13
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports lcd_e]       ;# RPi pin 35 -> BCM GPIO19
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {lcd_db[0]}] ;# RPi pin 36 -> BCM GPIO16
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {lcd_db[1]}] ;# RPi pin 37 -> BCM GPIO26
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {lcd_db[2]}] ;# RPi pin 38 -> BCM GPIO20
# set_property -dict {PACKAGE_PIN <BALL> IOSTANDARD LVCMOS18} [get_ports {lcd_db[3]}] ;# RPi pin 40 -> BCM GPIO21

# ---- async inputs are synchronized in RTL (2-FF); slow human-visible outputs ----
set_false_path -from [get_ports {rot_a rot_b rot_push rst_btn start_btn dip_sw[*]}]
set_false_path -to   [get_ports {led[*] lcd_rs lcd_rw lcd_e lcd_db[*]}]
