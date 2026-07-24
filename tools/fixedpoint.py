"""
NamesGPT의 고정소수점 정수 레퍼런스 — RTL 코어가 비트 단위로 재현해야 하는
기준 스펙. 모든 값은 Q5.11 부호 있는 16비트(FRAC=11). 모든 연산은 하드웨어에
직접 매핑되는 정수 산술만 사용한다: 넓은 MAC + 산술 우측 시프트, RMSNorm용
정수 isqrt + 역수, 테이블+보간 exp, 샘플링용 32비트 LCG.
(이들은 이 프로젝트를 위해 설계한 우리 고유의 선택이다.)
"""
import math
import numpy as np
from model import ModelConfig

FRAC = 11
SCALE = 1 << FRAC                 # 2048
QMAX, QMIN = 32767, -32768


def sat16(v):
    return QMAX if v > QMAX else (QMIN if v < QMIN else int(v))


def tdiv(a, b):
    """0 방향으로 절삭(부호-크기 하드웨어 나눗셈기와 일치)."""
    qq = abs(int(a)) // abs(int(b))
    return -qq if (a < 0) != (b < 0) else qq


def q(x):
    """float -> Q5.11 포화 int16(반올림)."""
    return sat16(int(math.floor(x * SCALE + 0.5)))


# ---- exp 테이블: EXP_TAB[k] = round(exp(-k) * 2048), k = 0..EXP_K -------------
EXP_K = 16
EXP_TAB = [int(math.floor(math.exp(-k) * SCALE + 0.5)) for k in range(EXP_K + 1)]


def exp_neg_q11(z):
    """z <= 0(z는 Q11)에 대한 Q11 형식 exp(z). 테이블 조회 + 선형 보간."""
    if z >= 0:
        return SCALE
    u = -z                                  # >= 0, Q11
    ui = u >> FRAC                           # 정수부
    if ui >= EXP_K:
        return 0
    uf = u & (SCALE - 1)                     # 소수부, Q11
    lo, hi = EXP_TAB[ui], EXP_TAB[ui + 1]    # hi <= lo (감소)
    e = lo + ((hi - lo) * uf >> FRAC)        # 산술 시프트(uf>=0)
    return e if e > 0 else 0


def matvec(W_q, x_q):
    """y[o] = sat16( (sum_i W[o,i]*x[i]) >> FRAC ). W_q:[out,in] 정수, x_q:[in] 정수."""
    acc = W_q.astype(np.int64) @ x_q.astype(np.int64)
    return np.array([sat16(int(a) >> FRAC) for a in acc], dtype=np.int64)


def rmsnorm(x_q, gain_q):
    """y = x / sqrt(mean(x^2)) * gain, 모두 Q11, 정수 isqrt + 역수로 계산."""
    n = len(x_q)
    ss = int((x_q.astype(np.int64) ** 2).sum())      # Q22
    mean_sq = ss // n                                 # Q22
    if mean_sq < 1:
        mean_sq = 1
    r = math.isqrt(mean_sq)                           # Q11 (Q22의 제곱근)
    if r < 1:
        r = 1
    scale = (1 << (2 * FRAC)) // r                    # 2^22 / r  -> Q11 역제곱근
    if scale > QMAX:
        scale = QMAX
    y = np.empty(n, dtype=np.int64)
    for i in range(n):
        t = sat16((int(x_q[i]) * scale) >> FRAC)
        y[i] = sat16((t * int(gain_q[i])) >> FRAC)
    return y


