// 독립적인 microGPT 추론 코어: 모듈형 데이터패스 액추에이터를 구동하는 마이크로코드-ROM
// 시퀀서. 프로그램 ROM(generated/ucode.hex)이 스케줄을 매크로 연산으로 담음; 시퀀서는
// 매 스텝마다 하나를 페치하여 해당 액추에이터를 시작하고 done을 기다림. 영속적 KV 캐시를
// 사용하는 증분 디코딩: 각 호출은 위치 pos_in의 새 토큰 하나(token_in)를 처리하여, 그 K/V를
// 캐시 슬롯 KC[pos]/VC[pos]에 쓰고(use_pos) 위치 0..pos_in에 어텐션함. KC/VC 캐시는 vmem에
// 있고 호출들에 걸쳐 유지됨. tools/fixedpoint.QModel.logits_last 와 비트 일치. (SystemVerilog)
module microgpt_core (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic [4:0]  token_in,             // 이 위치의 새 토큰
    input  logic [4:0]  pos_in,               // 절대 위치 (0..BLOCK-1)
    input  logic        sample_mode,
    input  logic signed [15:0] inv_temp,      // (1/temperature), Q5.11
    input  logic [31:0] rng_in,
    output logic        busy,
    output logic        done,
    output logic [4:0]  next_token,
    output logic [31:0] rng_out
);
`include "core_params.vh"
`include "coremap.vh"

    // ---------------- 프로그램 ROM (조합 case) + 페치/디코드 ----------------
    // 마이크로코드는 조합 함수이며 $readmemh 분산 ROM이 아님: 원래 ISE/XST 14.7이 작은
    // $readmemh ROM 배열을 0으로 묶어 보드에서 프로그램을 전부 NOP로 만들어(시퀀서가 HALT에
    // 도달 못해 코어 멈춤) 채택, Vivado에서도 유지. core/ucode_rom.vh 참조.
