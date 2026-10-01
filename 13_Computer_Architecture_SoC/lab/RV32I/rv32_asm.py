#!/usr/bin/env python3
"""RV32I 两遍汇编器（教学用，只依赖 Python 标准库）。

用法：python3 rv32_asm.py prog.s -o build/prog      # 生成 build/prog.text.hex / .data.hex / .lst

- 两个段：.text 从 0x0000_0000 开始（指令存储器），.data 从 0x1000_0000 开始（数据存储器）。
- 支持全部 RV32I 基础指令（含 fence / ecall / ebreak）和常用伪指令：
  nop li la mv not neg seqz snez j jal(单操作数) jr jalr(单操作数) ret call
  beqz bnez blez bgez bltz bgtz bgt ble bgtu bleu
- 第 5 节加入 Zicsr（csrrw/s/c、csrrwi/si/ci，伪指令 csrr csrw csrs csrc csrwi csrsi csrci，
  CSR 可以写名字或数字）、mret、wfi，以及 .text 段里的 .word（直接放一个指令字）。
- 第 6 节加入 .ascii / .asciz / .string（支持 \\n \\t \\0 \\\\ \\" 转义；字符串里不能有 #，
  因为 # 之后按注释处理）。
- 伪指令的展开方式与 GNU as（-march=rv32i，--no-relax 链接）一致，便于逐字比对：
  li 小立即数 → addi；否则 lui (+ addi，低 12 位为 0 时省略)
  la → auipc + addi（PC 相对），call → auipc ra + jalr ra
- 立即数写法：十进制、0x 十六进制、符号、%hi(x) / %lo(x)，以及 + - * << >> & | ~ ( ) 组成的表达式。
- 指令长度必须在第一遍就确定，所以 li 的立即数里不能出现"向前引用"的标号。
"""
import argparse
import re
import sys

TEXT_BASE = 0x0000_0000
DATA_BASE = 0x1000_0000

ABI = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2', 's0', 's1'] + \
      [f'a{i}' for i in range(8)] + [f's{i}' for i in range(2, 12)] + \
      ['t3', 't4', 't5', 't6']
REGS = {f'x{i}': i for i in range(32)}
REGS.update({n: i for i, n in enumerate(ABI)})
REGS['fp'] = 8

# 指令 → (格式, opcode, funct3, funct7)
OPS = {
    'lui':   ('U', 0x37, 0, 0), 'auipc': ('U', 0x17, 0, 0),
    'jal':   ('J', 0x6f, 0, 0), 'jalr':  ('I', 0x67, 0, 0),
    'beq':   ('B', 0x63, 0, 0), 'bne':   ('B', 0x63, 1, 0),
    'blt':   ('B', 0x63, 4, 0), 'bge':   ('B', 0x63, 5, 0),
    'bltu':  ('B', 0x63, 6, 0), 'bgeu':  ('B', 0x63, 7, 0),
    'lb':    ('L', 0x03, 0, 0), 'lh':    ('L', 0x03, 1, 0), 'lw': ('L', 0x03, 2, 0),
    'lbu':   ('L', 0x03, 4, 0), 'lhu':   ('L', 0x03, 5, 0),
    'sb':    ('S', 0x23, 0, 0), 'sh':    ('S', 0x23, 1, 0), 'sw': ('S', 0x23, 2, 0),
    'addi':  ('I', 0x13, 0, 0), 'slti':  ('I', 0x13, 2, 0), 'sltiu': ('I', 0x13, 3, 0),
    'xori':  ('I', 0x13, 4, 0), 'ori':   ('I', 0x13, 6, 0), 'andi':  ('I', 0x13, 7, 0),
    'slli':  ('SH', 0x13, 1, 0x00), 'srli': ('SH', 0x13, 5, 0x00), 'srai': ('SH', 0x13, 5, 0x20),
    'add':   ('R', 0x33, 0, 0x00), 'sub': ('R', 0x33, 0, 0x20),
    'sll':   ('R', 0x33, 1, 0x00), 'slt': ('R', 0x33, 2, 0x00), 'sltu': ('R', 0x33, 3, 0x00),
    'xor':   ('R', 0x33, 4, 0x00), 'srl': ('R', 0x33, 5, 0x00), 'sra':  ('R', 0x33, 5, 0x20),
    'or':    ('R', 0x33, 6, 0x00), 'and': ('R', 0x33, 7, 0x00),
    # Zicsr（第 5 节）：I 型格式，imm 字段放 CSR 地址；*i 形式的 rs1 字段放 5 bit 无符号立即数
    'csrrw': ('CSR', 0x73, 1, 0), 'csrrs': ('CSR', 0x73, 2, 0), 'csrrc': ('CSR', 0x73, 3, 0),
    'csrrwi': ('CSRI', 0x73, 5, 0), 'csrrsi': ('CSRI', 0x73, 6, 0), 'csrrci': ('CSRI', 0x73, 7, 0),
}

