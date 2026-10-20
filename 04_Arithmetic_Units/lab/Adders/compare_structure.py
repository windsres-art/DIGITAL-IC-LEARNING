"""仅比较统一通用门集合中的数量/拓扑层数，不把这些数解释成面积或 ns。"""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent
SOURCES = "adder_rca.v adder_cla.v adder_cselect.v adder_prefix.v csa3.v adder_three.v"
TOPS = ("adder_rca", "adder_cla", "adder_cselect", "adder_prefix", "csa3", "adder_three")


def main():
    rows = []
    for width in (8, 32, 64):
        for top in TOPS:
            rel = Path("build") / "structure" / f"{top}_w{width}"
            (ROOT / rel).mkdir(parents=True, exist_ok=True)
            command = (
                f"read_verilog {SOURCES}; chparam -set W {width} {top}; "
                f"hierarchy -check -top {top}; proc; flatten; opt; "
                "techmap; opt; check -assert; "
                "select -assert-none t:$_DLATCH_*; "
                f"ltp -noff; write_json {rel.as_posix()}/before.json; "
                "abc -g simple; clean; check -assert; "
                f"ltp -noff; write_json {rel.as_posix()}/after.json"
            )
            result = subprocess.run(
                ["yosys", "-Q", "-T", "-p", command], cwd=ROOT,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                check=False,
            )
            (ROOT / rel / "synth.log").write_text(result.stdout, encoding="utf-8")
            if result.returncode:
                raise RuntimeError(f"FAIL synthesis: {rel}/synth.log")
            depths = re.findall(r"longest topological path.*length=(\d+)", result.stdout, re.I)
            if len(depths) != 2:
                raise RuntimeError(f"FAIL missing before/after path: {rel}")
            cells = []
            for stage in ("before", "after"):
                data = json.loads((ROOT / rel / f"{stage}.json").read_text())
                cells.append(len(data["modules"][top]["cells"]))
            row = dict(width=width, top=top, before_cells=cells[0], before_depth=int(depths[0]),
                       after_cells=cells[1], after_depth=int(depths[1]))
            rows.append(row)
            print(f"W={width:2d} {top:14s} before cells={cells[0]:4d} depth={depths[0]:>3s}"
                  f" | abc cells={cells[1]:4d} depth={depths[1]:>3s}")
    (ROOT / "build/structure/summary.json").write_text(
        json.dumps(rows, indent=2), encoding="utf-8")
    print("PASS structure: 18 designs; generic gates only, no physical timing")


if __name__ == "__main__":
    main()