class QModel:
    """양자화된 NamesGPT; 정수 순전파가 계획된 RTL과 동일하다."""

    def __init__(self, sd, cfg: ModelConfig):
        self.cfg = cfg
        self.tok = np.array([[q(v) for v in row] for row in sd["tok_embed.weight"]], dtype=np.int64)
        self.pos = np.array([[q(v) for v in row] for row in sd["pos_embed.weight"]], dtype=np.int64)
        b = "blocks.0."
        self.g1 = np.array([q(v) for v in sd[b + "norm1.gain"]], dtype=np.int64)
        self.g2 = np.array([q(v) for v in sd[b + "norm2.gain"]], dtype=np.int64)
        self.gf = np.array([q(v) for v in sd["norm_f.gain"]], dtype=np.int64)
        qz = lambda name: np.array([[q(v) for v in row] for row in sd[name]], dtype=np.int64)
        self.wq = qz(b + "attn.wq.weight")
        self.wk = qz(b + "attn.wk.weight")
        self.wv = qz(b + "attn.wv.weight")
        self.wo = qz(b + "attn.wo.weight")
        self.fc1 = qz(b + "mlp.fc1.weight")
        self.fc2 = qz(b + "mlp.fc2.weight")
        self.lm = qz("lm_head.weight")
        self.attn_scale = q(1.0 / math.sqrt(cfg.head_dim))   # Q11 형식의 1/sqrt(head_dim)

    def attn_debug(self, ctx):
        """ctx(T=길이)에 대해 (qlast[24], k[T,24], v[T,24], attn_out[24]) 반환, RTL 테스트용."""
        cfg = self.cfg
        T, H, D = len(ctx), cfg.n_head, cfg.head_dim
        x = np.empty((T, cfg.n_embed), dtype=np.int64)
        for t in range(T):
            x[t] = np.array([sat16(int(self.tok[ctx[t]][i]) + int(self.pos[t][i]))
                             for i in range(cfg.n_embed)], dtype=np.int64)
        xn = np.array([rmsnorm(x[t], self.g1) for t in range(T)], dtype=np.int64)
        k = np.array([matvec(self.wk, xn[t]) for t in range(T)], dtype=np.int64)
        v = np.array([matvec(self.wv, xn[t]) for t in range(T)], dtype=np.int64)
        qlast = matvec(self.wq, xn[T - 1])
        attn_out = np.zeros(cfg.n_embed, dtype=np.int64)
        for h in range(H):
            sl = slice(h * D, (h + 1) * D)
            scores = []
            for s in range(T):
                acc = int((qlast[sl].astype(np.int64) * k[s][sl].astype(np.int64)).sum())
                sc = sat16(acc >> FRAC)
                sc = sat16((sc * self.attn_scale) >> FRAC)
                scores.append(sc)
            mm = max(scores)
            e = [exp_neg_q11(sc - mm) for sc in scores]
            se = sum(e)
            if se < 1:
                se = 1
            for d in range(D):
                num = sum(e[s] * int(v[s][h * D + d]) for s in range(T))
                attn_out[h * D + d] = sat16(tdiv(num, se))
        return qlast, k, v, attn_out

    def logits_last(self, ctx):
        """ctx: 토큰 id 리스트(길이 L<=block_size, 절대 위치 0..L-1).
        마지막 위치 L-1의 Q11 로짓 반환(점진적 KV 캐시 디코드와 일치)."""
        cfg = self.cfg
        T, H, D = len(ctx), cfg.n_head, cfg.head_dim
        # 모든 위치의 임베딩
        x = np.empty((T, cfg.n_embed), dtype=np.int64)
        for t in range(T):
            x[t] = np.array([sat16(int(self.tok[ctx[t]][i]) + int(self.pos[t][i]))
                             for i in range(cfg.n_embed)], dtype=np.int64)
        # --- 어텐션 서브레이어(마지막 위치의 출력만 필요) ---
        xn = np.array([rmsnorm(x[t], self.g1) for t in range(T)], dtype=np.int64)
        k = np.array([matvec(self.wk, xn[t]) for t in range(T)], dtype=np.int64)
        v = np.array([matvec(self.wv, xn[t]) for t in range(T)], dtype=np.int64)
        qlast = matvec(self.wq, xn[T - 1])
        attn_out = np.zeros(cfg.n_embed, dtype=np.int64)
        for h in range(H):
            sl = slice(h * D, (h + 1) * D)
            scores = []
            for s in range(T):
                acc = int((qlast[sl].astype(np.int64) * k[s][sl].astype(np.int64)).sum())
                sc = sat16(acc >> FRAC)
                sc = sat16((sc * self.attn_scale) >> FRAC)
                scores.append(sc)
            m = max(scores)
            e = [exp_neg_q11(sc - m) for sc in scores]
            sum_e = sum(e)
            if sum_e < 1:
                sum_e = 1
            for d in range(D):
                num = sum(e[s] * int(v[s][h * D + d]) for s in range(T))
                attn_out[h * D + d] = sat16(tdiv(num, sum_e))
        wo = matvec(self.wo, attn_out)
        x1 = np.array([sat16(int(x[T - 1][i]) + int(wo[i])) for i in range(cfg.n_embed)], dtype=np.int64)
        # --- MLP 서브레이어 ---
        xn2 = rmsnorm(x1, self.g2)
        h1 = matvec(self.fc1, xn2)
        h1 = np.array([hh if hh > 0 else 0 for hh in h1], dtype=np.int64)   # ReLU
        h2 = matvec(self.fc2, h1)
        x2 = np.array([sat16(int(x1[i]) + int(h2[i])) for i in range(cfg.n_embed)], dtype=np.int64)
        # --- 최종 norm + LM 헤드 ---
        xf = rmsnorm(x2, self.gf)
        return matvec(self.lm, xf)


# ---- 결정론적 샘플러(32비트 LCG, Numerical Recipes 상수) ----------
def lcg_next(state):
    return (state * 1664525 + 1013904223) & 0xFFFFFFFF


def generate(model: QModel, seed, inv_temp_q11, max_len=None, greedy=False):
    """이름 하나를 점진적으로 생성(절대 위치). (token_ids, 문자열) 반환."""
    cfg = model.cfg
    max_len = max_len or (cfg.block_size - 1)
    rng = seed & 0xFFFFFFFF
    seq = [0]               # 시작 토큰 '.'
    toks = []
    for _ in range(max_len):
        logits = model.logits_last(seq)
        if greedy:
            nxt = int(np.argmax(logits))
        else:
            scaled = [sat16((int(l) * inv_temp_q11) >> FRAC) for l in logits]
            m = max(scaled)
            e = [exp_neg_q11(s - m) for s in scaled]
            total = sum(e)
            if total < 1:
                total = 1
            rng = lcg_next(rng)
            r = rng % total
            acc, nxt = 0, len(e) - 1
            for i, ei in enumerate(e):
                acc += ei
                if acc > r:
                    nxt = i
                    break
        if nxt == 0:
            break
        toks.append(nxt)
        seq.append(nxt)                 # 다음 절대 위치에 점진적으로 추가
    s = "".join(chr(ord("a") + t - 1) for t in toks)
    return toks, s