# 没有操作数、编码固定的系统指令
FIXED = {'ecall': 0x00000073, 'ebreak': 0x00100073, 'fence': 0x0ff0000f,   # fence 只支持无操作数形式
         'mret': 0x30200073, 'wfi': 0x10500073}

# 机器模式 CSR 名字 → 地址（第 5 节用到的子集）
CSRS = {'mstatus': 0x300, 'misa': 0x301, 'mie': 0x304, 'mtvec': 0x305, 'mscratch': 0x340,
        'mepc': 0x341, 'mcause': 0x342, 'mtval': 0x343, 'mip': 0x344,
        'mcycle': 0xb00, 'minstret': 0xb02, 'mcycleh': 0xb80, 'minstreth': 0xb82,
        'mvendorid': 0xf11, 'marchid': 0xf12, 'mimpid': 0xf13, 'mhartid': 0xf14}


class AsmError(Exception):
    pass


def s32(v):
    v &= 0xffffffff
    return v - (1 << 32) if v & 0x80000000 else v


def hi20(v):
    """%hi：加 0x800 是因为 addi 的低 12 位是有符号数，低位 ≥ 0x800 时要向高位借 1。"""
    return ((v + 0x800) >> 12) & 0xfffff


def lo12(v):
    """%lo：低 12 位按有符号数解释，与 hi20 配对满足 (hi20 << 12) + lo12 == v。"""
    return ((v & 0xfff) ^ 0x800) - 0x800


