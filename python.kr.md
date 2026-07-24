# gateGPT에서 사용한 Python 문법·라이브러리 함수 정리

이 문서는 gateGPT 저장소의 `tools/*.py`에서 사용한 **모든 Python 언어 문법과 라이브러리 함수**를
상세히 정리합니다. 각 항목이 어느 파일에 쓰였는지도 함께 표기합니다.

**대상 파일 (8개)**
`model.py`, `fixedpoint.py`, `train.py`, `export.py`, `ucode_asm.py`, `check_quant.py`,
`dump_attn.py`, `dump_test.py`

**사용 라이브러리**: 표준 라이브러리(`math`, `os`, `dataclasses`), `numpy`, `torch`(PyTorch).

---

## 1. Python 언어 문법 (Core Syntax)

### 1.1 클래스와 상속

```python
class RMSNorm(nn.Module):
    def __init__(self, dim, eps=1e-5):
        super().__init__()          # 부모 클래스 초기화
        self.gain = nn.Parameter(...)
    def forward(self, x):
        return ...
```

| 문법 | 설명 | 사용처 |
|---|---|---|
| `class X(Base):` | 클래스 정의 + 상속(`nn.Module`) | `model.py`, `fixedpoint.py` |
| `super().__init__()` | 부모 생성자 호출 | `model.py` 모든 모듈 |
| `def __init__(self, ...)` | 생성자 메서드 | 전반 |
| `def forward(self, x)` | PyTorch 순전파 규약 메서드 | `model.py` |
| `self.attr = ...` | 인스턴스 속성 | 전반 |
| 메서드 정의 (`attn_debug`, `logits_last`) | QModel의 일반 메서드 | `fixedpoint.py` |

### 1.2 데이터클래스 (`@dataclass`)

```python
from dataclasses import dataclass

@dataclass
class ModelConfig:
    vocab_size: int = 27      # 타입 어노테이션 + 기본값
    block_size: int = 16
```

- **데코레이터** `@dataclass`가 `__init__` 등을 자동 생성.
- **타입 어노테이션**(`: int`)과 **필드 기본값**(`= 27`). (`model.py`)

### 1.3 함수 정의와 인자

| 문법 | 예시 | 사용처 |
|---|---|---|
| 기본 인자 | `def q(x):`, `def exp_neg_q11(z):` | `fixedpoint.py` |
| 기본값 인자 | `def generate(model, seed, inv_temp_q11, max_len=None, greedy=False)` | `fixedpoint.py` |
| 키워드 인자 호출 | `write_func_vh(..., signed=True)`, `generate(m, 0, ..., greedy=True)` | `export.py` |
| 다중 반환값(튜플) | `return toks, s` / `return qlast, k, v, attn_out` | `fixedpoint.py` |
| 가변 딕셔너리 언패킹 | `np.savez(path, **sd)` | `train.py` |

### 1.4 람다 함수

```python
qz = lambda name: np.array([[q(v) for v in row] for row in sd[name]], dtype=np.int64)
```

- 익명 함수로 반복되는 양자화 로직을 캡슐화. (`fixedpoint.py` QModel)

### 1.5 컴프리헨션 (Comprehensions)

| 종류 | 예시 | 사용처 |
|---|---|---|
| 리스트 컴프리헨션 | `[stoi[c] for c in w]` | `train.py` |
| 중첩 리스트 컴프리헨션 | `[[q(v) for v in row] for row in sd[...]]` | `fixedpoint.py`, `export.py` |
| 조건 포함 컴프리헨션 | `[hh if hh > 0 else 0 for hh in h1]` (ReLU) | `fixedpoint.py` |
| 제너레이터 표현식 | `sum(p.numel() for p in model.parameters())` | `train.py` |
| 제너레이터 표현식 | `sum(e[s] * int(v[s][...]) for s in range(T))` | `fixedpoint.py` |

### 1.6 조건·반복 제어

