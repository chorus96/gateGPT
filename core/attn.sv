// 등록된 vmem 읽기(1사이클 지연, read-ahead)를 사용하는 단일 위치 멀티헤드 어텐션.
// 헤드마다: 쿼리 슬라이스 로드, score = scale*(q.k), max-차감 + exp + sum으로 softmax,
// output = sum(e*v)/sum(e) (절삭 나눗셈). 각 vmem 읽기 루프는 데이터를 소비하기 한 사이클
// 전에 주소를 제시하며, 지연 인덱스(x_d)가 방금 도착한 데이터가 어느 원소인지 태그함.
// 한 헤드의 HEAD_DIM개 출력 성분은 모두 같은 softmax 합으로 나누므로, 분자들을 먼저
// 누산한 뒤 HEAD_DIM개의 병렬 나눗셈기로 동시에 나눔(성분당이 아니라 헤드당 나눗셈
// 지연 1회). QModel.attn_debug 와 비트 일치. (SystemVerilog)
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
    input  logic [4:0]  ctx_len,        // 유효 컨텍스트 위치 수 (1..BLOCK)
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
    logic [4:0]  s, d;             // 피드 인덱스 (s = 컨텍스트 위치, d = 헤드 내 차원)
    logic [4:0]  s_d, d_d;         // 지연됨: 이번 사이클에 유효한 데이터의 인덱스
    logic [9:0]  soff;             // 제시된 s에 대한 s*N_EMBED
    logic        feeding, vld;

    logic signed [15:0] qreg [0:HEAD_DIM-1];
    logic signed [15:0] score [0:BLOCK-1];
    logic [15:0]        ev [0:BLOCK-1];
    logic signed [15:0] mmax;
    logic [31:0]        sum_e;
    logic signed [47:0] acc;
    // 점수 계산 파이프라인 스테이지 2: 완료된 닷 프로덕트를 등록한 뒤, 스케일(2차 곱셈 +
    // 포화)과 max 비교를 다음 사이클에 실행.
    logic signed [47:0] dot_raw;
    logic [4:0]         dot_s;
    logic               dot_vld;

    // 이번 사이클에 제시되는 주소 (vmem에 등록됨 -> 데이터는 다음 사이클)
    always_comb begin
        unique case (ph)
            P_QLOAD: v_raddr = q_base + hbase + {5'd0, d};
            P_SCORE: v_raddr = k_base + soff + hbase + {5'd0, d};
            P_WSUM:  v_raddr = v_base + soff + hbase + {5'd0, d};
            default: v_raddr = 10'd0;
        endcase
    end

    // 점수 스케일링: attn_scale * sat16(acc >> FRAC)
    function automatic logic signed [15:0] scale_score(input logic signed [47:0] a);
        logic signed [47:0] ash; logic signed [15:0] s1; logic signed [31:0] m, msh;
        ash = a >>> FRAC;
        s1 = (ash > 48'sd32767) ? 16'sd32767 : (ash < -48'sd32768) ? -16'sd32768 : ash[15:0];
        m = s1 * attn_scale; msh = m >>> FRAC;
        return (msh > 32'sd32767) ? 16'sd32767 : (msh < -32'sd32768) ? -16'sd32768 : msh[15:0];
    endfunction

    // exp(score[s]-max); exp_unit은 입력을 내부적으로 등록함(지연 1)
    wire signed [16:0] diff = $signed(score[s]) - $signed(mmax);
    wire signed [15:0] dz = (diff < -17'sd32768) ? -16'sd32768 : diff[15:0];
    wire signed [15:0] eo;
    exp_unit u_exp (.clk(clk), .z(dz), .e(eo));

    // 가중합 나눗셈: 한 헤드의 HEAD_DIM개 분자는 분모 sum_e를 공유하므로 모두 동시에 나눔
    // -- 성분당이 아니라 헤드당 나눗셈 지연 1회.
    logic signed [47:0] num [0:HEAD_DIM-1];      // 출력 성분별 누산된 분자
    logic               d_start;                 // 모든 나눗셈기 공유 start 펄스
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

    // 방금 도착한 데이터로부터의 MAC 항
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
                    // 스테이지 2: 등록된 닷 프로덕트 마무리 (스케일 + max 비교)
                    if (dot_vld) begin
                        score[dot_s[3:0]] <= scale_score(dot_raw);
                        if (scale_score(dot_raw) > mmax) mmax <= scale_score(dot_raw);
                        if (dot_s == ctx_len - 1) begin s <= 0; sum_e <= 0; feeding <= 1; ph <= P_EXP; end
                    end
                    // 스테이지 1: MAC q.k; 완료된 닷 프로덕트 등록
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
                    if (vld) begin                           // exp_unit 출력 -> 누산
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
                    // 성분 d의 분자를 누산; s를 컨텍스트에 걸쳐 스윕
                    if (vld) begin
                        acc <= vacc;
                        if (s_d == ctx_len - 1) begin
                            num[d] <= vacc;                       // 이 성분의 분자
                            if (d == HEAD_DIM - 1) begin
                                d_start <= 1; feeding <= 0; ph <= P_WDIV;   // 모든 나눗셈기 발사
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
