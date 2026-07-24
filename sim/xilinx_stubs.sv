// xupv5_microgpt_top이 사용하는 Xilinx UltraScale+ 클럭 프리미티브의 동작 stub이며, 이를 통해
// Xilinx UNISIM 라이브러리 없이 보드 최상위를 시뮬레이션할 수 있음(Verilator / iverilog에는
// 벤더 셀이 없음).
//
// 시뮬레이션 전용 -- 이 파일을 Vivado 프로젝트에 추가하지 말 것; 거기서는 실제 UNISIM
// 프리미티브(MMCME4_BASE, BUFG)를 사용함.
//
// 모델은 top의 필요에 맞춰 사이클 정확함: BUFG는 입력을 통과시키고, MMCME4는 CLKIN1을
// CLKOUT0/CLKFBOUT으로 그대로 전달함(x12/15 주파수 비는 사이클 기반 시뮬레이션에서 무의미
// -- 전 설계가 단지 테스트벤치 클럭으로 동작함), 그리고 RST 해제 몇 사이클 뒤 LOCKED를 어서트함.
`timescale 1ns/1ps

// ---- 글로벌 클럭 버퍼 ----
module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

// ---- 혼합 모드 클럭 매니저 (UltraScale+ base) ----
module MMCME4_BASE #(
    parameter        CLKIN1_PERIOD    = 10.0,
    parameter        DIVCLK_DIVIDE    = 1,
    parameter        CLKFBOUT_MULT_F  = 8.0,
    parameter        CLKOUT0_DIVIDE_F = 10.0
) (
    input  wire CLKIN1,
    input  wire CLKFBIN,
    input  wire RST,
    input  wire PWRDWN,
    output wire CLKFBOUT,
    output wire CLKFBOUTB,
    output wire CLKOUT0,
    output wire CLKOUT0B,
    output wire CLKOUT1,
    output wire CLKOUT1B,
    output wire CLKOUT2,
    output wire CLKOUT2B,
    output wire CLKOUT3,
    output wire CLKOUT3B,
    output wire CLKOUT4,
    output wire CLKOUT5,
    output wire CLKOUT6,
    output reg  LOCKED
);
    // 시뮬레이션: CLKIN1을 통과(사이클 정확; 실제 x8/10 비는 무의미, 설계의 모든 동기 요소가
    // 이 하나의 클럭으로 동작하기 때문).
    assign CLKOUT0   = CLKIN1;
    assign CLKFBOUT  = CLKIN1;
    assign CLKFBOUTB = 1'b0;
    assign CLKOUT0B  = 1'b0;
    assign CLKOUT1   = 1'b0;
    assign CLKOUT1B  = 1'b0;
    assign CLKOUT2   = 1'b0;
    assign CLKOUT2B  = 1'b0;
    assign CLKOUT3   = 1'b0;
    assign CLKOUT3B  = 1'b0;
    assign CLKOUT4   = 1'b0;
    assign CLKOUT5   = 1'b0;
    assign CLKOUT6   = 1'b0;

    // LOCKED는 RST 해제 몇 사이클 뒤 어서트됨(MMCM lock 시간을 모사).
    reg [3:0] lockcnt;
    initial begin LOCKED = 1'b0; lockcnt = 4'd0; end
    always @(posedge CLKIN1 or posedge RST) begin
        if (RST) begin
            LOCKED  <= 1'b0;
            lockcnt <= 4'd0;
        end else if (!LOCKED) begin
            if (lockcnt >= 4'd8) LOCKED <= 1'b1;
            else                 lockcnt <= lockcnt + 4'd1;
        end
    end
endmodule