class Assembler:
    def __init__(self):
        self.syms = {}
        self.text = []      # (addr, word, 源码行)
        self.data = bytearray()

    # ---------------- 表达式 ----------------
    def eval(self, expr, pc=None, need=True):
        expr = expr.strip()
        m = re.fullmatch(r'%(hi|lo)\((.+)\)', expr)
        if m:
            v = self.eval(m.group(2), pc, need)
            if v is None:
                return None
            return hi20(v) if m.group(1) == 'hi' else lo12(v)

        def sub(mm):
            name = mm.group(0)
            if name in self.syms:
                return str(self.syms[name])
            if need:
                raise AsmError(f'未定义的符号 {name}')
            raise KeyError(name)

        if not re.fullmatch(r"[\w\s+\-*()<>&|~.]+", expr):
            raise AsmError(f'无法解析的表达式 {expr!r}')
        try:
            py = re.sub(r'(?<![\w.])(?!0x)[A-Za-z_.][\w.]*', sub, expr)
        except KeyError:
            return None
        try:
            return int(eval(py, {'__builtins__': {}}, {}))
        except Exception as e:  # noqa: BLE001
            raise AsmError(f'表达式错误 {expr!r}: {e}')

    @staticmethod
    def reg(tok):
        tok = tok.strip()
        if tok not in REGS:
            raise AsmError(f'不认识的寄存器 {tok!r}')
        return REGS[tok]

    @staticmethod
    def check_imm(v, bits, what, signed=True):
        lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
        if not lo <= v <= hi:
            raise AsmError(f'{what} = {v} 超出 {bits} bit 范围')

    # ---------------- 编码 ----------------
    def encode(self, op, args, pc):
        fmt, opc, f3, f7 = OPS[op]
        if fmt == 'R':
            rd, rs1, rs2 = (self.reg(a) for a in args)
            return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
        if fmt == 'SH':
            rd, rs1 = self.reg(args[0]), self.reg(args[1])
            sh = self.eval(args[2], pc)
            self.check_imm(sh, 5, 'shamt', signed=False)
            return (f7 << 25) | (sh << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
        if fmt == 'I':
            if op == 'jalr':
                rd, rs1, imm = self.mem_or_3(args, pc)
            else:
                rd, rs1, imm = self.reg(args[0]), self.reg(args[1]), self.eval(args[2], pc)
            self.check_imm(imm, 12, f'{op} 立即数')
            return ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
        if fmt == 'L':
            rd, rs1, imm = self.mem_or_3(args, pc)
            self.check_imm(imm, 12, f'{op} 偏移')
            return ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc
        if fmt == 'S':
            rs2, rs1, imm = self.mem_or_3(args, pc)
            self.check_imm(imm, 12, f'{op} 偏移')
            imm &= 0xfff
            return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
                   ((imm & 0x1f) << 7) | opc
        if fmt == 'B':
            rs1, rs2 = self.reg(args[0]), self.reg(args[1])
            off = self.eval(args[2], pc) - pc
            self.check_imm(off, 13, f'{op} 跳转距离')
            if off & 1:
                raise AsmError('分支偏移必须是偶数')
            o = off & 0x1fff
            return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3f) << 25) | (rs2 << 20) | \
                   (rs1 << 15) | (f3 << 12) | (((o >> 1) & 0xf) << 8) | \
                   (((o >> 11) & 1) << 7) | opc
        if fmt in ('CSR', 'CSRI'):
            rd = self.reg(args[0])
            c = args[1].strip().lower()
            csr = CSRS[c] if c in CSRS else self.eval(args[1], pc)
            self.check_imm(csr, 12, 'CSR 地址', signed=False)
            if fmt == 'CSR':
                src = self.reg(args[2])
            else:
                src = self.eval(args[2], pc)
                self.check_imm(src, 5, f'{op} 立即数', signed=False)
            return (csr << 20) | (src << 15) | (f3 << 12) | (rd << 7) | opc
        if fmt == 'U':
            rd, imm = self.reg(args[0]), self.eval(args[1], pc)
            self.check_imm(imm, 20, f'{op} 立即数', signed=False)
            return (imm << 12) | (rd << 7) | opc
        if fmt == 'J':
            rd = self.reg(args[0])
            off = self.eval(args[1], pc) - pc
            self.check_imm(off, 21, 'jal 跳转距离')
            o = off & 0x1fffff
            return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3ff) << 21) | \
                   (((o >> 11) & 1) << 20) | (((o >> 12) & 0xff) << 12) | (rd << 7) | opc
        raise AsmError(op)

    def mem_or_3(self, args, pc):
        """接受 `rd, imm(rs1)`、`rd, (rs1)` 和 `rd, rs1, imm` 三种写法。"""
        if len(args) == 2:
            m = re.fullmatch(r'(.*)\(\s*(\w+)\s*\)', args[1].strip())
            if not m:
                raise AsmError(f'访存操作数应为 imm(rs1)：{args[1]!r}')
            imm = self.eval(m.group(1), pc) if m.group(1).strip() else 0
            return self.reg(args[0]), self.reg(m.group(2)), imm
        return self.reg(args[0]), self.reg(args[1]), self.eval(args[2], pc)

    # ---------------- 伪指令展开 ----------------
    def expand(self, op, args, pc, first_pass):
        """返回 [(op, args)]。第一遍只需要知道条数，标号可以还未定义。"""
        def ev(x):
            return self.eval(x, pc, need=not first_pass)

        if op == 'nop':
            return [('addi', ['zero', 'zero', '0'])]
        if op == 'li':
            v = self.eval(args[1], pc, need=True)  # li 的值必须第一遍就已知
            v = s32(v)
            if -2048 <= v < 2048:
                return [('addi', [args[0], 'zero', str(v)])]
            seq = [('lui', [args[0], str(hi20(v))])]
            if lo12(v):
                seq.append(('addi', [args[0], args[0], str(lo12(v))]))
            return seq
        if op in ('la', 'call'):
            tgt = ev(args[-1])
            off = 0 if tgt is None else tgt - pc
            rd = args[0] if op == 'la' else 'ra'
            second = ('addi', [rd, rd, str(lo12(off))]) if op == 'la' else \
                     ('jalr', ['ra', f'{lo12(off)}(ra)'])
            return [('auipc', [rd, str(hi20(off))]), second]
        simple = {
            'mv':   lambda a: ('addi', [a[0], a[1], '0']),
            'not':  lambda a: ('xori', [a[0], a[1], '-1']),
            'neg':  lambda a: ('sub',  [a[0], 'zero', a[1]]),
            'seqz': lambda a: ('sltiu', [a[0], a[1], '1']),
            'snez': lambda a: ('sltu', [a[0], 'zero', a[1]]),
            'j':    lambda a: ('jal',  ['zero', a[0]]),
            'jr':   lambda a: ('jalr', ['zero', f'0({a[0]})']),
            'ret':  lambda a: ('jalr', ['zero', '0(ra)']),
            'beqz': lambda a: ('beq',  [a[0], 'zero', a[1]]),
            'bnez': lambda a: ('bne',  [a[0], 'zero', a[1]]),
            'blez': lambda a: ('bge',  ['zero', a[0], a[1]]),
            'bgez': lambda a: ('bge',  [a[0], 'zero', a[1]]),
            'bltz': lambda a: ('blt',  [a[0], 'zero', a[1]]),
            'bgtz': lambda a: ('blt',  ['zero', a[0], a[1]]),
            'bgt':  lambda a: ('blt',  [a[1], a[0], a[2]]),
            'ble':  lambda a: ('bge',  [a[1], a[0], a[2]]),
            'bgtu': lambda a: ('bltu', [a[1], a[0], a[2]]),
            'bleu': lambda a: ('bgeu', [a[1], a[0], a[2]]),
            'csrr':  lambda a: ('csrrs',  [a[0], a[1], 'zero']),
            'csrw':  lambda a: ('csrrw',  ['zero', a[0], a[1]]),
            'csrs':  lambda a: ('csrrs',  ['zero', a[0], a[1]]),
            'csrc':  lambda a: ('csrrc',  ['zero', a[0], a[1]]),
            'csrwi': lambda a: ('csrrwi', ['zero', a[0], a[1]]),
            'csrsi': lambda a: ('csrrsi', ['zero', a[0], a[1]]),
            'csrci': lambda a: ('csrrci', ['zero', a[0], a[1]]),
        }
        if op in simple:
            return [simple[op](args)]
        if op == 'jal' and len(args) == 1:
            return [('jal', ['ra', args[0]])]
        if op == 'jalr' and len(args) == 1 and '(' not in args[0]:
            return [('jalr', ['ra', f'0({args[0]})'])]
        return [(op, args)]

    # ---------------- 主流程 ----------------
    @staticmethod
    def split_args(s):
        return [a.strip() for a in s.split(',')] if s.strip() else []

    def run(self, lines):
        for first_pass in (True, False):
            sec = 'text'
            pc = {'text': TEXT_BASE, 'data': DATA_BASE}
            self.text, self.data = [], bytearray()
            for lineno, raw in enumerate(lines, 1):
                try:
                    self.line(raw, lineno, sec, pc, first_pass)
                    sec = self.cur_sec
                except AsmError as e:
                    raise AsmError(f'第 {lineno} 行：{e}\n    {raw.rstrip()}') from None

    def line(self, raw, lineno, sec, pc, first_pass):
        self.cur_sec = sec
        s = raw.split('#', 1)[0].strip()
        while True:
            m = re.match(r'([A-Za-z_.][\w.]*)\s*:\s*(.*)', s)
            if not m:
                break
            name = m.group(1)
            if first_pass:
                if name in self.syms:
                    raise AsmError(f'标号重复定义 {name}')
                self.syms[name] = pc[sec]
            s = m.group(2)
        if not s:
            return
        parts = s.split(None, 1)
        op, rest = parts[0].lower(), (parts[1] if len(parts) > 1 else '')
        args = self.split_args(rest)

        if op == '.word' and sec == 'text':
            # .text 里的 .word：直接放一个指令字（测试非法指令用）
            for a in args:
                v = 0 if first_pass else self.eval(a, pc['text'])
                self.text.append((pc['text'], v & 0xffffffff, raw.strip()))
                pc['text'] += 4
            return
        if op.startswith('.'):
            self.directive(op, args, rest, sec, pc, first_pass)
            return
        if sec != 'text':
            raise AsmError('指令只能放在 .text 段')
        for k, (real_op, real_args) in enumerate(self.expand(op, args, pc['text'], first_pass)):
            if real_op in FIXED:
                word = FIXED[real_op]
            elif real_op not in OPS:
                raise AsmError(f'不认识的指令 {real_op}')
            elif first_pass:
                word = 0
            else:
                word = self.encode(real_op, real_args, pc['text'])
            src = raw.strip() if k == 0 else f'    ({real_op} {", ".join(real_args)})'
            self.text.append((pc['text'], word, src))
            pc['text'] += 4

    def directive(self, op, args, rest, sec, pc, first_pass):
        if op in ('.text', '.data'):
            self.cur_sec = op[1:]
            return
        if op in ('.globl', '.global', '.section', '.option', '.file', '.type', '.size'):
            return
        if op == '.equ' or op == '.set':
            if first_pass:
                self.syms[args[0]] = self.eval(args[1])
            return
        if sec != 'data':
            raise AsmError(f'{op} 只能用在 .data 段')
        if op in ('.word', '.half', '.byte'):
            n = {'.word': 4, '.half': 2, '.byte': 1}[op]
            for a in args:
                v = self.eval(a, need=not first_pass) or 0
                self.data += (v & ((1 << (8 * n)) - 1)).to_bytes(n, 'little')
                pc['data'] += n
        elif op in ('.ascii', '.asciz', '.string'):
            m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', rest.strip())
            if not m:
                raise AsmError(f'{op} 需要一个带双引号的字符串')
            b = m.group(1).encode('latin-1').decode('unicode_escape').encode('latin-1')
            if op != '.ascii':
                b += b'\0'
            self.data += b
            pc['data'] += len(b)
        elif op in ('.space', '.zero'):
            n = self.eval(args[0])
            self.data += bytes(n)
            pc['data'] += n
        elif op in ('.align', '.p2align'):
            a = 1 << self.eval(args[0])
            while pc['data'] % a:
                self.data.append(0)
                pc['data'] += 1
        else:
            raise AsmError(f'不支持的伪操作 {op}')


