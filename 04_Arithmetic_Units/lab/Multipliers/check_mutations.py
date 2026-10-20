"""在 build 内副本注入错误；必须编译成功并由算术检查发现不匹配。"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
SOURCES = ["mul_shift.v", "mul_booth.v", "csa_reduce.v", "mul_wallace.v"]
CASES = [
    ("last_bit_lost", "mul_shift.v", "shift", 4,
     "product<=negative?(~next_acc+{{(2*W-1){1'b0}},1'b1}):next_acc;",
     "product<=negative?(~acc+{{(2*W-1){1'b0}},1'b1}):acc;"),
    ("unsigned_gets_negated", "mul_shift.v", "shift", 4,
     "negative<=signed_mode && (a[W-1]^b[W-1]);", "negative<=(a[W-1]^b[W-1]);"),
    ("booth_no_sign_extend", "mul_booth.v", "comb", 4,
     "a_ext={{W{a[W-1]}},a};", "a_ext={{W{1'b0}},a};"),
    ("booth_odd_padding", "mul_booth.v", "comb", 3,
     "b_ext={{PAD{b[W-1]}},b,1'b0};", "b_ext={{PAD{1'b0}},b,1'b0};"),
    ("wallace_carry_weight", "csa_reduce.v", "comb", 4,
     "=((x&y)|(x&z)|(y&z))<<1;", "=((x&y)|(x&z)|(y&z));"),
]


def main():
    for name, source, test, width, old, new in CASES:
        work = ROOT / "build/mutations" / name
        work.mkdir(parents=True, exist_ok=True)
        tb = f"tb_mul_{test}"
        for filename in SOURCES + [tb + ".sv"]:
            text = (ROOT / filename).read_text(encoding="utf-8")
            if filename == source:
                if text.count(old) != 1:
                    raise RuntimeError(f"FAIL mutation target changed: {name}")
                text = text.replace(old, new)
            (work / filename).write_text(text, encoding="utf-8")
        result = subprocess.run(
            ["iverilog", "-g2012", "-gstrict-expr-width", "-s", tb,
             f"-P{tb}.W={width}", "-o", "sim", *SOURCES, tb + ".sv"],
            cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (work / "compile.log").write_text(result.stdout, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"FAIL mutation did not compile: {name}")
        result = subprocess.run(["vvp", "-n", "sim"], cwd=work, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        (work / "result.log").write_text(result.stdout, encoding="utf-8")
        if result.returncode == 0 or "multiply mismatch" not in result.stdout:
            raise RuntimeError(f"FAIL arithmetic mutation escaped: {name}")
        print(f"PASS mutation caught: {name}")
    print("PASS multiplier mutations: 5/5")


if __name__ == "__main__":
    main()
