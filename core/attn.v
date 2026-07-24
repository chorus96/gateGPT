// Single-position multi-head attention with a REGISTERED vmem read (1-cycle latency,
// read-ahead). Per head: load the query slice, score = scale*(q.k), softmax via
// max-subtract + exp + sum, output = sum(e*v)/sum(e) (truncating divide). Each vmem
// read loop presents the address one cycle before consuming the data; a delayed index
// (x_d) tags which element the just-arrived data belongs to. The HEAD_DIM output
// components of a head all divide by the same softmax sum, so their numerators are
// accumulated first and then divided CONCURRENTLY by HEAD_DIM parallel dividers (one
// divide latency per head instead of one per component). Bit-exact with QModel.attn_debug.
// (SystemVerilog)
module attn #(
    parameter int N_EMBED  = 24,
    parameter int N_HEAD   = 4,
    parameter int HEAD_DIM = 6,
    parameter int BLOCK    = 16,
    parameter int FRAC     = 11
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic signed [15:0] attn_scale,
    input  logic [4:0]  ctx_len,        // number of valid context positions (1..BLOCK)
    input  logic [9:0]  q_base,
    input  logic [9:0]  k_base,
    input  logic [9:0]  v_base,
    input  logic [9:0]  o_base,
    output logic [9:0]  v_raddr,
    input  logic signed [15:0] v_rdata,
    output logic        v_we,
    output logic [9:0]  v_waddr,
    output logic signed [15:0] v_wdata,
    output logic        busy,
    output logic        done
);
    typedef enum logic [3:0] {
        P_IDLE, P_QLOAD, P_SCORE, P_EXP, P_WSUM, P_WDIV, P_WWB, P_NEXTH
    } phase_t;
    phase_t    ph;
    logic [3:0]  h;
    logic [9:0]  hbase;
    logic [4:0]  s, d;             // feed indices (s = context pos, d = within-head dim)
    logic [4:0]  s_d, d_d;         // delayed: index of the data valid THIS cycle
    logic [9:0]  soff;             // s*N_EMBED for the presented s
    logic        feeding, vld;

    logic signed [15:0] qreg [0:HEAD_DIM-1];
    logic signed [15:0] score [0:BLOCK-1];
    logic [15:0]        ev [0:BLOCK-1];
    logic signed [15:0] mmax;
    logic [31:0]        sum_e;
    logic signed [47:0] acc;
    // pipeline stage 2 of scoring: the completed dot product is registered, then the
    // scale (2nd multiply + saturates) and the max-compare run the next cycle.
    logic signed [47:0] dot_raw;
    logic [4:0]         dot_s;
    logic               dot_vld;

    // address presented this cycle (registered into vmem -> data next cycle)
    always_comb begin
        unique case (ph)
            P_QLOAD: v_raddr = q_base + hbase + {5'd0, d};
            P_SCORE: v_raddr = k_base + soff + hbase + {5'd0, d};
            P_WSUM:  v_raddr = v_base + soff + hbase + {5'd0, d};
            default: v_raddr = 10'd0;
        endcase
    end

    // score scaling: attn_scale * sat16(acc >> FRAC)
    function automatic logic signed [15:0] scale_score(input logic signed [47:0] a);
        logic signed [47:0] ash; logic signed [15:0] s1; logic signed [31:0] m, msh;
        ash = a >>> FRAC;
        s1 = (ash > 48'sd32767) ? 16'sd32767 : (ash < -48'sd32768) ? -16'sd32768 : ash[15:0];
        m = s1 * attn_scale; msh = m >>> FRAC;
        return (msh > 32'sd32767) ? 16'sd32767 : (msh < -32'sd32768) ? -16'sd32768 : msh[15:0];
    endfunction

    // exp(score[s]-max); exp_unit registers its input internally (latency 1)
    wire signed [16:0] diff = $signed(score[s]) - $signed(mmax);
    wire signed [15:0] dz = (diff < -17'sd32768) ? -16'sd32768 : diff[15:0];
    wire signed [15:0] eo;
    exp_unit u_exp (.clk(clk), .z(dz), .e(eo));

    // weighted-sum divide: the HEAD_DIM numerators of a head share the denominator sum_e,
    // so divide them all CONCURRENTLY -- one divide latency per head, not per component.
    logic signed [47:0] num [0:HEAD_DIM-1];      // accumulated numerator per output component
    logic               d_start;                 // shared start pulse for all dividers
    wire [HEAD_DIM-1:0] dv_done;
    wire signed [15:0]  o_sat_arr [0:HEAD_DIM-1];
    generate for (genvar gi = 0; gi < HEAD_DIM; gi++) begin : DIVS
        wire [47:0] na  = num[gi][47] ? (~num[gi] + 48'd1) : num[gi];
        wire [47:0] quo;
        udiv #(.W(48)) u_div (.clk(clk), .resetn(resetn), .start(d_start),
            .num(na), .den({31'd0, sum_e[16:0]}), .busy(), .done(dv_done[gi]), .quo(quo));
        wire signed [47:0] qs = num[gi][47] ? -$signed(quo) : $signed(quo);
        assign o_sat_arr[gi] =
            (qs > 48'sd32767) ? 16'sd32767 : (qs < -48'sd32768) ? -16'sd32768 : qs[15:0];
    end endgenerate

    // MAC terms from the just-arrived data
    wire signed [47:0] kprod = $signed(qreg[d_d[2:0]]) * $signed(v_rdata);          // q.k
    wire signed [47:0] vprod = $signed({1'b0, ev[s_d[3:0]]}) * $signed(v_rdata);    // e.v
    wire signed [47:0] kacc  = (d_d == 0) ? kprod : acc + kprod;
    wire signed [47:0] vacc  = (s_d == 0) ? vprod : acc + vprod;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            ph <= P_IDLE; busy <= 0; done <= 0; v_we <= 0; d_start <= 0;
            feeding <= 0; vld <= 0;
        end else begin
            done <= 0; v_we <= 0; d_start <= 0; dot_vld <= 0;
            s_d <= s; d_d <= d; vld <= feeding;
            unique case (ph)
                P_IDLE: if (start) begin
                    busy <= 1; h <= 0; hbase <= 0; d <= 0; feeding <= 1; ph <= P_QLOAD;
                end
                P_QLOAD: begin
                    if (vld) qreg[d_d[2:0]] <= v_rdata;
                    if (feeding) begin
                        if (d == HEAD_DIM - 1) feeding <= 0;
                        else d <= d + 1;
                    end
                    if (vld && d_d == HEAD_DIM - 1) begin
                        s <= 0; d <= 0; soff <= 0; acc <= 0; mmax <= -16'sd32768;
                        feeding <= 1; ph <= P_SCORE;
                    end
                end
                P_SCORE: begin
                    // stage 2: finalize the registered dot product (scale + max compare)
                    if (dot_vld) begin
                        score[dot_s[3:0]] <= scale_score(dot_raw);
                        if (scale_score(dot_raw) > mmax) mmax <= scale_score(dot_raw);
                        if (dot_s == ctx_len - 1) begin s <= 0; sum_e <= 0; feeding <= 1; ph <= P_EXP; end
                    end
                    // stage 1: MAC q.k; register the completed dot product
                    if (vld) begin
                        acc <= kacc;
                        if (d_d == HEAD_DIM - 1) begin
                            dot_raw <= kacc; dot_s <= s_d; dot_vld <= 1'b1;
                        end
                    end
                    if (feeding) begin
                        if (d == HEAD_DIM - 1) begin
                            d <= 0;
                            if (s == ctx_len - 1) feeding <= 0;
                            else begin s <= s + 1; soff <= soff + N_EMBED; end
                        end else d <= d + 1;
                    end
                end
                P_EXP: begin
                    if (vld) begin                           // exp_unit output -> accumulate
                        ev[s_d[3:0]] <= eo;
                        sum_e <= sum_e + {16'd0, eo};
                        if (s_d == ctx_len - 1) begin
                            d <= 0; s <= 0; soff <= 0; acc <= 0; feeding <= 1; ph <= P_WSUM;
                        end
                    end
                    if (feeding) begin
                        if (s == ctx_len - 1) feeding <= 0;
                        else s <= s + 1;
                    end
                end
                P_WSUM: begin
                    // accumulate the numerator for component d; sweep s over the context
                    if (vld) begin
                        acc <= vacc;
                        if (s_d == ctx_len - 1) begin
                            num[d] <= vacc;                       // numerator for this component
                            if (d == HEAD_DIM - 1) begin
                                d_start <= 1; feeding <= 0; ph <= P_WDIV;   // fire all dividers
                            end else begin
                                d <= d + 1; s <= 0; soff <= 0; acc <= 0; feeding <= 1;
                            end
                        end
                    end
                    if (feeding) begin
                        if (s == ctx_len - 1) feeding <= 0;
                        else begin s <= s + 1; soff <= soff + N_EMBED; end
                    end
                end
                P_WDIV: if (dv_done[0]) begin d <= 0; ph <= P_WWB; end
                P_WWB: begin
                    v_we <= 1; v_waddr <= o_base + hbase + {5'd0, d}; v_wdata <= o_sat_arr[d];
                    if (d == HEAD_DIM - 1) ph <= P_NEXTH;
                    else d <= d + 1;
                end
                P_NEXTH: begin
                    if (h == N_HEAD - 1) begin busy <= 0; done <= 1; ph <= P_IDLE; end
                    else begin
                        h <= h + 1; hbase <= hbase + HEAD_DIM; d <= 0; feeding <= 1; ph <= P_QLOAD;
                    end
                end
                default: ph <= P_IDLE;
            endcase
        end
    end
endmodule
