"""生成常量、数学参考和固定种子输入；参考不复写 CORDIC 递推。"""
from pathlib import Path
import argparse
import math
import random

ROOT = Path(__file__).resolve().parent
SCALE = 1 << 20
PI = round(math.pi*SCALE)
STEPS = (8, 12, 16, 20)


def gain(n):
    return math.prod(math.sqrt(1+2.0**(-2*i)) for i in range(n))


def tables():
    lines = ["// 由 generate_vectors.py --write-tables 生成；弧度乘 2^20 后取最近偶数。",
             "function signed [23:0] atan_value;", "    input [4:0] index;",
             "    begin", "        case(index)"]
    lines += [f"            5'd{i}: atan_value=24'sd{round(math.atan(2.0**-i)*SCALE)};"
              for i in range(20)]
    lines += ["            default: atan_value=24'sd0;", "        endcase",
              "    end", "endfunction"]
    lines += ["localparam signed [23:0] KINV ="]
    lines += [f"    (ITER=={n}) ? 24'sd{round(SCALE/gain(n))} :" for n in STEPS[:-1]]
    lines += [f"    24'sd{round(SCALE/gain(STEPS[-1]))};", ""]
    return "\n".join(lines)


def generate():
    rng = random.Random(20261021)
    cases = []
    # 全圆均匀角度 + 象限边界左右 1 LSB；参考使用实际量化后的输入。
    for i in range(721):
        cases.append((0, 0, 0, round((-math.pi+2*math.pi*i/720)*SCALE)))
    for center in (-PI, -round(math.pi*SCALE/2), 0, round(math.pi*SCALE/2), PI):
        for offset in (-1, 0, 1):
            cases.append((0, 0, 0, center+offset))
    for _ in range(256):
        cases.append((0, 0, 0, rng.randint(-PI, PI)))
    # 坐标轴、四象限、零、小幅度；完整有效输入方形为 [-1,1]^2。
    for x in (-SCALE, -SCALE//2, -1, 0, 1, SCALE//2, SCALE):
        for y in (-SCALE, -SCALE//2, -1, 0, 1, SCALE//2, SCALE):
            cases.append((1, x, y, 0))
    for _ in range(512):
        cases.append((1, rng.randint(-SCALE, SCALE), rng.randint(-SCALE, SCALE), 0))
    cases += [(0, 0, 0, PI+100), (0, 0, 0, -PI-100),
              (1, SCALE+1, 0, 0), (1, 0, -SCALE-1, 0)]
    for n in STEPS:
        folder = ROOT / "build" / f"n{n}"
        folder.mkdir(parents=True, exist_ok=True)
        rows = []
        for mode, x, y, angle in cases:
            bad = abs(angle)>PI if mode==0 else max(abs(x),abs(y))>SCALE
            zero = mode==1 and x==0 and y==0
            rho = math.hypot(x/SCALE, y/SCALE)
            # 工程验收容差，预先定义；不是任意输入的形式误差证明。
            quantization = 8*(n+1)/SCALE
            iteration = 4*2.0**(-n)
            # 残余 y 约为 G*rho*sin(残角)，坐标容差须包含幅度放大。
            xy_tol = quantization+iteration*(max(1.0, gain(n)*rho) if mode else 1.0)
            angle_tol = min(math.pi, quantization/max(rho, 1/SCALE)+iteration) if mode else xy_tol
            if bad or zero:
                ex=ey=ez=0.0
                xy_tol=angle_tol=0.0
            elif mode==0:
                ex=math.cos(angle/SCALE); ey=math.sin(angle/SCALE); ez=0.0
            else:
                ex=gain(n)*rho; ey=0.0; ez=math.atan2(y,x)
            rows.append(f"{mode} {x} {y} {angle} {int(bad)} {int(zero)} "
                        f"{ex:.17g} {ey:.17g} {ez:.17g} {xy_tol:.17g} {angle_tol:.17g}")
        (folder / "vectors.txt").write_text("\n".join(rows)+"\n")
        print(f"REFERENCE ITER={n} gain={gain(n):.12f} KINV={round(SCALE/gain(n))} vectors={len(rows)}")


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--write-tables", action="store_true")
    args=parser.parse_args()
    header=ROOT / "cordic_tables.vh"
    if args.write_tables:
        header.write_text(tables())
    if header.read_text() != tables():
        raise RuntimeError("CORDIC constants differ; explicitly regenerate and review")
    generate()
