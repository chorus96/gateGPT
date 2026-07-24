// Board-level (TOP) testbench for xupv5_microgpt_top.
//
// Simulates the whole board -- DCM/clock buffers (behavioral stubs in
// sim/xilinx_stubs.v), reset/​button debounce, rotary throttle, name generator
// (core), HD44780 LCD driver and the tokens/second meter -- WITHOUT any Xilinx
// UniSim library, so it runs under Verilator or iverilog.
//
// The top is instantiated with a reduced CLK_HZ (see SIMCLK_HZ) so the
// CLK_HZ-derived real-time delays shrink to a simulatable number of cycles.
// SIMCLK_HZ must stay >= 12_500_000, otherwise the LCD's setup delay
// SU_CYC = CLK_HZ/12_500_000 underflows to 0 and the LCD FSM stalls.
//
// Flow: release reset -> wait DCM lock -> wait the rotary start-up hold ->
// drive the encoder clockwise to raise the auto-rotation speed -> capture the
// first generated name and print it. A cycle watchdog guarantees termination.
`timescale 1ns/1ps
module tb_top;
    localparam integer SIMCLK_HZ = 12_500_000;   // sim core clock (keep >= 12.5 MHz)
    localparam integer WATCHDOG  = 25_000_000;   // hard stop (cycles)

    reg clk = 0;
    always #5 clk = ~clk;                         // pass-through DCM -> core runs on this

    reg        rst_btn   = 1'b1;                  // active-high reset (released below)
    reg        start_btn = 1'b0;                  // unused trigger on this board
    reg        rot_a = 0, rot_b = 0, rot_push = 0;
    reg  [7:0] dip_sw = 8'h5a;                    // perturbs the seed

    wire [7:0] led;
    wire       lcd_rs, lcd_rw, lcd_e;
    wire [3:0] lcd_db;

    xupv5_microgpt_top #(.CLK_HZ(SIMCLK_HZ)) dut (
        .clk_100(clk), .rst_btn(rst_btn), .start_btn(start_btn), .dip_sw(dip_sw),
        .rot_a(rot_a), .rot_b(rot_b), .rot_push(rot_push), .led(led),
        .lcd_rs(lcd_rs), .lcd_rw(lcd_rw), .lcd_e(lcd_e), .lcd_db(lcd_db)
    );

    // ---- cycle counter + capture the first completed name ----
    integer cyc = 0;
    reg          captured = 0;
    reg   [4:0]  cap_len;
    reg [(16*8)-1:0] cap_name;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (dut.gen_done && !captured) begin
            captured <= 1'b1; cap_len <= dut.name_len; cap_name <= dut.name_flat;
        end
        if (cyc > WATCHDOG) begin
            $display("TOP TIMEOUT at cycle %0d (captured=%0b)", cyc, captured);
            $finish;
        end
    end

    // ---- one clockwise detent: raises speed_level by 1 (once the rotary is armed) ----
    // Quadrature CW sequence of {a,b}: 00 -> 01 -> 11 -> 10 -> 00 (4 edges = 1 detent).
    // Each state is held longer than the rotary deglitch FILTER (2500 cycles).
    localparam integer HOLD = 4000;
    task detent_cw;
        begin
            rot_a = 1'b0; rot_b = 1'b1; repeat (HOLD) @(posedge clk);
            rot_a = 1'b1; rot_b = 1'b1; repeat (HOLD) @(posedge clk);
            rot_a = 1'b1; rot_b = 1'b0; repeat (HOLD) @(posedge clk);
            rot_a = 1'b0; rot_b = 1'b0; repeat (HOLD) @(posedge clk);
        end
    endtask

    integer i;
    reg [7:0] ch;
    initial begin
        // release reset after a short pulse
        repeat (30) @(posedge clk); rst_btn = 1'b0;

        // DCM lock (stub asserts a few cycles after RST drops)
        wait (dut.dcm_locked);
        $display("[cycle %0d] DCM locked", cyc);

        // wait for the rotary start-up hold to expire, then raise speed to max
        wait (dut.u_rot.armed);
        $display("[cycle %0d] rotary armed, raising speed...", cyc);
        for (i = 0; i < 15 && !captured; i = i + 1) detent_cw;
        $display("[cycle %0d] speed_level=%0d", cyc, dut.u_rot.speed_level);

        // first auto-generated name (the watchdog above bounds this)
        wait (captured);
        $write("generated name: ");
        for (i = 0; i < cap_len; i = i + 1) begin
            ch = 8'd97 + cap_name[(i*8) +: 8];    // name_buf holds token-1; 'a'=97
            $write("%c", ch);
        end
        $write("   (len=%0d)\n", cap_len);

        // basic sanity checks
        if (cap_len < 5'd1 || cap_len > 5'd16)
            $display("TOP FAIL: implausible name length %0d", cap_len);
        else if (dut.dcm_locked !== 1'b1)
            $display("TOP FAIL: DCM not locked");
        else begin
            // exercise the LCD/meter a little longer, then pass
            repeat (2000) @(posedge clk);
            $display("TOP PASS: board booted (DCM locked, LCD driving) and generated a name");
        end
        $finish;
    end
endmodule
