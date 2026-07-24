# gateGPT에서 사용한 LLM 개념 정리

이 문서는 gateGPT 저장소에서 사용한 **대규모 언어 모델(LLM)** 관련 개념을 상세히 정리합니다.
gateGPT는 Andrej Karpathy의 microGPT를 하드웨어(FPGA)로 구현한 **문자 단위 GPT**로, 이름을
생성하도록 학습되었습니다. 각 개념이 어느 파일/함수에 대응하는지도 함께 표기합니다.

> **큰 그림**: gateGPT는 최신 LLM(수십억 파라미터)의 극도로 축소된 형태이지만, GPT 계열의
> 핵심 아키텍처 요소 — 토큰화, 임베딩, 트랜스포머 블록, 자기회귀 디코딩, 온도 샘플링 — 를
> 그대로 담고 있습니다. 규모만 다를 뿐 개념은 동일합니다.

**모델 규모 요약**

| 항목 | 값 |
|---|---|
| 트랜스포머 블록 | 1개 |
| 임베딩 차원 ($d_\text{model}$) | 24 |
| 어텐션 헤드 | 4 (헤드 차원 6) |
| MLP 히든 | 96 |
| 컨텍스트 길이 (block size) | 16 |
| 어휘 크기 | 27 (`.` + a–z) |
| 수 형식 | Q5.11 고정소수점 |

---

## 1. 언어 모델링의 기본 개념

### 1.1 자기회귀 언어 모델 (Autoregressive Language Model)

LLM의 근본 원리. 시퀀스의 결합 확률을 조건부 확률의 곱으로 분해하고, 다음 토큰을 순차적으로 예측합니다:

$$
P(t_0, t_1, \dots, t_n) = \prod_{i=0}^{n} P(t_i \mid t_0, \dots, t_{i-1})
$$

- gateGPT는 이름을 `. n a m e .` 시퀀스로 모델링하고, 매 위치에서 다음 문자를 예측합니다.
- **디코더 전용(decoder-only)** 구조 — GPT 계열과 동일. (`tools/model.py` NamesGPT)

### 1.2 문자 단위 토큰화 (Character-Level Tokenization)

토큰이 곧 문자입니다. 대규모 LLM의 BPE/서브워드 토큰화를 문자 단위로 단순화한 형태:

$$
\text{어휘} = \{\,\texttt{'.'} \mapsto 0,\; \texttt{'a'} \mapsto 1,\; \dots,\; \texttt{'z'} \mapsto 26\,\}
$$

- `.`(id 0)는 **시퀀스 경계 토큰**(BOS/EOS 겸용) — 이름의 시작과 끝을 표시합니다.
- `tools/train.py`의 `build_vocab()`가 `stoi`(문자→id), `itos`(id→문자) 매핑을 생성.

### 1.3 특수 토큰과 시퀀스 경계

- 생성은 항상 `.`(0)에서 시작하고, 모델이 다시 `.`(0)을 내면 이름이 끝납니다.
- 최대 길이(`block_size - 1`)에 도달해도 종료. (`generate`, `name_generator.sv` 종료 조건)

---

## 2. 임베딩 (Embeddings)

### 2.1 토큰 임베딩 (Token Embedding)

각 토큰 id를 $d_\text{model}=24$차원 벡터로 매핑하는 학습 가능한 룩업 테이블:

$$
E_\text{tok} \in \mathbb{R}^{27 \times 24}, \qquad \mathbf{e}_i = E_\text{tok}[t_i]
$$

### 2.2 위치 임베딩 (Positional Embedding) — 절대 위치

트랜스포머는 순서 정보가 없으므로 위치를 명시적으로 주입합니다. gateGPT는 **학습된 절대 위치 임베딩**을 사용:

$$
E_\text{pos} \in \mathbb{R}^{16 \times 24}, \qquad \mathbf{x}_i = E_\text{tok}[t_i] + E_\text{pos}[i]
$$

- **절대 위치**(토큰 $i$는 항상 위치 $i$)라는 선택이 LLM 관점에서 핵심입니다 → **KV 캐시**를
  가능하게 합니다(§5.3). RoPE 같은 상대 위치 대신 단순 학습 임베딩을 채택.
- (`tools/model.py`의 `tok_embed`, `pos_embed` / `core/embed.sv`)

---

## 3. 트랜스포머 블록 (Transformer Block)

GPT의 기본 구성 단위. gateGPT는 이 블록을 1개만 사용하지만 구조는 대규모 GPT와 동일합니다.

### 3.1 사전 정규화 구조 (Pre-Norm Architecture)

현대 GPT(GPT-2 이후)의 표준. 서브레이어 **입력**에 정규화를 적용하고 잔차로 더합니다:

