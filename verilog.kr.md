# gateGPT에서 사용한 Verilog 문법 정리

이 문서는 gateGPT 저장소의 `core/*.sv`, `board/*.sv`, `sim/*.sv`에서 사용한 **모든 Verilog 문법**을
상세히 정리합니다. 각 문법이 어느 파일에 쓰였는지도 함께 표기합니다.

> **참고 (SystemVerilog 이관):** `core/`·`board/`의 RTL은 이후 **SystemVerilog**로 변환되었습니다
> — 자료형 `logic`, `always_ff`/`always_comb`, `typedef enum` FSM, `automatic` 함수 등 현대 SV 관용구를
> 사용합니다(동작·타이밍·비트 일치는 그대로 보존, Verilator로 검증). RTL/시뮬레이션 소스 파일은 이후
> **`.sv` 확장자**로 리네임되었습니다(`core/*.sv`, `board/*.sv`, `sim/*.sv`). 이 문서의 아래 문법 설명은
> 원래의 **Verilog-2001** 기반을 정리한 것으로, 개념적 배경으로 유효합니다.
> 생성된 `core/*.vh`(마이크로코드/가중치 ROM)는 여전히 Verilog(함수/`localparam`)이며 SV 모듈에서 그대로 포함됩니다.
> **주의:** SV 이관으로 XST 14.7(ISE) 합성 흐름은 폐기되었고, **Vivado 24.2**로 전환되었습니다.
> Vivado는 Virtex-5를 지원하지 않으므로 보드는 **Kria K26(xck26, Zynq UltraScale+)**로 리타깃됨(`DCM_BASE` → `MMCME4_BASE`,
> `.ucf` → `.xdc`). 빌드는 `build_board_vivado_project.tcl`, 시뮬레이션은 Verilator를 사용하세요.

**대상 파일 (25개)**
- **core/ (14)**: `microgpt_core`, `matvec`, `attn`, `norm`, `sampler`, `exp_unit`, `isqrt`,
  `udiv`, `embed`, `vecop`, `wrom`, `grom`, `vmem`, `vmem2`
- **board/ (5)**: `xupv5_microgpt_top`, `name_generator`, `lcd_hd44780`, `rotary_throttle`, `tok_meter`
- **sim/ (6)**: `tb_core`, `tb_matvec`, `tb_attn`, `tb_norm`, `tb_exp`, `tb_mathops`

---

## 1. 모듈 구조 (Module Structure)

### 1.1 모듈 정의와 파라미터

```verilog
module matvec #(
    parameter integer LANES = 24,        // 파라미터 (기본값)
    parameter integer ACCW  = 48
) (
    input  wire        clk,
    input  wire        resetn,
    output reg  [9:0]  addr_a,
    ...
);
    ...
endmodule
```

| 문법 | 설명 | 사용처 |
|---|---|---|
| `module X #(...) (...);` ~ `endmodule` | 모듈 정의 | 전반 |
| `parameter integer LANES = 24` | 파라미터 선언(기본값) | `matvec`, `attn`, `isqrt`, `udiv` 등 |
| ANSI 포트 스타일 | 포트 목록에 방향·타입 직접 선언 | 전반 |

### 1.2 포트 방향과 타입

| 선언 | 의미 | 사용처 |
|---|---|---|
| `input wire clk` | 입력 와이어 | 전반 |
| `output reg [9:0] addr_a` | 출력 레지스터(절차적 대입 대상) | 전반 |
| `output wire [9:0] v_raddr` | 출력 와이어(연속 대입) | `sampler`, `vecop` |
| `input wire signed [15:0] rd_a` | 부호 있는 벡터 입력 | 전반 |
| `output reg signed [15:0] wd_a` | 부호 있는 출력 레지스터 | 전반 |

### 1.3 `localparam`

```verilog
localparam [1:0] S_IDLE=2'd0, S_RUN=2'd1, S_DRAIN=2'd2, S_WB=2'd3;
localparam integer HW = LANES*16;
localparam [6:0] LANES_W = LANES;   // 정수 파라미터 → 크기 지정 상수
```

- **FSM 상태 인코딩**과 파생 상수에 사용. `matvec`의 `LANES_W`는 정수 파라미터 비트 선택
  버그(XST 14.7)를 피하려 크기 지정 localparam으로 복사. (전 core 모듈)

---

## 2. 데이터 타입과 선언

### 2.1 기본 넷/변수 타입

