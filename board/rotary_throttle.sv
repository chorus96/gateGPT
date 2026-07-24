// 이름 생성기용 로터리 엔코더 제어 (Panasonic EVQWK4001, 15 디텐트).
// 엔코더를 돌리면 푸시 버튼으로 선택된 두 설정 중 하나를 조정함:
//   cfg_mode = 0 (RATE) : 레벨 0..MAX_LEVEL이 자동 회전 간격을 설정,
//                         1 Hz(레벨 0)에서 연속까지 지수적으로.
//   cfg_mode = 1 (TEMP) : 레벨 0..NTEMP-1이 샘플링 온도를 선택(top이 작은 LUT로
//                         temp_sel -> inv_temp 매핑).
// 디바운스된 누르기가 cfg_mode를 토글함; top의 LED/LCD가 어느 것이 활성인지 표시.
// (SystemVerilog)
module rotary_throttle #(
    parameter int CLK_HZ    = 50_000_000,  // 코어 클럭
    parameter int MAX_LEVEL = 15,          // 1회전(15 디텐트)이 rate 범위를 커버
    parameter int NTEMP     = 8,           // 온도 프리셋 개수
    parameter int FILTER    = 2500         // ~50 us 디글리치 (레벨이 유지되어야 하는 사이클)
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        rot_a,        // INCA (비동기, active high)
    input  logic        rot_b,        // INCB (비동기)
    input  logic        rot_push,     // PUSH (비동기, active high) -> cfg_mode 토글
    input  logic        gen_busy,     // 이름 생성기 바쁨
    output logic        auto_start,   // 1사이클 펄스: 생성 시작
    output logic [4:0]  speed_level,  // RATE 설정
    output logic [2:0]  temp_sel,     // TEMP 프리셋 인덱스 (0..NTEMP-1)
    output logic        cfg_mode      // 0 = rate 조정, 1 = temperature 조정
);
    // ---- 비동기 엔코더 입력 동기화 (2 FF) ----
    logic [1:0] a_ff, b_ff, p_ff;
    always_ff @(posedge clk) begin
        a_ff <= {a_ff[0], rot_a};
        b_ff <= {b_ff[0], rot_b};
        p_ff <= {p_ff[0], rot_push};
    end
    wire a_sync = a_ff[1];
    wire b_sync = b_ff[1];

    // ---- 두 위상 라인 디글리치: FILTER만큼 안정 사이클 후에만 레벨을 채택 ----
    logic a_clean, b_clean;
    logic [11:0] a_cnt, b_cnt;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            a_clean <= 1'b0; b_clean <= 1'b0; a_cnt <= 12'd0; b_cnt <= 12'd0;
        end else begin
            if (a_sync == a_clean) a_cnt <= 12'd0;
            else if (a_cnt >= FILTER) begin a_clean <= a_sync; a_cnt <= 12'd0; end
            else a_cnt <= a_cnt + 12'd1;

            if (b_sync == b_clean) b_cnt <= 12'd0;
            else if (b_cnt >= FILTER) begin b_clean <= b_sync; b_cnt <= 12'd0; end
            else b_cnt <= b_cnt + 12'd1;
        end
    end

    // ---- 푸시 버튼: 디바운스(~2 ms) + 상승 엣지 -> cfg_mode 토글 ----
    localparam int PUSH_FILTER = CLK_HZ / 500;     // ~2 ms
    logic        push_clean, push_clean_d;
    logic [19:0] push_cnt;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            push_clean <= 1'b0; push_clean_d <= 1'b0; push_cnt <= 20'd0; cfg_mode <= 1'b0;
        end else begin
            if (p_ff[1] == push_clean) push_cnt <= 20'd0;
            else if (push_cnt >= PUSH_FILTER[19:0]) begin push_clean <= p_ff[1]; push_cnt <= 20'd0; end
            else push_cnt <= push_cnt + 20'd1;
            push_clean_d <= push_clean;
            if (push_clean & ~push_clean_d) cfg_mode <= ~cfg_mode;   // 누르기 시 토글
        end
    end

    // ---- 쿼드러처 디코드: 부호 있는 엣지 누산, 디텐트당 한 스텝 ----
    localparam int EDGES_PER_DETENT = 4;
    localparam int STARTUP_HOLD     = CLK_HZ / 5;   // ~200 ms 전원 투입/MMCM-lock 홀드오프

    logic [1:0] ab, ab_d;
    always_ff @(posedge clk) begin
        ab   <= {a_clean, b_clean};
        ab_d <= ab;
    end
    wire [3:0] tr = {ab_d, ab};
    wire up_edge = (tr == 4'b0001) || (tr == 4'b0111) || (tr == 4'b1110) || (tr == 4'b1000);
    wire dn_edge = (tr == 4'b0010) || (tr == 4'b1011) || (tr == 4'b1101) || (tr == 4'b0100);

    logic signed [3:0] acc;
    logic [31:0]       startup;
    wire armed = (startup == 32'd0);
    wire detent_up = armed && up_edge && !dn_edge && (acc >=  (EDGES_PER_DETENT - 1));
    wire detent_dn = armed && dn_edge && !up_edge && (acc <= -(EDGES_PER_DETENT - 1));

    always_ff @(posedge clk) begin
        if (!resetn) begin
            speed_level <= 5'd0;
            temp_sel    <= 3'd2;                 // 기본 프리셋 (top의 LUT에서 T=0.7)
            acc         <= 4'sd0;
            startup     <= STARTUP_HOLD[31:0];
        end else begin
            if (startup != 32'd0) startup <= startup - 32'd1;
            if (armed && (up_edge ^ dn_edge)) begin
                if (up_edge) begin
                    if (acc >= EDGES_PER_DETENT - 1) acc <= 4'sd0;
                    else acc <= acc + 4'sd1;
                end else begin
                    if (acc <= -(EDGES_PER_DETENT - 1)) acc <= 4'sd0;
                    else acc <= acc - 4'sd1;
                end
            end
            // 완료된 디텐트가 선택된 설정을 위/아래로 한 스텝 조정
            if (detent_up) begin
                if (cfg_mode) begin if (temp_sel < NTEMP - 1) temp_sel <= temp_sel + 3'd1; end
                else          begin if (speed_level < MAX_LEVEL) speed_level <= speed_level + 5'd1; end
            end else if (detent_dn) begin
                if (cfg_mode) begin if (temp_sel > 3'd0) temp_sel <= temp_sel - 3'd1; end
                else          begin if (speed_level > 5'd0) speed_level <= speed_level - 5'd1; end
            end
        end
    end

    // ---- 자동 시작 간격 = CLK_HZ >> speed_level (레벨 0 = 1 Hz) ----
    localparam logic [31:0] CLK_HZ_W = CLK_HZ;
    wire [31:0] interval = CLK_HZ_W >> speed_level;
    logic [31:0] timer;
    always_ff @(posedge clk) begin
        if (!resetn) begin
            timer      <= 32'd0;
            auto_start <= 1'b0;
        end else begin
            auto_start <= 1'b0;
            if (timer >= interval) begin
                if (!gen_busy) begin               // 코어가 idle일 때만 발사
                    auto_start <= 1'b1;
                    timer      <= 32'd0;
                end
            end else begin
                timer <= timer + 32'd1;
            end
        end
    end

endmodule
