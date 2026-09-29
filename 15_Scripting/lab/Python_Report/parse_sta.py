#!/usr/bin/env python3
"""解析 OpenSTA 时序报告 + Yosys 单元统计，输出汇总和 CSV。

只用标准库（re / argparse / csv / dataclasses / pathlib / collections），
服务器上没有 pip 权限时也能跑。

用法：
    python3 parse_sta.py                      # 默认读 ../Tcl_EDA/reports/ 下的报告
    python3 parse_sta.py --rpt x.rpt --top 5
"""
import argparse
import csv
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
TCL_LAB = HERE.parent / "Tcl_EDA"

# 预编译正则。报告是定宽文本，用 \s+ 容忍列宽变化，不要按列号切字符串
RE_START = re.compile(r"^Startpoint: (\S+)")
RE_END = re.compile(r"^Endpoint: (\S+)")
RE_GROUP = re.compile(r"^Path Group: (\S+)")
RE_TYPE = re.compile(r"^Path Type: (\w+)")
# 数据路径上的一级：Delay  Time  ^/v  引脚  (单元)
RE_STAGE = re.compile(r"^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+[\^v]\s+(\S+)\s+\((\S+)\)")
RE_ARRIVAL = re.compile(r"^\s*(-?\d+\.\d+)\s+data arrival time")
RE_REQUIRED = re.compile(r"^\s*(-?\d+\.\d+)\s+data required time")
RE_SLACK = re.compile(r"^\s*(-?\d+\.\d+)\s+slack \((MET|VIOLATED)\)")
# Yosys stat 的一行：个数  面积  单元名
RE_STAT_CELL = re.compile(r"^\s+(\d+)\s+(\S+)\s+(sky130_\S+)\s*$")
RE_STAT_AREA = re.compile(r"Chip area for module '\\(\S+)': ([\d.]+)")


@dataclass
class TimingPath:
    start: str = ""
    end: str = ""
    group: str = ""
    kind: str = ""  # max = setup，min = hold
    arrival: float | None = None
    required: float | None = None
    slack: float | None = None
    stages: list = field(default_factory=list)  # [(delay, pin, cell), ...]

    @property
    def worst_stage(self):
        return max(self.stages, key=lambda s: s[0]) if self.stages else None

    @property
    def depth(self):
        # 每个单元在报告里占两行（输入引脚、输出引脚），输出引脚那行的延时是单元延时
        return sum(1 for _, pin, _ in self.stages if pin.split("/")[-1] in ("X", "Y", "Q", "SUM", "COUT"))


def parse_sta(text: str) -> list[TimingPath]:
    """一条路径从 Startpoint 开始、到 slack 行结束，用一个小状态机逐行解析。"""
    paths, cur, in_data = [], None, False
    for line in text.splitlines():
        if m := RE_START.match(line):
            cur, in_data = TimingPath(start=m[1]), True
            continue
        if cur is None:
            continue
        if m := RE_END.match(line):
            cur.end = m[1]
        elif m := RE_GROUP.match(line):
            cur.group = m[1].strip("*")
        elif m := RE_TYPE.match(line):
            cur.kind = m[1]
        elif m := RE_ARRIVAL.match(line):
            # arrival 在报告里出现两次（路径末尾、汇总区的负数），只取第一次
            if cur.arrival is None:
                cur.arrival = float(m[1])
            in_data = False  # 之后是 capture 时钟侧，不再是数据路径
        elif m := RE_REQUIRED.match(line):
            cur.required = float(m[1])
        elif m := RE_SLACK.match(line):
            cur.slack = float(m[1])
            paths.append(cur)
            cur = None
        elif in_data and (m := RE_STAGE.match(line)):
            cur.stages.append((float(m[1]), m[3], m[4].removeprefix("sky130_fd_sc_hd__")))
    return paths


