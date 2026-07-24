"""고정소수점 모델 정상성 확인: 이름을 생성하고 결정론적 골든값을 출력한다."""
import os
import numpy as np
from model import ModelConfig
from fixedpoint import QModel, generate, q

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    cfg = ModelConfig()
    sd = dict(np.load(os.path.join(HERE, "weights.npz")))
    model = QModel(sd, cfg)

    inv_temp = q(1.0 / 0.7)   # 온도 0.7 -> Q11 형식의 1/0.7
    print("== sampled (seed sweep, T=0.7) ==")
    for seed in range(1, 16):
        _, s = generate(model, seed, inv_temp)
        print(f"  seed={seed:2d}  {s}")

    print("== greedy (deterministic) ==")
    toks, s = generate(model, 0, inv_temp, greedy=True)
    print(f"  greedy -> {s}  tokens={toks}")

    # 골든: 고정 시드 + 온도, RTL이 비트 단위로 일치시켜야 하는 시퀀스
    gseed, gtemp = 2, 0.7
    toks, s = generate(model, gseed, q(1.0 / gtemp))
    print(f"GOLDEN seed={gseed} T={gtemp}: tokens={toks} name='{s}'")


if __name__ == "__main__":
    main()
