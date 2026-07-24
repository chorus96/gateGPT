// 부호 없는 정수 제곱근: root = floor(sqrt(radicand)), W비트 radicand ->
// W/2비트 root. 고전적 비트-페어(비복원) 알고리즘, W/2 사이클. Python math.isqrt와
// 일치. RMSNorm이 사용. 합성 가능. (SystemVerilog)
module isqrt #(
    parameter int W = 48           // radicand 폭 (짝수)
) (
    input  logic           clk,
    input  logic           resetn,
    input  logic           start,
    input  logic [W-1:0]   radicand,
    output logic           busy,
    output logic           done,
    output logic [W/2-1:0] root
);
    logic [W-1:0] op;          // 남은 radicand
    logic [W-1:0] res;         // 결과 누산기
    logic [W-1:0] bitm;        // 현재 4의 거듭제곱
    logic         st;
    logic [7:0]   cnt;

    wire [W-1:0] resbit = res + bitm;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            busy <= 1'b0; done <= 1'b0; st <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!st) begin
                if (start) begin
                    op   <= radicand; res <= '0;
                    bitm <= {2'b01, {(W-2){1'b0}}};   // 1 << (W-2): 최상위 짝수 비트
                    cnt  <= (W/2) - 1; busy <= 1'b1; st <= 1'b1;
                end
            end else begin
                if (op >= resbit) begin
                    op  <= op - resbit;
                    res <= (res >> 1) + bitm;
                end else begin
                    res <= res >> 1;
                end
                bitm <= bitm >> 2;
                if (cnt == 0) begin
                    // 이 사이클 이후 res가 floor(sqrt)를 담음; 최종 레지스터로 노출
                    root <= ((op >= resbit) ? ((res >> 1) + bitm) : (res >> 1)) >> 0;
                    busy <= 1'b0; done <= 1'b1; st <= 1'b0;
                end else cnt <= cnt - 8'd1;
            end
        end
    end
endmodule