| 문법 | 예시 | 사용처 |
|---|---|---|
| 삼항 조건식 | `-qq if (a < 0) != (b < 0) else qq` | `fixedpoint.py` tdiv |
| 삼항 조건식(포화) | `QMAX if v > QMAX else (QMIN if v < QMIN else int(v))` | `fixedpoint.py` sat16 |
| `for i in range(n)` | 인덱스 반복 | 전반 |
| `enumerate` | `for i, v in enumerate(values)` | `export.py` |
| `for k, v in dict.items()` | 딕셔너리 순회 | `export.py`, `ucode_asm.py` |
| `break` | 샘플링 종료 | `fixedpoint.py` generate |
| `if __name__ == "__main__":` | 스크립트 진입점 | 전반 |

### 1.7 문자열 포매팅 (f-string과 포맷 스펙)

```python
f"{int(v) & 0xFFFF:04x}\n"                 # 16진수 4자리 0채움
f"{w & ((1 << 72) - 1):018x}\n"            # 18자리 16진수
f"{func_name} = {ret_w}'h{v & ((1<<ret_w)-1):0{nh}x};"   # 동적 폭 (0{nh}x)
f"step {step:5d}  loss {loss.item():.4f}"  # 정수 폭 + 부동소수점 4자리
f"  seed={seed:2d}  {s}"
```

| 포맷 스펙 | 의미 | 사용처 |
|---|---|---|
| `:04x` | 4자리 16진수, 0 채움 | `export.py`, `dump_*.py` |
| `:018x` | 18자리 16진수 | `ucode_asm.py` |
| `:0{nh}x` | 폭을 변수로 지정(중첩 포맷) | `export.py` write_func_vh |
| `:5d`, `:2d` | 정수 폭 지정 | `train.py`, `check_quant.py` |
| `:.4f` | 부동소수점 소수 4자리 | `train.py` |

### 1.8 비트 연산과 정수 산술

| 연산 | 의미 | 사용처 |
|---|---|---|
| `<<`, `>>` | 시프트 (`1 << FRAC`, `u >> FRAC`) | `fixedpoint.py`, `ucode_asm.py` |
| `&` | 비트 AND / 마스킹 (`u & (SCALE-1)`, `& 0xFFFF`) | 전반 |
| `\|` | 비트 OR (워드 패킹 `word \|= ...`) | `export.py`, `ucode_asm.py` |
| `//` | 정수 나눗셈(floor) (`ss // n`, `mean_sq // ...`) | `fixedpoint.py` |
| `%` | 모듈로 (`rng % total`) | `fixedpoint.py` |
| `**` | 거듭제곱 (`cfg.head_dim ** -0.5`) | `model.py` |
| 복합 대입 | `acc += ei`, `word += ...`, `se = sum(e)` | 전반 |

### 1.9 슬라이싱과 인덱싱

```python
toks[:-1], toks[1:]            # 시퀀스 슬라이스 (x, y 쌍 생성)
x + [0] * (B - L)             # 리스트 반복 + 연결 (패딩)
sl = slice(h * D, (h + 1) * D)  # slice 객체 생성 → 헤드 슬라이스
qlast[sl]                      # slice 객체로 인덱싱
```

- **`slice()` 객체**를 만들어 넘파이 배열에 재사용(헤드별 차원 슬라이스). (`fixedpoint.py`)

### 1.10 기타 내장 함수

