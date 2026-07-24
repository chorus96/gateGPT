// Python 레퍼런스 대비 exp_unit의 유닛 테스트 (z 값 스윕).
`timescale 1ns/1ps
module tb_exp;
    localparam M = 103;       // 골든 hex의 정확한 exp 케이스 수 (아래 스킵 로직은 x-센티넬로
                              // 더 적은 개수도 허용; M == 파일 줄 수로 유지)
    reg signed [15:0] zs [0:M-1], es [0:M-1];
    reg clk = 0;
    always #5 clk = ~clk;
    reg signed [15:0] zin;
    wire signed [15:0] eo;
    exp_unit u_exp (.clk(clk), .z(zin), .e(eo));   // 지연 1: e는 z 1사이클 뒤 유효

    integer k, errors, n;
    initial begin
        for (k = 0; k < M; k = k + 1) begin zs[k] = 16'shxxxx; es[k] = 16'shxxxx; end
        $readmemh("generated/test_exp_z.hex", zs);
        $readmemh("generated/test_exp_e.hex", es);
        errors = 0; n = 0;
        for (k = 0; k < M; k = k + 1) begin
            if (zs[k] !== 16'shxxxx) begin
                @(negedge clk); zin = zs[k]; @(posedge clk); #1;
                n = n + 1;
                if (eo !== es[k]) begin
                    $display("EXP MISMATCH z=%0d got=%0d exp=%0d", zs[k], $signed(eo), $signed(es[k]));
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0) $display("EXP PASS: all %0d cases match", n);
        else             $display("EXP FAIL: %0d/%0d mismatches", errors, n);
        $finish;
    end
endmodule
