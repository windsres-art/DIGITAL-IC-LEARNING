#!/usr/bin/env python3
"""FIFO 深度计算：公式 + 逐事件仿真交叉核对。

公式（最坏情况：一个突发 burst 个数据背靠背写入，期间读侧按自身速率读）：
    写完突发耗时   t = burst / (fw * wr_ratio)
    这段时间读走   r = t * fr * rd_ratio
    最小深度       depth = ceil(burst - r)
逐事件仿真：写沿、读沿按真实时刻排序，读沿只能读到严格早于它写入的数据，
扫描两个时钟的初相位取最大存量。仿真值可能比公式大 1（沿对齐的取整效应）。
不含异步 FIFO 的同步延迟：满空标志要晚 2~3 拍才更新，实际要再加余量。
"""
from fractions import Fraction as F
import math


def formula(burst, fw, fr, wr_ratio=F(1), rd_ratio=F(1)):
    t = F(burst) / (fw * wr_ratio)
    return burst - t * fr * rd_ratio


def simulate(burst, fw, fr, rd_every=1, phases=16):
    """写：背靠背 burst 个；读：每 rd_every 个读时钟读 1 个。返回最大存量。"""
    worst = 0
    tw, tr = F(1) / fw, F(1) / fr
    for p in range(phases):
        ph = tr * p / phases
        writes = [k * tw for k in range(burst)]
        occ = peak = 0
        wi, j = 0, 0
        while wi < burst or occ > 0:
            t_read = ph + j * tr
            # 先处理严格早于本读沿的写
            while wi < burst and writes[wi] < t_read:
                occ += 1
                wi += 1
                peak = max(peak, occ)
            if j % rd_every == 0 and occ > 0:
                occ -= 1
            j += 1
        worst = max(worst, peak)
    return worst


def next_pow2(n):
    return 1 << math.ceil(math.log2(n))


MHZ = 10**6
cases = [
    ("例1 fw=80MHz fr=50MHz，突发 120 个背靠背写，读每拍读",
     dict(burst=120, fw=80 * MHZ, fr=50 * MHZ)),
    ("例2 fw=100MHz fr=80MHz，每 100 拍写 80 个（最坏背靠背 160 个）",
     dict(burst=160, fw=100 * MHZ, fr=80 * MHZ)),
    ("例3 fw=fr=100MHz，突发 100 个，读侧每 4 拍读 1 个",
     dict(burst=100, fw=100 * MHZ, fr=100 * MHZ, rd_every=4)),
]

for name, c in cases:
    rd_every = c.get("rd_every", 1)
    f = formula(c["burst"], c["fw"], c["fr"], rd_ratio=F(1, rd_every))
    s = simulate(c["burst"], c["fw"], c["fr"], rd_every)
    print(name)
    print(f"  公式: {c['burst']} - {float(c['burst'] - f):g} = {float(f):g}"
          f"  -> 至少 {math.ceil(f)}")
    print(f"  逐事件仿真最大存量: {s}")
    print(f"  异步 FIFO 取 2 的幂: {next_pow2(max(s, math.ceil(f)))}")
