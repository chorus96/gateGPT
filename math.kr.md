# gateGPT에서 사용한 수학 개념 정리

이 문서는 gateGPT 저장소(부동소수점 레퍼런스 모델 → 고정소수점 양자화 → RTL 하드웨어 구현)
전반에서 사용한 모든 수학 개념을 상세히 정리합니다. 각 개념이 어느 파일/함수에 대응하는지도 함께 표기합니다.

**표기 규약**
- 벡터·행렬은 굵은 소문자/대문자로, 스칼라는 일반 글자로 표기.
- $\lfloor \cdot \rfloor$는 내림, $\gg$는 산술 우측 시프트, $\text{sat}_{16}$은 16비트 부호 있는 포화.
- 모델 상수: $d_\text{model}=24$, 헤드 수 $H=4$, 헤드 차원 $d_h=6$, MLP 히든 $=96$,
  컨텍스트 $T_\max=16$, 어휘 $V=27$, 고정소수점 소수 비트 $\text{FRAC}=11$.

---

## 1. 트랜스포머 모델 수학 (`tools/model.py`)

gateGPT는 **디코더 전용 트랜스포머** 1블록으로 구성된 문자 단위 언어 모델입니다.

### 1.1 임베딩 (Embedding)

입력 토큰 시퀀스 $\mathbf{idx} = (t_0, \dots, t_{T-1})$에 대해, 토큰 임베딩과 **절대 위치 임베딩**을 더합니다:

$$
\mathbf{x}_i = E_\text{tok}[t_i] + E_\text{pos}[i], \quad i = 0, \dots, T-1
$$

- $E_\text{tok} \in \mathbb{R}^{27 \times 24}$, $E_\text{pos} \in \mathbb{R}^{16 \times 24}$.
- **절대 위치**(토큰 $i$는 항상 위치 $i$)를 쓰는 것이 핵심 설계 — 추론 시 KV 캐시를 가능하게 합니다(§5.2).

### 1.2 RMSNorm (Root Mean Square Normalization)

평균 차감이나 바이어스 없이 제곱평균제곱근으로 정규화하고 학습 가능한 게인 $\mathbf{g}$를 곱합니다:

$$
\text{RMSNorm}(\mathbf{x})_i = \frac{x_i}{\sqrt{\frac{1}{d}\sum_{j=1}^{d} x_j^2 + \epsilon}} \cdot g_i
$$

- $\epsilon = 10^{-5}$ (0 나눗셈 방지), $d = d_\text{model} = 24$.
- LayerNorm과 달리 평균을 빼지 않아 하드웨어 구현이 단순합니다(고정소수점 버전은 §4.2).

### 1.3 스케일드 닷-프로덕트 인과적 어텐션 (Scaled Dot-Product Causal Attention)

멀티헤드 어텐션. 각 헤드 $h$에 대해 쿼리·키·값을 선형 projection으로 얻습니다:

$$
Q = XW_Q, \quad K = XW_K, \quad V = XW_V \quad (W_\bullet \in \mathbb{R}^{24 \times 24}, \text{바이어스 없음})
$$

**어텐션 스코어**와 **인과적 마스킹**:

$$
A = \frac{QK^\top}{\sqrt{d_h}}, \qquad A_{ij} \leftarrow
\begin{cases} A_{ij} & j \le i \\ -\infty & j > i \end{cases}
$$

- 스케일 계수 $1/\sqrt{d_h} = 1/\sqrt{6} \approx 0.4082$.
- 인과적 마스크(하삼각 행렬 `tril`)로 미래 위치를 차단 → 자기회귀 생성 보장.

**Softmax**와 값 가중합, 출력 projection:

$$
\text{softmax}(A)_{ij} = \frac{e^{A_{ij}}}{\sum_k e^{A_{ik}}}, \qquad
Y = \text{softmax}(A)\,V, \qquad \text{out} = Y W_O
$$

### 1.4 MLP (Feed-Forward, ReLU)

$$
\text{MLP}(\mathbf{x}) = \text{ReLU}(\mathbf{x} W_1)\, W_2, \qquad
W_1 \in \mathbb{R}^{24 \times 96},\; W_2 \in \mathbb{R}^{96 \times 24}
$$