$$
\mathbf{x} \leftarrow \mathbf{x} + \text{Attn}(\text{Norm}_1(\mathbf{x})), \qquad
\mathbf{x} \leftarrow \mathbf{x} + \text{MLP}(\text{Norm}_2(\mathbf{x}))
$$

- 사후 정규화(post-norm) 대비 깊은 네트워크에서 학습 안정성이 좋아 표준이 되었습니다.

### 3.2 RMSNorm (정규화 계층)

LLaMA 등 최신 LLM이 채택한 정규화. LayerNorm에서 평균 차감과 바이어스를 제거해 단순화:

$$
\text{RMSNorm}(\mathbf{x})_i = \frac{x_i}{\sqrt{\frac{1}{d}\sum_j x_j^2 + \epsilon}} \cdot g_i
$$

- 학습 가능한 게인 $\mathbf{g}$만 유지. 하드웨어 구현이 간단하고(평균 계산 불필요) 성능 손실이 적음.
- (`tools/model.py` RMSNorm / `core/norm.sv`)

### 3.3 잔차 연결 (Residual Connections)

각 서브레이어의 출력을 입력에 더해 그래디언트 흐름을 보존하고 깊은 네트워크 학습을 가능하게 합니다.
(`Block.forward`의 `x + ...`)

---

## 4. 어텐션 메커니즘 (Attention)

LLM의 심장부. "Attention Is All You Need"의 스케일드 닷-프로덕트 멀티헤드 어텐션입니다.

### 4.1 Query-Key-Value 프로젝션

입력을 세 가지 역할로 선형 변환(바이어스 없음):

$$
Q = XW_Q, \quad K = XW_K, \quad V = XW_V
$$

- 직관: **Query**(무엇을 찾는가), **Key**(무엇을 제공하는가), **Value**(실제 내용).

### 4.2 스케일드 닷-프로덕트 어텐션

$$
\text{Attention}(Q,K,V) = \text{softmax}\!\left(\frac{QK^\top}{\sqrt{d_h}}\right) V
$$

- **스케일링 $1/\sqrt{d_h}$**: 닷-프로덕트가 차원에 비례해 커져 softmax를 포화시키는 것을 방지.
  $d_h = 6$이므로 $1/\sqrt{6} \approx 0.408$. (하드웨어는 Q11 상수 `ATTN_SCALE`로 저장)

### 4.3 멀티헤드 어텐션 (Multi-Head Attention)

$H=4$개의 헤드가 각각 $d_h=6$차원 부분공간에서 독립적으로 어텐션을 수행 → 다양한 관계를 병렬 포착:

$$
\text{MultiHead}(X) = \text{Concat}(\text{head}_1, \dots, \text{head}_4)\, W_O, \qquad
H \times d_h = 4 \times 6 = 24 = d_\text{model}
$$

- (`tools/model.py` CausalAttention / `core/attn.sv` — 헤드별 순차 처리, 헤드 내 병렬 나눗셈)

### 4.4 인과적 마스킹 (Causal Masking)

자기회귀 성질을 강제. 위치 $i$는 자신과 과거($j \le i$)만 볼 수 있습니다:

$$
A_{ij} \leftarrow \begin{cases} A_{ij} & j \le i \\ -\infty & j > i \end{cases}
$$

- 하삼각 마스크(`tril`). $-\infty$는 softmax에서 확률 0이 됩니다. 이것이 GPT를 "디코더 전용"으로 만드는 요소.

### 4.5 어텐션 Softmax

스코어를 확률 분포로 변환. 수치 안정성을 위해 최댓값을 빼고 지수화합니다:

$$
\alpha_{ij} = \frac{\exp(A_{ij} - \max_k A_{ik})}{\sum_k \exp(A_{ik} - \max_k A_{ik})}
$$

- (`core/attn.sv`, `core/exp_unit.sv` — 테이블+보간 exp)

---

## 5. 추론과 디코딩 (Inference & Decoding)

### 5.1 순방향 패스 (Forward Pass)

입력 컨텍스트 → 임베딩 → 트랜스포머 블록 → 최종 RMSNorm → LM 헤드 → 로짓:

$$
\text{logits} = \text{RMSNorm}_f(\text{Block}(\text{Embed}(\mathbf{idx})))\, W_\text{lm} \in \mathbb{R}^{V}
$$

- (`fixedpoint.py`의 `logits_last` / `core/microgpt_core.sv` 전체 마이크로코드 스케줄)

### 5.2 로짓과 LM 헤드 (Logits & LM Head)

마지막 위치의 은닉 상태를 어휘 크기 $V=27$의 로짓 벡터로 투영. 각 로짓은 다음 토큰의
(미정규화) 점수입니다. 가중치 공유 없이 별도 `lm_head` 사용.

### 5.3 KV 캐시와 증분 디코딩 (KV Cache & Incremental Decoding)

