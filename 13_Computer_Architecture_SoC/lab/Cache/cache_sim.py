#!/usr/bin/env python3
"""cache 行为模拟器：与 cache.v 的策略完全相同（真 LRU、写回+写分配 / 写直达+写不分配）。

用法：
  python3 cache_sim.py replay build/trace.txt --sets 16 --ways 2 --line 16 --wb 1 --expect H,M,WB
      重放 testbench 写出的请求序列，独立复算命中 / 缺失 / 写回次数，与 RTL 比对
  python3 cache_sim.py experiments
      第 3 节用到的几组实验：循环顺序、冲突与相联度、3C 分类、行大小与 AMAT、写策略与内存流量
"""
import argparse
import random
import sys


class Cache:
    def __init__(self, size, ways, line, wb=True):
        assert size % (ways * line) == 0
        self.sets = size // (ways * line)
        self.ways, self.line, self.wb = ways, line, wb
        self.lru = [[] for _ in range(self.sets)]     # 每组一个列表：[tag, dirty]，下标 0 = 最近使用
        self.hits = self.misses = self.writebacks = 0
        self.rd_bytes = self.wr_bytes = 0

    def access(self, addr, write=False):
        blk = addr // self.line
        idx, tag = blk % self.sets, blk // self.sets
        s = self.lru[idx]
        for i, (t, d) in enumerate(s):
            if t == tag:
                self.hits += 1
                s.insert(0, [t, d or (write and self.wb)])
                del s[i + 1]
                if write and not self.wb:
                    self.wr_bytes += 4                   # 写直达：每次写都写内存
                return True
        self.misses += 1
        if write and not self.wb:                        # 写不分配
            self.wr_bytes += 4
            return False
        if len(s) == self.ways:
            t, d = s.pop()
            if d:
                self.writebacks += 1
                self.wr_bytes += self.line
        s.insert(0, [tag, write and self.wb])
        self.rd_bytes += self.line
        return False

    @property
    def miss_rate(self):
        n = self.hits + self.misses
        return self.misses / n if n else 0.0


def run(trace, size, ways, line, wb=True):
    c = Cache(size, ways, line, wb)
    for a, w in trace:
        c.access(a, w)
    return c


