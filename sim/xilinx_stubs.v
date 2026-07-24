// Behavioral stubs for the Xilinx Virtex-5 clocking primitives used by
// xupv5_microgpt_top, so the board top can be simulated WITHOUT the Xilinx
// UniSim library (Verilator / iverilog have no vendor cells).
//
// SIMULATION ONLY -- do NOT include this file in the ISE synthesis project;
// there the real UniSim primitives are used.
//
// The models are cycle-accurate for the top's needs: clock buffers pass their
// input through, and the DCM passes CLKIN straight to CLK0/CLKFX (the 4/5
// frequency ratio is irrelevant in a cycle-based sim -- the whole design just
// runs on the testbench clock) and asserts LOCKED a few cycles after RST drops.
`timescale 1ns/1ps

// ---- input clock buffer ----
module IBUFG (input wire I, output wire O);
    assign O = I;
endmodule

// ---- global clock buffer ----
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

// ---- Digital Clock Manager (base) ----
module DCM_BASE #(
    parameter CLKIN_PERIOD   = 10.0,
    parameter CLKFX_MULTIPLY = 4,
    parameter CLKFX_DIVIDE   = 5
) (
    input  wire CLKIN,
    input  wire CLKFB,
    input  wire RST,
    output wire CLK0,
    output wire CLKFX,
    output wire CLK90,
    output wire CLK180,
    output wire CLK270,
    output wire CLK2X,
    output wire CLK2X180,
    output wire CLKDV,
    output wire CLKFX180,
    output reg  LOCKED
);
    // sim: pass CLKIN through (cycle-accurate; the real 4/5 ratio does not matter
    // because every synchronous element in the design runs on this one clock).
    assign CLK0     = CLKIN;
    assign CLKFX    = CLKIN;
    assign CLK90    = 1'b0;
    assign CLK180   = 1'b0;
    assign CLK270   = 1'b0;
    assign CLK2X    = 1'b0;
    assign CLK2X180 = 1'b0;
    assign CLKDV    = 1'b0;
    assign CLKFX180 = 1'b0;

    // LOCKED asserts a few cycles after RST is released (mimics DCM lock time).
    reg [3:0] lockcnt;
    initial begin LOCKED = 1'b0; lockcnt = 4'd0; end
    always @(posedge CLKIN or posedge RST) begin
        if (RST) begin
            LOCKED  <= 1'b0;
            lockcnt <= 4'd0;
        end else if (!LOCKED) begin
            if (lockcnt >= 4'd8) LOCKED <= 1'b1;
            else                 lockcnt <= lockcnt + 4'd1;
        end
    end
endmodule
