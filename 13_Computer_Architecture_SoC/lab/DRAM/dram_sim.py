#!/usr/bin/env python3
"""DRAM 行缓冲（row buffer）分类的独立复算。

读 tb_dram 写出的 trace（"R 地址" / "W 地址" / "F k"），按请求顺序维护每个 bank
当前打开的行，把每个请求分成 行命中 / 行空 / 行冲突，与 RTL 的计数比对。
"F k" 表示刷新发生在第 k 个请求被分类之前：此时所有 bank 都已预充电。

用法：dram_sim.py trace.txt --map 0 --open 1 [--expect H,E,C]
"""
import argparse
import sys

BA_W, ROW_W, COL_W = 3, 8, 8
LCB = 3   # MAP=3 时 bank 位于行内 8 个字（一条 cache 行）之上


def decode(addr, m):
    """字节地址 -> (bank, row, col)。与 RTL 的位切片写法不同，这里逐字段取。"""
    w = addr >> 2
    col_mask, ba_mask = (1 << COL_W) - 1, (1 << BA_W) - 1
    row = w >> (BA_W + COL_W)
    if m == 1:                                   # bank:row:col
        bank, row, col = w >> (ROW_W + COL_W), (w >> COL_W) & ((1 << ROW_W) - 1), w & col_mask
    elif m == 2:                                 # row:bank:col，bank 再与行号低位异或
        bank = ((w >> COL_W) & ba_mask) ^ (row & ba_mask) ^ ((row >> BA_W) & ba_mask)
        col = w & col_mask
    elif m == 3:                                 # row:col_hi:bank:col_lo（cache 行交织）
        bank = (w >> LCB) & ba_mask
        col = ((w >> (LCB + BA_W)) << LCB | (w & ((1 << LCB) - 1))) & col_mask
    else:                                        # row:bank:col
        bank, col = (w >> COL_W) & ba_mask, w & col_mask
    return bank, row, col


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--map", type=int, default=0)
    ap.add_argument("--open", type=int, default=1)
    ap.add_argument("--expect", help="RTL 给出的 hit,empty,conflict")
    a = ap.parse_args()

    reqs, refs = [], []
    with open(a.trace) as f:
        for ln in f:
            t = ln.split()
            if not t:
                continue
            if t[0] == "F":
                refs.append(int(t[1]))
            else:
                reqs.append(int(t[1], 16))

    open_row = [None] * (1 << BA_W)
    cnt = [0, 0, 0]
    refs = sorted(refs)
    ri = 0
    for k, addr in enumerate(reqs):
        while ri < len(refs) and refs[ri] <= k:
            open_row = [None] * (1 << BA_W)
            ri += 1
        b, r, _ = decode(addr, a.map)
        if open_row[b] is None:
            cnt[1] += 1
        elif open_row[b] == r:
            cnt[0] += 1
        else:
            cnt[2] += 1
        open_row[b] = r if a.open else None

    n = len(reqs)
    banks = [0] * (1 << BA_W)
    for addr in reqs:
        banks[decode(addr, a.map)[0]] += 1
    print("python: n=%d hit=%d empty=%d conflict=%d (hit %.1f%%)  refresh=%d  per-bank=%s"
          % (n, cnt[0], cnt[1], cnt[2], 100.0 * cnt[0] / max(n, 1), len(refs), banks))
    if a.expect:
        exp = [int(x) for x in a.expect.split(",")]
        if exp == cnt:
            print("MATCH")
        else:
            print("MISMATCH: RTL %s" % exp)
            sys.exit(1)


if __name__ == "__main__":
    main()