**LLM 추론 효율의 핵심 기법.** 절대 위치 학습 덕분에 각 토큰의 K/V는 이후 스텝에서 변하지 않으므로,
한 번 계산해 캐시에 저장하고 재사용합니다:

$$
K[\text{pos}] = \text{Norm}(\mathbf{x}_\text{pos})W_K, \quad V[\text{pos}] = \text{Norm}(\mathbf{x}_\text{pos})W_V \;\;(\text{캐시에 영속 저장})
$$

- 매 스텝 새 토큰의 K/V만 계산하고 캐시된 전체 컨텍스트에 어텐션.
- 복잡도: 순진한 전체 재계산 $O(T^2 d)$ → 증분 $O(T d)$ (스텝당). README의 **3.2× 성과**.
- 이것이 gateGPT가 대규모 LLM 서빙과 공유하는 가장 중요한 최적화입니다.
- (`tools/ucode_asm.py`의 KC/VC 캐시, `core/microgpt_core.sv`의 `use_pos`, `name_generator.sv` 루프)

### 5.4 자기회귀 생성 루프 (Generation Loop)

$$
t_{i+1} \sim P(\cdot \mid t_0, \dots, t_i), \qquad t_0 = \texttt{'.'}
$$

각 반복: 로짓 계산 → 다음 토큰 샘플링/선택 → 시퀀스에 추가 → 위치 증가 → 반복. 구분자(0) 또는
최대 길이에서 종료. (`generate`, `name_generator.sv`)

---

## 6. 샘플링 전략 (Sampling Strategies)

생성 다양성을 제어하는 디코딩 전략. gateGPT는 두 가지를 구현합니다.

### 6.1 그리디 디코딩 (Greedy Decoding / Argmax)

항상 최고 확률 토큰을 선택 — 결정론적:

$$
t_{i+1} = \arg\max_v \text{logits}_v
$$

- gateGPT 골든: 그리디 결과 `alaya`. (`sample_mode=0`)

### 6.2 온도 샘플링 (Temperature Sampling)

로짓을 온도 $\tau$로 나눠 분포의 날카로움을 조절 후 샘플링:

$$
P(v) = \frac{\exp(\text{logits}_v / \tau)}{\sum_{v'} \exp(\text{logits}_{v'} / \tau)}
$$

- $\tau < 1$: 분포가 뾰족해짐(보수적, 반복적). $\tau > 1$: 평탄해짐(다양, 창의적). $\tau \to 0$: 그리디 수렴.
- 보드 프리셋 $\tau = 0.5 \dots 1.2$ (로터리로 선택), 기본 0.7. 하드웨어는 $1/\tau$(Q11)를 곱함.
- gateGPT 골든: 시드 2·$\tau{=}0.7$ 샘플 결과 `rosphod`.

### 6.3 범주형 샘플링 (Categorical Sampling)

Softmax 분포에서 역-CDF(inverse-CDF) 방식으로 토큰을 추출:

1. 미정규화 가중치 $e_v = \exp(\text{scaled}_v - \max)$, 총합 $S = \sum_v e_v$
2. 난수 $r = \text{RNG} \bmod S$
3. 누적합이 처음으로 $r$을 초과하는 토큰 선택: $\displaystyle t = \min\{k : \textstyle\sum_{v=0}^{k} e_v > r\}$

- 정규화 없이 미정규화 가중치와 비교 → 하드웨어에서 나눗셈 절약.
- (`generate` / `core/sampler.sv`)

### 6.4 결정론적 난수 생성 (Deterministic RNG / LCG)

재현 가능한 샘플링을 위해 선형 합동 생성기(LCG)를 사용:

$$
\text{rng}_{n+1} = (1664525 \cdot \text{rng}_n + 1013904223) \bmod 2^{32}
$$

- 시드가 같으면 소프트웨어와 하드웨어가 **동일 시퀀스**를 생성 → 비트 정확 검증 가능.
- (`lcg_next` / `sampler.sv`)

---

## 7. 학습 (Training)

### 7.1 다음 토큰 예측 목표 (Next-Token Prediction)

LLM 사전학습의 표준 목표. 모든 위치에서 다음 문자를 예측하도록 학습:

$$
\mathcal{L} = -\frac{1}{\sum_i m_i}\sum_i m_i \log P(y_i \mid t_{<i})
$$

- **교차 엔트로피 손실**, 패딩 위치는 마스크 $m_i$로 제외.
- 이름을 `.name.`로 구성하고 시프트하여 $(x, y)$ 쌍을 만듦: $x = \text{toks}[:-1]$, $y = \text{toks}[1:]$.
- (`tools/train.py`)

### 7.2 절대 위치 학습의 의도

훈련 시 토큰 $i$를 항상 위치 $i$에 배치 → 추론의 증분 KV 캐시(§5.3)가 성립하도록 보장하는
설계 결정. 이는 하드웨어 효율을 위해 아키텍처와 학습을 함께 설계한 예입니다.