| 함수 | 용도 | 사용처 |
|---|---|---|
| `int()`, `abs()` | 형변환/절댓값 | `fixedpoint.py` |
| `max()`, `min()` | 최대/최소 (softmax, 클램프) | `fixedpoint.py`, `dump_test.py` |
| `sum()` | 합 (softmax 분모, 파라미터 수) | 전반 |
| `len()` | 길이 | 전반 |
| `range()`, `reversed()` | 반복 (`reversed(range(lanes))`) | `export.py` |
| `chr()`, `ord()` | 문자↔코드 (`chr(ord("a") + t - 1)`) | 전반 |
| `"".join(...)` | 문자열 결합 | `fixedpoint.py`, `train.py` |
| `enumerate()` | 인덱스+값 | `export.py` |
| `dict(...)` | 딕셔너리 생성 (`dict(TMP=0, ...)`, `dict(np.load(...))`) | `ucode_asm.py`, 전반 |
| `open(...)` (컨텍스트 매니저) | `with open(path, "w") as f:` | 전반 |
| `print()` | 출력 | 전반 |
| `assert` | 불변식 검증 (`assert in_dim % 2 == 0`) | `export.py` |

---

## 2. 표준 라이브러리

### 2.1 `math` 모듈 (`fixedpoint.py`, `export.py`)

| 함수 | 수식/용도 | 사용처 |
|---|---|---|
| `math.floor(x)` | 내림 (양자화 반올림 `floor(x*SCALE+0.5)`) | `q`, `EXP_TAB` |
| `math.exp(x)` | 지수 함수 (exp 테이블 생성 `exp(-k)`) | `EXP_TAB` |
| `math.sqrt(x)` | 제곱근 (어텐션 스케일 `1/sqrt(head_dim)`) | QModel.__init__ |
| `math.isqrt(n)` | **정수 제곱근**(floor) — RMSNorm의 하드웨어 isqrt와 정확히 일치 | `rmsnorm` |

> `math.isqrt`는 부동소수점 오차 없이 $\lfloor\sqrt{n}\rfloor$을 반환 → RTL `isqrt.sv`와 비트 일치.

### 2.2 `os.path` 모듈 (파일 경로, 전반)

```python
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GEN  = os.path.join(ROOT, "generated")
os.makedirs(GEN, exist_ok=True)
```

| 함수 | 용도 | 사용처 |
|---|---|---|
| `os.path.abspath(__file__)` | 현재 스크립트 절대 경로 | 전반 |
| `os.path.dirname(p)` | 디렉터리 경로 추출 | 전반 |
| `os.path.join(a, b)` | 경로 결합(OS 독립) | 전반 |
| `os.makedirs(p, exist_ok=True)` | 디렉터리 생성(존재 시 무시) | `export.py` |

### 2.3 `dataclasses` 모듈

- `from dataclasses import dataclass` → `@dataclass` 데코레이터. (`model.py`) §1.2 참조.

---

## 3. NumPy (`np`)

`fixedpoint.py`, `export.py`, `train.py`, `check_quant.py`, `dump_attn.py`, `dump_test.py`에서 사용.

### 3.1 배열 생성

| 함수 | 용도 | 사용처 |
|---|---|---|
| `np.array(..., dtype=np.int64)` | 리스트→배열, dtype 지정 | 전반 |
| `np.asarray(x)` | 배열 변환(복사 회피) | `export.py` |
| `np.empty((T, N), dtype=...)` | 미초기화 배열 | `fixedpoint.py` |
| `np.zeros(N, dtype=...)` | 0 배열 (attn_out 누산) | `fixedpoint.py` |
| `np.full(N, 2048, dtype=...)` | 상수 채움 배열 (테스트 입력 ones) | `dump_test.py` |

### 3.2 dtype과 형변환

| 항목 | 용도 | 사용처 |
|---|---|---|
| `np.int64` | 64비트 정수(오버플로 방지 누산) | 전반 |
| `.astype(np.int64)` | dtype 변환 (MAC 전 확장) | `fixedpoint.py` matvec |

### 3.3 배열 연산

