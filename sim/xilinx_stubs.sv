// xupv5_microgpt_top이 사용하는 Xilinx Virtex-5 클럭 프리미티브의 동작 stub이며, 이를 통해
// Xilinx UniSim 라이브러리 없이 보드 최상위를 시뮬레이션할 수 있음(Verilator / iverilog에는
// 벤더 셀이 없음).
//
// 시뮬레이션 전용 -- 이 파일을 ISE 합성 프로젝트에 포함하지 말 것; 거기서는 실제 UniSim
// 프리미티브를 사용함.
//
// 모델은 top의 필요에 맞춰 사이클 정확함: 클럭 버퍼는 입력을 통과시키고, DCM은 CLKIN을
// CLK0/CLKFX로 그대로 전달함(4/5 주파수 비는 사이클 기반 시뮬레이션에서 무의미 -- 전 설계가
// 단지 테스트벤치 클럭으로 동작함), 그리고 RST 해제 몇 사이클 뒤 LOCKED를 어서트함.
`timescale 1ns/1ps

// ---- 입력 클럭 버퍼 ----
module IBUFG (input wire I, output wire O);
    assign O = I;
endmodule

// ---- 글로벌 클럭 버퍼 ----
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

// ---- Digital Clock Manager (base) ----
module DCM_BASE #(
    parameter CLKIN_PERIOD   = 10.0,
    parameter CLKFX_MULTIPLY = 4,
    parameter CLKFX_DIVIDE   = 5
) (
    input  wire CLKIN,
    input  wire CLKFB,
    input  wire RST,
    output wire CLK0,
    output wire CLKFX,
    output wire CLK90,
    output wire CLK180,
    output wire CLK270,
    output wire CLK2X,
    output wire CLK2X180,
    output wire CLKDV,
    output wire CLKFX180,
    output reg  LOCKED
);
    // 시뮬레이션: CLKIN을 통과(사이클 정확; 실제 4/5 비는 무의미, 설계의 모든 동기 요소가
    // 이 하나의 클럭으로 동작하기 때문).
    assign CLK0     = CLKIN;
    assign CLKFX    = CLKIN;
    assign CLK90    = 1'b0;
    assign CLK180   = 1'b0;
    assign CLK270   = 1'b0;
    assign CLK2X    = 1'b0;
    assign CLK2X180 = 1'b0;
    assign CLKDV    = 1'b0;
    assign CLKFX180 = 1'b0;

    // LOCKED는 RST 해제 몇 사이클 뒤 어서트됨(DCM lock 시간을 모사).
    reg [3:0] lockcnt;
    initial begin LOCKED = 1'b0; lockcnt = 4'd0; end
    always @(posedge CLKIN or posedge RST) begin
        if (RST) begin
            LOCKED  <= 1'b0;
            lockcnt <= 4'd0;
        end else if (!LOCKED) begin
            if (lockcnt >= 4'd8) LOCKED <= 1'b1;
            else                 lockcnt <= lockcnt + 4'd1;
        end
    end
endmodule
