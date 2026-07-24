// 실제 초당 토큰 미터. 1초 윈도우 동안 token_valid 스트로브를 세고, 초당 한 번 그 개수를
// 5개 BCD 자릿수(0..99999)로 래치함. BCD로 직접 세면 이진->십진 나눗셈을 피할 수 있음
// (XST는 2의 거듭제곱으로만 나눔). (SystemVerilog)
module tok_meter #(
    parameter int CLK_HZ = 50_000_000
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        token_valid,    // 생성 토큰당 1사이클 펄스
    output logic [19:0] tok_bcd         // {d4,d3,d2,d1,d0}, 각 4비트, 초당 래치
);
    logic [3:0]  d0, d1, d2, d3, d4;      // 일의 자리 .. 만의 자리
    logic [31:0] sec_timer;
    wire at_cap = (d4==9) && (d3==9) && (d2==9) && (d1==9) && (d0==9);

    always_ff @(posedge clk) begin
        if (!resetn) begin
            d0<=0; d1<=0; d2<=0; d3<=0; d4<=0; sec_timer<=0; tok_bcd<=20'd0;
        end else if (sec_timer >= (CLK_HZ - 1)) begin
            tok_bcd   <= {d4, d3, d2, d1, d0};   // 이번 초 발행
            d0<=0; d1<=0; d2<=0; d3<=0; d4<=0;
            sec_timer <= 32'd0;
        end else begin
            sec_timer <= sec_timer + 32'd1;
            if (token_valid && !at_cap) begin    // 리플 캐리 BCD 증분
                if (d0 != 9) d0 <= d0 + 4'd1;
                else begin
                    d0 <= 4'd0;
                    if (d1 != 9) d1 <= d1 + 4'd1;
                    else begin
                        d1 <= 4'd0;
                        if (d2 != 9) d2 <= d2 + 4'd1;
                        else begin
                            d2 <= 4'd0;
                            if (d3 != 9) d3 <= d3 + 4'd1;
                            else begin d3 <= 4'd0; d4 <= d4 + 4'd1; end
                        end
                    end
                end
            end
        end
    end

endmodule
