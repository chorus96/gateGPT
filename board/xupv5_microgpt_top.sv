// microGPT 이름 생성기를 위한 XUPV5 (Virtex-5 XC5VLX110T) 보드 최상위.
//
// 데모: 이름이 16x2 LCD에 자동으로 순환함. 로터리 엔코더는 누르기로 선택된 두 설정 중
// 하나를 조정함: RATE(회전 속도, 1 Hz ~ 연속) 또는 TEMP(샘플링 온도, T=0.5..1.2).
// TEMP 모드에서 led[5] 점등; LCD 2행은 활성 설정("rate: NNNNN t/s" 또는 "temp: X.Y")을
// 표시. DIP 스위치는 랜덤 시드를 교란함.
//
// PC 측(USB JTAG 케이블): 선택적 ChipScope/ILA VIO 코어 (CHIPSCOPE_VIO).
//
// 코어는 80 MHz로 동작(MMCME4 x12/15: 100 MHz -> VCO 1200 MHz -> 80 MHz).
// 원래 설계는 Virtex-5 + ISE 14.7(DCM CLKFX x4/5, post-PAR 80.24 MHz)이었으나,
// Vivado는 Virtex-5를 지원하지 않으므로 Kria K26 SOM(Zynq UltraScale+ MPSoC,
// xck26-sfvc784-2LV-c)으로 리타깃됨. Kria는 PL 오실레이터 핀이 없으므로 clk_100은
// PS의 pl_clk0(100 MHz)에서 공급됨(블록 디자인).
// (SystemVerilog, Vivado 24.2 / Zynq UltraScale+)
module xupv5_microgpt_top (
    input  logic        clk_100,      // 100 MHz 보드 오실레이터
    input  logic        rst_btn,      // 리셋 푸시 버튼 (active high)
    input  logic        start_btn,    // "하나 생성" 푸시 버튼 (active high)
    input  logic [7:0]  dip_sw,       // 8개 DIP 스위치 (시드 비트)
    input  logic        rot_a,        // 로터리 INCA
    input  logic        rot_b,        // 로터리 INCB
    input  logic        rot_push,     // 로터리 누르기 (누르는 동안 고정)
    output logic [7:0]  led,          // 상태 LED (속도 레벨 + 플래그)
    // 16x2 문자 LCD (HD44780, 4비트)
    output logic        lcd_rs,
    output logic        lcd_rw,
    output logic        lcd_e,
    output logic [3:0]  lcd_db        // DB[7:4]
);
    // CLK_HZ는 파라미터(기본값 = 실제 80 MHz 코어 클럭)여서, 시뮬레이션 top이 더 작은 값으로
    // 오버라이드하여 CLK_HZ 파생 실시간 지연(LCD 전원 투입/settle, 로터리 스타트업 홀드,
    // 자동 회전 간격, tok/s 윈도우)을 축소할 수 있음.
    // 합성은 기본값을 유지하므로 보드 동작은 변하지 않음.
    parameter int CLK_HZ = 80_000_000;   // 코어는 MMCME4 (100*12/15) = 80 MHz로 동작

    // ---------------- 클럭킹: 100 MHz(PS pl_clk0) -> MMCME4 -> 80 MHz 코어 (UltraScale+) -----
    // MMCME4_BASE: 100 MHz * (CLKFBOUT_MULT_F=12 / DIVCLK_DIVIDE=1) = VCO 1200 MHz,
    // CLKOUT0 = 1200 / CLKOUT0_DIVIDE_F=15 = 80 MHz. (UltraScale+ MMCM VCO 범위 800~1600 MHz)
    // clk_100은 Kria PS의 pl_clk0(100 MHz)에서 옴 -- 블록 디자인에서 zynq_ultra_ps_e ->
    // clk_100 으로 연결. (원래 Virtex-5 DCM_BASE CLKFX x4/5 를 대체.)
    wire clk, clkfb, clkfb_bufg, clk80, mmcm_locked;
    MMCME4_BASE #(
        .CLKIN1_PERIOD(10.0),          // 100 MHz 입력 (PS pl_clk0)
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(12.0),        // VCO = 100 * 12 = 1200 MHz (800..1600 범위)
        .CLKOUT0_DIVIDE_F(15.0)        // CLKOUT0 = 1200 / 15 = 80 MHz
    ) u_mmcm (
        .CLKIN1(clk_100), .RST(rst_btn), .PWRDWN(1'b0),
        .CLKFBIN(clkfb_bufg), .CLKFBOUT(clkfb), .CLKFBOUTB(),
        .CLKOUT0(clk80), .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(mmcm_locked)
    );
    BUFG u_bufgfb (.I(clkfb), .O(clkfb_bufg));   // MMCM 피드백 경로
    BUFG u_bufg0  (.I(clk80), .O(clk));          // 코어 클럭 = 80 MHz

    // ---------------- 리셋 버튼: 동기 + 디바운스 -------------------------------
    // rst_btn은 누름/뗌 시 바운스함; 동기 리셋을 바꾸기 전에 레벨이 RST_FILTER(~2 ms)
    // 동안 안정할 것을 요구함. MMCM은 원시 버튼을 RST에 유지함(전원 투입 시 리셋되어야
    // 하고 lock 시 자체 해제됨).
    localparam int RST_FILTER = 100000;        // ~2 ms @ 50 MHz
    logic [1:0]  rb_sync   = 2'd0;
    logic        rb_clean  = 1'b1;                    // lock까지 리셋 상태로 유지
    logic [17:0] rb_cnt    = 18'd0;
    always_ff @(posedge clk) begin
        rb_sync <= {rb_sync[0], rst_btn};
        if (rb_sync[1] == rb_clean)        rb_cnt <= 18'd0;
        else if (rb_cnt >= RST_FILTER)     begin rb_clean <= rb_sync[1]; rb_cnt <= 18'd0; end
        else                               rb_cnt <= rb_cnt + 18'd1;
    end
    wire resetn = mmcm_locked & ~rb_clean;

    // ---------------- start 버튼: 동기 + 디글리치 + 1사이클 엣지 --------------
    // 커서 버튼 라인이 글리치를 일으켜 초당 ~66회 허위 누름을 발생시켰음(정지 시 ~330 t/s
    // 바닥값). 누름이 등록되기 전에 레벨이 BTN_FILTER(~2 ms) 동안 안정할 것을 요구함;
    // 실제 누름은 훨씬 길게 지속되고 글리치는 거부됨.
    localparam int BTN_FILTER = 100000;        // ~2 ms @ 50 MHz
    logic [1:0]  sb_sync = 2'd0;
    logic        sb_clean = 1'b0, sb_clean_d = 1'b0;
    logic [17:0] sb_cnt = 18'd0;
    always_ff @(posedge clk) begin
        sb_sync <= {sb_sync[0], start_btn};
        if (sb_sync[1] == sb_clean)            sb_cnt <= 18'd0;
        else if (sb_cnt >= BTN_FILTER)         begin sb_clean <= sb_sync[1]; sb_cnt <= 18'd0; end
        else                                   sb_cnt <= sb_cnt + 18'd1;
        sb_clean_d <= sb_clean;
    end
    wire btn_pulse = sb_clean & ~sb_clean_d;       // 디바운스된 누름의 상승 엣지

    // ---------------- 시드 소스: 자유 실행 카운터 ---------------------------
    logic [31:0] seed_live = 32'd1;
    always_ff @(posedge clk) seed_live <= seed_live + 32'd1;

    // ---------------- VIO 제어 (기본 독립 실행) ---------------------------
    wire        vio_start, vio_use_host;
    wire [31:0] vio_seed;
    wire [15:0] vio_temp;

    // ---------------- 이름 생성기 ----------------------------------------------
    wire        gen_busy, gen_done, tok_valid;
    wire [7:0]  tok_out;
    wire [4:0]  name_len;
    wire [(16*8)-1:0] name_flat;

    // 로터리 제어: 회전은 rate 또는 temperature를 조정; 누르기는 대상을 전환
    wire        auto_start;
    wire [4:0]  speed_level;
    wire [2:0]  temp_sel;
    wire        cfg_mode;        // 0 = rate 조정, 1 = temperature 조정
    rotary_throttle #(.CLK_HZ(CLK_HZ), .NTEMP(8)) u_rot (
        .clk(clk), .resetn(resetn),
        .rot_a(rot_a), .rot_b(rot_b), .rot_push(rot_push),
        .gen_busy(gen_busy),
        .auto_start(auto_start), .speed_level(speed_level),
        .temp_sel(temp_sel), .cfg_mode(cfg_mode)
    );

    // 온도 프리셋: temp_sel 0..7 -> T = 0.5..1.2 (0.1 단위); inv_temp = round(2048/T),
    // Q5.11. 샘플러는 이미 16x16 곱셈을 가지므로 어떤 값이든 공짜; 0.1 단위는 LCD 표시를
    // 소수 한 자리로 유지함.
    function automatic logic signed [15:0] temp_lut(input logic [2:0] sel);
        unique case (sel)
            3'd0: return 16'sd4096;   // T=0.5
            3'd1: return 16'sd3413;   // T=0.6
            3'd2: return 16'sd2926;   // T=0.7  (기본)
            3'd3: return 16'sd2560;   // T=0.8
            3'd4: return 16'sd2276;   // T=0.9
            3'd5: return 16'sd2048;   // T=1.0
            3'd6: return 16'sd1862;   // T=1.1
            default: return 16'sd1707;// T=1.2
        endcase
    endfunction

    // 생성 트리거 = 로터리 스로틀(자동 회전) + 선택적 호스트(VIO).
    // start_btn (AJ6)은 의도적으로 트리거가 아님: 이 보드에서 해당 라인이 ~66 Hz로 자유
    // 실행되어 2 ms 디바운스를 그대로 통과했고(66 Hz 구형파는 반주기당 >2 ms 안정) ~330 t/s
    // 바닥값을 만들었음. gen_start=0 브링업 테스트로 증명됨(LCD가 배너에서 정지, 0 t/s ->
    // 생성기가 스스로 실행되지 않음), 따라서 유일한 소스는 btn_pulse였음. 스로틀은 레벨 0에서
    // 구조적으로 1 Hz로 제한되므로 데모는 이제 ~5 t/s로 시작함.
    wire        gen_start = auto_start | vio_start;
    wire        _unused   = btn_pulse;   // start_btn은 배선/디바운스 유지하되 미사용
    wire [31:0] gen_seed  = vio_use_host ? vio_seed : (seed_live ^ {24'd0, dip_sw});
    wire signed [15:0] gen_inv_temp = temp_lut(temp_sel);   // 로터리 선택 온도

    name_generator #(.MAX_LEN(16)) u_gen (
        .clk(clk), .resetn(resetn), .start(gen_start),
        .seed(gen_seed), .inv_temp(gen_inv_temp), .sample_mode(1'b1),
        .busy(gen_busy), .done(gen_done), .token_out(tok_out), .token_valid(tok_valid),
        .name_len(name_len), .name_flat(name_flat)
    );

    // LCD가 이름들 사이에 안정된 문자열을 보이도록 마지막 완료된 이름을 래치
    logic [(16*8)-1:0] name_show;
    logic [4:0]        name_len_show;
    always_ff @(posedge clk) begin
        if (!resetn) begin name_show <= {16{8'd0}}; name_len_show <= 5'd0; end
        else if (gen_done) begin name_show <= name_flat; name_len_show <= name_len; end
    end

    // ---------------- 초당 토큰 미터 -----------------------------------------
    wire [19:0] tok_bcd;
    tok_meter #(.CLK_HZ(CLK_HZ)) u_meter (
        .clk(clk), .resetn(resetn), .token_valid(tok_valid),
        .tok_bcd(tok_bcd)
    );

    // ---------------- LCD 1행: 환영 배너, 그 다음 생성된 이름 ---------
    logic show_welcome;
    always_ff @(posedge clk) begin
        if (!resetn)      show_welcome <= 1'b1;
        else if (gen_done) show_welcome <= 1'b0;
    end

    function automatic logic [7:0] tok_ascii(input logic [7:0] t);   // 토큰 0..25 -> 'a'..'z', 그 외 공백
        return (t < 8'd26) ? (8'd97 + t) : 8'h20;
    endfunction

    // 환영 배너를 플랫 상수로, col0을 LSB 바이트에 (역순 리터럴)
    wire [(16*8)-1:0] welcome_str = "   omed TPGorcim";   // = "microGPT demo   "

    wire [(16*8)-1:0] line1;
    generate
        for (genvar gi = 0; gi < 16; gi++) begin : GEN_LINE1
            assign line1[(gi*8) +: 8] =
                show_welcome ? welcome_str[(gi*8) +: 8] :
                (gi < name_len_show) ? tok_ascii(name_show[(gi*8) +: 8]) : 8'h20;
        end
    endgenerate

    // ---------------- LCD 2행: "rate: NNNNN t/s" (측정된 tok/s, BCD) ---------
    wire [3:0] d4 = tok_bcd[19:16];
    wire [3:0] d3 = tok_bcd[15:12];
    wire [3:0] d2 = tok_bcd[11:8];
    wire [3:0] d1 = tok_bcd[7:4];
    wire [3:0] d0 = tok_bcd[3:0];
    wire z4 = (d4 == 0);
    wire z3 = z4 & (d3 == 0);
    wire z2 = z3 & (d2 == 0);
    wire z1 = z2 & (d1 == 0);
    wire [7:0] c4 = z4 ? 8'h20 : (8'h30 + d4);   // 선행 0 공백 처리
    wire [7:0] c3 = z3 ? 8'h20 : (8'h30 + d3);
    wire [7:0] c2 = z2 ? 8'h20 : (8'h30 + d2);
    wire [7:0] c1 = z1 ? 8'h20 : (8'h30 + d1);
    wire [7:0] c0 =                8'h30 + d0;    // 항상 최소 1자리
    // RATE 뷰 (col0..15): "rate: NNNNN t/s"
    wire [(16*8)-1:0] line2_rate = {
        8'h20, 8'h73, 8'h2f, 8'h74, 8'h20,            // [15..11] ' ' s / t ' '
        c0, c1, c2, c3, c4,                           // [10..6]
        8'h20, 8'h3a, 8'h65, 8'h74, 8'h61, 8'h72      // [5..0]  ' ' : e t a r
    };
    // TEMP 뷰 (col0..15): "temp: X.Y       "  (T = 0.5..1.2, 소수 한 자리)
    wire [3:0] t_tenths = 4'd5 + {1'b0, temp_sel};    // 5..12
    wire       t_int    = (t_tenths >= 4'd10);
    wire [3:0] t_dec    = t_int ? (t_tenths - 4'd10) : t_tenths;
    wire [7:0] t_ic     = 8'h30 + {7'd0, t_int};      // '0' 또는 '1'
    wire [7:0] t_dc     = 8'h30 + {4'd0, t_dec};      // '0'..'9'
    wire [(16*8)-1:0] line2_temp = {
        8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20,   // [15..9] 공백
        t_dc, 8'h2e, t_ic, 8'h20,                          // [8..5]  Y . X ' '
        8'h3a, 8'h70, 8'h6d, 8'h65, 8'h74                  // [4..0]  ':' 'p' 'm' 'e' 't'
    };
    wire [(16*8)-1:0] line2 = cfg_mode ? line2_temp : line2_rate;

    // ---------------- LCD ---------------------------------------------------------
    wire lcd_ready;
    lcd_hd44780 #(.CLK_HZ(CLK_HZ)) u_lcd (
        .clk(clk), .resetn(resetn), .line1(line1), .line2(line2),
        .lcd_rs(lcd_rs), .lcd_rw(lcd_rw), .lcd_e(lcd_e), .lcd_db(lcd_db),
        .ready(lcd_ready)
    );

    // ---------------- LED 상태 + 타임베이스 하트비트 -----------------------------
    // led[7] = 독립적인 1 Hz 하트비트(0.5초마다 토글) -> 코어 클럭이 정말 ~80 MHz인지
    //          검증. 이것이 ~1/s로 깜빡이면 타임베이스가 맞고, 빠른 생성은 클럭이 아니라
    //          스로틀 간격 문제임.
    // led[6] = gen_busy (1 Hz에서는 짧게 깜빡임; 계속 켜져 있으면 생성이 연속적임).
    // led[4:0] = speed_level.
    logic [25:0] hb_cnt = 26'd0;
    logic        hb     = 1'b0;
    always_ff @(posedge clk) begin
        if (hb_cnt >= 26'd39_999_999) begin hb_cnt <= 26'd0; hb <= ~hb; end   // 0.5 s @ 80 MHz
        else                                hb_cnt <= hb_cnt + 26'd1;
    end
    assign led = {hb, gen_busy, cfg_mode, speed_level};   // led[5] = temp 조정 중 1

    // ---------------- ChipScope VIO (USB JTAG 통한 PC) ----------------------------
`ifdef CHIPSCOPE_VIO
    wire [35:0]  vio_control;
    wire [49:0]  vio_sync_out;
    wire [138:0] vio_sync_in;
    logic [1:0] vstart_sync = 2'd0;
    always_ff @(posedge clk) vstart_sync <= {vstart_sync[0], vio_sync_out[0]};
    assign vio_start    = (vstart_sync == 2'b01);
    assign vio_use_host = vio_sync_out[1];
    assign vio_seed     = vio_sync_out[33:2];
    assign vio_temp     = vio_sync_out[49:34];
    assign vio_sync_in  = {2'd0, speed_level, lcd_ready, gen_busy, name_len_show, name_show};
    chipscope_icon u_icon (.CONTROL0(vio_control));
    chipscope_vio  u_vio  (.CONTROL(vio_control), .CLK(clk),
                           .SYNC_IN(vio_sync_in), .SYNC_OUT(vio_sync_out));
`else
    assign vio_start = 1'b0; assign vio_use_host = 1'b0;
    assign vio_seed  = 32'd0; assign vio_temp = 16'd0;
`endif

endmodule