$$
\text{ReLU}(z) = \max(0, z)
$$

### 1.5 잔차 연결 (Residual / Pre-Norm Block)

사전 정규화(pre-norm) 잔차 구조:

$$
\mathbf{x} \leftarrow \mathbf{x} + \text{Attn}(\text{RMSNorm}_1(\mathbf{x})), \qquad
\mathbf{x} \leftarrow \mathbf{x} + \text{MLP}(\text{RMSNorm}_2(\mathbf{x}))
$$

### 1.6 LM 헤드 (Language Model Head)

최종 RMSNorm 후 로짓(logits)을 계산:

$$
\text{logits} = \text{RMSNorm}_f(\mathbf{x})\, W_\text{lm}, \qquad W_\text{lm} \in \mathbb{R}^{24 \times 27}
$$

---

## 2. 학습 수학 (`tools/train.py`)

### 2.1 교차 엔트로피 손실 (Cross-Entropy Loss)

다음 토큰 예측. 위치 $i$에서 정답 $y_i$에 대한 손실:

$$
\mathcal{L}_i = -\log \frac{e^{\text{logits}_{i,y_i}}}{\sum_{v=1}^{V} e^{\text{logits}_{i,v}}}
= -\text{logits}_{i,y_i} + \log \sum_v e^{\text{logits}_{i,v}}
$$

**패딩 마스킹**: 우측 패딩된 위치는 마스크 $m_i \in \{0,1\}$로 제외한 가중 평균:

$$
\mathcal{L} = \frac{\sum_i m_i \, \mathcal{L}_i}{\sum_i m_i}
$$

### 2.2 AdamW 최적화

가중치 감쇠(weight decay)를 분리한 Adam. 학습률 $\eta = 3\times10^{-3}$, weight decay $= 10^{-4}$.
1차·2차 모멘트 추정 $m_t, v_t$로 파라미터를 갱신:

$$
m_t = \beta_1 m_{t-1} + (1-\beta_1) g_t, \quad
v_t = \beta_2 v_{t-1} + (1-\beta_2) g_t^2
$$

$$
\theta_t = \theta_{t-1} - \eta \left( \frac{\hat{m}_t}{\sqrt{\hat{v}_t}+\epsilon} + \lambda \theta_{t-1} \right)
$$

($\hat{m}_t, \hat{v}_t$는 바이어스 보정된 모멘트, $\lambda$는 weight decay. PyTorch `AdamW` 기본 $\beta$ 사용.)

---

## 3. 고정소수점 수 체계 (`tools/fixedpoint.py`, 전 RTL)

### 3.1 Q5.11 고정소수점 형식

부호 있는 16비트 정수로 실수를 표현. 하위 11비트가 소수부:

$$
\text{실수 } x \;\longleftrightarrow\; \text{정수 } \hat{x} = \text{round}(x \cdot 2^{11}), \qquad
x \approx \frac{\hat{x}}{2048}
$$

- $\text{SCALE} = 2^{11} = 2048$, 표현 범위 $[-16, +16)$, 분해능 $2^{-11} \approx 4.88\times10^{-4}$.
- 부호 있는 16비트 범위: $[-32768, 32767]$.

### 3.2 float → Q5.11 양자화 (반올림)

$$
q(x) = \text{sat}_{16}\big(\lfloor x \cdot 2048 + 0.5 \rfloor\big)
$$

`tools/fixedpoint.q()`. 최근접 반올림 후 포화.

### 3.3 포화 (Saturation)

오버플로를 래핑 대신 클램프:

$$
\text{sat}_{16}(v) = \min\big(32767, \max(-32768, v)\big)
$$

### 3.4 고정소수점 곱셈과 리스케일

두 Q11 수의 곱은 Q22가 되므로 산술 우측 시프트로 Q11로 복원:

$$
\hat{z} = \text{sat}_{16}\!\left( (\hat{x} \cdot \hat{y}) \gg 11 \right)
$$

시프트는 $2^{11}$로 나눈 뒤 내림하는 것과 동치(음수는 $-\infty$ 방향 내림).