| 타입 | 용도 | 사용처 |
|---|---|---|
| `wire` | 조합 연결 | 전반 |
| `reg` | 절차적 대입 변수(레지스터/조합) | 전반 |
| `integer` | 반복/루프 변수 (`integer L, k;`) | `matvec`, TB |
| `genvar` | generate 루프 변수 | `attn`, `name_generator`, `top` |

### 2.2 벡터와 부호

```verilog
reg signed [47:0] acc [0:LANES-1];   // 부호 있는 48비트 × LANES 배열
wire [71:0] instr;                    // 72비트 벡터
wire signed [15:0] sat_a;
```

| 문법 | 의미 | 사용처 |
|---|---|---|
| `[15:0]` | 16비트 벡터(리틀 엔디언 범위) | 전반 |
| `[W-1:0]` | 파라미터 폭 벡터 | `isqrt`, `udiv`, `vmem` |
| `signed` | 부호 있는 산술 | 전반 |

### 2.3 메모리 배열 (2차원)

```verilog
(* ram_style = "block" *) reg signed [DW-1:0] mem [0:(1<<AW)-1];   // BRAM
reg signed [15:0] xreg [0:N-1];        // 로컬 레지스터 파일
reg signed [47:0] num [0:HEAD_DIM-1];  // 헤드별 분자
reg [7:0] name_buf [0:MAX_LEN-1];      // 이름 버퍼
```

- **언패킹 배열**로 스크래치패드(`vmem`/`vmem2`), 로컬 캐시(`xreg`, `areg`, `qreg`, `score`,
  `ev`, `scaled`), 상태 저장에 사용.

---

## 3. 연산자 (Operators)

### 3.1 산술 연산자

| 연산자 | 의미 | 사용처 |
|---|---|---|
| `+`, `-`, `*` | 덧셈/뺄셈/곱셈 | 전반 (MAC `acc + rd*w`) |
| `>>` | 논리 우측 시프트 | `udiv`, `isqrt`, `embed` |
| `>>>` | **산술 우측 시프트**(부호 유지) | 고정소수점 리스케일 전반 |
| `<<` | 좌측 시프트 (`48'd1 << (2*FRAC)`) | `norm`, `isqrt` |

### 3.2 비트/축약 연산자

| 연산자 | 의미 | 사용처 |
|---|---|---|
| `&`, `\|`, `~`, `^` | AND/OR/NOT/XOR | 전반 |
| `~num[gi] + 1` | 2의 보수(절댓값) | `attn` 병렬 나눗셈 |

### 3.3 비교·논리 연산자

| 연산자 | 의미 | 사용처 |
|---|---|---|
| `>`, `<`, `>=`, `<=` | 크기 비교 | 전반 (포화, FSM) |
| `==` | 논리 동등 | 전반 |
| `!==`, `===` | **케이스 동등**(x/z 포함 비교) | 테스트벤치 (`rda !== texp`) |
| `&&`, `\|\|`, `!` | 논리 AND/OR/NOT | `rotary_throttle`, FSM |

### 3.4 조건(삼항) 연산자

```verilog
wire signed [15:0] sat_a =
    (sh_a > 48'sd32767) ? 16'sd32767 :
    (sh_a < -48'sd32768) ? -16'sd32768 : sh_a[15:0];   // 포화 관용구
```

- **중첩 삼항**으로 포화(saturation) 로직을 표현. (전 core 모듈)

### 3.5 연결·복제·부분 선택

| 문법 | 의미 | 사용처 |
|---|---|---|
| `{a, b}` | 비트 연결(concatenation) | 전반 |
| `{N{x}}` | 복제(replication) (`{16{8'h20}}`, `{W{1'b0}}`) | `lcd`, `isqrt` |
| `{{2{z[15]}}, z}` | **부호 확장** (복제+연결) | `exp_unit` |
| `x[a +: b]` | **인덱스 부분 선택**(폭 b) | `matvec` `w_rdata[L*16 +: 16]`, `top` |
| `x[15:0]` | 고정 부분 선택 | 전반 |
| `instr[42:33]` | 비트 필드 추출(명령 디코드) | `microgpt_core` |

---

## 4. 절차적 블록 (Procedural Blocks)

### 4.1 클럭 동기 `always` (순차 로직)

```verilog
always @(posedge clk) begin
    if (!resetn) begin
        st <= S_IDLE; busy <= 0; ...
    end else begin
        ...
        acc[L] <= acc[L] + $signed(rd_a_r) * $signed(w_rdata_rr[L*16 +: 16]);
    end
end
```

| 요소 | 설명 | 사용처 |
|---|---|---|
| `always @(posedge clk)` | 상승 엣지 트리거 순차 로직 | 전반 |
| **동기 리셋** `if (!resetn)` | 클럭 동기 active-low 리셋 | 전반 |
| `<=` (논블로킹 대입) | 레지스터 갱신 | 순차 블록 전반 |

