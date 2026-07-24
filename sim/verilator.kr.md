# Verilator 시뮬레이션 가이드

이 문서는 gateGPT의 RTL을 **Verilator**(오픈소스 Verilog 시뮬레이터)로 시뮬레이션하는 방법을
설명합니다. 기존 iSim(Xilinx) 골든 테스트벤치를 그대로 사용하며, 별도의 C++ 래퍼 없이
Verilator의 `--binary --timing` 모드로 컴파일·실행합니다.

## 요구 사항

- **Verilator ≥ 5.006** (`--binary`와 `--timing` 지원 필요). 5.020에서 검증됨.
- C++ 컴파일러(`g++`)와 `make`.

설치 (Debian/Ubuntu):
```bash
sudo apt-get install verilator
```

## 빠른 시작

```bash
make -C sim            # 모든 테스트벤치 빌드 + 실행 (유닛 6개 + 보드 TOP)
make -C sim tb_core    # 하나만 빌드 + 실행
make -C sim tb_top     # 보드 최상위(xupv5_microgpt_top) 시뮬레이션
make -C sim lint       # 정적 lint만 수행(-Wall), 빌드/실행 없음
make -C sim clean      # 빌드 산출물 삭제
```

## 실행 결과 (기대 출력)

```
MATHOPS PASS
EXP PASS: all 103 cases match
MATVEC PASS: all 24 outputs match
NORM PASS: all 24 outputs match
ATTN PASS: all 24 outputs match
CYCLES_PER_TOKEN = 1157
greedy tokens: 1 12 1 25 1
AVG_CYCLES = 1322 over 12 tokens (last=1489)
sampled tokens: 18 15 19 16 8 15 4
CORE PASS: greedy + sampled match golden
```

- 그리디 결과 `1 12 1 25 1` = **alaya**, 샘플 결과(시드 2·T=0.7) `18 15 19 16 8 15 4` = **rosphod**
  — README의 골든과 일치합니다.
- 사이클 수(첫 토큰 1157, 평균 1322, 최장 1489)도 README 수치와 일치합니다.

## 테스트벤치 목록

| 타깃 | 검증 대상 | 골든 소스 |
|---|---|---|
| `tb_mathops` | `udiv`(radix-4), `isqrt`(비트-페어) | 하드코딩된 레퍼런스 값 |
| `tb_exp` | `exp_unit` (테이블+보간) | `generated/test_exp_*.hex` |
| `tb_matvec` | `matvec` + `wrom` + `vmem2` | `generated/test_in/wq.hex` |
| `tb_norm` | `norm` + `grom` + `udiv` + `isqrt` | `generated/test_norm_*.hex` |
| `tb_attn` | `attn` + `exp_unit` + `udiv` + `vmem` | `generated/test_attn_*.hex` |
| `tb_core` | 전체 `microgpt_core` 엔드투엔드 | `core/*.vh` (마이크로코드/가중치) |
| `tb_top`  | **보드 최상위** `xupv5_microgpt_top` (MMCM·리셋·로터리·LCD·미터+코어) | 내부 자기생성 이름 |

## 동작 원리

- **`--binary`**: Verilog 테스트벤치를 네이티브 실행 파일로 컴파일(각 `tb_*.v`가 자체 top 모듈).
- **`--timing`**: 테스트벤치의 `#delay`, `wait()`, `@(negedge clk)`, `always #5 clk = ~clk` 등
  이벤트/타이밍 구문을 지원(Verilator 5.x 기능).
- **`-I<repo>/core`**: 코어가 `` `include "core_params.vh" `` 등으로 참조하는 생성된 `.vh`
  (마이크로코드 ROM, 가중치, exp 테이블, 임베딩)를 찾는 검색 경로.
- 컴파일된 바이너리는 **저장소 루트에서 실행**됩니다 → 테스트벤치의
  `$readmemh("generated/*.hex", ...)` 상대 경로가 해결됩니다. (Makefile이 자동 처리)

## 이식성을 위한 변경 사항

원본은 특정 머신의 절대 경로를 사용했으나, Verilator/iverilog/iSim 어디서나 동작하도록 수정했습니다:

1. **RTL `` `include `` 경로**: `/home/hermes/microgpt_fpga/core/xxx.vh` → `xxx.vh` (파일 헤더만).
   - XST·iverilog는 인클루드하는 파일의 디렉터리를 검색하고, Verilator는 `-Icore`로 찾습니다.
2. **테스트벤치 `$readmemh` 경로**: 절대 경로 → `generated/xxx.hex` (저장소 루트 기준 상대 경로).
3. **`tb_exp`의 배열 크기**: `M=102` → `M=103`(실제 exp 케이스 수와 정확히 일치).
   Verilator는 파일이 배열보다 크면 치명 오류를 내고, 미사용 항목의 `x` 센티넬을
   보존하지 않으므로 정확한 개수로 맞췄습니다.

원래 흐름은 ISE 14.7(iSim)이었으나 현재는 Vivado 24.2로 전환됨(아래 참조).

## Lint (정적 검사) — 완전히 깨끗한 `-Wall`

`make -C sim lint`은 합성 대상 보드 최상위와 7개 테스트벤치 top을 **빌드 없이** `-Wall`로 lint합니다.

```
== lint xupv5_microgpt_top     clean
== lint tb_mathops             clean
...
LINT CLEAN: board top + all testbenches (-Wall)
```

깨끗한 트리는 경고 0개를 보고하며, **새로운** 경고가 생기면 타깃이 실패합니다(`set -e`).

### waiver 파일 `sim/gategpt.vlt`