def assemble(path):
    with open(path, encoding='utf-8-sig') as f:
        lines = f.readlines()
    asm = Assembler()
    asm.run(lines)
    return asm


def write_outputs(asm, prefix):
    with open(prefix + '.text.hex', 'w') as f:
        for _, w, _ in asm.text:
            f.write(f'{w:08x}\n')
    data = bytes(asm.data) + bytes(-len(asm.data) % 4)
    with open(prefix + '.data.hex', 'w') as f:
        for i in range(0, len(data), 4):
            f.write(f'{int.from_bytes(data[i:i + 4], "little"):08x}\n')
        if not data:
            f.write('00000000\n')
    with open(prefix + '.lst', 'w', encoding='utf-8') as f:
        for addr, w, src in asm.text:
            f.write(f'{addr:08x}: {w:08x}   {src}\n')
        f.write('\n# symbols\n')
        for k, v in sorted(asm.syms.items(), key=lambda kv: kv[1]):
            f.write(f'{v:08x} {k}\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('-o', '--out', required=True, help='输出前缀，如 build/isa_test')
    a = ap.parse_args()
    try:
        asm = assemble(a.src)
    except AsmError as e:
        print(f'{a.src}: {e}', file=sys.stderr)
        sys.exit(1)
    write_outputs(asm, a.out)
    print(f'{a.src}: {len(asm.text)} 条指令, {len(asm.data)} 字节数据 -> {a.out}.*')


if __name__ == '__main__':
    main()