| 연산/메서드 | 용도 | 사용처 |
|---|---|---|
| `A @ x` | 행렬-벡터 곱(matmul 연산자) | `fixedpoint.py` matvec |
| `.reshape(-1)` | 평탄화(1차원) | `export.py`, `dump_*.py` |
| `.sum()` | 원소 합 (제곱합 `(x**2).sum()`) | `fixedpoint.py` rmsnorm |
| `** 2` | 원소별 제곱 | `fixedpoint.py` rmsnorm |
| `.shape` | 배열 형상 (`out_dim, in_dim = W.shape`) | `export.py` |
| `.size` | 원소 개수 (`flat.size`) | `export.py` |
| `np.argmax(logits)` | 최댓값 인덱스(그리디 디코딩) | `fixedpoint.py` generate |
| 인덱싱/슬라이싱 | `x[t]`, `v[s][h*D+d]`, `qlast[sl]` | `fixedpoint.py` |

### 3.4 파일 입출력 (`.npz`)

| 함수 | 용도 | 사용처 |
|---|---|---|
| `np.savez(path, **sd)` | 여러 배열을 압축 저장 | `train.py` |
| `np.load(path)` | `.npz` 로드 | `export.py`, `dump_*.py`, `check_quant.py` |
| `dict(np.load(...))` | NpzFile → 딕셔너리 변환 | 전반 |

---

## 4. PyTorch (`torch`)

`model.py`, `train.py`에서 사용. 모델 정의·학습·부동소수점 샘플링 담당.

### 4.1 `torch.nn` — 신경망 모듈 (`model.py`)

| 클래스/함수 | 용도 | 사용처 |
|---|---|---|
| `nn.Module` | 모든 신경망 모듈의 기반 클래스 | 전반 |
| `nn.Parameter(torch.ones(dim))` | 학습 가능 파라미터(RMSNorm 게인) | RMSNorm |
| `nn.Linear(in, out, bias=False)` | 선형 계층(바이어스 없음) | Attention, MLP, lm_head |
| `nn.Embedding(num, dim)` | 임베딩 룩업 테이블 | tok_embed, pos_embed |
| `nn.ModuleList([...])` | 서브모듈 리스트(블록들) | NamesGPT |
| `self.register_buffer("mask", ...)` | 비학습 버퍼 등록(인과 마스크) | CausalAttention |

### 4.2 텐서 생성·조작 (`model.py`, `train.py`)

| 함수/메서드 | 용도 | 사용처 |
|---|---|---|
| `torch.ones(dim)` | 1 텐서 | RMSNorm 게인 초기화 |
| `torch.tril(torch.ones(B, B))` | 하삼각 행렬(인과 마스크) | CausalAttention |
| `torch.arange(T, device=...)` | 위치 인덱스 | NamesGPT.forward |
| `torch.tensor(X)` | 리스트→텐서 | train.py 데이터셋 |
| `.view(B, T, n_head, head_dim)` | 형상 변경(멀티헤드 분리) | CausalAttention |
| `.transpose(1, 2)` | 축 교환 | CausalAttention |
| `.contiguous()` | 메모리 연속화(view 전) | CausalAttention |
| `.reshape(-1, V)` | 손실 계산용 평탄화 | train.py |
| `.shape` | 형상 언패킹 (`B, T, C = x.shape`) | 전반 |
| `@` (matmul) | `q @ k.transpose(-2,-1)`, `att @ v` | CausalAttention |
| `.masked_fill(mask==0, float("-inf"))` | 마스킹(미래 위치 차단) | CausalAttention |

### 4.3 함수형 API `torch.nn.functional` (`F`)

| 함수 | 수식/용도 | 사용처 |
|---|---|---|
| `F.softmax(att, dim=-1)` | Softmax 정규화 | CausalAttention |
| `F.relu(x)` | ReLU 활성화 | MLP |
| `F.cross_entropy(logits, y, reduction="none")` | 교차 엔트로피 손실(위치별) | train.py |
| `torch.rsqrt(ms + eps)` | 역제곱근 $1/\sqrt{\cdot}$ | RMSNorm |
| `.pow(2).mean(dim=-1, keepdim=True)` | 제곱→평균(제곱평균) | RMSNorm |

### 4.4 학습 루프 (`train.py`)

