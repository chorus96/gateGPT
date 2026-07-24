// 24-레인, 2열/사이클 병렬 matvec 엔진을 위한 와이드 가중치 ROM. 각 워드는 연속된 두
// 입력 열(하위 절반 = 열 2j, 상위 절반 = 열 2j+1)에 대한 LANES=24개 Q5.11 가중치를 담으며,
// tile*(in_dim/2) + j 로 주소 지정됨; wdata[lane*16 +:16]는 열 2j에 대한 레인의 가중치,
// wdata[LANES*16 + lane*16 +:16]는 열 2j+1에 대한 것.
// 내용은 조합 case 함수(core/wrom_data.vh)에서 옴, $readmemh가 아님:
// 원래 ISE/XST 14.7이 작은 $readmemh 분산 ROM을 0으로 묶어(보드에서 가중치를 0으로 만듦
// -> 쓰레기 이름) 명시적 case 상수로 바꿨고, LUT로 신뢰성 있게 합성됨. 이 구조를 Vivado
// 흐름에서도 그대로 유지함. (SystemVerilog)
module wrom #(
    parameter int LANES = 24
) (
    input  logic [2:0]            sel,    // WQ WK WV WO FC1 FC2 LM
    input  logic [11:0]           addr,   // 타일-워드 주소: tile*(in_dim/2) + j
    output logic [2*LANES*16-1:0] wdata
);
`include "wrom_data.vh"
    assign wdata = wrom_data(sel, addr);
endmodule