### 4.2 조합 `always @(*)`

```verilog
always @(*) begin
    addr_a = act_base + {2'd0, fi, 1'b0};    // act[2j]
    we_a = 1'b0; wd_a = sat_a;
    if (st == S_WB) begin
        addr_a = dst_base + {3'd0, obase + wbi};
        we_a = (obase + wbi < out_dim);
    end
end
```

| 요소 | 설명 | 사용처 |
|---|---|---|
| `always @(*)` | 조합 로직(민감도 자동) | `matvec`, `norm`, `attn`, `lcd` |
| `=` (블로킹 대입) | 조합 신호 계산 | 조합 블록 |

> **관용구**: 논블로킹 `<=`는 순차, 블로킹 `=`는 조합에 사용하는 규칙을 일관되게 준수.

### 4.3 `case` 문과 FSM

```verilog
case (q)
    Q_IDLE: if (start) begin ... q <= Q_EXEC; end
    Q_EXEC: begin
        case (op)
            OP_EMBED: em_go <= 1;
            OP_NORM:  no_go <= 1;
            default: ;
        endcase
    end
    Q_WAIT: if (act_done) begin ... end
    default: q <= Q_IDLE;
endcase
```

| 요소 | 설명 | 사용처 |
|---|---|---|
| `case (x) ... endcase` | 다분기 | 전 FSM |
| **중첩 case** | 시퀀서 상태 안의 op 디코드 | `microgpt_core`, `lcd` |
| `default:` | 미지정 케이스(안전 상태) | 전반 |

### 4.4 `if`/`else`와 `for`

| 문법 | 용도 | 사용처 |
|---|---|---|
| `if/else if/else` | 조건 분기 | 전반 |
| `for (L=0; L<LANES; L=L+1)` | 절차적 루프(레인 병렬 MAC/초기화) | `matvec`, `norm`, TB |
| `begin ... end` | 블록 그룹화 | 전반 |

---

## 5. 연속 대입 (`assign`)

```verilog
assign w_addr = wbase + {5'd0, fi};
assign lcd_rw = 1'b0;                       // 상수 결선
assign pa_addr = (op == OP_NORM) ? no_aa :
                 (op == OP_MATV) ? mv_aa : ... ;   // 포트 먹스
assign wdata = wrom_data(sel, addr);        // 함수 호출 결과 결선
```

- **조합 신호 구동**, 상수 결선, 포트 먹스, 함수 결과 연결에 사용. (전반)

---

## 6. 함수 (`function`)

```verilog
function signed [15:0] scale_score;
    input signed [47:0] a;
    reg signed [47:0] ash; reg signed [15:0] s1; ...
    begin
        ash = a >>> FRAC;
        s1 = (ash > 48'sd32767) ? 16'sd32767 : ... ;
        scale_score = ...;      // 함수명에 반환값 대입
    end
endfunction
```

| 용례 | 설명 | 사용처 |
|---|---|---|
| `function [W-1:0] name; input ...; ... endfunction` | 조합 함수 | `attn` scale_score, `top` temp_lut/tok_ascii, `lcd` init_op |
| **조합 ROM 함수** | `ucode_rom`, `wrom_data`, `gain_lut`, `tok_emb`, `pos_emb`, `exp_tab_rom` | 생성된 `.vh` |
| 함수 내부 지역 변수 | `reg` 선언 후 계산 | `attn`, `lcd` |

> **핵심 설계**: 모든 ROM을 `$readmemh` 대신 **조합 case 함수**로 구현 — XST 14.7이 작은
> `$readmemh` 분산 ROM을 0으로 묶는 버그를 회피. (생성된 `core/*.vh`, `wrom.sv`/`grom.sv`/`embed.sv`/`exp_unit.sv`에서 include)

---

## 7. Generate 블록

```verilog
genvar gi;
generate for (gi = 0; gi < HEAD_DIM; gi = gi + 1) begin : DIVS
    wire [47:0] na = num[gi][47] ? (~num[gi] + 48'd1) : num[gi];
    udiv #(.W(48)) u_div (.clk(clk), .start(d_start), .num(na), ...);
end endgenerate
```

| 요소 | 설명 | 사용처 |
|---|---|---|
| `generate ... endgenerate` | 정적 반복 하드웨어 생성 | `attn`(병렬 나눗셈기), `name_generator`, `top`(LCD 라인) |
| `genvar` | generate 루프 변수 | 위 |
| 명명 블록 `: DIVS` | generate 스코프 이름 | `attn` |
| generate 내 모듈 인스턴스 | HEAD_DIM개 `udiv` 병렬 | `attn` |

