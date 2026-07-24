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
make -C sim            # 모든 테스트벤치 빌드 + 실행
make -C sim tb_core    # 하나만 빌드 + 실행
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

이 변경들은 ISE(iSim) 흐름과도 호환됩니다(상대 경로 검색은 XST에서도 동작).

## 참고: 경고에 대하여

빌드 시 나오던 `WIDTH`(넓은 중간 표현식)·`PINMISSING`(`udiv.rem_out` 미연결) 경고는
의도된 설계로 무해하며, `-Wno-WIDTH -Wno-PINMISSING`으로 억제했습니다. 모든 테스트벤치가
Python 레퍼런스와 **비트 단위로 일치**하므로 시뮬레이션 정확성에는 영향이 없습니다.

## iSim과의 관계

기존 iSim 흐름(README의 `fuse`/`isim_run.tcl`)은 그대로 유효합니다. Verilator는 오픈소스
도구만으로 동일한 골든 검증을 수행하는 대안 경로입니다.