| 함수/메서드 | 용도 |
|---|---|
| `torch.manual_seed(SEED)` | 재현성 시드 고정 |
| `torch.optim.AdamW(params, lr=..., weight_decay=...)` | AdamW 옵티마이저 |
| `torch.randint(0, n, (bs,))` | 랜덤 배치 인덱스 |
| `model.parameters()` | 파라미터 이터레이터 |
| `p.numel()` | 파라미터 원소 수 |
| `opt.zero_grad()` | 그래디언트 초기화 |
| `loss.backward()` | 역전파 |
| `opt.step()` | 파라미터 갱신 |
| `loss.item()` | 스칼라 텐서→파이썬 수 |

### 4.5 상태 저장과 추론 (`train.py`)

| 함수/메서드 | 용도 |
|---|---|
| `model.state_dict()` | 파라미터 딕셔너리 |
| `.detach().cpu().numpy()` | 그래프 분리→CPU→넘파이 변환(저장용) |
| `model.eval()` | 평가 모드 전환 |
| `torch.Generator().manual_seed(7)` | 결정론적 난수 생성기 |
| `F.softmax(logits / 0.7, dim=-1)` | 온도 스케일 softmax(샘플링) |
| `torch.multinomial(p, 1, generator=g)` | 범주형 샘플링 |
| `.item()` | 텐서→파이썬 정수 |

---

## 5. 파일별 사용 요약

| 파일 | 주요 문법/라이브러리 |
|---|---|
| `model.py` | `@dataclass`, `nn.Module`/`Linear`/`Embedding`/`ModuleList`/`Parameter`, `register_buffer`, 텐서 조작, `F.softmax`/`relu`, `torch.rsqrt`/`tril`/`arange` |
| `fixedpoint.py` | 클래스/메서드, 람다, 컴프리헨션, 삼항식, 비트 연산, `math.isqrt`/`floor`/`exp`, `np.array`/`@`/`argmax`, `slice()` |
| `train.py` | `os.path`, `np.savez`, `torch.optim.AdamW`, 학습 루프, `torch.multinomial`, `Generator`, f-string |
| `export.py` | 파일 쓰기, 중첩 컴프리헨션, 동적 f-string 폭(`0{nh}x`), `assert`, `enumerate`, `reversed`, 비트 패킹 |
| `ucode_asm.py` | 비트 필드 패킹(`<<`/`\|`/`&`), `dict(...)`, `.items()`, f-string(`:018x`) |
| `check_quant.py` | `np.load`, QModel 사용, f-string |
| `dump_attn.py` | `np.load`, 배열 리드백, 16진수 쓰기 |
| `dump_test.py` | `np.full`, `max`/`min` 클램프, 리스트 연결, 16진수 쓰기 |

---

## 부록: 핵심 관용구 (Idioms)

### A. 프로젝트 루트 기준 경로 (전 스크립트)
```python
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
```
스크립트 위치 기준으로 절대 경로를 잡아 어디서 실행해도 동작.

### B. 16진수 ROM 쓰기 (`export.py`, `dump_*.py`)
```python
with open(path, "w") as f:
    for v in flat:
        f.write(f"{int(v) & 0xFFFF:04x}\n")
```
`& 0xFFFF`로 16비트 2의 보수 표현, `:04x`로 4자리 0채움.

### C. 넓은 정수 누산 후 리스케일 (`fixedpoint.py`)
```python
acc = W_q.astype(np.int64) @ x_q.astype(np.int64)
return np.array([sat16(int(a) >> FRAC) for a in acc], dtype=np.int64)
```
int64로 오버플로 없이 MAC → 산술 시프트 → 포화. RTL과 비트 일치의 핵심 관용구.

### D. 비트 필드 패킹 (`ucode_asm.py`)
```python
w = (op & 0xF)
w |= (wsel & 0xF) << 4
w |= (in_dim & 0x7F) << 8
```
마이크로코드 명령을 72비트 워드로 인코딩(마스크 + 시프트 + OR).
