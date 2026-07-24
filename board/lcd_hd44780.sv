// 범용 HD44780 문자 LCD 컨트롤러, 4비트 모드(쓰기 전용), 2행.
// 전원 투입 초기화를 수행한 뒤, line1/line2(각 16 ASCII 바이트, 바이트 i = 열 i)로 두 행을
// 연속적으로 다시 그림. 각 프레임은 먼저 line1/line2를 래치하여 프레임 중간 변경이 화면을
// 찢지 않게 함. 호출자가 완성된 ASCII를 공급하므로(토큰->문자 / 숫자 포맷은 top에 있음)
// 이것은 단순 패널임.
//
// 모든 지연은 CLK_HZ(실시간)에서 파생되므로 어떤 코어 클럭에서도 정확함. 시뮬레이션은
// 작은 CLK_HZ를 넘기거나(또는 *_CYC 파라미터를 오버라이드하여) 지연을 축소할 수 있음.
// (SystemVerilog)
module lcd_hd44780 #(
    parameter int CLK_HZ      = 50_000_000,
    parameter int POWERON_CYC = CLK_HZ/25,        // ~40 ms
    parameter int LONG_CYC    = CLK_HZ/244,       // ~4.1 ms (첫 0x3 / clear 이후)
    parameter int SETTLE_CYC  = CLK_HZ/25000,     // ~40 us (일반 명령/데이터)
    parameter int E_CYC       = CLK_HZ/833333,    // ~1.2 us E high
    parameter int SU_CYC      = CLK_HZ/12500000   // ~80 ns E 전 RS/데이터 셋업 (tAS)
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic [(16*8)-1:0] line1,   // 1행 ASCII (바이트 0 = 최좌측 열)
    input  logic [(16*8)-1:0] line2,   // 2행 ASCII

    output logic        lcd_rs,        // 0 = 명령, 1 = 데이터
    output logic        lcd_rw,        // 0으로 고정 (쓰기 전용)
    output logic        lcd_e,         // enable 스트로브
    output logic [3:0]  lcd_db,        // DB[7:4]
    output logic        ready          // 초기화 완료 시 high
);
    assign lcd_rw = 1'b0;

    // ---- 초기화 마이크로 시퀀스: 8개 op. is_nibble=1 -> 상위 니블만 (8->4 비트). ----
    localparam int N_INIT = 8;
    function automatic logic [9:0] init_op(input logic [3:0] idx);   // {is_nibble, rs, data[7:0]}
        unique case (idx)
            4'd0: return {1'b1, 1'b0, 8'h30};  // 0x3 wake (8비트)
            4'd1: return {1'b1, 1'b0, 8'h30};
            4'd2: return {1'b1, 1'b0, 8'h30};
            4'd3: return {1'b1, 1'b0, 8'h20};  // 0x2 -> 4비트 모드
            4'd4: return {1'b0, 1'b0, 8'h28};  // function set: 4비트, 2행, 5x8
            4'd5: return {1'b0, 1'b0, 8'h0C};  // display on, cursor off
            4'd6: return {1'b0, 1'b0, 8'h01};  // clear (긴 대기 필요)
            default: return {1'b0, 1'b0, 8'h06}; // entry mode: increment
        endcase
    endfunction

    // 메인 페이즈 FSM
    typedef enum logic [2:0] {
        P_POWERON,   // 전원 투입 안정화
        P_INIT,      // 8-op 초기화 시퀀스
        P_LATCH,     // tear-free 프레임을 위한 line1/line2 스냅샷
        P_ADDR1,     // DDRAM 주소 0x80 설정 (1행)
        P_CHARS1,    // 1행 16문자 쓰기
        P_ADDR2,     // DDRAM 주소 0xC0 설정 (2행)
        P_CHARS2     // 2행 16문자 쓰기
    } phase_t;

    // 바이트 전송 서브-FSM (각 니블: RS/데이터 셋업 -> E high -> settle)
    typedef enum logic [2:0] {
        B_IDLE  = 3'd0,
        B_HI_E  = 3'd1, B_HI_S = 3'd2,
        B_LO_E  = 3'd3, B_LO_S = 3'd4,
        B_DONE  = 3'd5,
        B_HI_SU = 3'd6, B_LO_SU = 3'd7
    } bstate_t;

    phase_t    phase;
    bstate_t   bs;
    logic        bs_start, bs_busy, bs_nibble, bs_rs;
    logic [7:0]  bs_data;
    logic [31:0] bs_settle, cnt, poweron_cnt;
    logic [4:0]  step;
    logic [9:0]  op;
    logic [(16*8)-1:0] l1_buf, l2_buf;   // 래치된 프레임

    // 현재 문자: step으로 인덱싱된 1행 vs 2행 버퍼
    wire [7:0] char1 = l1_buf[(step*8) +: 8];
    wire [7:0] char2 = l2_buf[(step*8) +: 8];

    always_ff @(posedge clk) begin
        if (!resetn) begin
            phase <= P_POWERON; bs <= B_IDLE; bs_start <= 1'b0; bs_busy <= 1'b0;
            bs_nibble <= 1'b0; bs_rs <= 1'b0; bs_data <= 8'd0; bs_settle <= SETTLE_CYC;
            cnt <= 32'd0; step <= 5'd0; poweron_cnt <= 32'd0;
            lcd_rs <= 1'b0; lcd_e <= 1'b0; lcd_db <= 4'd0; ready <= 1'b0;
            l1_buf <= {16{8'h20}}; l2_buf <= {16{8'h20}};
        end else begin
            // ---------- 바이트 전송 서브-FSM ----------
            case (bs)
                B_IDLE: begin
                    lcd_e <= 1'b0;
                    if (bs_start) begin
                        bs_busy <= 1'b1;
                        lcd_rs  <= bs_rs;
                        lcd_db  <= bs_data[7:4];   // 상위 니블 유효, E low (셋업)
                        lcd_e   <= 1'b0;
                        cnt     <= 32'd0;
                        bs      <= B_HI_SU;
                    end
                end
                B_HI_SU: if (cnt >= SU_CYC - 1) begin lcd_e <= 1'b1; cnt <= 32'd0; bs <= B_HI_E; end
                         else cnt <= cnt + 32'd1;
                B_HI_E:  if (cnt >= E_CYC - 1)  begin lcd_e <= 1'b0; cnt <= 32'd0; bs <= B_HI_S; end
                         else cnt <= cnt + 32'd1;
                B_HI_S:  if (cnt >= bs_settle - 1) begin
                             cnt <= 32'd0;
                             if (bs_nibble) bs <= B_DONE;
                             else begin lcd_db <= bs_data[3:0]; bs <= B_LO_SU; end
                         end else cnt <= cnt + 32'd1;
                B_LO_SU: if (cnt >= SU_CYC - 1) begin lcd_e <= 1'b1; cnt <= 32'd0; bs <= B_LO_E; end
                         else cnt <= cnt + 32'd1;
                B_LO_E:  if (cnt >= E_CYC - 1)  begin lcd_e <= 1'b0; cnt <= 32'd0; bs <= B_LO_S; end
                         else cnt <= cnt + 32'd1;
                B_LO_S:  if (cnt >= bs_settle - 1) begin cnt <= 32'd0; bs <= B_DONE; end
                         else cnt <= cnt + 32'd1;
                B_DONE:  begin bs_busy <= 1'b0; bs <= B_IDLE; end
                default: bs <= B_IDLE;
            endcase
            if (bs_start && bs != B_IDLE) bs_start <= 1'b0;   // 요청 소비

            // ---------- 메인 페이즈 FSM ----------
            case (phase)
                P_POWERON: begin
                    ready <= 1'b0;
                    if (poweron_cnt >= POWERON_CYC - 1) begin step <= 5'd0; phase <= P_INIT; end
                    else poweron_cnt <= poweron_cnt + 32'd1;
                end

                P_INIT: begin
                    if (!bs_busy && !bs_start) begin
                        if (step == N_INIT) begin step <= 5'd0; phase <= P_LATCH; end
                        else begin
                            op        = init_op(step[3:0]);
                            bs_nibble <= op[9];
                            bs_rs     <= op[8];
                            bs_data   <= op[7:0];
                            bs_settle <= (step == 5'd0 || step == 5'd6) ? LONG_CYC : SETTLE_CYC;
                            bs_start  <= 1'b1;
                            step      <= step + 5'd1;
                        end
                    end
                end

                P_LATCH: begin                     // 이 프레임을 위해 두 행 스냅샷
                    ready  <= 1'b1;
                    l1_buf <= line1;
                    l2_buf <= line2;
                    step   <= 5'd0;
                    phase  <= P_ADDR1;
                end

                P_ADDR1: if (!bs_busy && !bs_start) begin
                    bs_nibble <= 1'b0; bs_rs <= 1'b0; bs_data <= 8'h80;   // 1행, 열 0
                    bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                    step <= 5'd0; phase <= P_CHARS1;
                end

                P_CHARS1: if (!bs_busy && !bs_start) begin
                    if (step == 5'd16) phase <= P_ADDR2;
                    else begin
                        bs_nibble <= 1'b0; bs_rs <= 1'b1; bs_data <= char1;
                        bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                        step <= step + 5'd1;
                    end
                end

                P_ADDR2: if (!bs_busy && !bs_start) begin
                    bs_nibble <= 1'b0; bs_rs <= 1'b0; bs_data <= 8'hC0;   // 2행, 열 0
                    bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                    step <= 5'd0; phase <= P_CHARS2;
                end

                P_CHARS2: if (!bs_busy && !bs_start) begin
                    if (step == 5'd16) phase <= P_LATCH;   // 프레임 완료 -> 다시 그리기
                    else begin
                        bs_nibble <= 1'b0; bs_rs <= 1'b1; bs_data <= char2;
                        bs_settle <= SETTLE_CYC; bs_start <= 1'b1;
                        step <= step + 5'd1;
                    end
                end

                default: phase <= P_POWERON;
            endcase
        end
    end

endmodule
