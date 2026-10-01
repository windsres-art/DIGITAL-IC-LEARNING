#!/usr/bin/env python3
"""把 rv32_asm.py 的输出和 GNU binutils 逐字比对，确认指令编码没写错。

用法：python3 asm_crosscheck.py programs/*.s
需要 riscv64-unknown-elf-{as,ld,objcopy}（Ubuntu：apt install binutils-riscv64-unknown-elf）；
没有安装时打印 SKIP 并返回 0，不影响其它仿真。
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32_asm import assemble, DATA_BASE  # noqa: E402

PFX = 'riscv64-unknown-elf-'


def gnu_words(src, tmp):
    obj, elf = os.path.join(tmp, 'a.o'), os.path.join(tmp, 'a.elf')
    subprocess.run([PFX + 'as', '-march=rv32i_zicsr', '-mabi=ilp32', '-o', obj, src], check=True)
    # --no-relax：不让链接器把 auipc+jalr 之类的序列缩短，保持与本汇编器相同的展开
    subprocess.run([PFX + 'ld', '-m', 'elf32lriscv', '--no-relax', '-Ttext=0',
                    f'-Tdata=0x{DATA_BASE:x}', '-e', '0', '-o', elf, obj], check=True)
    out = {}
    for sec in ('.text', '.data'):
        b = os.path.join(tmp, sec[1:] + '.bin')
        subprocess.run([PFX + 'objcopy', '-O', 'binary', '-j', sec, elf, b], check=True)
        data = open(b, 'rb').read()
        out[sec] = data
    return out


def main():
    if not shutil.which(PFX + 'as'):
        print('SKIP: 没有找到 riscv64-unknown-elf-as')
        return 0
    bad = 0
    for src in sys.argv[1:]:
        asm = assemble(src)
        mine_text = b''.join(w.to_bytes(4, 'little') for _, w, _ in asm.text)
        mine_data = bytes(asm.data)
        with tempfile.TemporaryDirectory() as tmp:
            g = gnu_words(src, tmp)
        diffs = []
        for i in range(max(len(mine_text), len(g['.text'])) // 4):
            a, b = mine_text[4 * i:4 * i + 4], g['.text'][4 * i:4 * i + 4]
            if a != b:
                diffs.append(f'  0x{4 * i:04x}: mine={a[::-1].hex() or "-"} gnu={b[::-1].hex() or "-"}'
                             f'   {asm.text[i][2] if i < len(asm.text) else ""}')
        data_ok = mine_data == g['.data'][:len(mine_data)] and len(g['.data']) >= len(mine_data)
        n = len(asm.text)
        if diffs or not data_ok:
            bad += 1
            print(f'MISMATCH {src}: {len(diffs)} 条指令不同, data {"ok" if data_ok else "不同"}')
            print('\n'.join(diffs[:10]))
        else:
            print(f'MATCH {src}: {n} 条指令, {len(mine_data)} 字节数据与 GNU as 完全一致')
    print('PASS' if bad == 0 else f'FAIL ({bad} 个文件不一致)')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
