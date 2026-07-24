// Generic HD44780 character-LCD controller, 4-bit mode (write-only), 2 lines.
// Runs the power-on init, then CONTINUOUSLY redraws both rows from line1/line2
// (16 ASCII bytes each, byte i = column i). Each frame latches line1/line2 first
// so a mid-frame change never tears the display. The caller supplies ready-made
// ASCII (token->char / number formatting live in the top), so this is a dumb panel.
//
// All delays are derived from CLK_HZ (real-time), so they stay correct at any core
// clock. Sim can pass a tiny CLK_HZ (or override the *_CYC params) to shrink them.
// (SystemVerilog)
module lcd_hd44780 #(
    parameter int CLK_HZ      = 50_000_000,
    parameter int POWERON_CYC = CLK_HZ/25,        // ~40 ms
    parameter int LONG_CYC    = CLK_HZ/244,       // ~4.1 ms (after first 0x3 / clear)
    parameter int SETTLE_CYC  = CLK_HZ/25000,     // ~40 us (normal command/data)
    parameter int E_CYC       = CLK_HZ/833333,    // ~1.2 us E high
    parameter int SU_CYC      = CLK_HZ/12500000   // ~80 ns RS/data setup before E (tAS)
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic [(16*8)-1:0] line1,   // row 1 ASCII (byte 0 = leftmost column)
    input  logic [(16*8)-1:0] line2,   // row 2 ASCII

    output logic        lcd_rs,        // 0 = command, 1 = data
    output logic        lcd_rw,        // tied 0 (write only)
    output logic        lcd_e,         // enable strobe
    output logic [3:0]  lcd_db,        // DB[7:4]
    output logic        ready          // high once init done
);
    assign lcd_rw = 1'b0;

    // ---- init micro-sequence: 8 ops. is_nibble=1 -> high nibble only (8->4 bit). ----
    localparam int N_INIT = 8;
    function automatic logic [9:0] init_op(input logic [3:0] idx);   // {is_nibble, rs, data[7:0]}
        unique case (idx)
            4'd0: return {1'b1, 1'b0, 8'h30};  // 0x3 wake (8-bit)
            4'd1: return {1'b1, 1'b0, 8'h30};
            4'd2: return {1'b1, 1'b0, 8'h30};
            4'd3: return {1'b1, 1'b0, 8'h20};  // 0x2 -> 4-bit mode
            4'd4: return {1'b0, 1'b0, 8'h28};  // function set: 4-bit, 2-line, 5x8
            4'd5: return {1'b0, 1'b0, 8'h0C};  // display on, cursor off
            4'd6: return {1'b0, 1'b0, 8'h01};  // clear (needs long wait)
            default: return {1'b0, 1'b0, 8'h06}; // entry mode: increment
        endcase
    endfunction

    // main phase FSM
    typedef enum logic [2:0] {
        P_POWERON,   // power-up settle
        P_INIT,      // 8-op init sequence
        P_LATCH,     // snapshot line1/line2 for a tear-free frame
        P_ADDR1,     // set DDRAM addr 0x80 (row 1)
        P_CHARS1,    // write 16 chars of row 1
        P_ADDR2,     // set DDRAM addr 0xC0 (row 2)
        P_CHARS2     // write 16 chars of row 2
    } phase_t;

    // byte-send sub-FSM (each nibble: RS/data setup -> E high -> settle)
    typedef enum logic [2:0] {
        B_IDLE  = 3'd0,
        B_HI_E  = 3'd1, B_HI_S = 3'd2,
        B_LO_E  = 3'd3, B_LO_S = 3'd4,
        B_DONE  = 3'd5,
        B_HI_SU = 3'd6, B_LO_SU = 3'd7
    } bstate_t;

    phase_t    phase;
    bstate_t   bs;
    logic        bs_start, bs_busy, bs_nibble, bs_rs;
    logic [7:0]  bs_data;
    logic [31:0] bs_settle, cnt, poweron_cnt;
    logic [4:0]  step;
    logic [9:0]  op;
    logic [(16*8)-1:0] l1_buf, l2_buf;   // latched frame

    // current char: row-1 vs row-2 buffer, indexed by step
    wire [7:0] char1 = l1_buf[(step*8) +: 8];
    wire [7:0] char2 = l2_buf[(step*8) +: 8];

    always_ff @(posedge clk) begin
        if (!resetn) begin
            phase <= P_POWERON; bs <= B_IDLE; bs_start <= 1'b0; bs_busy <= 1'b0;
            bs_nibble <= 1'b0; bs_rs <= 1'b0; bs_data <= 8'd0; bs_settle <= SETTLE_CYC;
            cnt <= 32'd0; step <= 5'd0; poweron_cnt <= 32'd0;
            lcd_rs <= 1'b0; lcd_e <= 1'b0; lcd_db <= 4'd0; ready <= 1'b0;
            l1_buf <= {16{8'h20}}; l2_buf <= {16{8'h20}};
        end else begin
            // ---------- byte-send sub-FSM ----------
            case (bs)
                B_IDLE: begin
                    lcd_e <= 1'b0;
                    if (bs_start) begin
                        bs_busy <= 1'b1;
                        lcd_rs  <= bs_rs;
                        lcd_db  <= bs_data[7:4];   // hi nibble valid, E low (setup)
                        lcd_e   <= 1'b0;
                        cnt     <= 32'd0;
                        bs      <= B_HI_SU;
                    end
                end
                B_HI_SU: if (cnt >= SU_CYC - 1) begin lcd_e <= 1'b1; cnt <= 32'd0; bs <= B_HI_E; end
                         else cnt <= cnt + 32'd1;
                B_HI_E:  if (cnt >= E_CYC - 1)  begin lcd_e <= 1'b0; cnt <= 32'd0; bs <= B_HI_S; end
                         else cnt <= cnt + 32'd1;
                B_HI_S:  if (cnt >= bs_settle - 1) begin
                             cnt <= 32'd0;
                             if (bs_nibble) bs <= B_DONE;
                             else begin lcd_db <= bs_data[3:0]; bs <= B_LO_SU; end
                         end else cnt <= cnt + 32'd1;
                B_LO_SU: if (cnt >= SU_CYC - 1) begin lcd_e <= 1'b1; cnt <= 32'd0; bs <= B_LO_E; end
                         else cnt <= cnt + 32'd1;
                B_LO_E:  if (cnt >= E_CYC - 1)  begin lcd_e <= 1'b0; cnt <= 32'd0; bs <= B_LO_S; end
                         else cnt <= cnt + 32'd1;
                B_LO_S:  if (cnt >= bs_settle - 1) begin cnt <= 32'd0; bs <= B_DONE; end
                         else cnt <= cnt + 32'd1;
                B_DONE:  begin bs_busy <= 1'b0; bs <= B_IDLE; end
                default: bs <= B_IDLE;
            endcase
            if (bs_start && bs != B_IDLE) bs_start <= 1'b0;   // consume request

            // ---------- main phase FSM ----------
            case (phase)
                P_POWERON: begin
                    ready <= 1'b0;
                    if (poweron_cnt >= POWERON_CYC - 1) begin step <= 5'd0; phase <= P_INIT; end
                    else poweron_cnt <= poweron_cnt + 32'd1;
                end

                P_INIT: begin
                    if (!bs_busy && !bs_start) begin
                        if (step == N_INIT) begin step <= 5'd0; phase <= P_LATCH; end
                        else begin
                            op        = init_op(step[3:0]);
                            bs_nibble <= op[9];
                            bs_rs     <= op[8];
                            bs_data   <= op[7:0];
                            bs_settle <= (step == 5'd0 || step == 5'd6) ? LONG_CYC : SETTLE_CYC;
                            bs_start  <= 1'b1;
                            step      <= step + 5'd1;
                        end
                    end
                end

                P_LATCH: begin                     // snapshot both lines for this frame
                    ready  <= 1'b1;
                    l1_buf <= line1;
                    l2_buf <= line2;
                    step   <= 5'd0;
                    phase  <= P_ADDR1;
                end

                P_ADDR1: if (!bs_busy && !bs_start) begin
                    bs_nibble <= 1'b0; bs_rs <= 1'b0; bs_data <= 8'h80;   // row 1, col 0
                    bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                    step <= 5'd0; phase <= P_CHARS1;
                end

                P_CHARS1: if (!bs_busy && !bs_start) begin
                    if (step == 5'd16) phase <= P_ADDR2;
                    else begin
                        bs_nibble <= 1'b0; bs_rs <= 1'b1; bs_data <= char1;
                        bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                        step <= step + 5'd1;
                    end
                end

                P_ADDR2: if (!bs_busy && !bs_start) begin
                    bs_nibble <= 1'b0; bs_rs <= 1'b0; bs_data <= 8'hC0;   // row 2, col 0
                    bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                    step <= 5'd0; phase <= P_CHARS2;
                end

                P_CHARS2: if (!bs_busy && !bs_start) begin
                    if (step == 5'd16) phase <= P_LATCH;   // frame done -> redraw
                    else begin
                        bs_nibble <= 1'b0; bs_rs <= 1'b1; bs_data <= char2;
                        bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                        step <= step + 5'd1;
                    end
                end

                default: phase <= P_POWERON;
            endcase
        end
    end

endmodule
