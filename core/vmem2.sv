// 활성값 스크래치패드: block RAM, 진정한 듀얼 포트. 두 독립 포트(A, B); 각 포트는
// 매 사이클 읽기를 등록하고(rdata는 addr 1사이클 뒤 유효) we가 어서트되면 씀. 이로써
// 사이클당 두 메모리 접근 가능 -- 두 읽기(예: RMSNorm 제곱합, 어텐션 점수/가중합),
// 두 쓰기(RMSNorm 스케일, matvec 라이트백), 또는 기존의 한 읽기 + 한 쓰기. 호출자는
// 한 사이클에 두 포트로 같은 주소를 쓰면 안 됨. 1024x16은 진정한 듀얼 포트 모드에서
// 하나의 RAMB18에 들어감. (SystemVerilog)
module vmem2 #(
    parameter int AW = 10,
    parameter int DW = 16
) (
    input  logic                 clk,
    // 포트 A
    input  logic                 we_a,
    input  logic [AW-1:0]        addr_a,
    input  logic signed [DW-1:0] wdata_a,
    output logic signed [DW-1:0] rdata_a,
    // 포트 B
    input  logic                 we_b,
    input  logic [AW-1:0]        addr_b,
    input  logic signed [DW-1:0] wdata_b,
    output logic signed [DW-1:0] rdata_b
);
    // 진정한 듀얼 포트 BRAM 추론 템플릿: 공유 배열에 대해 포트당 하나의 always 블록.
    // (원래 ISE/XST 시절 두 포트를 한 블록에 넣으면 block RAM이 아닌 플립플롭으로 폴백했음;
    //  이 템플릿은 Vivado BRAM 추론에도 그대로 적합.)
    (* ram_style = "block" *) logic signed [DW-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin                 // 포트 A
        if (we_a) mem[addr_a] <= wdata_a;
        rdata_a <= mem[addr_a];
    end
    always_ff @(posedge clk) begin                 // 포트 B
        if (we_b) mem[addr_b] <= wdata_b;
        rdata_b <= mem[addr_b];
    end
endmodule
