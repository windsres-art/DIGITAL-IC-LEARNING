"""只改 build 中的副本，检查三种真实算术错误能否被自检查 TB 抓到。"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
SOURCES = ["adder_rca.v", "adder_cla.v", "adder_cselect.v", "adder_prefix.v", "csa3.v", "adder_three.v"]
MUTATIONS = [
    ("cla_drop_cin", "adder_cla.v", "assign c[0]=cin;", "assign c[0]=1'b0;"),
    ("prefix_wrong_propagate", "adder_prefix.v",
     "assign p[s+1][i]=p[s][i]&p[s][i-(1<<s)];",
     "assign p[s+1][i]=p[s][i]|p[s][i-(1<<s)];"),
    ("csa_wrong_weight", "csa3.v",
     "assign saved_carry={(a&b)|(a&d)|(b&d),1'b0};",
     "assign saved_carry={1'b0,(a&b)|(a&d)|(b&d)};"),
]


def main():
    for name, filename, old, new in MUTATIONS:
        work = ROOT / "build/mutations" / name
        work.mkdir(parents=True, exist_ok=True)
        for source in SOURCES + ["tb_adders.sv"]:
            text = (ROOT / source).read_text(encoding="utf-8")
            if source == filename:
                if text.count(old) != 1:
                    raise RuntimeError(f"FAIL mutation target changed: {name}")
                text = text.replace(old, new)
            (work / source).write_text(text, encoding="utf-8")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-gstrict-expr-width", "-s", "tb_adders",
             "-Ptb_adders.W=8", "-Ptb_adders.B=4", "-o", "sim", *SOURCES, "tb_adders.sv"],
            cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (work / "compile.log").write_text(compiled.stdout, encoding="utf-8")
        if compiled.returncode:
            raise RuntimeError(f"FAIL mutation did not compile: {name}")
        result = subprocess.run(["vvp", "-n", "sim"], cwd=work, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        (work / "result.log").write_text(result.stdout, encoding="utf-8")
        if result.returncode == 0 or "FAIL W=" not in result.stdout or "arithmetic mismatch" not in result.stdout:
            raise RuntimeError(f"FAIL mutation escaped arithmetic checker: {name}")
        print(f"PASS mutation caught: {name}")
    print("PASS mutations: 3/3 arithmetic errors detected")


if __name__ == "__main__":
    main()
