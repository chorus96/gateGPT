// 부호 없는 반복 나눗셈기: quo = num / den (floor), W비트. Radix-4 복원 방식,
// MSB 우선, 사이클당 몫 2비트 -> W/2 사이클(W는 짝수여야 함). den==0이면 all-ones
// (가드). RMSNorm(ss/N, 2^22/r)과 어텐션(가중합 / softmax-합)이 공유하며, 샘플러는
// rem_out을 사용. 정확한 floor 몫과 나머지를 생성(radix-2 나눗셈기와 비트 동일),
// 단지 절반의 사이클로. 합성 가능('/' 연산자 없음). (SystemVerilog)
module udiv #(
    parameter int W = 48
) (
    input  logic         clk,
    input  logic         resetn,
    input  logic         start,
    input  logic [W-1:0] num,
    input  logic [W-1:0] den,
    output logic         busy,
    output logic         done,
    output logic [W-1:0] quo,
    output logic [W-1:0] rem_out      // num mod den (done과 함께 유효)
);
    logic [W-1:0]  ncur, q, dreg;
    logic [W+1:0]  rem;                // 부분 나머지 (radix-4 시프트용 +2 가드 비트)
    logic [7:0]    cnt;
    logic          st;

    // 다음 두 num 비트를 내려받음(MSB 우선): rshift = rem*4 + num[상위 2비트]
    wire [W+1:0] rshift = {rem[W-1:0], ncur[W-1:W-2]};
    wire [W+1:0] d1 = {2'b00, dreg};
    wire [W+1:0] d2 = {1'b0, dreg, 1'b0};
    wire [W+1:0] d3 = d2 + d1;
    // radix-4 몫 자릿수: rshift >= qd*den 을 만족하는 {0,1,2,3} 중 최대 qd
    wire [1:0]   qd  = (rshift >= d3) ? 2'd3 : (rshift >= d2) ? 2'd2 : (rshift >= d1) ? 2'd1 : 2'd0;
    wire [W+1:0] sub = (qd == 2'd3) ? d3 : (qd == 2'd2) ? d2 : (qd == 2'd1) ? d1 : '0;
    wire [W+1:0] remn = rshift - sub;

    always_ff @(posedge clk) begin
        if (!resetn) begin
            busy <= 1'b0; done <= 1'b0; st <= 1'b0;
        end else begin
            done <= 1'b0;
            if (!st) begin
                if (start) begin
                    ncur <= num; dreg <= (den == 0) ? '1 : den;
                    rem <= '0; q <= '0; cnt <= (W/2) - 1;
                    busy <= 1'b1; st <= 1'b1;
                end
            end else begin
                rem  <= remn;
                q    <= {q[W-3:0], qd};
                ncur <= {ncur[W-3:0], 2'b00};
                if (cnt == 0) begin
                    quo <= {q[W-3:0], qd};
                    rem_out <= remn[W-1:0];          // 최종 나머지
                    busy <= 1'b0; done <= 1'b1; st <= 1'b0;
                end else cnt <= cnt - 8'd1;
            end
        end
    end
endmodule
