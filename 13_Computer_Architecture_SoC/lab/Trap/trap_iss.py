#!/usr/bin/env python3
"""RV32I + Zicsr + 机器模式 trap 的参考模型，按 RTL 日志逐条复核（trace-driven co-simulation）。

用法：python3 trap_iss.py build/prog build/prog.log [--map trap|soc]

中断何时到来取决于 RTL 的时序（定时器、外设、总线等待），离线的 ISS 无法预知。
做法和工业界的 co-simulation 一样：
- 日志里的 "T" 行如果是中断，ISS 不去猜它什么时候来，而是检查它**合法**：
  PC 对得上、mstatus.MIE = 1、cause 是 (mip & mie) 里优先级最高的那个，然后自己进入 trap；
- 读外设寄存器、读 mcycle / mip 的结果是"不确定值"，ISS 直接采用日志里的值；
- 其余一切（每条指令的写回、存储、CSR 读写、同步异常的 cause / tval、trap 入口地址、
  mret 恢复的 MIE）都由 ISS 自己算，与日志逐条比对。

日志格式（tb 写出）：
  C pc insn rd_we rd wdata wstrb st_addr st_data      一条指令退休
  T cause epc tval mip                                进入 trap
  D addr data                                         DMA 往 RAM 写了一个字（只有 --map soc）
  R x1 … x31                                          寄存器堆上电值（只有 --map soc，第一行）

--map soc（第 6 节的 SoC）与 --map trap 的区别：
- 0x0000_0000 起 16 KB 是 ROM：数据口可读（代码 + 0x2000 处的 .data 初值），写 → 存储访问错误；
- RAM 上电内容随机：ISS 记录每个字节是否被写过，读到没写过的字节就报错
  （启动代码漏拷 .data、漏清 .bss，或者程序读了未初始化的栈，都会在这里暴露）。
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'RV32I'))
from rv32_iss import Decoded, Trap, sx, MASK  # noqa: E402

IMEM_SIZE = 16 * 1024
DMEM_BASE, DMEM_SIZE = 0x1000_0000, 16 * 1024
MAPS = {
    # 名字: [(基址, 大小)]  外设区：读是不确定值，写不影响 ISS 的内存
    'trap': [(0x0200_0000, 0x1_0000), (0x0C00_0000, 0x40_0000), (0x3000_0000, 0x100)],
    'soc':  [(0x0200_0000, 0x1_0000), (0x0C00_0000, 0x40_0000), (0x2000_0000, 0x10),
             (0x2000_1000, 0x1000)],
}
ROM_SIZE, ROM_DATA = 16 * 1024, 0x2000
CSR_ADDRS = {0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342, 0x343, 0x344,
             0xb00, 0xb02, 0xb80, 0xb82, 0xf11, 0xf12, 0xf13, 0xf14}
NONDET_CSR = {0xb00, 0xb80, 0x344}                    # mcycle、mcycleh、mip
IRQ_PRIO = [11, 3, 7]                                 # MEI > MSI > MTI


class Exc(Exception):
    def __init__(self, cause, tval=0):
        super().__init__(f'cause={cause} tval={tval:#x}')
        self.cause, self.tval = cause, tval & MASK


class TrapISS:
    def __init__(self, prefix, devmap):
        self.imem = [int(l, 16) for l in open(prefix + '.text.hex') if l.strip()]
        data = b''.join(int(l, 16).to_bytes(4, 'little') for l in open(prefix + '.data.hex') if l.strip())
        self.dmem = bytearray(DMEM_SIZE)
        self.soc = devmap == 'soc'
        if self.soc:
            self.rom = bytearray(ROM_SIZE)
            for i, w in enumerate(self.imem):
                self.rom[4 * i:4 * i + 4] = w.to_bytes(4, 'little')
            self.rom[ROM_DATA:ROM_DATA + len(data)] = data
            self.init = bytearray(DMEM_SIZE)             # 1 = 这个字节写过
        else:
            self.dmem[:len(data)] = data
            self.init = None
        self.uninit = []
        self.dev = MAPS[devmap]
        self.x = [0] * 32
        self.pc = 0
        self.mie_bit = self.mpie = 0
        self.mie = 0
        self.mtvec = self.mscratch = self.mepc = self.mcause = self.mtval = 0
        self.minstret = 0
        self.ntrap = {}

    # ---------------- 存储器 ----------------
    def is_dev(self, a):
        return any(b <= a < b + n for b, n in self.dev)

    def access(self, a, n, store):
        """返回 (存储器, 偏移)；外设返回 None；其它抛访问错误。"""
        if a % n:
            raise Exc(6 if store else 4, a)
        if DMEM_BASE <= a and a + n <= DMEM_BASE + DMEM_SIZE:
            return self.dmem, a - DMEM_BASE
        if self.soc and a + n <= ROM_SIZE and not store:
            return self.rom, a
        if self.is_dev(a):
            return None
        raise Exc(7 if store else 5, a)

    def load(self, mem, off, size):
        if mem is self.dmem and self.init is not None and not all(self.init[off:off + size]):
            self.uninit.append(DMEM_BASE + off)
        return int.from_bytes(mem[off:off + size], 'little')

    def store(self, off, size, v):
        self.dmem[off:off + size] = v.to_bytes(size, 'little')
        if self.init is not None:
            self.init[off:off + size] = b'\x01' * size

    # ---------------- CSR ----------------
    def csr_read(self, a):
        return {0x300: (3 << 11) | (self.mpie << 7) | (self.mie_bit << 3), 0x301: 0x4000_0100,
                0x304: self.mie, 0x305: self.mtvec, 0x340: self.mscratch, 0x341: self.mepc,
                0x342: self.mcause, 0x343: self.mtval,
                0xb02: self.minstret & MASK, 0xb82: self.minstret >> 32}.get(a, 0)

    def csr_write(self, a, v):
        if a == 0x300:
            self.mie_bit, self.mpie = (v >> 3) & 1, (v >> 7) & 1
        elif a == 0x304:
            self.mie = v & 0x888
        elif a == 0x305:
            self.mtvec = v & ~2 & MASK
        elif a == 0x340:
            self.mscratch = v
        elif a == 0x341:
            self.mepc = v & ~3 & MASK
        elif a == 0x342:
            self.mcause = v
        elif a == 0x343:
            self.mtval = v
        elif a == 0xb02:                   # 本条退休的自增先发生，再被写覆盖
            self.minstret = (self.minstret & ~MASK) | v
        elif a == 0xb82:
            self.minstret = (self.minstret & MASK) | (v << 32)

    # ---------------- trap ----------------
    def enter(self, cause, tval, epc):
        self.mepc, self.mcause, self.mtval = epc, cause, tval
        self.mpie, self.mie_bit = self.mie_bit, 0
        base = self.mtvec & ~3
        irq = cause >> 31
        self.pc = base + 4 * (cause & 0xf) if (irq and self.mtvec & 1) else base
        key = ('irq ' if irq else 'exc ') + str(cause & 0xf)
        self.ntrap[key] = self.ntrap.get(key, 0) + 1

    def check_irq(self, cause, epc, mip):
        if epc != self.pc:
            return f'中断的 epc {epc:08x} != ISS 的 pc {self.pc:08x}'
        if not self.mie_bit:
            return 'mstatus.MIE = 0 时进入了中断'
        p = mip & self.mie
        if not p:
            return f'mip & mie = 0（mip={mip:03x} mie={self.mie:03x}）时进入了中断'
        want = next(c for c in IRQ_PRIO if p >> c & 1)
        if (cause & 0xf) != want or not cause >> 31:
            return f'cause={cause:08x}，按优先级应为 {want}'
        return None

    # ---------------- 一条指令 ----------------
    def step(self, ext_val):
        """执行一条指令。返回 (rd_we, rd, wdata, strb, st_addr, st_data)；同步异常抛 Exc。
        ext_val：RTL 日志里的写回值，用于不确定值（外设读、mcycle、mip）。"""
        pc = self.pc
        w = self.imem[pc // 4] if pc // 4 < len(self.imem) else 0
        nxt = (pc + 4) & MASK
        res = None
        strb = st_addr = st_data = 0
        inc = 1
        rd = (w >> 7) & 31
        if w & 0x7f == 0x73:
            f3, rs1, csr = (w >> 12) & 7, (w >> 15) & 31, w >> 20
            if w == 0x00000073:
                raise Exc(11, 0)
            if w == 0x00100073:
                raise Exc(3, pc)
            if w == 0x30200073:
                self.mie_bit, self.mpie = self.mpie, 1
                nxt = self.mepc
            elif w == 0x10500073:
                pass                                        # wfi：架构上等同于 nop
            elif f3 in (1, 2, 3, 5, 6, 7):
                writes = (f3 & 3) == 1 or rs1 != 0
                if csr not in CSR_ADDRS or (writes and csr >> 10 == 3):
                    raise Exc(2, w)
                old = ext_val if csr in NONDET_CSR else self.csr_read(csr)
                src = rs1 if f3 & 4 else self.x[rs1]
                new = {1: src, 2: old | src, 3: old & ~src & MASK}[f3 & 3]
                if writes:
                    self.minstret += 1                      # 与 RTL 一致：本条的自增在前，写覆盖在后
                    inc = 0
                    self.csr_write(csr, new)
                res = old
            else:
                raise Exc(2, w)
        else:
            try:
                d = Decoded(w)
            except Trap:
                raise Exc(2, w) from None
            a, b = self.x[d.rs1], self.x[d.rs2]
            n = d.name
            if n == 'lui':
                res = d.imm
            elif n == 'auipc':
                res = pc + d.imm
            elif n in ('jal', 'jalr'):
                tgt = (pc + d.imm) & MASK if n == 'jal' else (a + d.imm) & MASK & ~1
                if tgt & 2:
                    raise Exc(0, tgt)
                res, nxt = pc + 4, tgt
            elif n in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'):
                sa_, sb_ = sx(a, 32), sx(b, 32)
                if {'beq': a == b, 'bne': a != b, 'blt': sa_ < sb_, 'bge': sa_ >= sb_,
                        'bltu': a < b, 'bgeu': a >= b}[n]:
                    tgt = (pc + d.imm) & MASK
                    if tgt & 2:
                        raise Exc(0, tgt)
                    nxt = tgt
            elif n in ('lb', 'lh', 'lw', 'lbu', 'lhu'):
                size = {'lb': 1, 'lbu': 1, 'lh': 2, 'lhu': 2, 'lw': 4}[n]
                ea = (a + d.imm) & MASK
                loc = self.access(ea, size, False)
                if loc is None:
                    res = ext_val
                else:
                    v = self.load(loc[0], loc[1], size)
                    res = v if n in ('lbu', 'lhu', 'lw') else sx(v, 8 * size)
            elif n in ('sb', 'sh', 'sw'):
                size = {'sb': 1, 'sh': 2, 'sw': 4}[n]
                ea = (a + d.imm) & MASK
                loc = self.access(ea, size, True)
                if loc is not None:
                    self.store(loc[1], size, b & ((1 << (8 * size)) - 1))
                strb = ((1 << size) - 1) << (ea & 3)
                st_addr = ea & ~3
                st_data = {1: (b & 0xff) * 0x01010101, 2: (b & 0xffff) * 0x00010001, 4: b}[size]
            elif n in ('fence',):
                pass
            else:
                # ALU 类：借用第 1 节 ISS 的语义太绕，这里直接算
                rhs = d.imm & MASK if d.opc == 0x13 else b
                sh = (d.rs2 if d.opc == 0x13 else b) & 31
                base = n[:-1] if (d.opc == 0x13 and n not in ('sltiu',) and n[-1] == 'i') else n
                base = 'sltu' if n == 'sltiu' else base
                res = {'add': a + rhs, 'sub': a - rhs, 'slt': int(sx(a, 32) < sx(rhs, 32)),
                       'sltu': int(a < rhs), 'xor': a ^ rhs, 'or': a | rhs, 'and': a & rhs,
                       'sll': a << sh, 'srl': a >> sh, 'sra': sx(a, 32) >> sh}[base]
        rd_we = res is not None and rd != 0
        wd = res & MASK if rd_we else 0
        if rd_we:
            self.x[rd] = wd
        self.minstret += inc
        self.pc = nxt
        return int(rd_we), rd if rd_we else 0, wd, strb, st_addr, st_data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('prog')
    ap.add_argument('log')
    ap.add_argument('--map', default='trap', choices=sorted(MAPS))
    a = ap.parse_args()
    iss = TrapISS(a.prog, a.map)
    errors = ncommit = ndma = 0
    for ln, line in enumerate(open(a.log), 1):
        t = line.split()
        if not t:
            continue
        err = None
        if t[0] == 'R':
            iss.x[1:32] = [int(v, 16) for v in t[1:32]]
        elif t[0] == 'D':
            addr, data = int(t[1], 16), int(t[2], 16)
            if not (DMEM_BASE <= addr < DMEM_BASE + DMEM_SIZE and addr % 4 == 0):
                err = f'DMA 写到了 RAM 以外 {addr:08x}'
            else:
                iss.store(addr - DMEM_BASE, 4, data)
                ndma += 1
        elif t[0] == 'T':
            cause, epc, tval, mip = (int(v, 16) for v in t[1:5])
            if cause >> 31:
                err = iss.check_irq(cause, epc, mip)
                if not err:
                    iss.enter(cause, 0, epc)
            else:
                pc = iss.pc
                try:
                    iss.step(0)
                    err = f'RTL 在 {epc:08x} 进入异常 cause={cause}，ISS 没有异常'
                except Exc as e:
                    if (e.cause, e.tval, pc) != (cause, tval, epc):
                        err = (f'异常不符：RTL cause={cause} tval={tval:08x} epc={epc:08x}，'
                               f'ISS cause={e.cause} tval={e.tval:08x} pc={pc:08x}')
                    else:
                        iss.enter(cause, tval, pc)
        else:
            pc, insn, we, rd, wd, strb, sa, sd = (int(v, 10 if k in (2, 3) else 16)
                                                  for k, v in enumerate(t[1:9]))
            if pc != iss.pc:
                err = f'pc {pc:08x}，ISS 应为 {iss.pc:08x}'
            else:
                try:
                    e = iss.step(wd)
                    lane = sum(0xff << (8 * i) for i in range(4) if e[3] >> i & 1)
                    if (we, rd, wd if we else 0, strb) != e[:4]:
                        err = f'写回 / 字节使能不符：RTL {(we, rd, wd, strb)}，ISS {e[:4]}'
                    elif strb and (sa != e[4] or (sd & lane) != (e[5] & lane)):
                        err = f'存储不符：RTL {sa:08x}/{sd:08x}，ISS {e[4]:08x}/{e[5]:08x}'
                except Exc as ex:
                    err = f'RTL 正常退休，ISS 产生异常 {ex}'
                if iss.uninit:
                    err = f'读了从未写过的 RAM {iss.uninit[0]:08x}（RAM 上电是随机值）'
                iss.uninit.clear()
            ncommit += 1
        if err:
            errors += 1
            if errors <= 5:
                print(f'MISMATCH 日志第 {ln} 行 ({line.strip()}): {err}')
            if errors > 50:
                break
    tohost = int.from_bytes(iss.dmem[0:4], 'little')
    traps = ', '.join(f'{k}×{v}' for k, v in sorted(iss.ntrap.items()))
    dma = f'、DMA 写 {ndma} 字' if ndma else ''
    print(f'trap_iss: {ncommit} 条退休、trap [{traps}]{dma} 全部复核，tohost={tohost}')
    if errors == 0 and tohost == 1:
        print('MATCH')
        return 0
    print(f'FAIL ({errors} 处不一致，tohost={tohost})')
    return 1


if __name__ == '__main__':
    sys.exit(main())