`include "ucode_rom.vh"
    logic [7:0]  pc;
    wire [71:0] instr   = ucode_rom(pc);
    wire [3:0]  op      = instr[3:0];
    wire [3:0]  wsel    = instr[7:4];
    wire [6:0]  in_dim  = instr[14:8];
    wire [6:0]  out_dim = instr[21:15];
    wire [4:0]  descale = instr[26:22];
    wire [1:0]  gsel    = instr[28:27];
    wire [9:0]  a_base  = instr[42:33];
    wire [9:0]  b_base  = instr[53:44];
    wire [9:0]  d_base  = instr[64:55];
    wire        use_pos = instr[66];

    // 토큰별로 래치된 입력
    logic [4:0] tok_r, pos_r;
    wire [9:0] pos_off = pos_r * N_EMBED;                    // 캐시 슬롯 오프셋
    wire [9:0] mv_dst  = use_pos ? (d_base + pos_off) : d_base;

    // ---------------- 공유 vmem (진정한 듀얼 포트) ----------------
    // 포트 A는 주 읽기(rdata=v_rdata)이자 norm의 2번째 쓰기; 포트 B는 주 쓰기이자
    // norm의 2번째 읽기(rdata=v_rdata_b).
    wire [9:0]  pa_addr, pb_addr;
    wire        pa_we, pb_we;
    wire signed [15:0] pa_wd, pb_wd, v_rdata, v_rdata_b;
    vmem2 #(.AW(10), .DW(16)) u_vmem (.clk(clk),
        .we_a(pa_we), .addr_a(pa_addr), .wdata_a(pa_wd), .rdata_a(v_rdata),
        .we_b(pb_we), .addr_b(pb_addr), .wdata_b(pb_wd), .rdata_b(v_rdata_b));

    // ---------------- 액추에이터 ----------------
    logic em_go, no_go, mv_go, at_go, vo_go, sp_go;
    wire em_we; wire [9:0] em_wa; wire signed [15:0] em_wd; wire em_busy, em_done;
    embed #(.N_EMBED(N_EMBED)) u_embed (.clk(clk), .resetn(resetn), .start(em_go),
        .token(tok_r), .pos(pos_r[3:0]), .dst_base(d_base),
        .v_we(em_we), .v_waddr(em_wa), .v_wdata(em_wd), .busy(em_busy), .done(em_done));

    wire [9:0] no_aa, no_ab; wire no_wea, no_web; wire signed [15:0] no_wda, no_wdb;
    wire no_busy, no_done;
    wire [5:0] g_addr_a, g_addr_b; wire signed [15:0] g_rdata_a, g_rdata_b;
    norm #(.N(N_EMBED), .FRAC(FRAC_BITS)) u_norm (.clk(clk), .resetn(resetn), .start(no_go),
        .src_base(a_base), .dst_base(d_base), .gain_sel(gsel),
        .addr_a(no_aa), .rd_a(v_rdata), .we_a(no_wea), .wd_a(no_wda),
        .addr_b(no_ab), .rd_b(v_rdata_b), .we_b(no_web), .wd_b(no_wdb),
        .g_addr_a(g_addr_a), .g_addr_b(g_addr_b), .g_rdata_a(g_rdata_a), .g_rdata_b(g_rdata_b),
        .busy(no_busy), .done(no_done));
    grom u_grom (.sel(gsel), .addr_a(g_addr_a), .addr_b(g_addr_b),
        .gdata_a(g_rdata_a), .gdata_b(g_rdata_b));

    wire [9:0] mv_aa, mv_ab; wire mv_wea, mv_web; wire signed [15:0] mv_wda, mv_wdb;
    wire mv_busy, mv_done;
    wire [11:0] w_addr; wire [768-1:0] w_rdata;   // 24 레인 x 16비트 x 2 열/사이클
    matvec u_mv (.clk(clk), .resetn(resetn), .start(mv_go),
        .wsel(wsel[2:0]), .in_dim(in_dim), .out_dim(out_dim),
        .act_base(a_base), .dst_base(mv_dst), .descale(descale),
        .addr_a(mv_aa), .rd_a(v_rdata), .we_a(mv_wea), .wd_a(mv_wda),
        .addr_b(mv_ab), .rd_b(v_rdata_b), .we_b(mv_web), .wd_b(mv_wdb),
        .w_addr(w_addr), .w_rdata(w_rdata), .busy(mv_busy), .done(mv_done));
    wrom u_wrom (.sel(wsel[2:0]), .addr(w_addr), .wdata(w_rdata));

    wire [9:0] at_ra, at_wa; wire at_we; wire signed [15:0] at_wd; wire at_busy, at_done;
    attn #(.N_EMBED(N_EMBED), .N_HEAD(N_HEAD), .HEAD_DIM(HEAD_DIM), .BLOCK(BLOCK), .FRAC(FRAC_BITS))
      u_attn (.clk(clk), .resetn(resetn), .start(at_go), .attn_scale(ATTN_SCALE),
        .ctx_len(pos_r + 5'd1),
        .q_base(A_QV), .k_base(A_KC), .v_base(A_VC), .o_base(A_AO),
        .v_raddr(at_ra), .v_rdata(v_rdata), .v_we(at_we), .v_waddr(at_wa), .v_wdata(at_wd),
        .busy(at_busy), .done(at_done));

    wire [9:0] vo_ra, vo_wa; wire vo_we; wire signed [15:0] vo_wd; wire vo_busy, vo_done;
    vecop u_vecop (.clk(clk), .resetn(resetn), .start(vo_go), .op(op == OP_RELU),
        .a_base(a_base), .b_base(b_base), .dst_base(d_base), .cnt(out_dim),
        .v_raddr(vo_ra), .v_rdata(v_rdata), .v_we(vo_we), .v_waddr(vo_wa), .v_wdata(vo_wd),
        .busy(vo_busy), .done(vo_done));

    wire [9:0] sp_ra; wire [4:0] sp_tok; wire [31:0] sp_rng; wire sp_busy, sp_done;
    sampler #(.VOCAB(VOCAB), .FRAC(FRAC_BITS)) u_samp (.clk(clk), .resetn(resetn), .start(sp_go),
        .sample_mode(sample_mode), .inv_temp(inv_temp), .rng_in(rng_in), .lm_base(A_LOG),
        .v_raddr(sp_ra), .v_rdata(v_rdata), .token(sp_tok), .rng_out(sp_rng),
        .busy(sp_busy), .done(sp_done));

    // ---------------- vmem 듀얼 포트 먹스 (활성 액추에이터) ----------------
    // 포트 A: 모든 액추에이터의 주 읽기 (norm/matvec은 여기에 쓰기도 함)
    assign pa_addr =
        (op == OP_NORM) ? no_aa : (op == OP_MATV) ? mv_aa :
        (op == OP_ATTN) ? at_ra : (op == OP_VADD || op == OP_RELU) ? vo_ra :
        (op == OP_SAMPLE) ? sp_ra : 10'd0;
    assign pa_we = (op == OP_NORM) ? no_wea : (op == OP_MATV) ? mv_wea : 1'b0;
    assign pa_wd = (op == OP_MATV) ? mv_wda : no_wda;
    // 포트 B: 모든 액추에이터의 주 쓰기 (norm/matvec은 여기서 읽기도 함)
    assign pb_addr =
        (op == OP_NORM) ? no_ab : (op == OP_MATV) ? mv_ab : (op == OP_EMBED) ? em_wa :
        (op == OP_ATTN) ? at_wa : (op == OP_VADD || op == OP_RELU) ? vo_wa : 10'd0;
    assign pb_we =
        (op == OP_NORM) ? no_web : (op == OP_MATV) ? mv_web : (op == OP_EMBED) ? em_we :
        (op == OP_ATTN) ? at_we : (op == OP_VADD || op == OP_RELU) ? vo_we : 1'b0;
    assign pb_wd =
        (op == OP_NORM) ? no_wdb : (op == OP_MATV) ? mv_wdb : (op == OP_EMBED) ? em_wd :
        (op == OP_ATTN) ? at_wd : vo_wd;

    wire act_done =
        (op == OP_EMBED) ? em_done : (op == OP_NORM) ? no_done : (op == OP_MATV) ? mv_done :
        (op == OP_ATTN) ? at_done : (op == OP_VADD || op == OP_RELU) ? vo_done :
        (op == OP_SAMPLE) ? sp_done : 1'b1;

    // ---------------- 시퀀서 ----------------
    typedef enum logic [1:0] { Q_IDLE, Q_EXEC, Q_WAIT } qstate_t;
    qstate_t q;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            q <= Q_IDLE; pc <= 0; busy <= 0; done <= 0;
            em_go<=0; no_go<=0; mv_go<=0; at_go<=0; vo_go<=0; sp_go<=0;
        end else begin
            done <= 0;
            em_go<=0; no_go<=0; mv_go<=0; at_go<=0; vo_go<=0; sp_go<=0;
            unique case (q)
                Q_IDLE: if (start) begin
                    busy <= 1; pc <= 0; tok_r <= token_in; pos_r <= pos_in; q <= Q_EXEC;
                end
                Q_EXEC: begin
                    case (op)
                        OP_EMBED:  em_go <= 1;
                        OP_NORM:   no_go <= 1;
                        OP_MATV:   mv_go <= 1;
                        OP_ATTN:   at_go <= 1;
                        OP_VADD:   vo_go <= 1;
                        OP_RELU:   vo_go <= 1;
                        OP_SAMPLE: sp_go <= 1;
                        default: ;
                    endcase
                    if (op == OP_HALT) begin busy <= 0; done <= 1; q <= Q_IDLE; end
                    else q <= Q_WAIT;
                end
                Q_WAIT: if (act_done) begin
                    if (op == OP_SAMPLE) begin next_token <= sp_tok; rng_out <= sp_rng; end
                    pc <= pc + 1; q <= Q_EXEC;
                end
                default: q <= Q_IDLE;
            endcase
        end
    end
endmodule