### 7.3 최적화 (Optimization)

AdamW 옵티마이저, 학습률 $3\times10^{-3}$, weight decay $10^{-4}$, 6000 스텝, 배치 512.
학습 후 float 가중치를 `weights.npz`로 저장. (`tools/train.py`)

---

## 8. 양자화 (Quantization)

LLM 배포의 핵심 기법. gateGPT는 float 모델을 **고정소수점 정수**로 양자화해 하드웨어에 올립니다.

### 8.1 학습 후 양자화 (Post-Training Quantization, PTQ)

float로 학습한 뒤 별도 재학습 없이 가중치·활성값을 저정밀도로 변환:

$$
\hat{w} = \text{round}(w \cdot 2^{11}), \qquad w \approx \hat{w}/2048
$$

- **Q5.11 고정소수점**(16비트): 부호 1 + 정수 4 + 소수 11비트. 범위 $[-16, 16)$.
- 모든 가중치 텐서(임베딩, wq/wk/wv/wo, fc1/fc2, lm, 게인)를 양자화. (`fixedpoint.py` QModel)

### 8.2 정수 전용 추론 (Integer-Only Inference)

양자화된 모델의 순방향 패스는 정수 연산만 사용 — 대규모 MAC, 산술 시프트, 정수 나눗셈/제곱근.
부동소수점 유닛이 전혀 필요 없어 FPGA에 적합. (수학 세부는 `math.kr.md` 참조)

### 8.3 비트 정확 레퍼런스 (Bit-Exact Reference)

`fixedpoint.py`의 정수 QModel이 RTL이 재현해야 하는 **권위 있는 사양**입니다. 부동소수점 →
고정소수점 Python → RTL이 동일한 연산 순서를 따라 비트 단위로 일치. Verilator 골든으로 검증
(그리디 `alaya`, 샘플 `rosphod`). (`sim/tb_core.sv`)

---

## 9. 이 축소 모델과 대규모 LLM의 대응

| 개념 | gateGPT | 대규모 LLM (예: GPT/LLaMA) |
|---|---|---|
| 토큰화 | 문자 단위 (27) | BPE/서브워드 (수만~수십만) |
| 위치 인코딩 | 학습된 절대 위치 | RoPE/ALiBi/학습 위치 |
| 정규화 | RMSNorm | RMSNorm/LayerNorm |
| 어텐션 | 멀티헤드 인과적 (4 헤드) | 멀티헤드/GQA/MQA (수십~수백 헤드) |
| 블록 수 | 1 | 수십~수백 |
| KV 캐시 | 있음 (영속) | 있음 (서빙 필수) |
| 샘플링 | 온도/그리디 | 온도/top-k/top-p/빔서치 |
| 양자화 | Q5.11 (16비트) | INT8/INT4/FP8 등 |
| 학습 목표 | 다음 토큰 예측 | 다음 토큰 예측 |

gateGPT는 규모를 극단적으로 줄였을 뿐, **디코더 전용 GPT의 모든 핵심 개념**을 담고 있습니다.

---

## 부록: LLM 개념 → 파일 대응표

| LLM 개념 | 부동소수점 | 고정소수점 | RTL |
|---|---|---|---|
| 자기회귀 생성 | `train.py` 샘플링 | `generate` | `name_generator.sv`, `microgpt_core.sv` |
| 문자 토큰화 | `train.py` build_vocab | — | (id 직접 사용) |
| 토큰/위치 임베딩 | `model.py` | QModel 임베딩 | `embed.sv` |
| RMSNorm | `model.py` RMSNorm | `rmsnorm` | `norm.sv` |
| 멀티헤드 어텐션 | `model.py` CausalAttention | `attn_debug`, `logits_last` | `attn.sv` |
| 인과적 마스킹 | `model.py` mask | (컨텍스트 길이로 암묵) | `attn.sv` ctx_len |
| Softmax | `model.py` F.softmax | `exp_neg_q11` | `exp_unit.sv` |
| MLP/ReLU | `model.py` MLP | `logits_last` | `matvec.sv`, `vecop.sv` |
| LM 헤드/로짓 | `model.py` lm_head | `logits_last` | `matvec.sv` (lm) |
| KV 캐시 | — | `logits_last` (증분) | `microgpt_core.sv`, `ucode_asm.py` |
| 온도/범주형 샘플링 | `train.py` multinomial | `generate` | `sampler.sv` |
| 그리디 디코딩 | — | `generate(greedy)` | `sampler.sv` |
| 결정론적 RNG | — | `lcg_next` | `sampler.sv` |
| 다음 토큰 예측 학습 | `train.py` | — | — |
| 양자화 (PTQ) | — | `q`, QModel | (전 모듈) |
