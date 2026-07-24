// xupv5_microgpt_top을 위한 보드 레벨(TOP) 테스트벤치.
//
// 보드 전체를 시뮬레이션함 -- DCM/클럭 버퍼(sim/xilinx_stubs.sv의 동작 stub), 리셋/버튼
// 디바운스, 로터리 스로틀, 이름 생성기(코어), HD44780 LCD 드라이버, 초당 토큰 미터 --
// Xilinx UniSim 라이브러리 없이, 따라서 Verilator나 iverilog에서 실행됨.
//
// top은 축소된 CLK_HZ(SIMCLK_HZ 참조)로 인스턴스화되어 CLK_HZ 파생 실시간 지연을
// 시뮬레이션 가능한 사이클 수로 축소함. SIMCLK_HZ는 >= 12_500_000 을 유지해야 하며,
// 그렇지 않으면 LCD의 셋업 지연 SU_CYC = CLK_HZ/12_500_000 이 0으로 언더플로되어 LCD FSM이 멈춤.
//
// 흐름: 리셋 해제 -> DCM lock 대기 -> 로터리 스타트업 홀드 대기 -> 엔코더를 시계방향으로
// 구동해 자동 회전 속도를 올림 -> 첫 생성 이름을 포착해 출력. 사이클 워치독이 종료를 보장함.
`timescale 1ns/1ps
module tb_top;
    localparam integer SIMCLK_HZ = 12_500_000;   // 시뮬레이션 코어 클럭 (>= 12.5 MHz 유지)
    localparam integer WATCHDOG  = 25_000_000;   // 강제 정지 (사이클)

    reg clk = 0;
    always #5 clk = ~clk;                         // 패스스루 DCM -> 코어가 이 클럭으로 동작

    reg        rst_btn   = 1'b1;                  // active-high 리셋 (아래에서 해제)
    reg        start_btn = 1'b0;                  // 이 보드에서 미사용 트리거
    reg        rot_a = 0, rot_b = 0, rot_push = 0;
    reg  [7:0] dip_sw = 8'h5a;                    // 시드를 교란

    wire [7:0] led;
    wire       lcd_rs, lcd_rw, lcd_e;
    wire [3:0] lcd_db;

    xupv5_microgpt_top #(.CLK_HZ(SIMCLK_HZ)) dut (
        .clk_100(clk), .rst_btn(rst_btn), .start_btn(start_btn), .dip_sw(dip_sw),
        .rot_a(rot_a), .rot_b(rot_b), .rot_push(rot_push), .led(led),
        .lcd_rs(lcd_rs), .lcd_rw(lcd_rw), .lcd_e(lcd_e), .lcd_db(lcd_db)
    );

    // ---- 사이클 카운터 + 첫 완료된 이름 포착 ----
    integer cyc = 0;
    reg          captured = 0;
    reg   [4:0]  cap_len;
    reg [(16*8)-1:0] cap_name;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (dut.gen_done && !captured) begin
            captured <= 1'b1; cap_len <= dut.name_len; cap_name <= dut.name_flat;
        end
        if (cyc > WATCHDOG) begin
            $display("TOP TIMEOUT at cycle %0d (captured=%0b)", cyc, captured);
            $finish;
        end
    end

    // ---- 시계방향 디텐트 1회: speed_level을 1 올림 (로터리가 armed된 후) ----
    // {a,b}의 쿼드러처 CW 시퀀스: 00 -> 01 -> 11 -> 10 -> 00 (4 엣지 = 1 디텐트).
    // 각 상태는 로터리 디글리치 FILTER(2500 사이클)보다 길게 유지됨.
    localparam integer HOLD = 4000;
    task detent_cw;
        begin
            rot_a = 1'b0; rot_b = 1'b1; repeat (HOLD) @(posedge clk);
            rot_a = 1'b1; rot_b = 1'b1; repeat (HOLD) @(posedge clk);
            rot_a = 1'b1; rot_b = 1'b0; repeat (HOLD) @(posedge clk);
            rot_a = 1'b0; rot_b = 1'b0; repeat (HOLD) @(posedge clk);
        end
    endtask

    integer i;
    reg [7:0] ch;
    initial begin
        // 짧은 펄스 후 리셋 해제
        repeat (30) @(posedge clk); rst_btn = 1'b0;

        // DCM lock (stub이 RST 해제 몇 사이클 뒤 어서트)
        wait (dut.dcm_locked);
        $display("[cycle %0d] DCM locked", cyc);

        // 로터리 스타트업 홀드가 만료될 때까지 대기한 뒤, 속도를 최대로 올림
        wait (dut.u_rot.armed);
        $display("[cycle %0d] rotary armed, raising speed...", cyc);
        for (i = 0; i < 15 && !captured; i = i + 1) detent_cw;
        $display("[cycle %0d] speed_level=%0d", cyc, dut.u_rot.speed_level);

        // 첫 자동 생성 이름 (위의 워치독이 이를 제한)
        wait (captured);
        $write("generated name: ");
        for (i = 0; i < cap_len; i = i + 1) begin
            ch = 8'd97 + cap_name[(i*8) +: 8];    // name_buf는 token-1을 담음; 'a'=97
            $write("%c", ch);
        end
        $write("   (len=%0d)\n", cap_len);

        // 기본 정상성 검사
        if (cap_len < 5'd1 || cap_len > 5'd16)
            $display("TOP FAIL: implausible name length %0d", cap_len);
        else if (dut.dcm_locked !== 1'b1)
            $display("TOP FAIL: DCM not locked");
        else begin
            // LCD/미터를 조금 더 동작시킨 뒤 통과
            repeat (2000) @(posedge clk);
            $display("TOP PASS: board booted (DCM locked, LCD driving) and generated a name");
        end
        $finish;
    end
endmodule
