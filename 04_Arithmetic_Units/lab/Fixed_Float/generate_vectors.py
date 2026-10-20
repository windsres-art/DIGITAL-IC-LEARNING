"""精确 Fraction 参考模型；不重复 RTL 的算术右移/低位判断算法。"""
from fractions import Fraction
from pathlib import Path
import math
import random
import struct

ROOT = Path(__file__).resolve().parent
CONFIGS = [(1, 1, 0, 0), (4, 3, 2, 1), (8, 4, 4, 2),
           (8, 4, 4, 0), (8, 4, 2, 2), (8, 12, 0, 4),
           (8, 4, 0, 3), (16, 8, 12, 4)]


def reference(x, mode, iw, ow, inf, outf):
    scaled = Fraction(x, 2**inf) * 2**outf
    rounded = (math.floor, math.trunc, round, math.ceil)[mode](scaled)
    lo, hi = -(2**(ow-1)), 2**(ow-1)-1
    y = max(lo, min(hi, rounded))
    return y, int(not lo <= rounded <= hi), int(Fraction(y) != scaled)


def generate():
    rng = random.Random(20261020)
    for iw, ow, inf, outf in CONFIGS:
        folder = ROOT / "build" / f"{iw}_{ow}_{inf}_{outf}"
        folder.mkdir(parents=True, exist_ok=True)
        lo, hi = -(2**(iw-1)), 2**(iw-1)-1
        xs = list(range(lo, hi+1)) if iw <= 8 else (
            [lo, lo+1, hi-1, hi, -1, 0, 1] +
            list(range(-64, 65)) + [rng.randint(lo, hi) for _ in range(4096)])
        rows = []
        for x in xs:
            for mode in range(4):
                answer = reference(x, mode, iw, ow, inf, outf)
                rows.append(" ".join(map(str, (x, mode, *answer))))
        (folder / "fixed.txt").write_text("\n".join(rows)+"\n")

    # 先构造类别，再生成其编码，期待值不通过调用 RTL 或宿主浮点分类取得。
    words = []
    for sign in (0, 1):
        prefix = sign << 31
        words += [(prefix, 1), (prefix | 0x7f800000, 8)]
        for payload in [1, 0x3fffff, 0x400000, 0x7fffff]:
            words.append((prefix | payload, 2))
        for exponent in range(1, 255):
            for fraction in (0, 1, 0x3fffff, 0x400000, 0x7fffff):
                words.append((prefix | exponent << 23 | fraction, 4))
        for payload in [0, 1, 0x3fffff] + [rng.randrange(2**22) for _ in range(512)]:
            words.append((prefix | 0x7fc00000 | payload, 16))
        for payload in [1, 0x3fffff] + [rng.randrange(1, 2**22) for _ in range(512)]:
            words.append((prefix | 0x7f800000 | payload, 32))
    (ROOT / "build" / "fp32.txt").write_text(
        "".join(f"{word:08x} {kind}\n" for word, kind in words))
    print(f"PASS vector generation: fixed_configs={len(CONFIGS)} fp32={len(words)}")


def f32(x):
    return struct.unpack(">f", struct.pack(">f", x))[0]


def bits32(x):
    return struct.unpack(">I", struct.pack(">f", x))[0]


def examples():
    for x in (-26, -22, 22, 26, 30):
        results = [reference(x, mode, 8, 4, 4, 2)[0] for mode in range(4)]
        print(f"EXAMPLE fixed raw={x} value={Fraction(x,16)} outputs={results}")
    tenth = f32(0.1)
    error = Fraction(tenth)-Fraction(1, 10)
    assert bits32(tenth) == 0x3dcccccd and error == Fraction(1, 671088640)
    print(f"EXAMPLE binary32 0.1 bits={bits32(tenth):08x} exact_error={error}")
    assert f32(2**24+1) == 2**24
    # 每一步显式存回 binary32；选择正侧内层加法展示不结合。
    left = f32(f32(-(2**24) + 2**24) + 1)
    right = f32(-(2**24) + f32(2**24 + 1))
    assert (left, right) == (1.0, 0.0)
    print(f"EXAMPLE binary32 nonassociative left={left:.1f} right={right:.1f}")
    # 解码边界，用 Fraction 避免把下溢/有效位问题混入宿主算术。
    smallest_sub = Fraction(1, 2**149)
    largest_sub = Fraction(2**23-1, 2**149)
    smallest_normal = Fraction(1, 2**126)
    assert smallest_normal-largest_sub == smallest_sub
    print("PASS binary32 numeric examples: encoding, error, tie, nonassociation, subnormal gap")


if __name__ == "__main__":
    generate()
    examples()
