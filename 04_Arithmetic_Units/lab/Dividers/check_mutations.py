"""编译必须成功；仿真必须由数值/不变量检查拒绝，超时不算抓到错误。"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
source = (root / "div_iter.v").read_text()
mutations = {
    "missing_restore": ("? shifted : trial;", "? trial : trial;"),
    "missing_final_correction": ("r_next[W-1:0] + divisor :", "r_next[W-1:0] :"),
    "wrong_remainder_sign": ("neg_r <= signed_mode && a[W-1];",
                             "neg_r <= signed_mode && (a[W-1] ^ b[W-1]);"),
    "stale_final_quotient": ("(neg_q ? -q_next : q_next);",
                             "(neg_q ? -q_work : q_work);"),
    "wrong_divzero_remainder": ("remainder <= zero_saved ? original_a :",
                                "remainder <= zero_saved ? {W{1'b0}} :"),
}
for name, (old, new) in mutations.items():
    assert source.count(old) == 1, (name, "ambiguous mutation")
    folder = root / "build" / "mutations" / name
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "div_iter.v").write_text(source.replace(old, new))
    subprocess.run(["iverilog", "-g2012", "-gstrict-expr-width", "-s", "tb_div_iter",
                    "-Ptb_div_iter.W=4", "-o", str(folder / "sim"),
                    str(folder / "div_iter.v"), str(root / "tb_div_iter.sv")], check=True)
    result = subprocess.run(["vvp", "-n", "sim"], cwd=folder, text=True,
                            capture_output=True, timeout=30)
    log = result.stdout + result.stderr
    (folder / "result.log").write_text(log)
    if result.returncode == 0 or not any(s in log for s in
            ("FAIL division mismatch", "FAIL partial invariant")):
        raise RuntimeError(f"{name}: did not fail through arithmetic checks\n{log}")
    print(f"PASS mutation caught: {name}")
print("PASS Dividers mutations: 5/5")