### 3.5 0 방향 절삭 나눗셈 (Truncate-Toward-Zero Division)

부호-크기 하드웨어 나눗셈기와 일치하도록, 몫을 0 방향으로 절삭:

$$
\text{tdiv}(a,b) = \text{sign}(a/b)\cdot \left\lfloor \frac{|a|}{|b|} \right\rfloor
$$

`tools/fixedpoint.tdiv()`. 어텐션의 가중합 나눗셈에 사용(§4.3). Python 기본 `//`(floor)와
다르게 음수에서 0 방향으로 자릅니다.

---

## 4. 고정소수점 연산 알고리즘

### 4.1 행렬-벡터 곱 (Matvec, `matvec` / `core/matvec.v`)

$$
y_o = \text{sat}_{16}\!\left( \left( \sum_{i} \hat{W}_{o,i}\, \hat{x}_i \right) \gg \text{descale} \right)
$$

- 넓은(int64/48비트) 누산기로 정확히 합한 뒤 한 번만 리스케일 → 반올림 오차 최소화.
- **타일링**: 출력 행을 LANES=24개 단위 타일로 분할. 하드웨어는 매 사이클 활성값 2개를 읽어
  레인당 2 MAC → 타일당 $\lceil \text{in\_dim}/2 \rceil$ 사이클(§6.1).

### 4.2 RMSNorm의 정수 구현 (`rmsnorm` / `core/norm.v`)

부동소수점 $1/\sqrt{\cdot}$를 **정수 isqrt + 정수 역수**로 대체:

1. 제곱합 (Q22): $\displaystyle ss = \sum_i \hat{x}_i^2$
2. 평균 제곱: $\displaystyle \text{ms} = \max\!\left(1, \left\lfloor \frac{ss}{d} \right\rfloor \right)$
3. 정수 제곱근: $r = \lfloor \sqrt{\text{ms}} \rfloor$ (Q22의 제곱근 → Q11), $r \ge 1$ 보장
4. 역제곱근 스케일 (Q11): $\displaystyle \text{scale} = \min\!\left( \left\lfloor \frac{2^{22}}{r} \right\rfloor, 32767 \right)$
5. 원소별 적용: $\displaystyle y_i = \text{sat}_{16}\!\Big( \text{sat}_{16}(\hat{x}_i \cdot \text{scale} \gg 11) \cdot \hat{g}_i \gg 11 \Big)$

수학적 근거: $\dfrac{2^{22}}{\sqrt{\text{ms}\cdot 2^{22}}/2^{11}\cdot 2^{11}} = \dfrac{1}{\sqrt{\text{ms}/2^{22}}}$
형태로 $1/\sqrt{\text{mean}(x^2)}$의 Q11 근사가 됩니다.

### 4.3 고정소수점 지수 함수 (`exp_neg_q11` / `core/exp_unit.v`)

$z \le 0$ (Q11)에 대해 $e^z$를 **17개 항목 테이블 + 선형 보간**으로 계산:

- 테이블: $\text{EXP\_TAB}[k] = \text{round}(e^{-k}\cdot 2048), \quad k = 0, \dots, 16$
- 입력 분해: $u = -z$, 정수부 $u_i = u \gg 11$, 소수부 $u_f = u \;\&\; (2^{11}-1)$
- 선형 보간:

$$
e^z \approx \text{EXP\_TAB}[u_i] + \big( (\text{EXP\_TAB}[u_i+1] - \text{EXP\_TAB}[u_i]) \cdot u_f \big) \gg 11
$$

- 경계: $z \ge 0 \Rightarrow 2048$, $u_i \ge 16 \Rightarrow 0$.
- 지수 함수의 국소 선형 근사(1차 테일러/구간 선형 보간). 감소 함수이므로 $\text{EXP\_TAB}[u_i+1] \le \text{EXP\_TAB}[u_i]$.

### 4.4 수치적으로 안정한 Softmax (max-subtraction)

오버플로를 막기 위해 최댓값을 빼고 지수화. 이동은 softmax를 불변으로 유지:

$$
\text{softmax}(\mathbf{s})_j = \frac{e^{s_j}}{\sum_k e^{s_k}} = \frac{e^{s_j - m}}{\sum_k e^{s_k - m}}, \quad m = \max_k s_k
$$

- $s_j - m \le 0$이 보장되므로 §4.3의 $e^z\ (z\le0)$ 테이블을 그대로 사용 가능.
- 어텐션(`attn`)과 샘플러(`sampler`)가 동일 기법 사용.

---

## 5. 어텐션·디코딩 수학

### 5.1 헤드별 어텐션 계산 (`attn_debug`, `logits_last` / `core/attn.v`)

헤드 $h$의 슬라이스 $\text{sl} = [h\,d_h, (h{+}1)d_h)$에 대해:

1. 스코어: $\displaystyle s_t = \text{sat}_{16}\!\Big( \text{sat}_{16}(\mathbf{q}_\text{sl}\cdot\mathbf{k}_{t,\text{sl}} \gg 11) \cdot \widehat{\text{scale}} \gg 11 \Big)$, $t = 0,\dots,T-1$
2. Softmax 분자: $e_t = \exp_{Q11}(s_t - \max_t s_t)$, 분모 $S_e = \max(1, \sum_t e_t)$
3. 출력 성분: $\displaystyle \text{out}_{h d_h + d} = \text{sat}_{16}\!\left( \text{tdiv}\Big( \sum_t e_t\, \hat{v}_{t, h d_h + d},\; S_e \Big) \right)$

**병렬 나눗셈**: 한 헤드의 $d_h=6$개 출력 성분은 같은 분모 $S_e$로 나누므로, 분자들을 먼저
누산한 뒤 6개의 나눗셈기로 **동시에** 나눕니다(헤드당 나눗셈 지연 1회).

### 5.2 증분 디코딩과 KV 캐시 (Incremental Decoding)

절대 위치 학습 덕분에 토큰의 K/V는 시퀀스가 길어져도 불변입니다. 따라서 매 스텝 새 토큰의 K/V만
계산해 캐시 슬롯에 저장하고, 저장된 컨텍스트에 어텐션합니다:

$$
K[\text{pos}] = \text{RMSNorm}(\mathbf{x}_\text{pos}) W_K, \quad
V[\text{pos}] = \text{RMSNorm}(\mathbf{x}_\text{pos}) W_V
$$

- 계산 복잡도: 전체 재계산 $O(T^2 d)$ → 증분 $O(T d)$ (스텝당). README의 3.2× 성과의 근거.

---

## 6. 하드웨어 산술 알고리즘 (`core/*.v`)

### 6.1 병렬 곱셈-누산 타일 (Systolic MAC Tile, `core/matvec.v`)

$$
\text{acc}[L] \mathrel{+}= \hat{x}_{2j}\cdot \hat{W}_{L,2j} + \hat{x}_{2j+1}\cdot \hat{W}_{L,2j+1}
$$

- 레인 $L = 0,\dots,23$가 병렬로, 사이클당 2열씩 처리. 48개 DSP48E 사용(§8).

### 6.2 정수 제곱근 (`core/isqrt.v`)

$\text{root} = \lfloor \sqrt{n} \rfloor$을 **비트-페어(비복원) 알고리즘**으로 계산. $W$비트 → $W/2$ 사이클.
4의 거듭제곱 비트마스크 $b_k = 4^k$를 상위부터 내려가며:

$$
\text{if } \text{op} \ge \text{res} + b_k:\quad \text{op} \mathrel{-}= \text{res}+b_k,\; \text{res} \leftarrow (\text{res} \gg 1) + b_k
$$
$$
\text{else}:\quad \text{res} \leftarrow \text{res} \gg 1
$$

Python `math.isqrt`와 비트 동일. 근거: $(\text{res}+b_k)^2$의 자릿수별 전개로 제곱근을 한 비트씩 결정.

### 6.3 Radix-4 정수 나눗셈 (`core/udiv.v`)

부호 없는 복원(restoring) 나눗셈, **사이클당 몫 2비트**(radix-4). MSB부터 부분 나머지를 4배 시프트하며
다음 두 비트를 내려받고, 몫 자릿수 $q_d \in \{0,1,2,3\}$을 선택:

