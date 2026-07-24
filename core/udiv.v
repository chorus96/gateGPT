// Unsigned iterative divider: quo = num / den (floor), W-bit. Radix-4 restoring,
// MSB-first, 2 quotient bits per cycle -> W/2 cycles (W must be even). den==0 yields
// all-ones (guard). Shared by RMSNorm (ss/N, 2^22/r) and attention (weighted-sum /
// softmax-sum); the sampler uses rem_out. Produces the exact floor quotient and
// remainder (bit-identical to a radix-2 divider), just in half the cycles.
// Synthesizable (no '/' operator). (SystemVerilog)
module udiv #(
    parameter int W = 48
) (
    input  logic         clk,
    input  logic         resetn,
    input  logic         start,
    input  logic [W-1:0] num,
    input  logic [W-1:0] den,
    output logic         busy,
    output logic         done,
    output logic [W-1:0] quo,
    output logic [W-1:0] rem_out      // num mod den (valid with done)
);
    logic [W-1:0]  ncur, q, dreg;
    logic [W+1:0]  rem;                // partial remainder (+2 guard bits for the radix-4 shift)
    logic [7:0]    cnt;
    logic          st;

    // bring down the next two num bits (MSB-first): rshift = rem*4 + num[top 2]
    wire [W+1:0] rshift = {rem[W-1:0], ncur[W-1:W-2]};
    wire [W+1:0] d1 = {2'b00, dreg};
    wire [W+1:0] d2 = {1'b0, dreg, 1'b0};
    wire [W+1:0] d3 = d2 + d1;
    // radix-4 quotient digit: largest qd in {0,1,2,3} with rshift >= qd*den
    wire [1:0]   qd  = (rshift >= d3) ? 2'd3 : (rshift >= d2) ? 2'd2 : (rshift >= d1) ? 2'd1 : 2'd0;
    wire [W+1:0] sub = (qd == 2'd3) ? d3 : (qd == 2'd2) ? d2 : (qd == 2'd1) ? d1 : '0;
    wire [W+1:0] remn = rshift - sub;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            busy <= 1'b0; done <= 1'b0; st <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!st) begin
                if (start) begin
                    ncur <= num; dreg <= (den == 0) ? '1 : den;
                    rem <= '0; q <= '0; cnt <= (W/2) - 1;
                    busy <= 1'b1; st <= 1'b1;
                end
            end else begin
                rem  <= remn;
                q    <= {q[W-3:0], qd};
                ncur <= {ncur[W-3:0], 2'b00};
                if (cnt == 0) begin
                    quo <= {q[W-3:0], qd};
                    rem_out <= remn[W-1:0];          // final remainder
                    busy <= 1'b0; done <= 1'b1; st <= 1'b0;
                end else cnt <= cnt - 8'd1;
            end
        end
    end
endmodule