---

## 8. 모듈 인스턴스화 (Instantiation)

```verilog
vmem2 #(.AW(10), .DW(16)) u_vmem (.clk(clk),
    .we_a(pa_we), .addr_a(pa_addr), .wdata_a(pa_wd), .rdata_a(v_rdata),
    .we_b(pb_we), .addr_b(pb_addr), .wdata_b(pb_wd), .rdata_b(v_rdata_b));
```

| 요소 | 설명 | 사용처 |
|---|---|---|
| **명명 포트 연결** `.port(signal)` | 순서 무관 연결 | 전반 |
| **파라미터 오버라이드** `#(.AW(10))` | 인스턴스별 파라미터 | 전반 |
| 미연결 포트 `.busy()` | 출력 무시 | `attn`, `norm` udiv |
| Xilinx 프리미티브 인스턴스 | `BUFG`, `MMCME4_BASE` | `top` |

---

## 9. 숫자 리터럴 (Number Literals)

| 리터럴 | 의미 | 사용처 |
|---|---|---|
| `16'sd32767` | 16비트 부호 있는 10진 | 포화 상수 전반 |
| `16'sh0836` / `16'sd836` | 16비트 부호 있는 16진/10진 | `attn` 스케일 |
| `10'd0`, `5'd1`, `7'd2` | 크기 지정 10진 | 전반 |
| `4'b0001` | 2진 | `rotary` 쿼드러처 전이 |
| `72'h000000000000000008` | 72비트 16진(HALT 명령) | `ucode_asm` 생성 |
| `2'b00`, `1'b1` | 비트 상수 | 전반 |
| `{W{1'b0}}` | 폭 파라미터 0 채움 | `isqrt`, `udiv` |

---

## 10. 컴파일러 지시자 (Compiler Directives)