$$
r \leftarrow 4r + (\text{다음 2비트}), \qquad q_d = \max\{ d \in \{0,1,2,3\} : r \ge d\cdot \text{den} \}
$$
$$
r \leftarrow r - q_d\cdot\text{den}, \qquad Q \leftarrow (Q \ll 2) \,|\, q_d
$$

- $d_1=\text{den},\, d_2=2\,\text{den},\, d_3=3\,\text{den}$을 미리 계산해 비교.
- radix-2 나눗셈과 **비트 동일한** floor 몫·나머지를 절반 사이클에 산출. `den=0`이면 all-ones 가드.
- 나머지 $r$은 $\text{num} \bmod \text{den}$이며 샘플러의 모듈로에 재사용(§7.2).

---

## 7. 샘플링 수학 (`generate` / `core/sampler.v`)

### 7.1 온도 스케일링 (Temperature Scaling)

로짓을 온도 $\tau$로 나눠 분포의 뾰족함을 조절. 하드웨어는 $1/\tau$(Q11)를 곱합니다:

$$
\text{scaled}_v = \text{sat}_{16}\!\left( \hat{\text{logit}}_v \cdot \widehat{(1/\tau)} \gg 11 \right)
$$

- 보드 프리셋: $\tau = 0.5,\dots,1.2$ (0.1 간격), $\widehat{1/\tau} = \text{round}(2048/\tau)$.
  예: $\tau=0.7 \Rightarrow \text{round}(2048/0.7)=2926$.

### 7.2 범주형 샘플링 (Categorical Sampling, Inverse-CDF)

Softmax 확률의 누적분포에서 역변환 샘플링:

1. 미정규화 가중치 $e_v = \exp_{Q11}(\text{scaled}_v - \max)$, 총합 $S = \sum_v e_v$
2. 난수 $r = \text{LCG(rng)} \bmod S$ (§7.4, 모듈로는 §6.3 나눗셈기의 나머지)
3. 누적합이 처음으로 $r$을 초과하는 토큰 선택:

$$
\text{token} = \min\Big\{ k : \sum_{v=0}^{k} e_v > r \Big\}
$$

- 정규화($/S$) 없이 미정규화 가중치와 $r \in [0,S)$의 비교로 동일한 분포를 구현(나눗셈 절약).

### 7.3 그리디 디코딩 (Argmax)

$\text{sample\_mode}=0$일 때 확률 최대 토큰을 결정론적으로 선택:

$$
\text{token} = \arg\max_v \hat{\text{logit}}_v
$$

### 7.4 선형 합동 생성기 (LCG, Linear Congruential Generator)

32비트 의사난수. Numerical Recipes 상수:

$$
\text{rng}_{n+1} = (1664525 \cdot \text{rng}_n + 1013904223) \bmod 2^{32}
$$

`lcg_next()`와 `sampler.v`가 동일. 결정론적이므로 소프트웨어 골든과 비트 일치.

---

## 8. 자원 추정 수학 (`README.md`)

### 8.1 NAND2 등가 게이트 환산

각 FPGA 프리미티브를 2입력 NAND 등가로 환산해 설계 복잡도를 추정:

$$
\text{게이트 등가} \approx \underbrace{16427 \times 12}_{\text{LUT6}} + \underbrace{5530 \times 6}_{\text{FF}} + \underbrace{62 \times 3500}_{\text{DSP48E}} \approx 4.5\times10^{5}
$$

- 환산 계수는 ±2× 편차의 대략적 추정치.

### 8.2 처리량 계산 (Throughput)

$$
\text{tok/s} = \frac{f_\text{clk}}{\text{cycles/token}} = \frac{80\times10^6}{\text{cycles/token}}
$$

- 예: 첫 토큰 1156 사이클 → $80\times10^6/1156 \approx 69{,}200$ tok/s.

---

## 9. 보드 주변장치 수학 (`board/*.v`)

### 9.1 클럭 합성 (DCM CLKFX)

$$
f_\text{core} = f_\text{osc} \cdot \frac{\text{CLKFX\_MULTIPLY}}{\text{CLKFX\_DIVIDE}} = 100\,\text{MHz} \cdot \frac{4}{5} = 80\,\text{MHz}
$$

