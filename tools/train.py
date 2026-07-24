"""
공개 makemore 이름 코퍼스(data/names.txt)로 레퍼런스 NamesGPT를 학습시키고
float 가중치를 tools/weights.npz에 저장한다.

절대 위치(토큰 i는 항상 위치 i)를 쓰는 표준 코잘 학습이므로, 추론에서는
점진적 KV 캐시를 쓸 수 있다(시퀀스가 길어져도 토큰의 K/V는 변하지 않음).
이름은 시퀀스  . n a m e .  로 모델링되며, 모든 위치에서 신경망이 다음
토큰을 예측한다. 어휘: 0='.', 1..26='a'..'z'.
"""
import os
import numpy as np
import torch
import torch.nn.functional as F
from model import ModelConfig, NamesGPT

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SEED = 1337


def build_vocab():
    chars = ["."] + [chr(ord("a") + i) for i in range(26)]
    stoi = {c: i for i, c in enumerate(chars)}
    itos = {i: c for i, c in enumerate(chars)}
    return stoi, itos


def load_dataset(cfg, stoi):
    """전체 시퀀스 예제(절대 위치), 오른쪽 패딩 + 마스킹."""
    names = [w.strip() for w in open(os.path.join(ROOT, "data", "names.txt")) if w.strip()]
    B = cfg.block_size
    X, Y, M = [], [], []
    for w in names:
        toks = ([0] + [stoi[c] for c in w] + [0])[: B + 1]   # .name.  (길이 제한)
        x, y = toks[:-1], toks[1:]
        L = len(x)
        X.append(x + [0] * (B - L))
        Y.append(y + [0] * (B - L))
        M.append([1.0] * L + [0.0] * (B - L))
    return torch.tensor(X), torch.tensor(Y), torch.tensor(M)


def main():
    torch.manual_seed(SEED)
    cfg = ModelConfig()
    stoi, itos = build_vocab()
    X, Y, M = load_dataset(cfg, stoi)
    V = cfg.vocab_size
    print(f"dataset: {X.shape[0]} examples, block_size={cfg.block_size}")

    model = NamesGPT(cfg)
    print(f"params: {sum(p.numel() for p in model.parameters())}")
    opt = torch.optim.AdamW(model.parameters(), lr=3e-3, weight_decay=1e-4)

    n, bs, steps = X.shape[0], 512, 6000
    for step in range(steps):
        ix = torch.randint(0, n, (bs,))
        logits = model(X[ix])                                  # [bs, T, V]
        loss = F.cross_entropy(logits.reshape(-1, V), Y[ix].reshape(-1), reduction="none")
        loss = (loss * M[ix].reshape(-1)).sum() / M[ix].sum()  # 패딩 마스킹
        opt.zero_grad(); loss.backward(); opt.step()
        if step % 500 == 0 or step == steps - 1:
            print(f"step {step:5d}  loss {loss.item():.4f}")

    sd = {k: v.detach().cpu().numpy() for k, v in model.state_dict().items()}
    np.savez(os.path.join(HERE, "weights.npz"), **sd)
    print("saved tools/weights.npz")

    # 이름 품질 확인용 점진적 float 샘플링(절대 위치)
    model.eval()
    g = torch.Generator().manual_seed(7)
    for _ in range(12):
        seq, out = [0], []
        for _ in range(cfg.block_size):
            logits = model(torch.tensor([seq]))[0, -1, :]
            p = F.softmax(logits / 0.7, dim=-1)
            nxt = torch.multinomial(p, 1, generator=g).item()
            if nxt == 0:
                break
            out.append(itos[nxt]); seq.append(nxt)
        print("  ", "".join(out))


if __name__ == "__main__":
    main()
