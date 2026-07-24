"""
마이크로어셈블러: 영구 KV 캐시를 사용한 점진적 디코딩을 위해 코어의 제어
프로그램(마이크로코드)을 방출한다. 토큰마다 코어는 위치 하나를 처리한다: 새 토큰을
임베딩하고, 그 K/V를 캐시 슬롯 KC[pos]/VC[pos]에 계산한 뒤, 유효 위치 0..pos에 걸쳐
어텐션, MLP, LM 헤드, 샘플링을 수행한다. KC/VC 캐시는 vmem에 상주하며 토큰 간에
유지된다(작업 벡터는 라이브 레인지별로 0..255에 패킹되어 캐시 영역 256..1023을
절대 건드리지 않는다).
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ---- vmem 메모리 맵(AW=10). 작업 벡터는 0..255에 패킹(라이브 레인지로 재사용);
#      KV 캐시(KC/VC)는 256..1023에 영구 상주하며 스크래치가 절대 덮어쓰지 않음. ----
MAP = dict(
    TMP=0, XN=24, QV=48, AO=72, WOT=96, X1=120, XN2=144,   # 페이즈 A 작업 집합
    HID=0, H2T=96, X2=144, XF=0, LOG=24,                    # 페이즈 B (죽은 페이즈-A 슬롯 재사용)
    KC=256, VC=640,                                         # 영구 KV 캐시(각 16*24)
)
NE, BLOCK, MLP, VOCAB = 24, 16, 96, 27

OP = dict(NOP=0, EMBED=1, NORM=2, MATV=3, ATTN=4, VADD=5, RELU=6, SAMPLE=7, HALT=8)
WS = dict(WQ=0, WK=1, WV=2, WO=3, FC1=4, FC2=5, LM=6)
GS = dict(G1=0, G2=1, GF=2)


def enc(op, wsel=0, in_dim=0, out_dim=0, descale=0, gsel=0, a=0, b=0, d=0, use_pos=0):
    w = (op & 0xF)
    w |= (wsel & 0xF) << 4
    w |= (in_dim & 0x7F) << 8
    w |= (out_dim & 0x7F) << 15
    w |= (descale & 0x1F) << 22
    w |= (gsel & 0x3) << 27
    # 비트 29..32 미사용
    w |= (a & 0x7FF) << 33
    w |= (b & 0x7FF) << 44
    w |= (d & 0x7FF) << 55
    w |= (use_pos & 0x1) << 66       # d += pos_in*N_EMBED (KV 캐시 쓰기 슬롯)
    return w


def build():
    M = MAP
    return [
        enc(OP["EMBED"], d=M["TMP"]),                                              # pos_in 위치의 token_in
        enc(OP["NORM"], a=M["TMP"], d=M["XN"], gsel=GS["G1"]),
        enc(OP["MATV"], wsel=WS["WK"], in_dim=NE, out_dim=NE, descale=11, a=M["XN"], d=M["KC"], use_pos=1),
        enc(OP["MATV"], wsel=WS["WV"], in_dim=NE, out_dim=NE, descale=11, a=M["XN"], d=M["VC"], use_pos=1),
        enc(OP["MATV"], wsel=WS["WQ"], in_dim=NE, out_dim=NE, descale=11, a=M["XN"], d=M["QV"]),
        enc(OP["ATTN"]),                                                           # ctx_len = pos_in+1
        enc(OP["MATV"], wsel=WS["WO"], in_dim=NE, out_dim=NE, descale=11, a=M["AO"], d=M["WOT"]),
        enc(OP["VADD"], a=M["TMP"], b=M["WOT"], d=M["X1"], out_dim=NE),
        enc(OP["NORM"], a=M["X1"], d=M["XN2"], gsel=GS["G2"]),
        enc(OP["MATV"], wsel=WS["FC1"], in_dim=NE, out_dim=MLP, descale=11, a=M["XN2"], d=M["HID"]),
        enc(OP["RELU"], a=M["HID"], d=M["HID"], out_dim=MLP),
        enc(OP["MATV"], wsel=WS["FC2"], in_dim=MLP, out_dim=NE, descale=11, a=M["HID"], d=M["H2T"]),
        enc(OP["VADD"], a=M["X1"], b=M["H2T"], d=M["X2"], out_dim=NE),
        enc(OP["NORM"], a=M["X2"], d=M["XF"], gsel=GS["GF"]),
        enc(OP["MATV"], wsel=WS["LM"], in_dim=NE, out_dim=VOCAB, descale=11, a=M["XF"], d=M["LOG"]),
        enc(OP["SAMPLE"]),
        enc(OP["HALT"]),
    ]


def main():
    prog = build()
    with open(os.path.join(ROOT, "generated", "ucode.hex"), "w") as f:
        for w in prog:
            f.write(f"{w & ((1 << 72) - 1):018x}\n")
    # 마이크로코드 ROM을 조합 case로($readmemh 아님): XST 14.7이 작은 $readmemh
    # 분산 ROM을 0으로 묶어서, 보드에서 프로그램이 전부 NOP로 남았고 -> 시퀀서가
    # HALT에 도달하지 못해 코어가 멈췄다. 명시적 case 상수는 LUT로 안정적으로
    # 합성된다(core/gains.vh와 같은 기법).
    with open(os.path.join(ROOT, "core", "ucode_rom.vh"), "w") as f:
        f.write("// Auto-generated microcode ROM (combinational). Do not edit by hand.\n")
        f.write("function [71:0] ucode_rom;\n")
        f.write("    input [7:0] pc;\n")
        f.write("    case (pc)\n")
        for i, w in enumerate(prog):
            f.write(f"        8'd{i}: ucode_rom = 72'h{w & ((1 << 72) - 1):018x};\n")
        f.write("        default: ucode_rom = 72'h000000000000000008;  // OP_HALT (safe stop)\n")
        f.write("    endcase\nendfunction\n")
    with open(os.path.join(ROOT, "core", "coremap.vh"), "w") as f:
        f.write("// Auto-generated memory map + opcodes. Do not edit.\n")
        f.write(f"localparam integer NINSTR = {len(prog)};\n")
        for k, v in MAP.items():
            f.write(f"localparam [9:0] A_{k} = 10'd{v};\n")
        for k, v in OP.items():
            f.write(f"localparam [3:0] OP_{k} = 4'd{v};\n")
    print(f"emitted {len(prog)} instructions -> generated/ucode.hex")


if __name__ == "__main__":
    main()
