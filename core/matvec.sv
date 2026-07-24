// 병렬 행렬-벡터 엔진: out[o] = sat16( (sum_i act[act_base+i] * W[sel][o,i]) >>> descale )
// o in 0..out_dim-1, vmem[dst_base+o]에 씀. 출력 행은 한 번에 LANES개(하나의 타일)씩
// 처리됨. 진정한 듀얼 포트 vmem을 사용해 매 계산 사이클마다 활성값 두 개(act[2j],
// act[2j+1])를 읽고, 와이드 가중치 ROM이 두 열의 LANES개 가중치를 반환하므로 각 레인이
// 사이클당 2 MAC -> 타일이 in_dim/2 사이클에 계산됨. 라이트백은 두 쓰기 포트로 사이클당
// 2행을 배출 -> LANES/2 사이클. tiles = ceil(out_dim/LANES).
// 읽기는 등록됨(1사이클): 주소는 한 사이클 먼저 조합적으로 구동되고 가중치 버스는
// 등록되어(w_rdata_r) 정렬됨 -- 곱셈기에 MREG 스테이지도 부여. (SystemVerilog)
module matvec #(
    parameter int LANES = 24,
    parameter int ACCW  = 48
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic [2:0]  wsel,
    input  logic [6:0]  in_dim,
    input  logic [6:0]  out_dim,
    input  logic [9:0]  act_base,
    input  logic [9:0]  dst_base,
    input  logic [4:0]  descale,
    // 포트 A (act[2j] 읽기; 짝수 행 쓰기)
    output logic [9:0]  addr_a,
    input  logic signed [15:0] rd_a,
    output logic        we_a,
    output logic signed [15:0] wd_a,
    // 포트 B (act[2j+1] 읽기; 홀수 행 쓰기)
    output logic [9:0]  addr_b,
    input  logic signed [15:0] rd_b,
    output logic        we_b,
    output logic signed [15:0] wd_b,
    output logic [11:0] w_addr,                  // 타일-워드 주소: tile*(in_dim/2) + j
    input  logic [2*LANES*16-1:0] w_rdata,       // 열 2j(하위) + 열 2j+1(상위)의 LANES개 가중치
    output logic        busy,
    output logic        done
);
    typedef enum logic [1:0] { S_IDLE, S_RUN, S_DRAIN, S_WB } state_t;
    localparam int HW = LANES*16;               // 하프워드 경계 (열 2j+1 오프셋)
    // 산술용 크기 지정 LANES 복사본: 정수 파라미터의 비트 선택(LANES[6:0])은 XST 14.7에서
    // 잘못 합성됨(obase를 0으로 만들어 멀티 타일 행렬곱이 보드에서 멈춤).
    localparam logic [6:0] LANES_W = LANES;
    state_t    st;
    logic [6:0]  fi;                    // 현재 타일 내 열-쌍(피드) 인덱스
    (* keep = "true" *) logic [6:0]  obase;   // 현재 타일의 첫 출력 행 = tile*LANES
    (* keep = "true" *) logic [11:0] wbase;   // 현재 타일의 첫 워드 = tile*(in_dim/2)
    logic [6:0]  wbi;                   // 타일 내 라이트백 행 인덱스 (2씩 증가)
    logic        feeding, vld, vld2;
    logic [1:0]  dcnt;                  // 드레인 카운터 (2단 오퍼랜드 파이프라인 플러시)
    // 오퍼랜드 파이프라인: 활성값과 가중치를 곱셈 전에 한 스테이지 더 등록하여, 긴
    // BRAM 출력 -> DSP 넷을 크리티컬 패스에서 제거(곱셈이 인근 fabric 레지스터 / DSP
    // 입력 레지스터에서 시작하도록).
    logic [2*LANES*16-1:0] w_rdata_r, w_rdata_rr;
    logic signed [15:0] rd_a_r, rd_b_r;
    logic signed [ACCW-1:0] acc [0:LANES-1];

    assign w_addr = wbase + {5'd0, fi};

    // 현재 행 쌍에 대한 라이트백 포화
    wire signed [ACCW-1:0] sh_a = acc[wbi[4:0]]        >>> descale;
    wire signed [ACCW-1:0] sh_b = acc[wbi[4:0] + 5'd1] >>> descale;
    wire signed [15:0] sat_a =
        (sh_a > 48'sd32767) ? 16'sd32767 : (sh_a < -48'sd32768) ? -16'sd32768 : sh_a[15:0];
    wire signed [15:0] sat_b =
        (sh_b > 48'sd32767) ? 16'sd32767 : (sh_b < -48'sd32768) ? -16'sd32768 : sh_b[15:0];

    // 조합 포트 드라이버: 계산 중 활성값 쌍 읽기, S_WB에서 행 쌍 쓰기
    always_comb begin
        addr_a = act_base + {2'd0, fi, 1'b0};       // act[2j]
        addr_b = act_base + {2'd0, fi, 1'b0} + 10'd1; // act[2j+1]
        we_a = 1'b0; we_b = 1'b0; wd_a = sat_a; wd_b = sat_b;
        if (st == S_WB) begin
            addr_a = dst_base + {3'd0, obase + wbi};
            addr_b = dst_base + {3'd0, obase + wbi} + 10'd1;
            we_a = (obase + wbi        < out_dim);
            we_b = (obase + wbi + 7'd1 < out_dim);
        end
    end

    always_ff @(posedge clk) begin
        if (!resetn) begin
            st <= S_IDLE; busy <= 0; done <= 0;
            fi <= 0; obase <= 0; wbase <= 0; wbi <= 0; feeding <= 0; vld <= 0; vld2 <= 0; dcnt <= 0;
            for (int L = 0; L < LANES; L++) acc[L] <= '0;
        end else begin
            done <= 0;
            // 오퍼랜드 파이프라인(2단): 가중치 조합-ROM -> w_rdata_r -> w_rdata_rr,
            // 활성값 BRAM -> rd_a_r ; 곱셈은 이중 등록된 오퍼랜드를 소비.
            w_rdata_r <= w_rdata; w_rdata_rr <= w_rdata_r;
            rd_a_r <= rd_a; rd_b_r <= rd_b;
            vld <= feeding; vld2 <= vld;
            unique case (st)
                S_IDLE: if (start) begin
                    busy <= 1; fi <= 0; obase <= 0; wbase <= 0;
                    for (int L = 0; L < LANES; L++) acc[L] <= '0;
                    feeding <= 1; st <= S_RUN;
                end
                S_RUN: begin
                    if (vld2)
                        for (int L = 0; L < LANES; L++)
                            acc[L] <= acc[L]
                                + $signed(rd_a_r) * $signed(w_rdata_rr[L*16 +: 16])
                                + $signed(rd_b_r) * $signed(w_rdata_rr[HW + L*16 +: 16]);
                    if (fi == (in_dim >> 1) - 7'd1) begin feeding <= 0; dcnt <= 0; st <= S_DRAIN; end
                    else fi <= fi + 7'd1;
                end
                S_DRAIN: begin
                    if (vld2)                                  // 마지막 열 쌍 플러시
                        for (int L = 0; L < LANES; L++)
                            acc[L] <= acc[L]
                                + $signed(rd_a_r) * $signed(w_rdata_rr[L*16 +: 16])
                                + $signed(rd_b_r) * $signed(w_rdata_rr[HW + L*16 +: 16]);
                    if (dcnt == 2'd1) begin wbi <= 0; st <= S_WB; end
                    else dcnt <= dcnt + 2'd1;
                end
                S_WB: begin                                    // 사이클당 2행 쓰기
                    if (wbi >= LANES_W - 7'd2) begin
                        if (obase + LANES_W >= out_dim) begin   // 마지막 타일 -> 완료
                            busy <= 0; done <= 1; st <= S_IDLE;
                        end else begin                         // 다음 타일
                            obase <= obase + LANES_W; wbase <= wbase + {5'd0, (in_dim >> 1)};
                            fi <= 0;
                            for (int L = 0; L < LANES; L++) acc[L] <= '0;
                            feeding <= 1; st <= S_RUN;
                        end
                    end else wbi <= wbi + 7'd2;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