`WIDTH`(의도된 넓은 고정소수점 중간 표현식)·`PINCONNECTEMPTY`/`PINMISSING`(미사용 예비 핀,
`udiv.rem_out`)·`UNUSEDSIGNAL`·`SYNCASYNCNET`(DCM 비동기 리셋) 등 **검토를 마친 의도된** 경고 범주는
Verilator 공식 waiver 파일 `sim/gategpt.vlt`로 처리합니다.

- **RTL을 전혀 수정하지 않습니다** → 비트 일치·Vivado 합성에 무영향. Verilator 전용이며 Vivado 프로젝트에 포함되지 않음.
- 빌드(`--binary`)와 lint(`--lint-only`) 모두 이 waiver를 사용하므로, 별도의 `-Wno-*` 플래그 없이도
  `-Wall`이 깨끗하게 통과합니다.
- 각 waiver에는 왜 무해한지 주석이 달려 있습니다. 모든 테스트벤치가 Python 레퍼런스와 **비트 단위로 일치**합니다.

## 보드 최상위(TOP) 시뮬레이션 — `tb_top`

`xupv5_microgpt_top`은 실제 보드 전체(클럭 합성 → 리셋/버튼 디바운스 → 로터리 스로틀 →
이름 생성기(코어) → HD44780 LCD → 초당 토큰 미터)를 통합합니다. 이를 Verilator로 돌리기 위해
두 가지 장애물을 해결했습니다.

### 1. Xilinx 프리미티브 stub (`sim/xilinx_stubs.sv`)

TOP은 UltraScale+ 클럭 프리미티브 `BUFG`, `MMCME4_BASE`를 인스턴스화하는데, Verilator/iverilog에는
Xilinx UNISIM 라이브러리가 없습니다. `sim/xilinx_stubs.sv`가 이들의 **동작 모델**을 제공합니다:

- `BUFG`: 입력을 출력으로 통과(`assign O = I`).
- `MMCME4_BASE`: `CLKIN1`을 `CLKOUT0`/`CLKFBOUT`으로 통과(사이클 기반 시뮬레이션에서는 x12/15 비가
  무의미 — 전 설계가 단일 테스트벤치 클럭으로 동작), `RST` 해제 몇 사이클 뒤 `LOCKED` 어서트.

> **주의**: 이 stub은 **시뮬레이션 전용**입니다. Vivado 프로젝트에는 포함하지 마세요(거기서는 실제 UNISIM 사용).
> (원래 Virtex-5 `DCM_BASE`를 썼으나 Vivado 미지원으로 UltraScale+ `MMCME4_BASE`로 리타깃됨.)

### 2. `CLK_HZ` 파라미터화

LCD·로터리·미터의 지연이 `CLK_HZ`(실제 80 MHz)에서 파생되어, 80 MHz 그대로면 전원 투입·자동 회전
간격 등이 수천만 사이클이 됩니다. TOP의 `CLK_HZ`를 `localparam` → **`parameter`**(기본값 80 MHz 유지,
합성 무영향)로 바꿔, 시뮬레이션 top이 작은 값으로 오버라이드할 수 있게 했습니다.

`tb_top`은 `#(.CLK_HZ(12_500_000))`으로 오버라이드합니다.
- **하한 12.5 MHz 제약**: LCD 셋업 지연 `SU_CYC = CLK_HZ/12_500_000`이 0이 되면(=CLK_HZ<12.5M)
  LCD FSM이 멈추므로, 이 값 이상이어야 합니다.

### 시뮬레이션 흐름

1. 리셋 펄스 해제 → `dut.mmcm_locked` 대기(stub이 곧 어서트).
2. 로터리 스타트업 홀드(`CLK_HZ/5` ≈ 2.5M 사이클) 만료(`dut.u_rot.armed`) 대기.
3. 로터리를 **시계방향으로 구동**(쿼드러처 `00→01→11→10→00` 시퀀스, 디글리치 FILTER보다 길게 유지)하여
   `speed_level`을 올림 → 자동 생성 간격 단축.
4. 첫 이름 생성(`dut.gen_done`)을 포착해 ASCII로 디코드·출력.
5. 이름 길이·MMCM lock 검증 후 `TOP PASS`. 사이클 워치독으로 종료 보장(무한 정지 없음).

### 기대 출력

```
[cycle 38] MMCM locked
[cycle 2600032] rotary armed, raising speed...
[cycle 2664031] speed_level=4
generated name: sivont   (len=6)
TOP PASS: board booted (MMCM locked, LCD driving) and generated a name
```

- 생성되는 이름은 시드(=자유 실행 카운터 `seed_live` ^ `dip_sw`)가 발사 시점에 결정되므로 특정 골든이 아닌,
  **유효한 이름 하나가 생성됨**을 확인합니다. 약 2~3초, 수백만 사이클 내 완료됩니다.
- 로터리 구동이 완벽하지 않아도, 자동 회전(1 Hz)의 자연 발사 + 워치독이 안전망 역할을 합니다.

## 합성 흐름과의 관계

RTL이 SystemVerilog로 이관되면서 원래의 ISE 14.7(iSim) 흐름은 폐기되었고, 합성은 **Vivado 24.2**로
전환되었습니다. Vivado는 Virtex-5를 지원하지 않아 보드는 **Kria K26(xck26, KR260)**로
리타깃되었습니다 — `DCM_BASE` → `MMCME4_BASE`, `.ucf` → `board/kr260_microgpt.xdc`, ISE tcl →
`build_board_vivado_project.tcl`. Verilator는 그 합성 RTL을 오픈소스 도구만으로 골든 검증하는
경로이며, `sim/xilinx_stubs.sv`가 Vivado 프리미티브를 대체합니다.
