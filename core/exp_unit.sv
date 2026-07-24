// z <= 0 에 대한 고정소수점 exp: e = round(exp(z/2048) * 2048) ∈ [0,2048], 17개 항목
// 테이블(exp(-k)) + 선형 보간으로 계산. tools/fixedpoint.exp_neg_q11 과 비트 일치.
// (z >= 0 이면 2048 = exp(0) 반환.)
//
// 파이프라인(지연 1): 테이블 조회 + 디코드를 등록하고, 보간 곱셈은 다음 사이클에 실행
// -> 더 짧은 조합 경로(이 체인이 파이프라인 이후 Fmax 제한 요소였음). 호출자는 z를 넣고
// 한 사이클 뒤 e를 읽음(조합 exp_unit 앞에 두던 dz_r 레지스터를 대체). (SystemVerilog)
module exp_unit (
    input  logic               clk,
    input  logic signed [15:0] z,
    output logic signed [15:0] e
);
    // exp 테이블을 조합 case 함수로($readmemh가 아님: XST 14.7이 작은 $readmemh 분산 ROM을
    // 0으로 만듦). 17개 항목: exp_tab_rom[k] = round(exp(-k)*2048).
`include "exp_data.vh"

    // 스테이지 1 (조합): |z|, 테이블 조회, 디코드
    wire signed [17:0] zx = {{2{z[15]}}, z};
    wire [17:0]        u  = -zx;            // z<=0 일 때 |z|  (0..32768)
    wire [4:0]         ui = u[15:11];       // 정수부 (<=16)
    wire [10:0]        uf = u[10:0];        // 소수부 (Q11)
    wire signed [15:0] lo = exp_tab_rom(ui[4:0]);
    wire signed [15:0] hi = (ui >= 5'd16) ? 16'sd0 : exp_tab_rom(ui[4:0] + 5'd1);

    // 파이프라인 레지스터 (ROM 조회와 보간 곱셈 사이를 절단)
    logic signed [15:0] lo_r, hi_r;
    logic [10:0]        uf_r;
    logic               pos_r, big_r;
    always_ff @(posedge clk) begin
        lo_r <= lo; hi_r <= hi; uf_r <= uf;
        pos_r <= (z >= 0); big_r <= (ui >= 5'd16);
    end

    // 스테이지 2 (등록된 값으로부터 조합): 보간 + 클램프
    wire signed [31:0] interp = lo_r + (($signed(hi_r) - $signed(lo_r)) * $signed({1'b0, uf_r}) >>> 11);
    assign e = pos_r ? 16'sd2048 : big_r ? 16'sd0 : (interp < 0) ? 16'sd0 : interp[15:0];
endmodule
