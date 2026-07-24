// RMSNorm 엔진: y[i] = sat16( sat16(x[i]*scale >> FRAC) * gain[i] >> FRAC ),
// scale = min( 2^(2*FRAC) / isqrt(sum(x^2)/N), 32767 ). Python 레퍼런스
// (tools/fixedpoint.rmsnorm)와 비트 일치. 진정한 듀얼 포트 vmem을 사용: 제곱합 패스는
// 사이클당 두 원소를 읽고(포트 A+B) 스케일 패스는 사이클당 두 원소를 쓰므로, 두 N-길이
// 루프가 각각 N/2 사이클에 실행됨(N은 짝수여야 함). 읽기 주소는 조합적으로 구동됨
// (vmem 내부 등록 읽기 -> 1사이클 지연, read-ahead). (SystemVerilog)
module norm #(
    parameter int N    = 24,
    parameter int FRAC = 11
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic [9:0]  src_base,
    input  logic [9:0]  dst_base,
    input  logic [1:0]  gain_sel,
    // 포트 A
    output logic [9:0]  addr_a,
    input  logic signed [15:0] rd_a,
    output logic        we_a,
    output logic signed [15:0] wd_a,
    // 포트 B
    output logic [9:0]  addr_b,
    input  logic signed [15:0] rd_b,
    output logic        we_b,
    output logic signed [15:0] wd_b,
    // 게인 (사이클당 두 개)
    output logic [5:0]  g_addr_a,
    output logic [5:0]  g_addr_b,
    input  logic signed [15:0] g_rdata_a,
    input  logic signed [15:0] g_rdata_b,
    output logic        busy,
    output logic        done
);
    typedef enum logic [2:0] {
        S_IDLE, S_SUM, S_SUMD, S_DIV1, S_SQRT, S_DIV2, S_SCALE
    } state_t;
    state_t    st;
    logic [6:0]  fi, fi_d;                  // 원소 인덱스(2씩 증가), 지연된 복사본
    logic        feeding, vld;
    logic signed [47:0] ss;
    logic [31:0] scale_q;
    logic signed [15:0] xreg [0:N-1];
    logic signed [15:0] t1a_r, t1b_r, ga_r, gb_r;   // 스케일 패스 파이프라인 레지스터

    assign g_addr_a = fi[5:0];
    assign g_addr_b = fi[5:0] + 6'd1;

    wire signed [47:0] xsq_a = $signed(rd_a) * $signed(rd_a);
    wire signed [47:0] xsq_b = $signed(rd_b) * $signed(rd_b);

    // 공유 udiv / isqrt
    logic [47:0] d_num, d_den;
    wire         d_done;  wire [47:0] d_quo;
    logic        d_start;
    udiv #(.W(48)) u_div (.clk(clk), .resetn(resetn), .start(d_start),
        .num(d_num), .den(d_den), .busy(), .done(d_done), .quo(d_quo));
    logic        s_start;
    wire         s_done;  wire [15:0] s_root;       // 평균 제곱 <= 2^30 -> 32비트 radicand
    isqrt #(.W(32)) u_sqrt (.clk(clk), .resetn(resetn), .start(s_start),
        .radicand(d_num[31:0]), .busy(), .done(s_done), .root(s_root));

    // 스케일 패스 스테이지 1 (두 레인): t1 = sat16( x*scale >> FRAC )
    wire signed [31:0] xsa    = $signed(xreg[fi[4:0]])        * $signed(scale_q[15:0]);
    wire signed [31:0] xsb    = $signed(xreg[fi[4:0] + 5'd1]) * $signed(scale_q[15:0]);
    wire signed [31:0] xsa_sh = xsa >>> FRAC;
    wire signed [31:0] xsb_sh = xsb >>> FRAC;
    wire signed [15:0] t1a =
        (xsa_sh >  32'sd32767) ? 16'sd32767 : (xsa_sh < -32'sd32768) ? -16'sd32768 : xsa_sh[15:0];
    wire signed [15:0] t1b =
        (xsb_sh >  32'sd32767) ? 16'sd32767 : (xsb_sh < -32'sd32768) ? -16'sd32768 : xsb_sh[15:0];
    // 스케일 패스 스테이지 2 (두 레인): y = sat16( t1 * gain >> FRAC )
    wire signed [31:0] tga    = t1a_r * ga_r;
    wire signed [31:0] tgb    = t1b_r * gb_r;
    wire signed [31:0] tga_sh = tga >>> FRAC;
    wire signed [31:0] tgb_sh = tgb >>> FRAC;
    wire signed [15:0] ya =
        (tga_sh >  32'sd32767) ? 16'sd32767 : (tga_sh < -32'sd32768) ? -16'sd32768 : tga_sh[15:0];
    wire signed [15:0] yb =
        (tgb_sh >  32'sd32767) ? 16'sd32767 : (tgb_sh < -32'sd32768) ? -16'sd32768 : tgb_sh[15:0];

    // 조합 포트 드라이버 (SUM 중 쌍 읽기, SCALE 중 쌍 쓰기)
    wire scale_wr = (st == S_SCALE) && vld;
    always_comb begin
        addr_a = src_base + {3'd0, fi};
        addr_b = src_base + {3'd0, fi} + 10'd1;
        we_a = 1'b0; we_b = 1'b0; wd_a = ya; wd_b = yb;
        if (scale_wr) begin
            addr_a = dst_base + {3'd0, fi_d};
            addr_b = dst_base + {3'd0, fi_d} + 10'd1;
            we_a = 1'b1; we_b = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            st <= S_IDLE; busy <= 0; done <= 0;
            d_start <= 0; s_start <= 0; feeding <= 0; vld <= 0;
        end else begin
            done <= 0; d_start <= 0; s_start <= 0;
            fi_d <= fi; vld <= feeding;
            unique case (st)
                S_IDLE: if (start) begin
                    busy <= 1; fi <= 0; ss <= 0; feeding <= 1; st <= S_SUM;
                end
                S_SUM: begin
                    if (vld) begin
                        ss <= ss + xsq_a + xsq_b;
                        xreg[fi_d[4:0]] <= rd_a; xreg[fi_d[4:0] + 5'd1] <= rd_b;
                    end
                    if (fi == N - 2) begin feeding <= 0; st <= S_SUMD; end
                    else fi <= fi + 7'd2;
                end
                S_SUMD: begin
                    xreg[fi_d[4:0]] <= rd_a; xreg[fi_d[4:0] + 5'd1] <= rd_b;   // 마지막 쌍
                    d_num <= ss + xsq_a + xsq_b; d_den <= N; d_start <= 1;      // 전체 합 / N
                    st <= S_DIV1;
                end
                S_DIV1: if (d_done) begin
                    d_num <= (d_quo[31:0] < 1) ? 48'd1 : {16'd0, d_quo[31:0]};  // isqrt에 공급
                    s_start <= 1; st <= S_SQRT;
                end
                S_SQRT: if (s_done) begin
                    d_num <= 48'd1 << (2*FRAC);
                    d_den <= {32'd0, ((s_root < 1) ? 16'd1 : s_root)};
                    d_start <= 1; st <= S_DIV2;
                end
                S_DIV2: if (d_done) begin
                    scale_q <= (d_quo > 48'd32767) ? 32'd32767 : d_quo[31:0];
                    fi <= 0; feeding <= 1; st <= S_SCALE;
                end
                S_SCALE: begin
                    t1a_r <= t1a; t1b_r <= t1b; ga_r <= g_rdata_a; gb_r <= g_rdata_b;
                    if (vld && fi_d == N - 2) begin busy <= 0; done <= 1; st <= S_IDLE; end
                    if (feeding) begin
                        if (fi == N - 2) feeding <= 0;
                        else fi <= fi + 7'd2;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
