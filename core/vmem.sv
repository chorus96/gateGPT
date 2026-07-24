// 활성값 스크래치패드: block RAM, 쓰기 포트 1개 + *등록된* 읽기 포트 1개.
// 등록 읽기(rdata는 raddr 1사이클 뒤 유효)는 읽기 주소 팬아웃을 작게 유지하며
// (분산 RAM의 ~256개 LUT-RAM 프리미티브 대비 단일 BRAM), 이것이 지배적 라우팅
// 지연이었음. 액추에이터는 주소를 한 사이클 먼저 제시하고 다음 사이클에 데이터를
// 소비함(read-ahead). (SystemVerilog)
module vmem #(
    parameter int AW = 10,   // 주소 폭 (1024 워드가 전 스크래치를 커버)
    parameter int DW = 16
) (
    input  logic                 clk,
    input  logic                 we,
    input  logic [AW-1:0]        waddr,
    input  logic signed [DW-1:0] wdata,
    input  logic [AW-1:0]        raddr,
    output logic signed [DW-1:0] rdata
);
    (* ram_style = "block" *) logic signed [DW-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];          // 등록 읽기 (1사이클 지연)
    end
endmodule