# ---------------------------------------------------------------------------
# 3C 分类：强制缺失（第一次碰这一行）、容量缺失（同容量全相联 LRU 也缺）、冲突缺失（其余）
# ---------------------------------------------------------------------------
def three_c(trace, size, ways, line):
    seen = set()
    comp = 0
    for a, _ in trace:
        b = a // line
        if b not in seen:
            seen.add(b)
            comp += 1
    total = run(trace, size, ways, line).misses
    fa = run(trace, size, size // line, line).misses
    return comp, fa - comp, total - fa, total


# ---------------------------------------------------------------------------
# 访问序列生成
# ---------------------------------------------------------------------------
def matrix_sum(n, row_major, base=0, pitch=None):
    """int A[n][pitch] 求和（只用前 n 列），元素 4 字节，按行优先存储；pitch > n 即行尾填充。"""
    pitch = pitch or n
    t = []
    for i in range(n):
        for j in range(n):
            r, c = (i, j) if row_major else (j, i)
            t.append((base + 4 * (r * pitch + c), False))
    return t


def streams(n, count, seed=1):
    """n 个缓慢前进的访问流：每次随机挑一个流，在它当前位置后 32 B 内随机读，1/4 概率前进 4 B。
    行太小 → 前进时频繁缺失（空间局部性没用上）；行太大 → 行数太少，n 个流互相挤占。"""
    rnd = random.Random(seed)
    p = [k * 1360 for k in range(n)]
    t = []
    for _ in range(count):
        s = rnd.randrange(n)
        t.append(((p[s] + rnd.randrange(0, 32)) // 4 * 4 % 16384, False))
        if rnd.random() < 0.25:
            p[s] += 4
    return t


def dot(n, a_base, b_base):
    """s += a[i] * b[i]：两个数组交替读。"""
    t = []
    for i in range(n):
        t.append((a_base + 4 * i, False))
        t.append((b_base + 4 * i, False))
    return t


def experiments():
    KB = 1024
    print('=== E1 循环顺序：int A[64][64]（16 KB）求和，cache 1 KB / 2 路 ===')
    for line in (16, 64):
        for rm in (True, False):
            c = run(matrix_sum(64, rm), 1 * KB, 2, line)
            print(f'  line={line:3d}B  {"行优先" if rm else "列优先"}: miss rate = {100 * c.miss_rate:6.2f}%')
    c = run(matrix_sum(64, False, pitch=68), 1 * KB, 2, 16)
    print(f'  line= 16B  列优先，每行填充 16 B（A[64][68]）: miss rate = {100 * c.miss_rate:6.2f}%')

    print('\n=== E2 冲突与相联度：dot(a, b)，a、b 相距 4 KB，各 256 个 int，cache 1 KB / 16B 行 ===')
    tr = dot(256, 0, 4 * KB)
    for ways in (1, 2, 4, 64):
        c = run(tr, 1 * KB, ways, 16)
        name = '全相联' if ways == 64 else f'{ways} 路'
        print(f'  {name:>5}: miss rate = {100 * c.miss_rate:6.2f}%')
    tr2 = dot(256, 0, 4 * KB + 16)                       # b 错开一行（padding）
    c = run(tr2, 1 * KB, 1, 16)
    print(f'  直接映射，b 错开 16 B（padding）: miss rate = {100 * c.miss_rate:6.2f}%')

    print('\n=== E3 3C 分类（cache 1 KB / 16B 行）===')
    traces = {'dot 相距 4KB': tr, '列优先矩阵': matrix_sum(64, False),
              '列优先+填充': matrix_sum(64, False, pitch=68)}
    rnd = random.Random(1)
    traces['随机 4KB 范围'] = [(rnd.randrange(0, 4 * KB, 4), False) for _ in range(20000)]
    for name, t in traces.items():
        for ways in (1, 2, 4):
            comp, cap, conf, tot = three_c(t, 1 * KB, ways, 16)
            print(f'  {name:12s} {ways} 路: 总缺失 {tot:6d} = 强制 {comp:5d} + 容量 {cap:6d} + 冲突 {conf:6d}')

    print('\n=== E4 行大小与 AMAT（cache 1 KB / 2 路；命中 1 拍，缺失代价 = 8 + 每字 1 拍）===')
    seq = matrix_sum(64, True)
    rnd_t = [(rnd.randrange(0, 16 * KB, 4), False) for _ in range(20000)]
    loc = streams(4, 40000)
    print('  line   顺序 miss / AMAT      4 个流 miss / AMAT      随机 miss / AMAT')
    for line in (8, 16, 32, 64, 128, 256):
        pen = 8 + line // 4
        row = []
        for t in (seq, loc, rnd_t):
            c = run(t, 1 * KB, 2, line)
            row.append(f'{100 * c.miss_rate:6.2f}% / {1 + c.miss_rate * pen:5.2f}')
        print(f'  {line:4d}B  ' + '      '.join(row))

    print('\n=== E5 写策略与内存流量：对 256 B 的数组反复读改写 20 遍，cache 1 KB / 2 路 / 16B 行 ===')
    t = []
    for _ in range(20):
        for i in range(64):
            t.append((4 * i, False))
            t.append((4 * i, True))
    for wb in (True, False):
        c = run(t, 1 * KB, 2, 16, wb)
        dirty = sum(d for s in c.lru for _, d in s)
        print(f'  {"写回  " if wb else "写直达"}: miss rate {100 * c.miss_rate:5.2f}%  内存读 {c.rd_bytes:5d} B  '
              f'写 {c.wr_bytes:5d} B  结束时 cache 里的脏行 {dirty}')


def replay(a):
    trace = []
    for ln in open(a.trace):
        op, addr = ln.split()
        trace.append((int(addr, 16), op == 'W'))
    c = run(trace, a.sets * a.ways * a.line, a.ways, a.line, bool(a.wb))
    print(f'cache_sim: reqs={len(trace)} hits={c.hits} misses={c.misses} writebacks={c.writebacks}')
    if a.expect:
        exp = tuple(int(x) for x in a.expect.split(','))
        got = (c.hits, c.misses, c.writebacks)
        print('MATCH: 与 RTL 计数完全一致' if got == exp else f'MISMATCH: RTL {exp} vs 模型 {got}')
        return 0 if got == exp else 1
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('replay')
    r.add_argument('trace')
    r.add_argument('--sets', type=int, required=True)
    r.add_argument('--ways', type=int, required=True)
    r.add_argument('--line', type=int, required=True)
    r.add_argument('--wb', type=int, default=1)
    r.add_argument('--expect')
    sub.add_parser('experiments')
    a = ap.parse_args()
    if a.cmd == 'replay':
        return replay(a)
    experiments()
    return 0


if __name__ == '__main__':
    sys.exit(main())
