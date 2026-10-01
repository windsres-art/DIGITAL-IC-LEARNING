# 编码演示（第 1 节用，不自检查）：每种格式、每个"坑"各一条
#   python3 rv32_asm.py programs/encode_demo.s -o build/encode_demo   → 看 build/encode_demo.lst
#   riscv64-unknown-elf-objdump -d 可对照（asm_crosscheck.py 已逐字比对）

    .data
tohost: .word 0
buf:    .word 0, 0

    .text
_start:
    add  a0, a1, a2           # R 型
    sub  a0, a1, a2           # R 型，funct7 = 0100000
    addi a0, a1, -1           # I 型，负立即数
    srai a0, a1, 3            # I 型移位：imm[11:5] = 0100000 区分 srai / srli
    lw   a0, 8(sp)            # I 型（load）
    sw   a0, -4(sp)           # S 型：立即数被拆成 [11:5] 和 [4:0]
    li   t0, 0x12345678       # lui + addi：低 12 位 0x678 < 0x800，不借位
    li   t1, 0x12345fff       # 低 12 位 0xfff ≥ 0x800 → addi -1，lui 要先加 1：0x12346
    li   t2, -2048            # 正好落在 12 bit 有符号范围，一条 addi
    li   t3, 0x80000000       # 只需 lui（低 12 位为 0）
    la   a0, buf              # auipc + addi：PC 相对，代码搬到哪里都对
back:
    beq  a0, a1, back         # B 型，偏移 0
    bne  a0, a1, back         # B 型，偏移 -4：符号位在 instr[31]
    jal  ra, fwd              # J 型
fwd:
    call func                 # auipc ra + jalr ra
    ecall
func:
    ret                       # jalr x0, 0(ra)