### 9.2 이진화 십진수(BCD) 카운팅 (`tok_meter.v`)

이진→십진 나눗셈을 피하려 처음부터 BCD 리플 캐리로 계수. 자릿수 $d_k$가 9에서 넘칠 때 캐리 전파:

$$
d_0: 9 \to 0 \Rightarrow d_1{+}{+}, \quad d_1: 9 \to 0 \Rightarrow d_2{+}{+}, \dots
$$

XST가 2의 거듭제곱으로만 나누므로 임의 상수 나눗셈을 회피하는 기법입니다.

### 9.3 쿼드러처 디코딩 (`rotary_throttle.v`)

로터리 엔코더의 두 위상 신호 $A, B$의 그레이 코드 전이로 회전 방향을 판정. 상태 전이
$\text{tr} = \{A_{n-1}B_{n-1}, A_n B_n\}$에서 특정 패턴이 up/down 엣지를 나타내며,
$\text{EDGES\_PER\_DETENT}=4$ 엣지마다 한 디텐트로 누산:

$$
\text{acc} \mathrel{+}= (\text{up\_edge} - \text{dn\_edge}), \qquad
|\text{acc}| \ge 3 \Rightarrow \text{한 디텐트 완료}
$$

### 9.4 지수적 회전 간격 (`rotary_throttle.v`)

자동 생성 간격을 레벨에 따라 지수적으로 단축(비트 시프트로 2의 거듭제곱 나눗셈):

$$
\text{interval} = \frac{f_\text{clk}}{2^{\text{speed\_level}}} = f_\text{clk} \gg \text{speed\_level}
$$

- 레벨 0 = 1 Hz(= $f_\text{clk}/f_\text{clk}$... 실제로는 $f_\text{clk} \gg 0$ 사이클 = 1초), 레벨 증가 시 2배씩 빨라짐.

---

## 10. 비트 정확성(Bit-Exactness) 원리

전체 설계의 핵심 불변식: **부동소수점 레퍼런스 → 고정소수점 Python → RTL**이 모두 동일한 정수
연산 순서를 따르므로 결과가 비트 단위로 일치합니다.

- 모든 곱셈은 넓은 정수로 누산 후 한 번만 리스케일(중간 반올림 없음).
- 나눗셈은 §3.5(tdiv, 0 방향)와 §6.3(udiv, floor)의 정확한 정수 결과.
- 지수는 §4.3의 결정론적 테이블+보간.
- 난수는 §7.4의 결정론적 LCG.

이로써 시뮬레이션 골든(그리디 `alaya`, 시드 2·$\tau{=}0.7$ 샘플 `rosphod`)이 소프트웨어와
하드웨어에서 동일하게 재현됩니다(`sim/tb_core.v`).

---

## 부록: 개념 → 파일 대응표

| 수학 개념 | 부동소수점 | 고정소수점 | RTL |
|---|---|---|---|
| 임베딩 | `model.py` NamesGPT | `fixedpoint.py` QModel | `embed.v` |
| RMSNorm | `model.py` RMSNorm | `rmsnorm` | `norm.v`, `isqrt.v`, `udiv.v` |
| 어텐션 | `model.py` CausalAttention | `attn_debug` | `attn.v`, `exp_unit.v`, `udiv.v` |
| MLP/ReLU | `model.py` MLP | `logits_last` | `matvec.v`, `vecop.v` |
| 행렬-벡터 곱 | (torch Linear) | `matvec` | `matvec.v`, `wrom.v` |
| Softmax | (torch) | `exp_neg_q11` | `exp_unit.v` |
| 샘플링/LCG | — | `generate`, `lcg_next` | `sampler.v` |
| 교차 엔트로피/AdamW | `train.py` | — | — |
| 양자화 | — | `q`, `sat16`, `tdiv` | (전 모듈) |
| 자원/처리량 추정 | — | — | `README.md` |
| BCD/쿼드러처/클럭 | — | — | `tok_meter.v`, `rotary_throttle.v`, `xupv5_microgpt_top.v` |
