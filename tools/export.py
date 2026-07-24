"""
양자화된 모델을 RTL 산출물로 내보낸다:
  - generated/*.hex     텐서마다 행 우선 Q5.11 ROM 하나(16비트 2의 보수)
  - core/core_params.vh  차원, FRAC, 어텐션 스케일, exp 테이블, 골든값
모든 경로는 이 프로젝트 내부이며, 외부 의존성은 없다.
"""
import os
import numpy as np
from model import ModelConfig
from fixedpoint import QModel, generate, q, EXP_TAB, EXP_K, FRAC

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GEN = os.path.join(ROOT, "generated")
COREP = os.path.join(ROOT, "core", "core_params.vh")


def write_hex(name, arr2d):
    """arr2d 행 우선 -> hex 파일, 한 줄당 4자리(16비트 2의 보수) 워드 하나."""
    flat = np.asarray(arr2d).reshape(-1)
    with open(os.path.join(GEN, name), "w") as f:
        for v in flat:
            f.write(f"{int(v) & 0xFFFF:04x}\n")
    return flat.size


def write_tiled_hex(name, W, lanes=24):
    """LANES 병렬, 사이클당 2열 matvec 타일을 위한 넓은 가중치 ROM. W는 형상
    (out_dim, in_dim). 출력 행은 LANES 행 단위 타일로 분할되며, 각 ROM 워드는
    타일의 행들에 걸쳐 연속된 입력 열 두 개(2j, 2j+1)의 LANES개 가중치를 담는다.
    워드는 tile*(in_dim/2) + j로 주소 지정하고, 패킹은 열 2j를 하위 LANES*16
    비트(lane 0 = LSB), 열 2j+1을 상위 LANES*16 비트에 두므로, w_rdata[lane*16 +:16]가
    lane의 열 2j 가중치, w_rdata[LANES*16 + lane*16 +:16]가 열 2j+1 가중치다.
    in_dim은 짝수여야 하며, out_dim을 넘는 타일은 0으로 패딩된다."""
    W = np.asarray(W)
    out_dim, in_dim = W.shape
    assert in_dim % 2 == 0, "2-column matvec needs even in_dim"
    tiles = (out_dim + lanes - 1) // lanes
    with open(os.path.join(GEN, name), "w") as f:
        for t in range(tiles):
            for j in range(in_dim // 2):
                word = ""
                # 최상위부터: 열 2j+1 (lane23..0), 그다음 열 2j (lane23..0)
                for col in (2 * j + 1, 2 * j):
                    for lane in reversed(range(lanes)):
                        o = t * lanes + lane
                        val = int(W[o, col]) if o < out_dim else 0
                        word += f"{val & 0xFFFF:04x}"
                f.write(word + "\n")
    return tiles * (in_dim // 2)


def _tiled_words(W, lanes=24):
    """타일화된 가중치 ROM을 정수 워드 리스트(각 2*lanes*16 비트)로 반환,
    write_tiled_hex와 같은 패킹(열 2j 하위, 열 2j+1 상위; lane 0 = LSB)."""
    W = np.asarray(W)
    out_dim, in_dim = W.shape
    tiles = (out_dim + lanes - 1) // lanes
    words = []
    for t in range(tiles):
        for j in range(in_dim // 2):
            word = 0
            for slot, col in enumerate((2 * j, 2 * j + 1)):     # slot 0 = 하위 절반
                for lane in range(lanes):
                    o = t * lanes + lane
                    val = int(W[o, col]) if o < out_dim else 0
                    word |= (val & 0xFFFF) << (slot * lanes * 16 + lane * 16)
            words.append(word)
    return words


def write_func_vh(path, func_name, ret_w, idx_w, values, idx2=None, signed=False):
    """조합 ROM을 명시적 상수의 Verilog 함수로 방출한다. XST 14.7은 작은
    $readmemh 분산 ROM 배열을 0으로 묶어버리므로, 코어가 읽는 모든 ROM
    (마이크로코드, 가중치, exp 테이블, 임베딩)을 대신 이 방식으로 방출한다."""
    nh = (ret_w + 3) // 4
    sgn = " signed" if signed else ""
    with open(path, "w") as f:
        f.write(f"// Auto-generated ROM (combinational case constants). Do not edit by hand.\n")
        if idx2 is None:
            f.write(f"function{sgn} [{ret_w-1}:0] {func_name};\n    input [{idx_w-1}:0] idx;\n    case (idx)\n")
            for i, v in enumerate(values):
                f.write(f"        {idx_w}'d{i}: {func_name} = {ret_w}'h{v & ((1<<ret_w)-1):0{nh}x};\n")
            f.write(f"        default: {func_name} = {ret_w}'d0;\n    endcase\nendfunction\n")
        else:  # 2단계: values는 dict sel -> list
            f.write(f"function{sgn} [{ret_w-1}:0] {func_name};\n")
            f.write(f"    input [{idx2[0]-1}:0] sel;\n    input [{idx_w-1}:0] idx;\n    case (sel)\n")
            for sel, words in values.items():
                f.write(f"        {idx2[0]}'d{sel}: case (idx)\n")
                for i, v in enumerate(words):
                    f.write(f"            {idx_w}'d{i}: {func_name} = {ret_w}'h{v & ((1<<ret_w)-1):0{nh}x};\n")
                f.write(f"            default: {func_name} = {ret_w}'d0;\n        endcase\n")
            f.write(f"        default: {func_name} = {ret_w}'d0;\n    endcase\nendfunction\n")


def main():
    os.makedirs(GEN, exist_ok=True)
    cfg = ModelConfig()
    sd = dict(np.load(os.path.join(HERE, "weights.npz")))
    m = QModel(sd, cfg)

    sizes = {}
    sizes["tok_embed"] = write_hex("tok_embed.hex", m.tok)     # 27 x 24 (embed가 읽음)
    sizes["pos_embed"] = write_hex("pos_embed.hex", m.pos)     # 16 x 24 (embed가 읽음)

    # 24-lane, 사이클당 2열 matvec용 타일화 가중치 ROM(워드 하나 = 48개 가중치).
    # RTL이 로드하는 유일한 가중치 ROM(wrom이 generated/*_t.hex를 읽음). RMSNorm
    # 게인은 ROM이 아니라 core/gains.vh에 조합 함수로 들어간다(아래).
    sizes["wq_t"] = write_tiled_hex("wq_t.hex", m.wq)          # 24 x 24
    sizes["wk_t"] = write_tiled_hex("wk_t.hex", m.wk)
    sizes["wv_t"] = write_tiled_hex("wv_t.hex", m.wv)
    sizes["wo_t"] = write_tiled_hex("wo_t.hex", m.wo)
    sizes["fc1_t"] = write_tiled_hex("fc1_t.hex", m.fc1)       # 96 x 24
    sizes["fc2_t"] = write_tiled_hex("fc2_t.hex", m.fc2)       # 24 x 96
    sizes["lm_t"] = write_tiled_hex("lm_t.hex", m.lm)          # 27 x 24
    sizes["exp"] = None
    with open(os.path.join(GEN, "exp_tab.hex"), "w") as f:
        for v in EXP_TAB:
            f.write(f"{int(v) & 0xFFFF:04x}\n")

    # 게인을 조합 case로(XST는 이 작은 배열에 ROM을 추론하지 않고 $readmemh를
    # 0으로 묶으므로 -> 명시적 상수로 방출).
    with open(os.path.join(ROOT, "core", "gains.vh"), "w") as f:
        f.write("// Auto-generated RMSNorm gains (Q5.11). gsel 0=g1 1=g2 2=gf.\n")
        f.write("function signed [15:0] gain_lut;\n")
        f.write("    input [1:0] gsel; input [4:0] gidx;\n")
        f.write("    case ({gsel, gidx})\n")
        for si, gain in enumerate([m.g1, m.g2, m.gf]):
            for idx in range(cfg.n_embed):
                key = (si << 5) | idx
                f.write(f"        7'd{key}: gain_lut = 16'sh{int(gain[idx]) & 0xFFFF:04x};\n")
        f.write("        default: gain_lut = 16'sd0;\n    endcase\nendfunction\n")

    # 코어가 읽는 모든 ROM도 조합 case 함수로 방출한다. XST 14.7이 작은 $readmemh
    # 분산 ROM을 0으로 만들기 때문(보드에서 가중치/exp/임베딩을 0으로 남겨 -> 엉터리
    # 이름). 위의 .hex 파일들은 시뮬레이션/레퍼런스용으로 유지된다.
    CORE = os.path.join(ROOT, "core")
    wsel = {0: m.wq, 1: m.wk, 2: m.wv, 3: m.wo, 4: m.fc1, 5: m.fc2, 6: m.lm}
    wwords = {s: _tiled_words(W) for s, W in wsel.items()}
    write_func_vh(os.path.join(CORE, "wrom_data.vh"), "wrom_data", 2 * 24 * 16, 12, wwords, idx2=(3,))
    write_func_vh(os.path.join(CORE, "tok_emb.vh"), "tok_emb", 16, 10,
                  [int(v) for v in np.asarray(m.tok).reshape(-1)], signed=True)
    write_func_vh(os.path.join(CORE, "pos_emb.vh"), "pos_emb", 16, 10,
                  [int(v) for v in np.asarray(m.pos).reshape(-1)], signed=True)
    write_func_vh(os.path.join(CORE, "exp_data.vh"), "exp_tab_rom", 16, 5,
                  [int(v) for v in EXP_TAB], signed=True)

    # 테스트벤치용 골든값
    gseed, gtemp = 2, 0.7
    toks, s = generate(m, gseed, q(1.0 / gtemp))
    gtoks, gs = generate(m, 0, q(1.0 / gtemp), greedy=True)

    with open(COREP, "w") as f:
        f.write("// Auto-generated model parameters (Q5.11). Do not edit by hand.\n")
        f.write(f"localparam integer FRAC_BITS = {FRAC};\n")
        f.write(f"localparam integer VOCAB    = {cfg.vocab_size};\n")
        f.write(f"localparam integer N_EMBED  = {cfg.n_embed};\n")
        f.write(f"localparam integer N_HEAD   = {cfg.n_head};\n")
        f.write(f"localparam integer HEAD_DIM = {cfg.head_dim};\n")
        f.write(f"localparam integer MLP_HID  = {cfg.mlp_hidden};\n")
        f.write(f"localparam integer BLOCK    = {cfg.block_size};\n")
        f.write(f"localparam integer EXP_K    = {EXP_K};\n")
        f.write(f"localparam signed [15:0] ATTN_SCALE = 16'sd{m.attn_scale};\n")
        f.write(f"// golden sample seed={gseed} T={gtemp}: '{s}' tokens={toks}\n")
        f.write(f"// golden greedy: '{gs}' tokens={gtoks}\n")

    print("wrote ROMs:", {k: v for k, v in sizes.items() if v})
    print(f"GOLDEN sample seed={gseed} T={gtemp}: tokens={toks} '{s}'")
    print(f"GOLDEN greedy: tokens={gtoks} '{gs}'")


if __name__ == "__main__":
    main()
