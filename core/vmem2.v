// Activation scratchpad: block RAM, TRUE dual-port. Two independent ports (A, B); each
// port registers its read every cycle (rdata valid one cycle after addr) and writes when
// its we is asserted. This gives two memory accesses per cycle -- either two reads (e.g.
// RMSNorm sum-of-squares, attention score/weighted-sum), two writes (RMSNorm scale,
// matvec writeback), or the legacy one-read + one-write. Callers must not write the same
// address on both ports in one cycle. 1024x16 fits one RAMB18 in true-dual-port mode.
// (SystemVerilog)
module vmem2 #(
    parameter int AW = 10,
    parameter int DW = 16
) (
    input  logic                 clk,
    // port A
    input  logic                 we_a,
    input  logic [AW-1:0]        addr_a,
    input  logic signed [DW-1:0] wdata_a,
    output logic signed [DW-1:0] rdata_a,
    // port B
    input  logic                 we_b,
    input  logic [AW-1:0]        addr_b,
    input  logic signed [DW-1:0] wdata_b,
    output logic signed [DW-1:0] rdata_b
);
    // XST true-dual-port BRAM template: one always block PER PORT on the shared array.
    // (Both ports in a single block makes XST fall back to flip-flops, not block RAM.)
    (* ram_style = "block" *) logic signed [DW-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin                 // port A
        if (we_a) mem[addr_a] <= wdata_a;
        rdata_a <= mem[addr_a];
    end
    always_ff @(posedge clk) begin                 // port B
        if (we_b) mem[addr_b] <= wdata_b;
        rdata_b <= mem[addr_b];
    end
endmodule
