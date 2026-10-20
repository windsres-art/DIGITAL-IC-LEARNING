"""成功编译后必须被数值比较拒绝；复用已生成的精确参考向量。"""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
cases = [
    ("tie_always_up", "fixed_quantize.v",
     "above_half || (tie && base[0])", "above_half || tie", "8_4_4_2"),
    ("negative_zero_rounding", "fixed_quantize.v",
     "increment=x[IW-1] && lost;", "increment=1'b0;", "8_4_4_2"),
    ("positive_wrap", "fixed_quantize.v",
     "y=MAXIMUM[OW-1:0];", "y=rounded[OW-1:0];", "8_4_4_2"),
    ("missing_saturation_inexact", "fixed_quantize.v",
     "assign inexact=lost || overflow;", "assign inexact=lost;", "8_4_2_2"),
    ("subnormal_as_zero", "fp32_classify.v",
     "6'b000001 : 6'b000010", "6'b000001 : 6'b000001", None),
    ("quiet_signaling_swapped", "fp32_classify.v",
     "bits[22] ? 6'b010000 : 6'b100000",
     "bits[22] ? 6'b100000 : 6'b010000", None),
]
for name, filename, old, new, config in cases:
    source = (ROOT / filename).read_text()
    assert source.count(old) == 1, name
    folder = ROOT / "build" / "mutations" / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / filename).write_text(source.replace(old, new))
    top = "tb_fixed" if config else "tb_fp32"
    params = []
    if config:
        params = [f"-P{top}.{p}={v}" for p, v in
                  zip(("IW", "OW", "IF", "OF"), config.split("_"))]
        shutil.copyfile(ROOT / "build" / config / "fixed.txt", folder / "fixed.txt")
    else:
        shutil.copyfile(ROOT / "build" / "fp32.txt", folder / "fp32.txt")
    subprocess.run(["iverilog", "-g2012", "-gstrict-expr-width", "-s", top, *params,
                    "-o", str(folder / "sim"), str(folder / filename),
                    str(ROOT / f"{top}.sv")], check=True)
    result = subprocess.run(["vvp", "-n", "sim"], cwd=folder,
                            capture_output=True, text=True, timeout=30)
    log = result.stdout+result.stderr
    (folder / "result.log").write_text(log)
    marker = "FAIL quantize" if config else "FAIL classification"
    if result.returncode == 0 or marker not in log:
        raise RuntimeError(f"{name}: not caught by value check\n{log}")
    print(f"PASS mutation caught: {name}")
print("PASS Fixed_Float mutations: 6/6")
