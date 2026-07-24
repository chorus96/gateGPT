// Autoregressive name generator: drives the independent microgpt_core, which does
// INCREMENTAL decoding (one token per call at an absolute position, with a persistent
// KV cache). Maintains the position counter, the current token, and the RNG state;
// emits the name as packed bytes plus a per-token strobe. Tokens are 0='.', 1..26=
// 'a'..'z'; name_buf stores (token-1) so a 0..25 -> 'a'..'z' display mapping works.
// (SystemVerilog)
module name_generator #(
    parameter int MAX_LEN = 16
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic [31:0] seed,
    input  logic signed [15:0] inv_temp,
    input  logic        sample_mode,
    output logic        busy,
    output logic        done,
    output logic [7:0]  token_out,
    output logic        token_valid,
    output logic [4:0]  name_len,
    output logic [(MAX_LEN*8)-1:0] name_flat
);
    typedef enum logic [1:0] { G_IDLE, G_FIRE, G_WAIT, G_DONE } state_t;
    state_t    state;
    logic [4:0]  pos, cur_token;       // current absolute position + token fed to the core
    logic [31:0] rng;
    logic [7:0]  name_buf [0:MAX_LEN-1];

    logic       core_start;
    wire        core_busy, core_done;
    wire [4:0]  core_tok;
    wire [31:0] core_rng;
    microgpt_core u_core (
        .clk(clk), .resetn(resetn), .start(core_start),
        .token_in(cur_token), .pos_in(pos),
        .sample_mode(sample_mode), .inv_temp(inv_temp), .rng_in(rng),
        .busy(core_busy), .done(core_done), .next_token(core_tok), .rng_out(core_rng));

    generate for (genvar g = 0; g < MAX_LEN; g++) begin : GEN_FLAT
        assign name_flat[(g*8) +: 8] = name_buf[g];
    end endgenerate

    always_ff @(posedge clk) begin
        if (!resetn) begin
            state <= G_IDLE; busy <= 0; done <= 0; token_valid <= 0; name_len <= 0;
            pos <= 0; cur_token <= 0; rng <= 32'd1; core_start <= 0; token_out <= 0;
            for (int k = 0; k < MAX_LEN; k++) name_buf[k] <= 8'd0;
        end else begin
            done <= 0; token_valid <= 0; core_start <= 0;
            unique case (state)
                G_IDLE: begin
                    busy <= 0;
                    if (start) begin
                        busy <= 1; pos <= 0; cur_token <= 0; rng <= seed; name_len <= 0;
                        for (int k = 0; k < MAX_LEN; k++) name_buf[k] <= 8'd0;
                        state <= G_FIRE;
                    end
                end
                G_FIRE: if (!core_busy && !core_done) begin core_start <= 1; state <= G_WAIT; end
                G_WAIT: if (core_done) begin
                    rng <= core_rng;
                    if (core_tok == 5'd0) state <= G_DONE;       // delimiter -> end of name
                    else begin
                        name_buf[name_len[3:0]] <= {3'd0, core_tok} - 8'd1;
                        token_out   <= {3'd0, core_tok};
                        token_valid <= 1'b1;
                        name_len    <= name_len + 5'd1;
                        cur_token   <= core_tok;
                        if (pos == MAX_LEN - 1) state <= G_DONE;  // no further positions
                        else begin pos <= pos + 5'd1; state <= G_FIRE; end
                    end
                end
                G_DONE: begin busy <= 0; done <= 1; state <= G_IDLE; end
                default: state <= G_IDLE;
            endcase
        end
    end
endmodule