def parse_stat(text: str):
    cells = {m[3].removeprefix("sky130_fd_sc_hd__"): (int(m[1]), float(m[2]))
             for line in text.splitlines() if (m := RE_STAT_CELL.match(line))}
    m = RE_STAT_AREA.search(text)
    return cells, float(m[2]) if m else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rpt", type=Path, default=TCL_LAB / "reports/sta_paths.rpt")
    ap.add_argument("--stat", type=Path, default=TCL_LAB / "reports/synth.stat")
    ap.add_argument("--slack-csv", type=Path, default=TCL_LAB / "reports/endpoint_slack.csv",
                    help="Tcl 脚本导出的全部端点 slack，用来交叉核对")
    ap.add_argument("--out", type=Path, default=HERE / "reports/paths.csv")
    ap.add_argument("--top", type=int, default=5)
    args = ap.parse_args()

    fails = []

    # ---------------- 1. 时序报告 ----------------
    paths = parse_sta(args.rpt.read_text())
    print(f"== 1. {args.rpt.name}: 解析出 {len(paths)} 条路径 ==")
    by_group = defaultdict(list)
    for p in paths:
        by_group[p.group].append(p)
    print(f"  {'group':<16}{'paths':>6}{'viol':>6}{'WNS':>9}{'TNS(报告内)':>14}")
    for g, ps in sorted(by_group.items()):
        viol = [p.slack for p in ps if p.slack < 0]
        print(f"  {g:<16}{len(ps):>6}{len(viol):>6}{min(p.slack for p in ps):>9.3f}{sum(viol):>14.3f}")

    worst = sorted(paths, key=lambda p: p.slack)[: args.top]
    print(f"\n  最差 {args.top} 条：")
    print(f"  {'endpoint':<12}{'slack':>8}{'arrival':>9}{'depth':>7}  最慢一级")
    for p in worst:
        d, pin, cell = p.worst_stage
        print(f"  {p.end:<12}{p.slack:>8.3f}{p.arrival:>9.3f}{p.depth:>7}  {d:.3f} ns @ {pin} ({cell})")

    # 违例路径里，最慢一级是什么单元：定位"是哪类单元拖后腿"
    hot = Counter(p.worst_stage[2] for p in paths if p.slack < 0)
    print(f"\n  违例路径最慢一级的单元类型：{dict(hot.most_common(3))}")

    # 每条路径自洽：slack = required − arrival（setup）
    bad = [p.end for p in paths if p.kind == "max"
           and abs((p.required - p.arrival) - p.slack) > 0.0015]
    if bad:
        fails.append(f"slack ≠ required − arrival: {bad[:3]}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["group", "startpoint", "endpoint", "arrival", "required", "slack", "depth"])
        for p in paths:
            w.writerow([p.group, p.start, p.end, p.arrival, p.required, p.slack, p.depth])
    print(f"  → 写出 {args.out.relative_to(HERE)}")

    # ---------------- 2. 与 Tcl 导出的全部端点交叉核对 ----------------
    print(f"\n== 2. 与 {args.slack_csv.name} 交叉核对 ==")
    with args.slack_csv.open() as f:
        rows = [(r["endpoint"], float(r["slack_ns"])) for r in csv.DictReader(f)]
    tns = sum(s for _, s in rows if s < 0)
    nviol = sum(1 for _, s in rows if s < 0)
    print(f"  CSV 端点 {len(rows)} 个，违例 {nviol} 个，WNS {min(s for _, s in rows):.3f}，TNS {tns:.3f}")
    if abs(min(s for _, s in rows) - worst[0].slack) > 0.0015:
        fails.append("WNS 与 Tcl 导出的不一致")
    # 文本报告每组只列前 N 条；只有违例路径全在报告里时，报告算出的 TNS 才是真 TNS
    rpt_viol = [p.slack for p in paths if p.slack < 0]
    if len(rpt_viol) == nviol:
        print("  文本报告包含了全部违例端点，两边 TNS 应一致")
        if abs(sum(rpt_viol) - tns) > 0.01:
            fails.append("TNS 与 Tcl 导出的不一致")
    else:
        print(f"  文本报告只含 {len(rpt_viol)}/{nviol} 个违例端点，TNS 要以全部端点为准")

    # ---------------- 3. Yosys 单元统计 ----------------
    cells, chip_area = parse_stat(args.stat.read_text())
    total_n = sum(n for n, _ in cells.values())
    total_a = sum(a for _, a in cells.values())
    seq = {k: v for k, v in cells.items() if k.startswith(("df", "sdf", "dl"))}
    seq_a = sum(a for _, a in seq.values())
    print(f"\n== 3. {args.stat.name}: {len(cells)} 种单元，共 {total_n} 个 ==")
    print(f"  各行面积之和 {total_a:.1f}，报告 Chip area {chip_area:.1f}")
    print(f"  时序单元 {sum(n for n, _ in seq.values())} 个，占面积 {100 * seq_a / chip_area:.1f}%")
    top_area = sorted(cells.items(), key=lambda kv: -kv[1][1])[:3]
    print("  面积前 3：" + "，".join(f"{k} {a:.0f}" for k, (_, a) in top_area))
    # stat 里面积用 %g 打印（如 1.35E+03），逐行加起来会有舍入误差，按相对误差比
    if abs(total_a - chip_area) / chip_area > 0.01:
        fails.append("单元面积之和与 Chip area 相差超过 1%")

    print()
    if fails:
        print("FAIL parse_sta: " + "; ".join(fails))
        return 1
    print("PASS parse_sta")
    return 0


if __name__ == "__main__":
    sys.exit(main())
