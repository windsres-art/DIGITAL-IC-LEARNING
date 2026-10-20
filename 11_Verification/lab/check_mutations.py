"""在隔离目录注入缺陷；只有目标检查失败才算检出，编译失败/超时不算。"""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build" / "mutations"
BUILD.mkdir(parents=True, exist_ok=True)
rtl = (ROOT / "Handshake/elastic_alu.v").read_text()


def command(args, cwd):
    p = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=180)
    return p


def changed(old, new):
    assert rtl.count(old) == 1
    return rtl.replace(old, new)


mutants = [
    ("wrong_add", "(a+b)", "(a-b)", "FAIL scoreboard"),
    ("overwrite_stall", "else if (in_ready)", "else if (1'b1)", "FAIL stall stability"),
    ("drop_valid", "out_valid<=in_valid;", "out_valid<=1'b0;", "FAIL"),
    ("bad_reset", "out_valid<=0; result<=0;", "out_valid<=1; result<=0;", "FAIL async reset"),
]
for name, old, new, marker in mutants:
    work = BUILD / name
    work.mkdir(exist_ok=True)
    (work / "elastic_alu.v").write_text(changed(old, new))
    shutil.copy(ROOT / "Handshake/tb_channel.sv", work)
    p = command(["iverilog", "-g2012", "-s", "tb_channel", "-o", "sim",
                 "elastic_alu.v", "tb_channel.sv"], work)
    assert p.returncode == 0, p.stdout
    p = command(["vvp", "sim", "+SEED=2026"], work)
    (work / "run.log").write_text(p.stdout)
    assert p.returncode != 0 and marker in p.stdout and "timeout" not in p.stdout, p.stdout
    print(f"PASS mutation caught: {name}")

# 同一错误分别要求 SVA 和形式属性检出，避免只有 scoreboard 有效。
for name, folder, marker in [
    ("sva_capture", "SVA", "FAIL SVA capture_response"),
    ("formal_capture", "Formal", "Assert failed"),
]:
    work = BUILD / name
    (work / "Handshake").mkdir(parents=True, exist_ok=True)
    (work / "Handshake/elastic_alu.v").write_text(changed("(a+b)", "(a-b)"))
    shutil.copytree(ROOT / folder, work / folder, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("build"))
    p = command(["bash", "run_sim.sh"], work / folder)
    if folder == "Formal":
        details = (work / folder / "build/prove.log").read_text()
        assert "DONE (FAIL" in details and marker in details, details
    else:
        assert marker in p.stdout, p.stdout
    assert p.returncode != 0
    (work / "run.log").write_text(p.stdout)
    print(f"PASS mutation caught: {name}")

work = BUILD / "missing_sdf"
work.mkdir(exist_ok=True)
for f in ("delay_cell.v", "tb_delay.sv"):
    shutil.copy(ROOT / "GLS" / f, work)
source = (work / "tb_delay.sv").read_text()
(work / "tb_delay.sv").write_text(source.replace('$sdf_annotate("../delay.sdf",tb_delay);', ""))
p = command(["iverilog", "-g2012", "-gspecify", "-s", "tb_delay", "-o",
             "sim", "delay_cell.v", "tb_delay.sv"], work)
assert p.returncode == 0, p.stdout
p = command(["vvp", "sim"], work)
(work / "run.log").write_text(p.stdout)
assert p.returncode != 0 and "FAIL SDF too early or missing" in p.stdout, p.stdout
print("PASS mutation caught: missing_sdf")
print("PASS verification mutations: 7/7")
