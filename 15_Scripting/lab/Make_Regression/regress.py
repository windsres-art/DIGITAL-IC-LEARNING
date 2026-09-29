#!/usr/bin/env python3
"""并行回归：W × SEED 全组合调用 make sim，汇总结果、给出复现命令。

先按 W 并行编译（每个 W 一个 vvp 文件，互不冲突），
再并行跑全部用例（此时 make 发现 vvp 已是最新，不会重复编译，也就不会互相覆盖）。

用法（先 source /root/oss-cad-suite/environment）：
    python3 regress.py
    python3 regress.py --widths 4 8 --seeds 20 --bug --corner -j 8
"""
import argparse
import csv
import itertools
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
RE_RESULT = re.compile(r"^(PASS|FAIL)\b.*$", re.M)
RE_KV = re.compile(r"(\w+)=(\d+)")


def make(target, timeout, **var):
    cmd = ["make", "-s", "-C", str(HERE), target] + [f"{k}={v}" for k, v in var.items()]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def run_case(w, seed, opts, timeout):
    t0 = time.perf_counter()
    try:
        r = make("sim", timeout, W=w, SEED=seed, **opts)
        found = list(RE_RESULT.finditer(r.stdout))
        line = found[-1].group(0) if found else ""
        # 退出码和结果行都要看：TB 中途崩溃时可能根本没有 PASS/FAIL 行
        status = "PASS" if r.returncode == 0 and line.startswith("PASS") else "FAIL"
    except subprocess.TimeoutExpired:
        status, line = "TIMEOUT", ""
    stats = {k: int(v) for k, v in RE_KV.findall(line)}
    return {"W": w, "seed": seed, "status": status, "sec": time.perf_counter() - t0,
            "errors": stats.get("errors", 0), "load_en_ones": stats.get("load_en_ones", 0),
            "wraps": stats.get("wraps", 0)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--widths", type=int, nargs="+", default=[4, 8, 16])
    ap.add_argument("--seeds", type=int, default=5, help="每个 W 跑 1..N 号种子")
    ap.add_argument("--cycles", type=int, default=1000)
    ap.add_argument("--bug", action="store_true", help="打开 RTL 里注入的 bug")
    ap.add_argument("--corner", action="store_true", help="装载值加 corner 偏置")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--timeout", type=float, default=60)
    args = ap.parse_args()

    opts = {"CYCLES": args.cycles, "BUG": int(args.bug), "CORNER": int(args.corner)}
    cases = list(itertools.product(args.widths, range(1, args.seeds + 1)))
    t0 = time.perf_counter()

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        # 1. 编译：每个 W 一次
        for w, r in zip(args.widths, pool.map(
                lambda w: make("compile", args.timeout, W=w, BUG=opts["BUG"]), args.widths)):
            if r.returncode != 0:
                print(f"编译失败 W={w}:\n{r.stderr}")
                return 1
        # 2. 仿真：全部组合并行
        results = list(pool.map(lambda c: run_case(*c, opts, args.timeout), cases))

    elapsed = time.perf_counter() - t0
    print(f"{'W':>3} {'seed':>4}  {'status':<7} {'errors':>6} {'load_en_ones':>12} {'wraps':>6}")
    for r in sorted(results, key=lambda r: (r["W"], r["seed"])):
        print(f"{r['W']:>3} {r['seed']:>4}  {r['status']:<7} {r['errors']:>6}"
              f" {r['load_en_ones']:>12} {r['wraps']:>6}")

    # 按 W 汇总：通过率 + 关键场景命中次数（覆盖率的朴素版本）
    per_w = defaultdict(list)
    for r in results:
        per_w[r["W"]].append(r)
    print("\n按 W 汇总：")
    for w, rs in sorted(per_w.items()):
        n_pass = sum(r["status"] == "PASS" for r in rs)
        hit = sum(r["load_en_ones"] > 0 for r in rs)
        wraps = sum(r["wraps"] > 0 for r in rs)
        print(f"  W={w:<3} pass {n_pass}/{len(rs)}   打到 load&en&全1 的种子 {hit}/{len(rs)}"
              f"   出现过回绕的种子 {wraps}/{len(rs)}")

    failed = [r for r in results if r["status"] != "PASS"]
    serial = sum(r["sec"] for r in results)
    print(f"\ntotal={len(results)} pass={len(results) - len(failed)} fail={len(failed)}"
          f"  墙钟 {elapsed:.1f} s（各用例耗时之和 {serial:.1f} s，jobs={args.jobs}）")

    out = HERE / "build" / "regress_summary.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(results[0].keys()))
        w.writeheader()
        w.writerows(results)

    if failed:
        print("复现失败用例：")
        for r in failed:
            print(f"  make sim W={r['W']} SEED={r['seed']} BUG={opts['BUG']} CORNER={opts['CORNER']}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
