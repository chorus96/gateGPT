// RMSNorm 게인 ROM (Q5.11), sel로 선택되는 세 게인 (0=g1, 1=g2, 2=gf).
// 조합 case(core/gains.vh)로 방출됨 -- 원래 ISE/XST가 이렇게 작은 배열에 대해 $readmemh
// ROM을 신뢰성 있게 추론/초기화하지 못해(0으로 묶어 하드웨어에서 게인이 0 -> 쓰레기)
// 명시적 상수로 바꿨고, 이 구조를 Vivado 흐름에서도 그대로 유지함. 상수는 올바르게 합성됨.
// 듀얼 읽기(addr_a/addr_b)로 2원소/사이클 스케일 패스가 두 게인을 모두 가져올 수 있음.
// (SystemVerilog)
module grom (
    input  logic [1:0]         sel,
    input  logic [5:0]         addr_a,
    input  logic [5:0]         addr_b,
    output logic signed [15:0] gdata_a,
    output logic signed [15:0] gdata_b
);
`include "gains.vh"
    assign gdata_a = gain_lut(sel, addr_a[4:0]);
    assign gdata_b = gain_lut(sel, addr_b[4:0]);
endmodule
