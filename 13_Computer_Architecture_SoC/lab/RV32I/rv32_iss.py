#!/usr/bin/env python3
"""RV32I 指令集模拟器（ISS），作为 RTL 的参考模型。

用法：python3 rv32_iss.py build/prog [--trace build/prog.trace.hex] [--pipe]

- 读 rv32_asm.py 生成的 prog.text.hex / prog.data.hex，从 PC=0 执行到 ecall。
- 内存映射：指令存储器 0x0000_0000 起 16 KB；数据存储器 0x1000_0000 起 16 KB。
  数据段第一个字是 tohost：程序自检查通过写 1，失败写 (测试号 << 1) | 1。
- --trace：每条提交的指令写 5 个字给 testbench 做逐条比对（lockstep）：
    pc, flags, rd_wdata, st_addr, st_data
    flags[4:0] = rd，flags[5] = 写寄存器（rd != 0），flags[11:8] = 存储字节使能
- --pipe：用"按阶段推算"的时序模型，预测第 2 节五级流水线在各种配置下的周期数，
  与 RTL 实测比对（见本章 README 第 2 节）。
"""
import argparse
import sys
from collections import Counter

IMEM_BASE, IMEM_SIZE = 0x0000_0000, 16 * 1024
DMEM_BASE, DMEM_SIZE = 0x1000_0000, 16 * 1024
MASK = 0xffffffff


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


class Trap(Exception):
    pass


class Decoded:
    """把一条指令拆成字段。与 RTL 的译码器独立实现。"""
    __slots__ = ('w', 'opc', 'rd', 'f3', 'rs1', 'rs2', 'f7', 'imm', 'name', 'uses1', 'uses2')

    def __init__(self, w):
        self.w = w
        self.opc = w & 0x7f
        self.rd = (w >> 7) & 31
        self.f3 = (w >> 12) & 7
        self.rs1 = (w >> 15) & 31
        self.rs2 = (w >> 20) & 31
        self.f7 = w >> 25
        o = self.opc
        i_imm = sx(w >> 20, 12)
        s_imm = sx(((w >> 25) << 5) | ((w >> 7) & 31), 12)
        b_imm = sx((((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) |
                   (((w >> 25) & 0x3f) << 5) | (((w >> 8) & 0xf) << 1), 13)
        u_imm = w & 0xfffff000
        j_imm = sx((((w >> 31) & 1) << 20) | (((w >> 12) & 0xff) << 12) |
                   (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3ff) << 1), 21)
        self.uses1 = self.uses2 = False
        if o == 0x37:
            self.name, self.imm = 'lui', u_imm
        elif o == 0x17:
            self.name, self.imm = 'auipc', u_imm
        elif o == 0x6f:
            self.name, self.imm = 'jal', j_imm
        elif o == 0x67 and self.f3 == 0:
            self.name, self.imm, self.uses1 = 'jalr', i_imm, True
        elif o == 0x63 and self.f3 not in (2, 3):
            self.name = ['beq', 'bne', '', '', 'blt', 'bge', 'bltu', 'bgeu'][self.f3]
            self.imm, self.uses1, self.uses2 = b_imm, True, True
        elif o == 0x03 and self.f3 in (0, 1, 2, 4, 5):
            self.name = ['lb', 'lh', 'lw', '', 'lbu', 'lhu'][self.f3]
            self.imm, self.uses1 = i_imm, True
        elif o == 0x23 and self.f3 in (0, 1, 2):
            self.name = ['sb', 'sh', 'sw'][self.f3]
            self.imm, self.uses1, self.uses2 = s_imm, True, True
        elif o == 0x13:
            self.imm, self.uses1 = i_imm, True
            if self.f3 == 1 and self.f7 == 0:
                self.name = 'slli'
            elif self.f3 == 5 and self.f7 in (0, 0x20):
                self.name = 'srai' if self.f7 else 'srli'
            elif self.f3 in (1, 5):
                raise Trap(f'非法移位立即数 {w:08x}')
            else:
                self.name = {0: 'addi', 2: 'slti', 3: 'sltiu', 4: 'xori', 6: 'ori', 7: 'andi'}[self.f3]
        elif o == 0x33 and (self.f7 == 0 or (self.f7 == 0x20 and self.f3 in (0, 5))):
            names = ['add', 'sll', 'slt', 'sltu', 'xor', 'srl', 'or', 'and']
            self.name = names[self.f3]
            if self.f7 == 0x20:
                self.name = 'sub' if self.f3 == 0 else 'sra'
            self.imm, self.uses1, self.uses2 = 0, True, True
        elif o == 0x0f:
            self.name, self.imm = 'fence', 0
        elif w == 0x00000073:
            self.name, self.imm = 'ecall', 0
        elif w == 0x00100073:
            self.name, self.imm = 'ebreak', 0
        else:
            raise Trap(f'非法指令 {w:08x}')

    @property
    def writes_rd(self):
        return self.name not in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu',
                                 'sb', 'sh', 'sw', 'fence', 'ecall', 'ebreak') and self.rd != 0


