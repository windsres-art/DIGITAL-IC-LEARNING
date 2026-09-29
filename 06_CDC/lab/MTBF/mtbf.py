#!/usr/bin/env python3
"""同步器 MTBF 估算：MTBF = exp(Tr / tau) / (Tw * fclk * fdata)

参数是教学用的示例值（数量级接近常见工艺），不是 Sky130 的实测特征值；
真实项目里 tau、Tw 由工艺厂或库特征化给出。

用法：python3 mtbf.py
"""
import math

TAU = 20e-12        # 亚稳态恢复时间常数 tau
TW = 30e-12         # 亚稳态窗口 Tw（也写作 T0）
T_CQ = 0.10e-9      # 触发器 clk->Q
T_SU = 0.10e-9      # 触发器 setup
F_DATA = 50e6       # 异步输入的翻转频率

SECONDS_PER_YEAR = 365 * 24 * 3600


def mtbf(tr, fclk, fdata=F_DATA):
    return math.exp(tr / TAU) / (TW * fclk * fdata)


def fmt_time(s):
    if s < 1:
        return f"{s:.3g} s"
    if s < SECONDS_PER_YEAR:
        return f"{s:.3g} s ({s / 3600:.3g} h)"
    return f"{s / SECONDS_PER_YEAR:.3g} years"


def tr_for(stages, period, t_logic=0.0):
    """留给亚稳态恢复的时间（保守口径）。
    1 级：采样后的 Q 直接进组合逻辑，只剩下游路径的余量 T - Tcq - Tsu - Tlogic
    N 级：级间没有逻辑，每级之间有 T - Tcq - Tsu；不计最后一级之后的余量
    """
    if stages == 1:
        return period - T_CQ - T_SU - t_logic
    return (stages - 1) * (period - T_CQ - T_SU)


def main():
    print(f"tau={TAU*1e12:.0f} ps  Tw={TW*1e12:.0f} ps  Tcq={T_CQ*1e9:.2f} ns  "
          f"Tsu={T_SU*1e9:.2f} ns  fdata={F_DATA/1e6:.0f} MHz")
    print()

    fclk = 500e6
    period = 1 / fclk
    t_logic = 1.5e-9
    print(f"[1] fclk = {fclk/1e6:.0f} MHz (T = {period*1e9:.1f} ns)；1 级时 Q 后面直接接 {t_logic*1e9:.1f} ns 组合逻辑")
    print(f"{'stages':>6} {'Tr (ns)':>8} {'Tr/tau':>7}  MTBF")
    for n in (1, 2, 3):
        tr = tr_for(n, period, t_logic)
        print(f"{n:>6} {tr*1e9:>8.2f} {tr/TAU:>7.1f}  {fmt_time(mtbf(tr, fclk))}")
    print()

    print("[2] 提高目的时钟频率：两级 vs 三级")
    print(f"{'fclk':>8} {'2-stage MTBF':>24} {'3-stage MTBF':>24}")
    for f in (200e6, 500e6, 1e9, 2e9, 3e9):
        m2 = mtbf(tr_for(2, 1 / f), f)
        m3 = mtbf(tr_for(3, 1 / f), f)
        print(f"{f/1e6:>5.0f}MHz {fmt_time(m2):>24} {fmt_time(m3):>24}")
    print()

    print("[3] 芯片里有 N 个同步器时，整体 MTBF = 单个 MTBF / N（1 GHz 两级）")
    one = mtbf(tr_for(2, 1e-9), 1e9)
    for n in (1, 1000, 100000):
        print(f"  N={n:<7d} MTBF = {fmt_time(one / n)}")


if __name__ == "__main__":
    main()
