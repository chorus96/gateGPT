// Token sampler. Reads VOCAB logits from vmem (registered read -> read-ahead).
// sample_mode=0 -> argmax (greedy). sample_mode=1 -> temperature softmax categorical:
// scaled=logit/temp, softmax via max+exp+sum, draw r = LCG(rng) mod total, pick first
// cumulative > r. Bit-exact with tools/fixedpoint.generate. Emits token + advanced LCG.
// (SystemVerilog)
module sampler #(
    parameter int VOCAB = 27,
    parameter int FRAC  = 11
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic        sample_mode,
    input  logic signed [15:0] inv_temp,    // (1/temperature) in Q11
    input  logic [31:0] rng_in,
    input  logic [9:0]  lm_base,
    output logic [9:0]  v_raddr,
    input  logic signed [15:0] v_rdata,
    output logic [4:0]  token,
    output logic [31:0] rng_out,
    output logic        busy,
    output logic        done
);
    typedef enum logic [2:0] { S_IDLE, S_SCALE, S_EXP, S_MOD, S_PICK } state_t;
    state_t    st;
    logic [4:0]  i, fi, fi_d, fi_d2, amax;
    logic        feeding, vld, vld2;
    logic signed [15:0] logit_r;    // logit registered before the variable temp multiply
    logic signed [15:0] scaled [0:31];
    logic [15:0]        ev [0:31];
    logic signed [15:0] mmax;       // max of scaled logits (for softmax)
    logic signed [15:0] maxlog;     // max of raw logits (for greedy argmax)
    logic [31:0]        total, cum, rval, rngs;

    assign v_raddr = lm_base + {5'd0, fi};

    // temperature scale: sat16( (logit * inv_temp) >> FRAC ). inv_temp is now variable
    // (rotary-selected), so register the logit first -> the 16x16 multiply starts from a
    // fabric register, keeping the BRAM-output net off the critical path.
    wire signed [31:0] sc  = $signed(logit_r) * inv_temp;
    wire signed [31:0] scs = sc >>> FRAC;
    wire signed [15:0] scaled_v =
        (scs >  32'sd32767) ? 16'sd32767 : (scs < -32'sd32768) ? -16'sd32768 : scs[15:0];

    // exp(scaled[fi]-max); exp_unit registers its input internally (latency 1)
    wire signed [16:0] diff = $signed(scaled[fi]) - $signed(mmax);
    wire signed [15:0] dz = (diff < -17'sd32768) ? -16'sd32768 : diff[15:0];
    wire signed [15:0] eo;
    exp_unit u_exp (.clk(clk), .z(dz), .e(eo));

    // modulo via udiv: the divider already produces the remainder (rng mod total),
    // so no separate q*total multiply is needed.
    logic       d_start;
    wire        d_done;
    wire [47:0] d_quo, d_rem;
    udiv #(.W(48)) u_div (.clk(clk), .resetn(resetn), .start(d_start),
        .num({16'd0, rngs}), .den({16'd0, total}), .busy(), .done(d_done),
        .quo(d_quo), .rem_out(d_rem));

    always_ff @(posedge clk) begin
        if (!resetn) begin
            st <= S_IDLE; busy <= 0; done <= 0; d_start <= 0; feeding <= 0; vld <= 0;
        end else begin
            done <= 0; d_start <= 0;
            fi_d <= fi; vld <= feeding;
            fi_d2 <= fi_d; vld2 <= vld; logit_r <= v_rdata;     // scale-pass pipeline stage
            unique case (st)
                S_IDLE: if (start) begin
                    busy <= 1; fi <= 0; mmax <= -16'sd32768; maxlog <= -16'sd32768; amax <= 0;
                    total <= 0; feeding <= 1; st <= S_SCALE;
                end
                S_SCALE: begin
                    if (vld2) begin                              // consume the registered logit
                        scaled[fi_d2] <= scaled_v;
                        if (scaled_v > mmax) mmax <= scaled_v;
                        if ($signed(logit_r) > maxlog) begin maxlog <= logit_r; amax <= fi_d2; end
                    end
                    if (feeding) begin
                        if (fi == VOCAB - 1) feeding <= 0;
                        else fi <= fi + 1;
                    end
                    if (vld2 && fi_d2 == VOCAB - 1) begin
                        if (sample_mode) begin fi <= 0; feeding <= 1; st <= S_EXP; end
                        else begin token <= amax; rng_out <= rng_in;
                                   busy <= 0; done <= 1; st <= S_IDLE; end
                    end
                end
                S_EXP: begin
                    if (vld) begin                           // exp_unit output -> accumulate
                        ev[fi_d] <= eo;
                        total <= total + {16'd0, eo};
                        if (fi_d == VOCAB - 1) begin
                            rngs <= rng_in * 32'd1664525 + 32'd1013904223;
                            st <= S_MOD;
                        end
                    end
                    if (feeding) begin
                        if (fi == VOCAB - 1) feeding <= 0;
                        else fi <= fi + 1;
                    end
                end
                S_MOD: begin
                    if (!d_start && !d_done) d_start <= 1;
                    if (d_done) begin
                        rval <= d_rem[31:0]; rng_out <= rngs;
                        cum <= 0; i <= 0; token <= VOCAB - 1; st <= S_PICK;
                    end
                end
                S_PICK: begin
                    if ((cum + {16'd0, ev[i]}) > rval) begin
                        token <= i; busy <= 0; done <= 1; st <= S_IDLE;
                    end else if (i == VOCAB - 1) begin
                        busy <= 0; done <= 1; st <= S_IDLE;
                    end else begin
                        cum <= cum + {16'd0, ev[i]}; i <= i + 1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