| 지시자 | 용도 | 사용처 |
|---|---|---|
| `` `timescale 1ns/1ps `` | 시뮬레이션 시간 단위 | 테스트벤치 전반 |
| `` `include "path.vh" `` | 파일 포함(생성된 ROM/파라미터) | `microgpt_core`, `wrom`, `grom`, `embed`, `exp_unit` |
| `` `ifdef / `else / `endif `` | 조건부 컴파일(`CHIPSCOPE_VIO`) | `top` |

---

## 11. 합성 속성 (Synthesis Attributes)

```verilog
(* ram_style = "block" *) reg signed [DW-1:0] mem [0:(1<<AW)-1];
(* keep = "true" *) reg [6:0] obase;
```

| 속성 | 용도 | 사용처 |
|---|---|---|
| `(* ram_style = "block" *)` | BRAM 추론 강제 | `vmem`, `vmem2` |
| `(* keep = "true" *)` | 상수 폴딩/트리밍 방지 | `matvec` (`obase`, `wbase`) |

> XST 14.7이 살아있는 레지스터(`obase`)를 상수 0으로 트리밍해 멀티 타일 행렬곱이 보드에서
> 멈춘 버그를 `keep` 속성으로 방지.

---

## 12. 테스트벤치 전용 문법 (`sim/*.sv`)

### 12.1 `initial`과 시간 제어

```verilog
initial begin
    $readmemh(".../test_in.hex", tin);
    resetn = 0;
    repeat (4) @(posedge clk); resetn = 1;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    wait (mv_done);
    #1;
    $finish;
end
```

| 문법 | 설명 | 사용처 |
|---|---|---|
| `initial begin ... end` | 1회 실행 블록 | TB 전반 |
| `#5`, `#1` | 시간 지연 | TB 전반 |
| `@(posedge clk)`, `@(negedge clk)` | 엣지 대기 | TB 전반 |
| `wait (cond)` | 조건 대기 | `tb_core`, `tb_matvec` 등 |
| `repeat (N) @(posedge clk)` | N 사이클 대기 | TB 전반 |

### 12.2 클럭 생성

```verilog
reg clk = 0;
always #5 clk = ~clk;      // 10ns 주기(100MHz)
```

### 12.3 `task`

```verilog
task run_gen(input mode, input [31:0] seed, input signed [15:0] itemp);
    begin
        ...
        for (step = 0; step < 16; step = step + 1) begin ... end
    end
endtask
```

| 요소 | 설명 | 사용처 |
|---|---|---|
| `task ... endtask` | 재사용 시퀀스(시간 소비 가능) | `tb_core`(run_gen), `tb_attn`(wload), `tb_mathops`(chk_div/chk_sqrt) |
| task 내부 지역 변수 `integer j;` | task 스코프 | `tb_attn` |

### 12.4 시스템 태스크·함수

| 시스템 태스크 | 용도 | 사용처 |
|---|---|---|
| `$readmemh(file, array)` | 16진수 파일 → 배열 로드 | TB 전반 |
| `$display(...)` | 개행 포함 출력 | TB 전반 |
| `$write(...)` | 개행 없는 출력 | `tb_core` |
| `$finish` | 시뮬레이션 종료 | TB 전반 |
| `$signed(x)` | 부호 있는 해석(출력/연산) | TB, `matvec`, `attn`, `norm` |

### 12.5 x/z 값과 케이스 동등

```verilog
zs[k] = 16'shxxxx;                 // 미정의 값 초기화
if (zs[k] !== 16'shxxxx) begin ... end   // 케이스 부등(x 구분)
if (rda !== texp[k]) begin ... end       // 정확 비교(x 검출)
```

- **`!==`/`===`**로 x(미정의)를 포함해 정확히 비교 → 검증 신뢰성. (`tb_exp`, 전 TB)

---

## 13. 주요 하드웨어 설계 관용구 (Idioms)

### A. 포화 산술 (Saturating Arithmetic)
```verilog
wire signed [15:0] esat =
    (sum > 17'sd32767) ? 16'sd32767 : (sum < -17'sd32768) ? -16'sd32768 : sum[15:0];
```
넓은 폭에서 계산 후 중첩 삼항으로 16비트 클램프. (전 core 모듈)

### B. 등록 읽기 BRAM (Registered-Read, Read-Ahead)
```verilog
always @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    rdata <= mem[raddr];      // 1사이클 지연
end
```
주소를 한 사이클 먼저 제시하고 다음 사이클 데이터 소비. (`vmem`, `vmem2`)

### C. 진정한 듀얼 포트 BRAM 템플릿 (포트당 always 블록)
```verilog
always @(posedge clk) begin   // 포트 A
    if (we_a) mem[addr_a] <= wdata_a;
    rdata_a <= mem[addr_a];
end
always @(posedge clk) begin   // 포트 B
    if (we_b) mem[addr_b] <= wdata_b;
    rdata_b <= mem[addr_b];
end
```
두 포트를 **별도** always 블록으로 → XST가 BRAM으로 추론(한 블록이면 FF로 폴백). (`vmem2`)

### D. FSM + go 펄스 핸드셰이크
```verilog
localparam [1:0] Q_IDLE=0, Q_EXEC=1, Q_WAIT=2;
// go 펄스로 액추에이터 시작, act_done으로 완료 대기
```
시퀀서-액추에이터 간 start/done 핸드셰이크. (`microgpt_core` 및 전 액추에이터)

### E. 파이프라인 레지스터로 크리티컬 패스 단축
```verilog
w_rdata_r <= w_rdata; w_rdata_rr <= w_rdata_r;   // 2단 오퍼랜드 파이프
rd_a_r <= rd_a;
```
BRAM 출력→DSP 넷을 레지스터로 끊어 80 MHz 타이밍 클로징. (`matvec`, `sampler`, `exp_unit`, `attn`, `norm`)

### F. 동기화 + 디바운스 (비동기 입력)
```verilog
a_ff <= {a_ff[0], rot_a};      // 2-FF 동기화
if (sb_sync[1] == sb_clean) sb_cnt <= 0;
else if (sb_cnt >= FILTER) sb_clean <= sb_sync[1];   // 안정 후 채택
```
비동기 버튼/엔코더를 2-FF 동기화 후 카운터 디바운스. (`top`, `rotary_throttle`)

---

## 부록: 문법 → 파일 대응표

| 문법 범주 | 대표 파일 |
|---|---|
| 파라미터 모듈 | `matvec`, `attn`, `isqrt`, `udiv`, `vmem2` |
| FSM (`case`/`localparam` 상태) | `microgpt_core`, `attn`, `norm`, `sampler`, `lcd_hd44780`, `name_generator` |
| 조합 함수 ROM (`function`) | 생성된 `.vh` + `wrom`/`grom`/`embed`/`exp_unit` |
| generate + 병렬 인스턴스 | `attn`(udiv ×6), `name_generator`, `xupv5_microgpt_top` |
| 메모리 배열 + 합성 속성 | `vmem`, `vmem2` (`ram_style`), `matvec` (`keep`) |
| 부호 있는 고정소수점 산술(`>>>`, `$signed`, 포화) | 전 core 모듈 |
| 부분 선택 `[a +: b]` | `matvec`, `xupv5_microgpt_top` |
| 컴파일러 지시자 (`include`/`ifdef`) | `microgpt_core`, `xupv5_microgpt_top` |
| 테스트벤치 (`initial`/`task`/`$readmemh`/`$display`) | `sim/tb_*.sv` 전반 |
| Xilinx 프리미티브 (`MMCME4_BASE`/`BUFG`) | `xupv5_microgpt_top` |

---

# 14. Verilog 기반 알고리즘 상세

이 장은 저장소의 RTL이 **하드웨어로 구현한 알고리즘**을 파일별로 상세히 정리합니다. 각 알고리즘의
동작 원리, 상태 흐름, 사이클 복잡도, 핵심 최적화를 포함합니다. (개념적 수식은 `math.kr.md` 참조)

## 14.1 마이크로코드 시퀀서 (`microgpt_core.sv`)

**알고리즘**: 프로그램 카운터(`pc`)가 조합 ROM 함수 `ucode_rom(pc)`에서 72비트 매크로 명령을 페치 →
필드를 디코드해 해당 액추에이터에 `go` 펄스 → `act_done`을 기다렸다가 `pc++` → 반복. `OP_HALT`에서 종료.

- **3-상태 FSM**: `Q_IDLE`(start 대기) → `Q_EXEC`(op별 go 펄스) → `Q_WAIT`(완료 대기, pc 증가).
- **핸드셰이크**: 시퀀서와 액추에이터가 start/done으로 동기화 → 각 매크로 연산이 가변 사이클을 가져도 안전.
- **KV 캐시 슬롯 주소**: `use_pos`면 목적지에 `pos_r * N_EMBED`를 더해 캐시 위치에 K/V 기록.
- 17개 명령이 한 토큰의 전체 트랜스포머 스케줄(embed → norm → K/V/Q matvec → attn → wo →
  잔차 → norm → fc1 → relu → fc2 → 잔차 → norm → lm → sample)을 인코딩.

## 14.2 타일드 병렬 행렬-벡터 (`matvec.sv`)

**알고리즘**: 출력 행을 LANES=24개 단위 타일로 나누고, 각 타일을 systolic MAC로 계산:

1. **S_RUN**: 매 사이클 활성값 2개(`act[2j]`, `act[2j+1]`)를 듀얼 포트로 읽고, 와이드 ROM에서
   두 열의 24개 가중치를 받아 **레인당 2 MAC** → 타일이 `in_dim/2` 사이클에 완료.
2. **S_DRAIN**: 2단 오퍼랜드 파이프라인의 잔여 열 쌍을 플러시.
3. **S_WB**: 누산기를 `>>> descale` 후 포화, 두 쓰기 포트로 **2행/사이클** 배출 → `LANES/2` 사이클.
4. 다음 타일로 `obase`/`wbase` 전진, 마지막 타일에서 종료.

- **최적화**: 2단 오퍼랜드 파이프(`w_rdata_rr`, `rd_a_r`)로 BRAM→DSP 넷을 크리티컬 패스에서 제거.
- **복잡도**: 타일당 ≈ `in_dim/2 + LANES/2` 사이클. 48개 DSP48E 사용(바인딩 리소스).

## 14.3 RMSNorm 엔진 (`norm.sv`)

**알고리즘**: 6-상태 FSM으로 정규화를 순차 계산.

1. **S_SUM/S_SUMD**: 듀얼 포트로 2원소/사이클 읽어 제곱합 `ss` 누산 + `xreg`에 캐시.
2. **S_DIV1**: 공유 `udiv`로 `ss / N` (평균 제곱).
3. **S_SQRT**: `isqrt`로 $\lfloor\sqrt{\text{mean\_sq}}\rfloor = r$.
4. **S_DIV2**: `udiv`로 `2^22 / r` → 역제곱근 스케일 `scale_q`(32767 클램프).
5. **S_SCALE**: 2단 파이프로 `y = sat16(sat16(x·scale>>F)·gain>>F)`, 2원소/사이클 쓰기.

- **자원 공유**: 하나의 `udiv`를 두 나눗셈에 재사용, `isqrt`는 좁은 32비트.
- **복잡도**: 약 `N/2`(합) + 나눗셈/제곱근 지연 + `N/2`(스케일) 사이클.

## 14.4 단일 위치 멀티헤드 어텐션 (`attn.sv`)

**알고리즘**: 헤드마다 8-페이즈 FSM을 순회.

1. **P_QLOAD**: 쿼리 슬라이스를 `qreg`에 로드(read-ahead).
2. **P_SCORE**: `q·k` 닷프로덕트(2단 파이프: `dot_raw` 등록 후 scale+max 비교) → `score[t]`, 최댓값.
3. **P_EXP**: `exp_unit`으로 `exp(score-max)` → `ev[t]`, 합 `sum_e` 누산.
4. **P_WSUM**: 성분별 분자 `Σ(e·v)`를 `num[d]`에 누산(s를 컨텍스트에 걸쳐 스윕).
5. **P_WDIV**: HEAD_DIM개 `udiv`를 **동시 발사**(공유 `d_start`) → 헤드당 나눗셈 지연 1회.
6. **P_WWB**: 결과를 `o_base`에 기록 → **P_NEXTH**로 다음 헤드.

- **핵심 최적화**: 한 헤드의 6개 출력이 같은 분모를 공유하므로 병렬 나눗셈으로 처리(스테이지 4, 44,919 tok/s).
- **read-ahead**: 지연 인덱스(`s_d`, `d_d`)로 등록 읽기의 1사이클 지연을 정렬.

## 14.5 고정소수점 지수 (`exp_unit.sv`)

**알고리즘**: 파이프라인(지연 1) 테이블 + 선형 보간.

1. **스테이지 1(조합)**: `|z|`에서 정수부 `ui`, 소수부 `uf` 추출, `exp_tab_rom(ui)`/`(ui+1)` 조회.
2. **파이프 레지스터**: `lo_r`, `hi_r`, `uf_r`, `pos_r`, `big_r`로 컷.
3. **스테이지 2(조합)**: `interp = lo + (hi-lo)·uf >>> 11`, 특수값(z≥0→2048, ui≥16→0) 클램프.

- 감소 함수 테이블(17항목)에 구간 선형 보간 → 곱셈 1회. 파이프 컷으로 Fmax 개선.

## 14.6 정수 제곱근 (`isqrt.sv`)

**알고리즘**: 비트-페어(비복원) 제곱근, W/2 사이클.

- 4의 거듭제곱 비트마스크 `bitm`을 상위부터 내려가며, 매 사이클 `res+bitm`과 `op` 비교:
  크면 `op -= res+bitm`, `res = (res>>1)+bitm`; 작으면 `res >>= 1`. `bitm >>= 2`.
- 마지막 사이클에서 최종 $\lfloor\sqrt{\cdot}\rfloor$을 `root`에 노출. Python `math.isqrt`와 비트 일치.

## 14.7 Radix-4 정수 나눗셈 (`udiv.sv`)

**알고리즘**: 복원 나눗셈, MSB 우선, **사이클당 몫 2비트**, W/2 사이클.

- 매 사이클 부분 나머지를 4배 시프트하고 피제수 상위 2비트를 내려받음.
- `d1=den`, `d2=2den`, `d3=3den`을 미리 계산해 `rshift`와 비교, 몫 자릿수 `qd∈{0,1,2,3}` 결정.
- `rem = rshift - qd·den`, `q = {q, qd}`. `den=0`이면 all-ones 가드.
- radix-2와 **비트 동일한** floor 몫·나머지를 절반 사이클에 산출(스테이지 5, 51,914 tok/s). 나머지는 샘플러 모듈로에 재사용.

## 14.8 토큰 샘플러 (`sampler.sv`)

**알고리즘**: 5-상태 FSM, 그리디 또는 온도 softmax 범주형.

1. **S_SCALE**: logit을 등록 후 `·inv_temp>>F`로 온도 스케일, `scaled[]`·최댓값 계산, 동시에 그리디 argmax 추적.
2. (그리디면 argmax 토큰으로 종료.)
3. **S_EXP**: `exp(scaled-max)` → `ev[]`, 총합 `total`. LCG로 난수 `rngs` 진행.
4. **S_MOD**: `udiv`의 **나머지**로 `rngs mod total = rval`(별도 곱셈 불필요).
5. **S_PICK**: 누적합이 처음 `rval`을 초과하는 토큰 선택(역-CDF 샘플링).

- **LCG**: `rng·1664525 + 1013904223`. 결정론적 → 소프트웨어 골든과 비트 일치.

## 14.9 임베딩 조회 (`embed.sv`)

**알고리즘**: `tbase=token·N_EMBED`, `pbase=pos·N_EMBED`로 두 ROM을 인덱싱해
`sat16(tok_emb + pos_emb)`를 `dst_base+i`에 순차 기록(N_EMBED 사이클). 조합 case 함수 ROM 사용.

## 14.10 원소별 벡터 연산 (`vecop.sv`)

**알고리즘**:
- **ADD**: `S_LOADA`에서 벡터 a를 `areg` 캐시에 읽어들인 뒤(read-ahead), `S_COMB`에서 b를
  스트리밍하며 `sat16(a+b)` 기록(잔차 덧셈).
- **RELU**: 캐시 생략, `S_COMB`에서 a를 스트리밍하며 `v_rdata[15] ? 0 : v_rdata` 기록.

## 14.11 듀얼 포트 스크래치패드 접근 (`vmem.sv`, `vmem2.sv`)

**알고리즘**: 등록 읽기 BRAM. `vmem`은 1읽기+1쓰기, `vmem2`는 진정한 듀얼 포트(포트당 독립 always).
액추에이터가 주소를 한 사이클 먼저 제시하고 다음 사이클 데이터 소비(read-ahead) → 2읽기 또는 2쓰기/사이클.

## 14.12 자기회귀 이름 생성 루프 (`name_generator.sv`)

**알고리즘**: 4-상태 FSM(`G_IDLE`/`G_FIRE`/`G_WAIT`/`G_DONE`).

- 각 반복: `cur_token`/`pos`/`rng`를 코어에 넘겨 `core_start` 펄스 → `core_done` 대기 →
  결과 토큰을 다음 입력으로 피드백, `pos++`, `rng=core_rng`.
- 구분자(0) 또는 `pos==MAX_LEN-1`에서 종료. `name_buf`에 `token-1`을 저장(표시 매핑).

## 14.13 HD44780 LCD 컨트롤러 (`lcd_hd44780.sv`)

**알고리즘**: 이중 FSM.

- **메인 페이즈 FSM**: POWERON(~40ms) → INIT(8-op 초기화) → LATCH(라인 스냅샷) →
  ADDR1/CHARS1(1행) → ADDR2/CHARS2(2행) → LATCH 반복(연속 재드로).
- **바이트 전송 서브-FSM**: 각 바이트를 상위/하위 니블로 나눠 각 니블마다 setup(tAS) → E high → settle.
  `is_nibble`이면 상위 니블만(8→4비트 전환).
- **tear-free**: 프레임 시작 시 `l1_buf`/`l2_buf`로 스냅샷. 모든 지연은 `CLK_HZ` 파생(실시간).

## 14.14 로터리 쿼드러처 디코드 + 디바운스 (`rotary_throttle.sv`)

**알고리즘**:
- **동기화+디글리치**: 비동기 A/B/push를 2-FF 동기화 후 카운터로 안정화(FILTER 사이클).
- **쿼드러처 디코드**: 상태 전이 `tr={ab_d, ab}`로 up/dn 엣지 판정, `acc`에 부호 있는 엣지 누산,
  `EDGES_PER_DETENT=4`마다 한 디텐트로 설정값(±1) 변경.
- **모드 토글**: 디바운스된 push 상승 엣지로 `cfg_mode`(RATE/TEMP) 전환.
- **지수적 간격**: `interval = CLK_HZ >> speed_level`, `timer`가 만료되고 코어가 idle이면 `auto_start` 펄스.
- **스타트업 홀드오프**: `STARTUP_HOLD`(~200ms) 동안 무장 해제.

## 14.15 BCD 초당 토큰 미터 (`tok_meter.sv`)

**알고리즘**: 이진→십진 나눗셈 없이 처음부터 BCD 리플 캐리로 계수.

- `token_valid`마다 `d0`++, 9에서 넘치면 상위 자릿수로 캐리 전파(`d0→d1→d2→d3→d4`).
- `at_cap`(99999)에서 포화. `sec_timer`가 `CLK_HZ-1`에 도달하면 `tok_bcd`에 5자리 발행 후 리셋.

## 14.16 클럭 합성·리셋·버튼 디바운스 (`xupv5_microgpt_top.sv`)

**알고리즘**:
- **MMCM 클럭 합성**: `MMCME4_BASE`로 100 MHz → 80 MHz(×12/15: VCO 1200 MHz), `BUFG` 피드백으로
  deskew/lock. (원래 Virtex-5 `DCM_BASE` CLKFX ×4/5를 대체.)
- **리셋 디바운스**: `rst_btn`을 2-FF 동기화 후 `RST_FILTER`(~2ms) 안정 시 동기 리셋 갱신,
  MMCM lock까지 리셋 유지.
- **버튼 디바운스**: `start_btn`을 같은 방식으로 걸러 상승 엣지 펄스 생성(단, 이 보드에선 트리거로 미사용).
- **1 Hz 하트비트**: 카운터로 0.5초마다 토글해 `led[7]`에 클럭 검증 표시.

---