class ISS:
    def __init__(self, prefix):
        self.imem = self.load_hex(prefix + '.text.hex', IMEM_SIZE)
        self.dmem = bytearray(DMEM_SIZE)
        for i, w in enumerate(self.load_hex(prefix + '.data.hex', DMEM_SIZE)):
            self.dmem[4 * i:4 * i + 4] = w.to_bytes(4, 'little')
        self.x = [0] * 32
        self.pc = 0
        self.commits = []     # (pc, Decoded, rd_we, rd, wdata, strb, st_addr, st_data, next_pc)

    @staticmethod
    def load_hex(path, size):
        words = [int(l, 16) for l in open(path) if l.strip()]
        if len(words) * 4 > size:
            raise Trap(f'{path} 超出存储器大小')
        return words

    def daddr(self, a, n):
        if a % n:
            raise Trap(f'非对齐访问 0x{a:08x}（本模型与 RTL 都不支持，规范允许实现为异常）')
        off = a - DMEM_BASE
        if not 0 <= off <= DMEM_SIZE - n:
            raise Trap(f'访问越界 0x{a:08x}')
        return off

    def step(self):
        pc = self.pc
        if pc % 4 or not 0 <= pc - IMEM_BASE < IMEM_SIZE:
            raise Trap(f'取指地址非法 0x{pc:08x}')
        idx = (pc - IMEM_BASE) // 4
        w = self.imem[idx] if idx < len(self.imem) else 0
        d = Decoded(w)
        a, b = self.x[d.rs1], self.x[d.rs2]
        sa, sb = sx(a, 32), sx(b, 32)
        n = d.name
        nxt = (pc + 4) & MASK
        res = None
        strb = st_addr = st_data = 0
        imm = d.imm & MASK
        if n == 'lui':
            res = d.imm
        elif n == 'auipc':
            res = pc + d.imm
        elif n == 'jal':
            res, nxt = pc + 4, (pc + d.imm) & MASK
        elif n == 'jalr':
            res, nxt = pc + 4, (a + d.imm) & MASK & ~1   # 目标地址最低位清零
        elif n in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'):
            take = {'beq': a == b, 'bne': a != b, 'blt': sa < sb, 'bge': sa >= sb,
                    'bltu': a < b, 'bgeu': a >= b}[n]
            if take:
                nxt = (pc + d.imm) & MASK
        elif n in ('lb', 'lh', 'lw', 'lbu', 'lhu'):
            size = {'lb': 1, 'lbu': 1, 'lh': 2, 'lhu': 2, 'lw': 4}[n]
            ea = (a + d.imm) & MASK
            off = self.daddr(ea, size)
            v = int.from_bytes(self.dmem[off:off + size], 'little')
            res = v if n in ('lbu', 'lhu', 'lw') else sx(v, 8 * size)
        elif n in ('sb', 'sh', 'sw'):
            size = {'sb': 1, 'sh': 2, 'sw': 4}[n]
            ea = (a + d.imm) & MASK
            off = self.daddr(ea, size)
            self.dmem[off:off + size] = (b & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
            strb = ((1 << size) - 1) << (ea & 3)
            st_addr = ea & ~3
            # 总线上的写数据：把字节 / 半字复制到所有通道，由字节使能决定写哪几个（TB 只比对使能的通道）
            st_data = {1: (b & 0xff) * 0x01010101, 2: (b & 0xffff) * 0x00010001, 4: b}[size]
        elif n in ('addi', 'slti', 'sltiu', 'xori', 'ori', 'andi',
                   'add', 'sub', 'slt', 'sltu', 'xor', 'or', 'and'):
            rhs, srhs = (imm, sx(imm, 32)) if d.opc == 0x13 else (b, sb)
            base = n[:-1] if d.opc == 0x13 and n != 'sltiu' else n
            base = 'sltu' if n == 'sltiu' else base
            res = {'add': a + rhs, 'sub': a - rhs, 'slt': int(sa < srhs), 'sltu': int(a < (rhs & MASK)),
                   'xor': a ^ rhs, 'or': a | rhs, 'and': a & rhs}[base]
        elif n in ('slli', 'srli', 'srai', 'sll', 'srl', 'sra'):
            sh = (d.rs2 if d.opc == 0x13 else b) & 31   # 移位量只取低 5 位
            if n in ('srai', 'sra'):
                res = sa >> sh
            elif n in ('srli', 'srl'):
                res = a >> sh
            else:
                res = a << sh
        elif n in ('fence', 'ecall', 'ebreak'):
            pass
        rd_we = res is not None and d.rd != 0
        wdata = res & MASK if rd_we else 0
        if rd_we:
            self.x[d.rd] = wdata
        self.commits.append((pc, d, rd_we, d.rd if rd_we else 0, wdata, strb, st_addr, st_data, nxt))
        self.pc = nxt
        return n

    def run(self, max_steps=2_000_000):
        while len(self.commits) < max_steps:
            if self.step() in ('ecall', 'ebreak'):
                return
        raise Trap('超过最大步数，可能死循环')

    @property
    def tohost(self):
        return int.from_bytes(self.dmem[0:4], 'little')

    def write_trace(self, path):
        with open(path, 'w') as f:
            for pc, d, we, rd, wd, strb, sa, sdat, _ in self.commits:
                flags = (strb << 8) | (int(we) << 5) | rd
                f.write(f'{pc:08x}\n{flags:08x}\n{wd:08x}\n{sa:08x}\n{sdat:08x}\n')


# ---------------------------------------------------------------------------
# 五级流水线时序模型（只用于预测 ../Pipeline 的周期数，不参与功能比对）
#   t(i) = 第 i 条指令在 ID 级的周期。EX = t+1，MEM = t+2，WB = t+3。
#   约束：
#     顺序：           t(i) >= t(i-1) + 1
#     控制冒险：       上一条在 EX 级改向（预测错） -> t(i) >= t(i-1) + 3（冲掉 IF、ID 两条）
#     数据冒险 FWD=1： 生产者是 load 且紧挨着 -> t(i) >= t(p) + 2（load-use 停 1 拍）
#     数据冒险 FWD=0： 任何生产者 -> t(i) >= t(p) + 3（等它到 WB，寄存器堆写穿透）
#   第一条指令复位后第 1 个周期在 IF，第 2 个周期在 ID；ecall 到达 WB 的周期即结束。
# ---------------------------------------------------------------------------
BRANCHES = ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu')


def redirect(d, pc, nxt, bp):
    """该指令在 EX 级是否需要改向：预测的下一条 PC 与实际不同（与 RTL 的判断方式相同）。
    bp=0 总预测不跳；bp=1 静态 BTFN（向后的分支预测跳）+ IF 级预译码 jal；jalr 都不预测。"""
    pred = (pc + 4) & MASK
    if bp == 1 and (d.name == 'jal' or (d.name in BRANCHES and d.imm < 0)):
        pred = (pc + d.imm) & MASK
    return pred != nxt


def pipe_model(commits, fwd, bp):
    t_prev = 1                   # 虚拟的"第 0 条"，使第一条的 t = 2
    pen_prev = 0
    last_w = {}                  # reg -> (t, is_load, 序号)
    stalls = flushes = 0
    for k, (pc, d, we, rd, _, _, _, _, nxt) in enumerate(commits):
        t = t_prev + 1 + pen_prev
        need = t
        for use, r in ((d.uses1, d.rs1), (d.uses2, d.rs2)):
            if use and r and r in last_w:
                tp, is_load, kp = last_w[r]
                if fwd:
                    if is_load:
                        need = max(need, tp + 2)
                else:
                    need = max(need, tp + 3)
        stalls += need - t
        t = need
        if we:
            last_w[rd] = (t, d.name in ('lb', 'lh', 'lw', 'lbu', 'lhu'), k)
        pen_prev = 2 if redirect(d, pc, nxt, bp) else 0
        flushes += pen_prev // 2
        t_prev = t
    return t_prev + 3, stalls, flushes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('prefix')
    ap.add_argument('--trace')
    ap.add_argument('--pipe', action='store_true')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args()
    iss = ISS(a.prefix)
    try:
        iss.run()
    except Trap as e:
        print(f'ISS TRAP @pc=0x{iss.pc:08x}: {e}')
        sys.exit(1)
    if a.trace:
        iss.write_trace(a.trace)
    n = len(iss.commits)
    mix = Counter()
    taken = 0
    for pc, d, *_, nxt in iss.commits:
        cls = ('load' if d.opc == 0x03 else 'store' if d.opc == 0x23 else
               'branch' if d.opc == 0x63 else 'jump' if d.name in ('jal', 'jalr') else
               'system' if d.name in ('ecall', 'ebreak', 'fence') else 'alu')
        mix[cls] += 1
        if d.opc == 0x63 and nxt != pc + 4:
            taken += 1
    th = iss.tohost
    status = 'PASS' if th == 1 else f'FAIL(test {th >> 1})' if th & 1 else f'tohost={th}'
    if not a.quiet:
        print(f'ISS: {n} instructions, tohost={th} ({status})')
        print('     mix: ' + '  '.join(f'{k}={mix[k]}' for k in
                                      ('alu', 'load', 'store', 'branch', 'jump', 'system')) +
              f'  branch_taken={taken}/{mix["branch"]}')
    if a.pipe:
        for fwd, bp in ((1, 0), (0, 0), (1, 1)):
            cyc, st, fl = pipe_model(iss.commits, fwd, bp)
            print(f'MODEL FWD={fwd} BP={bp}: cycles={cyc} stalls={st} flushes={fl} '
                  f'CPI={cyc / n:.3f}')
    sys.exit(0 if th == 1 else 2)


if __name__ == '__main__':
    main()
