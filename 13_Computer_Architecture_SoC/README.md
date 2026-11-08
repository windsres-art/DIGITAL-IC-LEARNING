# 13 体系结构与 SoC —— 面试向

目标：数字前端面试里，体系结构题通常这样考：

- 指令集：给一条指令让你手工编码或译码；问 RISC-V 为什么这样设计。
- 流水线：画五级流水线的时空图，说清三类冒险和对应的解决办法；手写前递与 load-use 检测。
- Cache：给参数算 tag / index / offset，算命中率和 AMAT；讲替换策略和写策略的取舍。
- 存储器：行命中 / 行冲突的延迟、DDR 带宽计算、地址映射与页策略。
- 中断与 DMA：trap 时硬件做了什么、流水线里怎么精确地接中断、PLIC 的 claim / complete、DMA 与 cache 的一致性。
- SoC：总线互联与仲裁、默认从机、APB 桥、从上电到 `main()` 的启动流程。

本章从一个 RV32I 指令集出发，依次写出汇编器、指令集模拟器（ISS）、单周期核、五级流水线、参数化 cache、DDR3 内存控制器、带精确 trap 的流水线核与中断控制器 / DMA，最后连成一个能从 ROM 启动、通过 UART 打印的最小 SoC。所有 RTL 都有自检查 testbench，用独立参考模型逐条比对，并配变异测试，在 WSL 中实际跑通。README 里贴的是真实输出。

前置知识：

- 寄存器堆、同步 / 组合读存储器：`../03_Common_Circuits/README.md` 第 11 节（本章的 2R1W 寄存器堆、写穿透都在那里讲过）
- 流水线与 skid buffer、valid/ready 握手：`../03_Common_Circuits/README.md` 第 13、8 节（CPU 流水线的停顿 / 冲刷就是"带取消的全局停顿流水"）
- 同步 FIFO：`../03_Common_Circuits/README.md` 第 1 节（写缓冲、取指队列）
- setup 时序与关键路径：`../07_STA/README.md` 第 4 节（流水线为什么能提高频率）
- 总线：`../12_Bus_Interfaces/README.md`（cache 的内存口、第 6 节 SoC 互联会用到；APB 在其第 1 节，UART 在其第 4 节）
- 轮转仲裁器：`../03_Common_Circuits/README.md` 中的 `Arbiter` 实验（第 6 节 crossbar 的仲裁）
- 复位同步、门控时钟：`../05_Clock_Reset_Design/README.md` 第 2、4、5 节；跨时钟域：`../06_CDC/README.md`（第 6 节的时钟 / 复位域）

建议顺序：

1. 第 1 节指令集：先把"指令长什么样"弄清楚，这是软硬件之间的契约。
2. 第 2 节流水线：先用单周期核理解数据通路，再切成五级，逐个解决冒险。
3. 第 3 节 Cache：流水线假设存储器一拍返回，cache 是让这个假设大体成立的办法。
4. 第 4 节存储层次与 DDR：cache 缺失之后真正去哪里取数据，为什么同一个地址有时快有时慢。
5. 第 5 节中断与 DMA：让核能响应计划外的事件（精确 trap），并把搬数据的活交给 DMA。
6. 第 6 节 SoC 集成：用互联、桥和启动代码把前面所有部件连成一颗能开机的芯片。

前三节是一条线：指令集定义要做什么，流水线决定每拍做多少，cache 决定数据能不能跟上。后三节是另一条线：存储器从哪来、事件怎么进来、部件怎么连起来。面试前直接看每节末尾的"面试要点"和第 8 节速查表。

配套实验（`lab/` 下，每个文件夹 `bash run_sim.sh` 一键 lint + 仿真，`bash mutation.sh` 跑变异测试）：

| 实验 | 内容 |
|------|------|
| `lab/RV32I/` | 两遍汇编器（伪指令、`%hi/%lo`、表达式，与 GNU as 逐字比对）；独立实现的 ISS（参考模型 + 指令统计 + 流水线时序模型）；单周期核（commit 接口）。5 个自检查程序，与 ISS 逐条比对；5 个变异 |
| `lab/Pipeline/` | 五级流水线，参数 `FWD`（前递开 / 关）× `BP`（总预测不跳 / 静态 BTFN / BTB + 2 bit 计数器）。与 ISS 逐条比对，周期数与解析模型逐拍相等；7 个变异 |
| `lab/Cache/` | 参数化组相联 cache（直接映射到全相联、真 LRU、写回 + 写分配 / 写直达 + 写不分配）。两层参考模型 + Python 独立复算；`cache_sim.py` 跑 5 组实验（循环顺序、冲突、3C、行大小、写策略）；7 个变异（含 1 个等价变异） |
| `lab/DRAM/` | DDR3-1600 内存控制器（4 种地址映射 × 开页 / 关页 × bank 预激活开关、队列深度可调、刷新），配逐命令时序检查的 DRAM 器件模型；Python 独立复算行命中分类；延迟探针、配置 × 负载矩阵、预激活和队列深度对比；8 个变异 |
| `lab/Trap/` | 流水线核加 Zicsr 与机器模式 trap（精确异常和中断、`wfi`、数据口等待 / 错误）；CLINT、PLIC、描述符链 DMA；`trap_iss.py` 按日志逐条复核（trace-driven co-simulation）；3 个自检查程序 × 有无随机等待；12 个变异 |
| `lab/SoC/` | 2 主 × 6 从 crossbar（轮转仲裁、默认从机）、APB 桥、带反压的 UART；ROM 启动的 crt0 + 5 项外设自检查；引脚上的 UART 监视器、上电随机化、ISS 复核与仲裁公平性断言；11 个变异 |

本章进度：第 1–6 节全部完成。

**如果单周期也有些忘了，从这里开始读。** 第 1.3–1.6 节的 ABI、编码和伪指令可以作为查阅材料，第一遍不必全部背下来。先读下面四段，再回头补指令细节：

1. [单周期：存储、数据通路与时钟](#single-cycle-start)：区分 PC、指令、寄存器编号和数据，理解组合计算与沿上更新。
2. [五级流水线：每一级到底保存什么](#pipeline-start)：把单周期的功能拆开，理解级间寄存器、控制信号和 `valid`。
3. [数据依赖：读到的值为什么可能过时](#pipeline-data-hazards)：依次看写穿透、EX 前递、load-use 和停顿动作。
4. [控制依赖：下一条指令从哪里来](#pipeline-control-hazards)：先看 `BP=0` 的冲刷，再看静态和动态预测。

讲解对应本章的 [单周期顶层](lab/RV32I/rv32i_single.v) 和 [五级流水线顶层](lab/Pipeline/rv32i_pipe.v)。两者共用 `lab/RV32I/` 下的功能模块。五级流水线的四组级间寄存器直接用 `if_id_* / id_ex_* / ex_mem_* / mem_wb_*` 命名，对应 IF/ID、ID/EX、EX/MEM、MEM/WB；本级信号使用 `if_ / id_ / ex_ / mem_ / wb_` 等前缀，下文沿用真实信号名。文中的小例子分别解释不同问题，不要求把所有机制套进同一个程序。

---

## 目录

1. [RISC-V 指令集](#1-risc-v-指令集)
2. [流水线与冒险](#2-流水线与冒险)
3. [Cache](#3-cache)
4. [存储层次与 DDR](#4-存储层次与-ddr)
5. [中断与 DMA](#5-中断与-dma)
6. [SoC 集成](#6-soc-集成)
7. [运行全部实验](#7-运行全部实验)
8. [速查表](#8-速查表)

---

## 1. RISC-V 指令集

### 1.1 解决什么问题，面试怎么考

**指令集架构（ISA，Instruction Set Architecture）** 是软件和硬件之间的契约：它规定有哪些寄存器、哪些指令、每条指令的二进制编码和语义、访存与异常的规则。只要遵守这份契约，同一个二进制程序就能跑在任何实现上：单周期、五级流水、乱序超标量都可以。

RISC-V 是开放、免授权费的 ISA，结构干净，近几年成了 CPU 面试的默认语言。它是模块化的：

- **基础整数指令集**：RV32I / RV64I（还有面向嵌入式的 RV32E，只有 16 个寄存器）。
- **标准扩展**：M（乘除）、A（原子）、F / D（单 / 双精度浮点）、C（16 bit 压缩指令）、Zicsr（CSR 读写）、Zifencei（指令 fence）等。
- 常见组合有 `RV32IMAC`（MCU）和 `RV64GC`（G = IMAFD + Zicsr + Zifencei，跑 Linux 用）。

本节只讲 RV32I：40 条指令，足够跑 C 程序（乘除可以用软件库实现）。

面试考法：

1. 手工编码 / 译码一条指令，常考 B 型、J 型立即数的拼接。
2. RISC-V 的编码设计有哪些"用心"之处？比如源寄存器位置固定、符号位永远在 `instr[31]`。
3. `li` 一个 32 bit 常数要几条指令？为什么 `lui` 的值有时要加 1（`%hi` 的 +0x800）？
4. 调用约定：哪些寄存器是调用者保存、哪些是被调用者保存；`ra`、`sp` 的作用。
5. RISC 与 CISC 的区别；为什么 RISC-V 没有条件码（flags）、没有延迟槽。

### 1.2 基本概念

RV32I 是典型的 **load-store 架构**：load / store 负责访问数据内存，整数运算的操作数来自寄存器或指令里的立即数。取指本身也要读指令存储器，不能把“只有 load / store 访存”理解为其它指令不需要取指。

| 项目 | RV32I 的规定 |
|------|--------------|
| 通用寄存器 | 32 个，每个 32 bit；`x0` 恒为 0（写入被丢弃） |
| PC | 单独的寄存器，不是通用寄存器（不能像 ARMv7 那样直接读写 PC） |
| 指令长度 | 固定 32 bit，4 字节对齐（有 C 扩展时 2 字节对齐） |
| 访存 | 字节寻址、小端（little-endian）；字节 / 半字 / 字三种宽度 |
| 条件码 | 没有。分支指令直接比较两个寄存器 |
| 溢出 | 加减法不报溢出，结果按 2^32 回绕；需要时用 `slt` / `sltu` 在软件里判断 |
| 非对齐访存 | 规范允许硬件支持，也允许报异常（本章的核报 trap） |

和 CISC（如 x86）对比：

- x86 的指令长度可变（1–15 字节），一条指令可以"读内存 + 运算 + 写内存"，寻址方式很多，有条件码。
- RISC 把这些拆成多条简单的定长指令，换来译码简单、易于流水。
- 现代 x86 的前端会把指令拆成类似 RISC 的微操作（micro-op），内部执行方式其实也是 RISC 式的。

### 1.3 寄存器与调用约定

汇编里一般写 **ABI 名**（应用二进制接口约定的别名），而不是 `x5` 这样的编号：

| 寄存器 | ABI 名 | 用途 | 跨调用保存者 |
|--------|--------|------|--------------|
| x0 | zero | 恒 0 | — |
| x1 | ra | 返回地址（return address） | 调用者 |
| x2 | sp | 栈指针（向下增长，16 字节对齐） | 被调用者 |
| x3 | gp | 全局指针 | — |
| x4 | tp | 线程指针 | — |
| x5–x7 | t0–t2 | 临时 | 调用者 |
| x8 | s0 / fp | 保存寄存器 / 帧指针 | 被调用者 |
| x9 | s1 | 保存寄存器 | 被调用者 |
| x10–x11 | a0–a1 | 参数 / 返回值 | 调用者 |
| x12–x17 | a2–a7 | 参数 | 调用者 |
| x18–x27 | s2–s11 | 保存寄存器 | 被调用者 |
| x28–x31 | t3–t6 | 临时 | 调用者 |

- **调用者保存（caller-saved）**：被调函数可以随便改。调用者如果调用后还要用，就得自己先存到栈上。
- **被调用者保存（callee-saved）**：被调函数如果要用，必须在入口保存、返回前恢复。

`lab/RV32I/programs/fib.s` 的递归 Fibonacci 就是按这个约定写的：入口把 `ra`、`s0`、`s1` 压栈，返回前弹出；testbench 最后检查 `sp` 回到原值。

硬件只认识 x0–x31，ABI 完全是软件约定。唯一的例外是 `x0` 恒为 0。另外硬件上 `ra` 在 `jal` 里并没有特殊地位（`jal` 可以写任何 rd），但取指端的返回地址栈（RAS，第 2 节）会把 `rd = x1/x5` 当作"调用"的提示。

### 1.4 六种指令格式

```
31           25 24     20 19     15 14   12 11            7 6         0
+--------------+---------+---------+-------+---------------+----------+
|    funct7    |   rs2   |   rs1   |funct3 |      rd       |  opcode  |  R 型  add/sub/sll/...
+--------------+---------+---------+-------+---------------+----------+
|       imm[11:0]        |   rs1   |funct3 |      rd       |  opcode  |  I 型  addi/lw/jalr/...
+--------------+---------+---------+-------+---------------+----------+
|  imm[11:5]   |   rs2   |   rs1   |funct3 |   imm[4:0]    |  opcode  |  S 型  sw/sh/sb
+--------------+---------+---------+-------+---------------+----------+
| imm[12,10:5] |   rs2   |   rs1   |funct3 |  imm[4:1,11]  |  opcode  |  B 型  beq/bne/blt/...
+--------------+---------+---------+-------+---------------+----------+
|               imm[31:12]                 |      rd       |  opcode  |  U 型  lui/auipc
+------------------------------------------+---------------+----------+
|          imm[20,10:1,11,19:12]           |      rd       |  opcode  |  J 型  jal
+------------------------------------------+---------------+----------+
```

这张图里有四个设计决定值得记住，面试最常问：

1. **rs1、rs2、rd 的位置在所有格式里都固定。** 译码器还没弄清是什么指令，就可以先拿 `instr[19:15]`、`instr[24:20]` 去读寄存器堆，读寄存器与译码并行。
2. **立即数的符号位永远是 `instr[31]`。** 符号扩展不用等格式判断出来，扩展用的那根线可以最早准备好。
3. **B / J 型的立即数位"打乱"摆放。** 目的是尽量让同一个立即数位在不同格式里来自同一个指令位：
   - `imm[10:5]` 在 I/S/B 三种格式里都来自 `instr[30:25]`；
   - `imm[4:1]` 在 S/B 里都来自 `instr[11:8]`；
   - J 型的 `imm[19:12]` 和 U 型同位。

   这样立即数生成器每一位的 MUX 输入更少。代价是人手工编码麻烦。
4. **B / J 型不存 `imm[0]`（恒为 0）。** 偏移以 2 字节为单位，同样位数的跳转范围翻倍：分支 ±4 KB、`jal` ±1 MB。之所以是 2 字节而不是 4 字节，是为了兼容 C 扩展的 16 bit 指令。

`opcode` 的低 2 位为 `11` 表示 32 bit 指令；`00/01/10` 留给 C 扩展的 16 bit 指令。RV32I 用到的主 opcode：

| opcode | 名称 | 指令 |
|--------|------|------|
| `0110111` | LUI | `lui` |
| `0010111` | AUIPC | `auipc` |
| `1101111` | JAL | `jal` |
| `1100111` | JALR | `jalr` |
| `1100011` | BRANCH | `beq bne blt bge bltu bgeu` |
| `0000011` | LOAD | `lb lh lw lbu lhu` |
| `0100011` | STORE | `sb sh sw` |
| `0010011` | OP-IMM | `addi slti sltiu xori ori andi slli srli srai` |
| `0110011` | OP | `add sub sll slt sltu xor srl sra or and` |
| `0001111` | MISC-MEM | `fence` |
| `1110011` | SYSTEM | `ecall ebreak`（及 Zicsr 的 `csrrw` 等） |

数一下：4（lui/auipc/jal/jalr）+ 6 分支 + 5 load + 3 store + 9 立即数运算 + 10 寄存器运算 + fence/ecall/ebreak = **40 条**。

几个"没有"的指令（面试常问"怎么实现"）：

- 没有 `subi`：用 `addi` 加负立即数。
- 没有 `not`：`xori rd, rs, -1`。
- 没有 `mov`：`addi rd, rs, 0`。
- 没有 `nop`：`addi x0, x0, 0`，编码 `0x00000013`。
- 没有 `bgt` / `ble`：交换 `blt` / `bge` 的操作数。

这些都是汇编器提供的伪指令（1.6 节）。

**功能上的几个细节**（本章的 `isa_test.s` 每条都测了）：

| 细节 | 规定 |
|------|------|
| 移位量 | 只取低 5 位：`sll x, y, 33` 等于左移 1 位 |
| `srai` / `srli` 的区分 | 靠 `instr[30]`（立即数的 bit 10），其它 I 型指令的这一位只是普通立即数位 |
| `sltiu` | 立即数**先符号扩展**，再按无符号比较：`sltiu rd, rs, -1` 表示 "rs < 0xFFFFFFFF" |
| `jalr` | 目标 = `(rs1 + imm) & ~1`，最低位清零；`rd == rs1` 时先用旧 rs1 算目标，再写链接值 |
| `lb` / `lh` | 符号扩展；`lbu` / `lhu` 零扩展 |
| `auipc` | `rd = PC + (imm20 << 12)`，是 PC 相对寻址的基础 |
| 写 `x0` | 指令照常执行，结果丢弃（`x0` 不能被改变） |

### 1.5 寻址方式

| 方式 | 例子 | 说明 |
|------|------|------|
| 立即数寻址 | `addi a0, a1, -1` | 操作数在指令里（12 bit 有符号） |
| 寄存器寻址 | `add a0, a1, a2` | 操作数在寄存器里 |
| 基址 + 偏移 | `lw a0, 8(sp)` | **唯一的访存寻址方式**：地址 = rs1 + 12 bit 有符号偏移 |
| PC 相对 | `beq`、`jal`、`auipc` | 目标 / 结果 = PC + 偏移，代码位置无关（PIC） |
| 寄存器间接跳转 | `jalr ra, 0(t0)` | 目标 = rs1 + 偏移（函数指针、`switch` 跳转表、函数返回） |

和 x86 相比，RISC-V 没有"基址 + 变址 × 比例"、自增 / 自减、内存间接寻址：

- 数组访问 `a[i]` 要先 `slli` 再 `add`，多一两条指令；
- 换来的好处是每条访存指令只需要一个加法器算地址，流水线的 EX 级很简单。

### 1.6 伪指令、`li` 与 `%hi/%lo`

**伪指令**是汇编器提供的"语法糖"，展开成一条或几条真指令：

| 伪指令 | 展开 |
|--------|------|
| `nop` | `addi x0, x0, 0` |
| `mv rd, rs` | `addi rd, rs, 0` |
| `not rd, rs` | `xori rd, rs, -1` |
| `neg rd, rs` | `sub rd, x0, rs` |
| `seqz rd, rs` / `snez rd, rs` | `sltiu rd, rs, 1` / `sltu rd, x0, rs` |
| `j off` / `jr rs` / `ret` | `jal x0, off` / `jalr x0, 0(rs)` / `jalr x0, 0(ra)` |
| `beqz rs, off` | `beq rs, x0, off` |
| `bgt a, b, off` / `ble a, b, off` | `blt b, a, off` / `bge b, a, off` |
| `li rd, imm` | 12 bit 以内：`addi rd, x0, imm`；否则 `lui` +（低 12 位非 0 时）`addi` |
| `la rd, sym` | `auipc rd, %pcrel_hi(sym)` + `addi rd, rd, %pcrel_lo(sym)` |
| `call f` | `auipc ra, %pcrel_hi(f)` + `jalr ra, %pcrel_lo(f)(ra)` |

**为什么 `%hi` 要加 0x800。** 32 bit 常数 `v` 用 `lui` + `addi` 拼出来：`lui` 给高 20 位，`addi` 加低 12 位。问题是 `addi` 的立即数是**有符号**的，范围 −2048 ~ 2047：

- 低 12 位 `< 0x800` 时，`addi` 加的是正数，`lui` 直接取 `v[31:12]` 即可。
- 低 12 位 `≥ 0x800` 时，`addi` 实际加的是一个负数（低 12 位 − 4096），所以 `lui` 要多加 1 来补偿。

两种情况合并成一个公式：

$$
\text{hi20} = (v + \text{0x800}) \gg 12, \qquad \text{lo12} = v - (\text{hi20} \ll 12) \in [-2048,\, 2047]
$$

本章汇编器（`lab/RV32I/rv32_asm.py`）的实现就是这两行：

```python
def hi20(v):
    """%hi：加 0x800 是因为 addi 的低 12 位是有符号数，低位 ≥ 0x800 时要向高位借 1。"""
    return ((v + 0x800) >> 12) & 0xfffff


def lo12(v):
    """%lo：低 12 位按有符号数解释，与 hi20 配对满足 (hi20 << 12) + lo12 == v。"""
    return ((v & 0xfff) ^ 0x800) - 0x800
```

`la` / `call` 用 `auipc` 而不是 `lui`，是 **PC 相对**的：程序被加载到任何地址都能正确找到符号。`lui` 得到的是绝对地址。`call` 用 `auipc + jalr` 可以跳 ±2 GB；链接器开启松弛（relaxation）时，目标够近就把它换成一条 `jal`。

**真实输出**：`lab/RV32I/programs/encode_demo.s` 把每种格式和每个"坑"各写一条。下面是本章汇编器生成的列表文件（`build/encode_demo.lst`），括号里是伪指令展开出的第二条：

```
00000000: 00c58533   add  a0, a1, a2           # R 型
00000004: 40c58533   sub  a0, a1, a2           # R 型，funct7 = 0100000
00000008: fff58513   addi a0, a1, -1           # I 型，负立即数
0000000c: 4035d513   srai a0, a1, 3            # I 型移位：imm[11:5] = 0100000 区分 srai / srli
00000010: 00812503   lw   a0, 8(sp)            # I 型（load）
00000014: fea12e23   sw   a0, -4(sp)           # S 型：立即数被拆成 [11:5] 和 [4:0]
00000018: 123452b7   li   t0, 0x12345678       # lui + addi：低 12 位 0x678 < 0x800，不借位
0000001c: 67828293       (addi t0, t0, 1656)
00000020: 12346337   li   t1, 0x12345fff       # 低 12 位 0xfff ≥ 0x800 → addi -1，lui 要先加 1：0x12346
00000024: fff30313       (addi t1, t1, -1)
00000028: 80000393   li   t2, -2048            # 正好落在 12 bit 有符号范围，一条 addi
0000002c: 80000e37   li   t3, 0x80000000       # 只需 lui（低 12 位为 0）
00000030: 10000517   la   a0, buf              # auipc + addi：PC 相对，代码搬到哪里都对
00000034: fd450513       (addi a0, a0, -44)
00000038: 00b50063   beq  a0, a1, back         # B 型，偏移 0
0000003c: feb51ee3   bne  a0, a1, back         # B 型，偏移 -4：符号位在 instr[31]
00000040: 004000ef   jal  ra, fwd              # J 型
00000044: 00000097   call func                 # auipc ra + jalr ra
00000048: 00c080e7       (jalr ra, 12(ra))
0000004c: 00000073   ecall
00000050: 00008067   ret                       # jalr x0, 0(ra)
```

用 GNU 工具链对照（`riscv64-unknown-elf-objdump -d -M no-aliases`，节选）：

```
  20:	12346337          	lui	t1,0x12346
  24:	fff30313          	addi	t1,t1,-1 # 12345fff <__global_pointer$+0x23457ff>
  30:	10000517          	auipc	a0,0x10000
  34:	fd450513          	addi	a0,a0,-44 # 10000004 <buf>
  3c:	feb51ee3          	bne	a0,a1,38 <back>
  44:	00000097          	auipc	ra,0x0
  48:	00c080e7          	jalr	ra,12(ra) # 50 <func>
```

注意 `la a0, buf`：`buf = 0x1000_0004`，指令在 `0x30`，偏移 `0x0FFF_FFD4`，低 12 位 `0xFD4 ≥ 0x800`。于是 `auipc` 取 `0x10000`（已经借了 1），`addi` 加 −44。

**手工译码一条 B 型**（面试常考）：`bne a0, a1, back` = `0xfeb51ee3`。

```
1111111 01011 01010 001 11101 1100011
   │      │     │    │    │      └─ opcode = BRANCH
   │      │     │    │    └─ instr[11:8] = 1110 → imm[4:1]；instr[7] = 1 → imm[11]
   │      │     │    └─ funct3 = 001 → bne
   │      │     └─ rs1 = 01010 = x10 = a0
   │      └─ rs2 = 01011 = x11 = a1
   └─ instr[31] = 1 → imm[12]；instr[30:25] = 111111 → imm[10:5]

imm = {imm[12], imm[11], imm[10:5], imm[4:1], 0} = 1 1 111111 1110 0 = 13 bit 的 −4
```

S 型 `sw a0, -4(sp)` = `0xfea12e23`：`instr[31:25] = 1111111` 是 `imm[11:5]`，`instr[11:7] = 11100` 是 `imm[4:0]`，拼起来是 12 bit 的 `111111111100` = −4。

### 1.7 实验：汇编器、ISS 与单周期核

<a id="single-cycle-start"></a>

这一节先建立能读 RTL 的基础，再看验证工具。读完应当能解释：一条指令需要哪些输入、经过哪些组合电路、在什么时钟沿改变哪些状态。后面的五级流水线会复用这里的译码器、寄存器堆、ALU、分支比较器和 LSU。

#### 1.7.1 先分清四种东西：地址、指令、编号、数值

假设 `PC=0x100`，该地址存着 `addi x3, x1, 5` 的机器码，寄存器 `x1` 当前保存 `10`：

- `0x100` 是**指令的字节地址**，由 PC（program counter，程序计数器）保存。
- `addi x3, x1, 5` 是人看的汇编；指令存储器里存的是对应的 32 位编码 `0x00508193`。
- `1` 和 `3` 是**寄存器编号**，分别决定读 x1、写 x3。32 个寄存器用 5 位就能编号。
- `10` 是 x1 的**内容**，`5` 是编码在指令里的立即数（immediate）。二者相加得到待写回的 32 位数据 `15`。

寄存器堆（register file）就是 x0–x31 的存储体，每个寄存器 32 位。PC 是另一个独立的状态寄存器，不在 x0–x31 里。x0 的读值固定为 0，写入被忽略。

本实验的指令存储器 IMEM 和数据存储器 DMEM 位于 testbench 中，CPU 顶层只提供访问端口。二者各有 4096 个 32 位字，即 16 KB：IMEM 从 `0x0000_0000` 开始，DMEM 从 `0x1000_0000` 开始。地址按字节计数，数组下标按字计数，所以 testbench 用地址的 `[13:2]` 选择一个字。数据访问的高位范围由 testbench 另外检查，数据地址的低 2 位交给 LSU 处理字节位置。

**两套核的 IMEM 和 DMEM 都采用组合读，DMEM 在上升沿按字节使能写入。** 地址稳定后，本拍内得到读数据；IMEM 的内容由 testbench 在仿真开始时加载，CPU 没有指令存储器写口。基础流水线沿用这一存储器时序；同步读 SRAM 是第 2.9 节讨论的改造方向。

#### 1.7.2 读硬件代码：先找状态，再找组合路径

从 [rv32i_single.v](lab/RV32I/rv32i_single.v) 开始，先按注释找到“译码、寄存器堆、执行、访存、写回、PC 与停机”这些区域。

- `assign`、声明时带赋值表达式的 `wire`、`always @*` 描述组合关系：输入变化，输出经过传播延迟变化。`wire y = a + b` 是持续驱动这根线，不是只在启动时计算一次。
- `always @(posedge clk)` 描述上升沿采样；`or negedge rst_n` 另加异步低有效复位。
- `<=` 是非阻塞赋值：各时序块在同一个沿读取沿前的输入，再更新自己的寄存器。文件中谁写在前面，不决定哪一级先更新。
- Verilog 的 `reg` 表示可在过程块里赋值的变量，**不等于一定有触发器**。例如 `wb_data` 在完整赋值的 `always @*` 里只是组合选择器的输出。
- `.raddr1(rs1)` 中，左边是子模块的端口名，右边是顶层接过去的信号；这不是调用一次软件函数，而是把两段电路连起来。

本单周期核的主要状态是 PC、寄存器堆、数据存储器和停机标志。译码结果、ALU 输入输出、下一 PC 都是由当前状态算出来的组合信号。

下面是按功能分组的数据通路。ALU 与分支比较器并行工作，立即数从指令直接生成，不需要经过寄存器堆：

```text
PC ──地址──> IMEM ──instr──> 译码 / 字段提取 / 立即数生成
                              │ rs1、rs2       │ 控制信号、imm
                              v               v
                         寄存器堆读口 ──> 输入选择 ──> ALU
                              │                         │
                              └──> 分支比较             ├──运算结果────────┐
                              │                         └──访存地址─> DMEM / LSU
                              └──rs2 值────────────────────store 数据      │
                                                                           v
寄存器堆写口 <──────── 写回选择器：ALU 结果 / load 数据 / PC+4 <───────────────┘

ALU 输出 ──> 跳转目标（jalr 清 bit 0）──┐
PC+4 ─────────────────────────────────┴──> 下一 PC 选择器 ──> PC 的输入
```

图中的组合路径在两个上升沿之间传播；PC、寄存器堆写口和 DMEM 写口在沿上保存结果。对 `addi`，DMEM 不执行读写；对 `sw`，寄存器堆不执行写回。电路可以同时计算多个候选值，只有被选中且使能有效的值才产生效果。

#### 1.7.3 取指与译码：从 32 位编码得到操作和控制

取指对应顶层的三行：

```verilog
reg  [31:0] pc;
wire [31:0] instr = imem_rdata;
assign imem_addr = pc;
```

PC 驱动指令存储器的地址，返回值叫 `instr`。这一段没有“等待一拍”的状态机；当前存储模型允许指令在本周期内返回。

[rv32i_decode.v](lab/RV32I/rv32i_decode.v) 首先拆固定字段：

```verilog
wire [6:0] opcode = instr[6:0];
assign rd     = instr[11:7];
assign funct3 = instr[14:12];
assign rs1    = instr[19:15];
assign rs2    = instr[24:20];
```

`opcode` 确定大类，例如寄存器运算、立即数运算、load、store、分支；`funct3` 及必要的其它位再区分具体操作。字段提取本质上只是连线。`rs1/rs2/rd` 的字段位置固定，但某种指令可能根本不用其中某个字段：`addi` 不使用 rs2，`sw` 不写 rd，`lui` 不读源寄存器。译码器的 `uses_rs1/uses_rs2` 记录“真的要用谁”，到流水线时才用来判断依赖。

立即数生成把指令中的若干位重排并扩成 32 位。先理解最常用的 I 型：

```verilog
wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
```

`instr[31:20]` 是 12 位立即数，`{20{instr[31]}}` 把符号位重复 20 次，外层花括号再把两部分拼起来。`5` 扩展后是 `0x00000005`；`-1` 的 12 位编码是 `0xfff`，扩展后是 `0xffffffff`。符号扩展让负数在 32 位加法器里仍保持原来的补码含义。

S 型用于 store，立即数分散在 `[31:25]` 和 `[11:7]`；B/J 型用于跳转，补回未编码的最低位 0；U 型把高 20 位放到 `[31:12]`，低 12 位补 0。需要检查位序时再回到第 1.4 节，第一遍先确认“这条指令最终需要什么数”。

译码器还产生控制信号。它们决定输入选谁、做哪种运算、是否允许写入：

| 信号 | 在单周期顶层中的作用 |
|---|---|
| `alu_a_zero`、`alu_a_pc` | ALU 的 A 输入依次选择 0、PC，否则选择 `rs1_val` |
| `alu_b_imm` | 1 选择立即数，0 选择 `rs2_val` |
| `alu_op` | 选择加减、移位、比较或按位运算 |
| `reg_we` | 本指令是否要求写寄存器堆；最终还要经过 `stop` 屏蔽 |
| `mem_re`、`mem_we` | 本指令是否要求读、写数据存储器 |
| `wb_sel` | 0 选 ALU，1 选 load 数据，2 选 PC+4 |
| `is_branch`、`is_jal`、`is_jalr` | 参与下一 PC 的选择 |

读 `always @*` 时，要把**块开头的默认值和命中的 case 分支合起来看**。例如 `OP_IMM` 分支没有再次写 `alu_b_imm=1`、`wb_sel=0`，因为默认值已经这样设置。完整默认赋值也避免组合块因漏赋值而推断锁存器。

一个容易误读的编码细节：R 型可用 `{instr[30], funct3}` 区分加减和移位；普通 I 型的 `instr[30]` 属于立即数，不能一律当作操作码。实际代码是：

```verilog
alu_op = {(funct3 == 3'b101) & instr[30], funct3};
```

只有右移立即数指令才让该位区分 `srli/srai`。否则 `addi` 的负立即数可能误触发减法。这里解释的是这份 ALU 的内部编码，不是要求另造一种 ISA 编码。

#### 1.7.4 寄存器堆：读编号得到数值，写使能决定是否保存

[rv32i_regfile.v](lab/RV32I/rv32i_regfile.v) 的核心状态和写口是：

```verilog
reg [31:0] rf [0:31];
always @(posedge clk) begin
    if (we && waddr != 5'd0) rf[waddr] <= wdata;
end
```

`rf[1]` 是 x1 的内容。读口是组合逻辑；写口在上升沿把 `wdata` 存到 `waddr` 指定的位置。两个读口允许 `add x3,x1,x2` 在同一周期拿到两个操作数，一个写口接收最终结果，即 2R1W（two read ports, one write port）。

单周期顶层将 `BYPASS` 设为 0。忽略 x0 的特殊处理后，读口就相当于 `rdata1 = rf[raddr1]`。例如 `rs1=1`、`rf[1]=10`，则 `rs1_val=10`。流水线使用的 `BYPASS=1` 在第 2.4 节单独解释。

`addi x1,x1,5` 也符合这个规则：沿前读取旧 x1，组合加法得到旧值加 5，在沿上写入新 x1。同一个周期内不会不断自加，因为 ALU 的输出没有直接写穿到存储体。沿后 PC 前进，下一条指令开始计算。

本模块没有复位 x1–x31。testbench 为了与 ISS 的初值假设一致，显式把它们初始化成 0；不能据此推断硬件复位后这些寄存器必定为 0。

#### 1.7.5 执行：先看输入选择，再看 ALU 做什么

顶层的 ALU 前面有两个多路选择器（multiplexer，MUX）：

```verilog
wire [31:0] alu_a = alu_a_zero ? 32'd0 : alu_a_pc ? pc : rs1_val;
wire [31:0] alu_b = alu_b_imm  ? imm   : rs2_val;
rv32i_alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));
```

`条件 ? 值一 : 值二` 表示条件为真选值一，否则选值二。ALU 本身不需要知道当前指令叫 `addi` 还是 `lw`，只需要知道 A、B 和操作码。

| 指令例子 | A | B | ALU 结果的用途 |
|---|---|---|---|
| `add x3,x1,x2` | x1 的值 | x2 的值 | 加法结果写 x3 |
| `addi x3,x1,5` | x1 的值 | 5 | 加法结果写 x3 |
| `lw x3,8(x1)` | x1 的值 | 8 | 访存地址；读出的内存数据才写 x3 |
| `sw x3,8(x1)` | x1 的值 | 8 | 访存地址；x3 的值另走 store 数据通路 |
| `lui x3,0x12345` | 0 | `0x12345000` | 相加结果写 x3 |
| `auipc x3,1` | 本指令 PC | `0x00001000` | 相加结果写 x3 |
| `jal x1,label` | 本指令 PC | J 型偏移 | 跳转目标；写 x1 的是独立计算的 PC+4 |
| `beq x1,x2,label` | 本指令 PC | B 型偏移 | 候选跳转目标；是否采用由比较器决定 |
| `jalr x1,8(x5)` | x5 的值 | 8 | 清 bit 0 后作为跳转目标；写 x1 的仍是 PC+4 |

尤其要分清 store 的两个输入：`sw x3,8(x1)` 中 rs1 是基址 x1，rs2 是待存数据 x3；ALU 的 B 口选择立即数 8，所以**store 数据不能取 ALU 的 B 口**。

branch 同样有两条并行路径：**ALU 用 PC 和立即数算目标，比较器用 rs1 和 rs2 判断跳不跳**。比较器直接接寄存器读值，不接 ALU 选择后的输入。因此 `alu_a_pc=1、alu_b_imm=1` 不代表分支不读寄存器；`uses_rs1/uses_rs2` 仍必须都为 1。JAL 不需要比较，也不读源寄存器，但同样复用 ALU 计算目标。

ALU 的加法、移位等实现见 [rv32i_alu.v](lab/RV32I/rv32i_alu.v)。算术右移需把 A 显式转成有符号值，`>>>` 才会补符号位；`$signed(a)` 改变解释方式，不会先改动 a 的位模式。

#### 1.7.6 load/store：地址、数据和字节使能各走一条线

假设 x1=`0x10000020`，执行 `lw x3,8(x1)`：

1. ALU 算出地址 `0x10000028`。
2. `dmem_addr` 给 DMEM 这个字的地址，`dmem_re=1` 表示有效读请求。
3. DMEM 的组合读口输出该位置保存的 32 位数据。
4. LSU（load/store unit，访存处理单元）按访问宽度选取并扩展数据，写回选择器选中它，拍末写入 x3。

所以 load 有两种不同的“结果”：ALU 结果是**地址**，load 写回值是**该地址的内容**。后面理解 load-use 冒险时还会用到这个区别。

换成 `sw x3,8(x1)`，地址计算相同，但数据来自 `rs2_val`，并且 `reg_we=0`、`mem_we=1`。本拍上升沿改变 DMEM，不改变通用寄存器。

对 `sb/sh`，DMEM 仍按 32 位整字连接，`dmem_wstrb[3:0]` 决定四个字节中哪些被写入。以 `sb x3,1(x1)` 为例，假设 x1=`0x10000020`、x3 低 8 位为 `0xab`：

```text
ALU 的字节地址      0x10000021
发给 DMEM 的字地址  0x10000020（低 2 位清零）
addr_lo             01
wstrb               0010（只写 bit[15:8] 对应的字节）
wdata               0xabababab（其余通道虽然有值，但不会被写）
```

反向读取时，LSU 从返回的整字里选字节。例如该字节为 `0x80`，`lb` 写回 `0xffffff80`，`lbu` 写回 `0x00000080`。`lh/lhu` 同理。半字要求地址为偶数，字要求低 2 位为 0；不满足时 `misalign=1`，顶层禁止本条的写回和存储并置 trap。

LSU 是组合模块，会一直计算候选读写结果；真正发起访问还要看顶层的使能：

```verilog
assign dmem_re    = mem_re & ~stop;
assign dmem_wstrb = (mem_we & ~stop) ? lsu_strb : 4'b0000;
```

因此一条 `add` 即使让 `dmem_addr` 或 LSU 输出发生变化，也不代表它在执行 store。判断是否改变内存，首先看 `dmem_wstrb`。

#### 1.7.7 写回与下一 PC：本条指令有哪些最终效果

写回（writeback）专指把结果写进通用寄存器堆。顶层用 `wb_sel` 选出值：

```verilog
always @* begin
    case (wb_sel)
        2'd1:    wb_data = ld_data;
        2'd2:    wb_data = pc_plus4;
        default: wb_data = alu_y;
    endcase
end
```

普通运算写 ALU 结果，load 写内存数据，`jal/jalr` 写返回地址 PC+4。store 和条件分支没有寄存器写回，靠 `reg_we=0` 关闭写口，不是靠把 `wb_data` 清成 0。实际写使能为 `rf_we = reg_we & ~stop`，x0 再由寄存器堆屏蔽。

下一 PC 选择器复用 ALU 计算的目标；PC+4 仍由独立加法路径提供：

```verilog
wire [31:0] pc_plus4  = pc + 32'd4;
wire [31:0] pc_target = is_jalr ? {alu_y[31:1], 1'b0} : alu_y;
wire [31:0] next_pc   = (is_jal | is_jalr | (is_branch & br_taken)) ? pc_target : pc_plus4;
```

- 普通运算、load、store 顺序执行，下一地址是 PC+4，因为本实验每条指令占 4 字节。
- `beq x1,x2,label` 用单独的 [分支比较器](lab/RV32I/rv32i_branch.v) 比较两个寄存器，同时 ALU 算“本条分支的 PC + 偏移”。相等时采用 ALU 目标，否则选 PC+4。目标计算不是以 PC+4 为基准。
- `jal x1,label` 用 ALU 算 PC+偏移并无条件跳转，同时把独立计算的 PC+4 写入 x1。目标地址和写回地址用途不同，不能把 JAL 的 ALU 结果直接写入 x1。
- `jalr x1,0(x5)` 用 ALU 算 x5+立即数，清目标的最低位后作为下一 PC，同时仍把 PC+4 写入 x1。即使 rd 与 rs1 相同，也是先用旧值计算，再在沿上保存结果。

例如 PC=`0x100`、分支偏移为 12，成立时下一 PC 是 `0x10c`；同位置的 `jal x1,+12` 还会把 `0x104` 写入 x1。汇编里的标号由汇编器换算成这个偏移，硬件不会读取标号名称。

`stop = halted | illegal | mem_bad` 用于禁止错误指令的写回和数据访问。`ecall/ebreak` 在本教学核中代表结束程序，沿上置 `halted`；非法指令或非对齐数据访问还会置 `trap`。本节没有 CSR、异常入口和 `mret`，不能当作完整的机器模式异常处理器。

实现边界也要与代码一起读：两套基础核没有检查跳转目标是否满足 RV32I 的 4 字节指令对齐；`jalr` 清 bit 0 并不等于已经检查 bit 1。后面的正常程序回归不能替代完整的 ISA 合规验证。

#### 1.7.8 单周期里的“一拍”到底包含什么

下面把两次相邻上升沿之间叫一个周期。图中的步骤只是组合信号的依赖关系，不是状态机依次进入多个状态：

```text
上升沿 A                                                    上升沿 B
  |                                                            |
  | PC/寄存器输出稳定 → 取指/译码/读寄存器 → 执行/访存 → 写回值稳定 |
  |                                               next_pc 稳定 |
  |                                                            | 采样写回值
  |                                                            | 更新 PC
  |                                                            | 必要时写 DMEM
```

`addi x3,x1,5` 在沿 B 写 x3；`sw` 在沿 B 写 DMEM；分支在沿 B 把 PC 更新成选中的下一地址。多个时序块在同一个沿采样，不是先更新 PC 再用新 PC 决定旧指令的结果。

一个周期必须足够长，让最慢的组合路径满足接收端的建立时间。本设计中，load 通常经过最长的功能链：取指 → 译码/读寄存器 → ALU 算地址 → 读 DMEM → LSU → 寄存器写口。其它指令即使更早算完，也要等同一个拍末写入。

这说明两个不同的概念：**单周期核每条指令只用 1 拍，但这一拍可能很长；流水线的一条指令用多拍，但每拍可以更短。** 是否更快，要比较指令数、平均每条指令周期数 CPI（cycles per instruction）和时钟周期长度，不能只比较 CPI。

#### 1.7.9 代码阅读顺序与验证工具的分工

建议第一遍按这个顺序读，每个模块都先看端口，再看产生输出的逻辑：

1. `rv32i_single.v`：先圈出 PC、寄存器堆、写回 MUX 和下一 PC MUX，知道顶层在连接什么。
2. `rv32i_regfile.v`：理解编号与数值、组合读与沿上写、x0。
3. `rv32i_decode.v`：先只跟 `OP_IMM/OP_REG`，然后分别加 load/store、分支/跳转；每次都合并默认值和 case 分支。
4. `rv32i_alu.v`、`rv32i_branch.v`、`rv32i_lsu.v`：分别回答“算什么、比什么、如何把整字总线变成字节访问”。
5. 回到顶层，确认每类指令究竟更新寄存器、DMEM、PC 中的哪些状态；最后再看 `commit_*`。

`commit_*` 是供 testbench 观察本条指令最终效果的接口，不参与 ALU 输入选择或 PC 控制。理解数据通路时可以暂时略过。

软件和验证工具的关系如下：

```text
programs/*.s → rv32_asm.py → .text.hex / .data.hex / .lst
                                  ├→ rv32_iss.py → .trace.hex（参考结果）
                                  └→ testbench → RTL → commit_*（实际结果）
                                                       ↓
                                    testbench 逐条比较参考结果与实际结果
```

汇编器将文本程序变成机器码；ISS（instruction set simulator，指令集模拟器）用 Python 按指令语义计算参考状态；RTL 仿真执行的是硬件模块。ISS 不替 RTL 计算 ALU，RTL 也不读参考轨迹来决定行为。testbench 同时保存参考结果和存储器模型，在观察接口上进行比较。

`asm_crosscheck.py` 还会用 GNU 工具对汇编结果逐字交叉检查，未安装对应 binutils 时打印 SKIP。`programs/` 中的 `isa_test` 测指令细节，`sort/fib` 测较长程序，`hazards` 在第 2 节专测流水线依赖，`branchy` 用于比较预测策略。

数据段第一个字 `tohost` 是测试程序和 testbench 约定的结束结果：成功写 1，失败写 `(测试号 << 1) | 1`。它不是 RV32I 的专用硬件寄存器。

#### 1.7.10 运行与看波形：先观察一次状态更新

以下命令在 WSL root 的 Bash 中执行，从本章目录开始：

```bash
cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/13_Computer_Architecture_SoC'
bash lab/RV32I/run_sim.sh
```

脚本完成 lint、汇编交叉检查和五个程序的回归。若要单看一个程序，在回归生成可执行文件和参考轨迹后执行：

```bash
cd lab/RV32I
source /root/oss-cad-suite/environment
vvp -n build/single_sim +prog=build/isa_test
```

波形位于当前目录的 `rv32i_single.vcd`，对应本次单独运行；回归脚本结束时留下的是最后一个程序的波形。

第一轮只加 `u_core.pc`、`instr`、`rs1`、`rs1_val`、`imm`、`alu_a`、`alu_b`、`alu_y`、`rf_we`、`rd`、`wb_data`、`next_pc` 以及顶层 `clk/rst_n`。除顶层时钟复位外，这些信号都在 `u_core` 下。对照 `build/isa_test.lst` 找一条运算指令，检查沿前的输入与写回值，再看沿后 PC 是否前进。

第二轮再加 `dmem_addr/dmem_re/dmem_wstrb/dmem_wdata` 看 load/store，第三轮加 `br_taken/is_branch/is_jal/is_jalr` 看下一 PC 的选择。先确认使能，再解释总线上的数值；没有使能时的候选值不是一次有效访问。

#### 1.7.11 已有回归与变异测试结果

**验证方法：commit 接口 + 逐条比对（lockstep）。**

- 核每退休一条指令，就在 `commit_*` 端口报告一次：PC、是否写寄存器、写哪个寄存器、写的值、store 的字节使能 / 地址 / 数据。这个思路同 RISC-V 社区的 RVFI（RISC-V Formal Interface）。
- ISS 对同一程序生成同样格式的轨迹，testbench 一条一条比。

和只看最终结果相比，逐条比对的好处是：

- 错误定位到**第一条**出错的指令，而不是程序最后的一个 FAIL；
- 中间被覆盖掉的错误值也逃不掉。

ISS 和 RTL 由不同代码独立实现（Python 的译码器不复用 RTL 的任何逻辑），两边犯同一个错的概率很低。

**仿真结果**（`bash lab/RV32I/run_sim.sh`，真实输出节选）：

```
===== 汇编器交叉检查 =====
MATCH programs/branchy.s: 36 条指令, 4 字节数据与 GNU as 完全一致
MATCH programs/encode_demo.s: 21 条指令, 12 字节数据与 GNU as 完全一致
MATCH programs/fib.s: 42 条指令, 4 字节数据与 GNU as 完全一致
MATCH programs/hazards.s: 118 条指令, 24 字节数据与 GNU as 完全一致
MATCH programs/isa_test.s: 234 条指令, 36 字节数据与 GNU as 完全一致
MATCH programs/sort.s: 51 条指令, 68 字节数据与 GNU as 完全一致
PASS
===== isa_test =====
programs/isa_test.s: 234 条指令, 36 字节数据 -> build/isa_test.*
ISS: 220 instructions, tohost=1 (PASS)
     mix: alu=140  load=13  store=5  branch=57  jump=3  system=2  branch_taken=5/57
build/isa_test: instret=220 cycles=220 CPI=1.000 tohost=1
PASS
===== sort =====
ISS: 1037 instructions, tohost=1 (PASS)
     mix: alu=348  load=273  store=111  branch=289  jump=15  system=1  branch_taken=185/289
build/sort: instret=1037 cycles=1037 CPI=1.000 tohost=1
PASS
===== fib =====
ISS: 5355 instructions, tohost=1 (PASS)
     mix: alu=2563  load=696  store=697  branch=467  jump=931  system=1  branch_taken=233/467
build/fib: instret=5355 cycles=5355 CPI=1.000 tohost=1
PASS
===== hazards =====
ISS: 162 instructions, tohost=1 (PASS)
build/hazards: instret=162 cycles=162 CPI=1.000 tohost=1
PASS
===== branchy =====
ISS: 5163 instructions, tohost=1 (PASS)
     mix: alu=3309  load=0  store=1  branch=851  jump=1001  system=1  branch_taken=599/851
build/branchy: instret=5163 cycles=5163 CPI=1.000 tohost=1
PASS
```

从 `mix` 看指令分布：

- `sort` 里访存占 37%，分支占 28%；
- `fib` 里跳转（`call` / `ret`）占 17%；
- `isa_test` 的 57 条分支只跳了 5 条，因为都是"出错才跳到 fail"。

第 2 节流水线的表现差异就来自这些分布。

**变异测试**（`bash lab/RV32I/mutation.sh`，每个变异在 5 个程序上各跑一次）：

```
===== M1: sra 变成逻辑右移 =====
 isa_test:FAIL sort:PASS fib:PASS hazards:PASS branchy:PASS
  首个错误: ERROR #48 pc=000000c0: rd / wdata mismatch  got(... wd=00000001 ...) exp(... wd=ffffffff ...)
===== M2: lb / lh 不做符号扩展 =====
 isa_test:FAIL sort:PASS fib:PASS hazards:PASS branchy:PASS
  首个错误: ERROR #161 pc=000002a4: rd / wdata mismatch  got(... wd=000000ff ...) exp(... wd=ffffffff ...)
===== M3: jalr 不清最低位 =====
 isa_test:FAIL sort:PASS fib:PASS hazards:PASS branchy:PASS
  首个错误: ERROR #132 pc=00000219: pc mismatch  got(... wd=00000219 ...) exp(pc=00000218 ...)
===== M4: sltu 用有符号比较 =====
 isa_test:FAIL sort:PASS fib:PASS hazards:PASS branchy:PASS
  首个错误: ERROR #14 pc=00000038: rd / wdata mismatch  got(... wd=00000001 ...) exp(... wd=00000000 ...)
===== M5: I 型指令误用 instr[30] =====
 isa_test:FAIL sort:FAIL fib:FAIL hazards:FAIL branchy:FAIL
  首个错误: ERROR #3 pc=0000000c: rd / wdata mismatch  got(... wd=0000000c ...) exp(... wd=fffffffe ...)
```

（`got(...)` / `exp(...)` 里省略了与结论无关的字段。）两点结论：

1. **M1–M4 只有 `isa_test` 抓得到。** 排序、递归、循环这类"真实程序"根本不会用到 `sra` 一个负数、`lb` 一个高位为 1 的字节、`jalr` 一个奇数地址。只跑应用程序做验证，这些 bug 会一直潜伏到某个编译器生成了这样的代码。所以要有逐条指令、覆盖边界值的定向测试（工业界用 riscv-tests、riscv-arch-test，再加随机指令生成器）。
2. **M3 是靠 PC 比对抓到的。** 跳到 `0x219` 后，指令存储器只用地址的 `[13:2]` 位，取出的仍是 `0x218` 处的正确指令，程序结果完全正确。只有逐条比对 PC 才看得出来。按规范，`jalr` 清掉最低位后目标仍不是 4 的倍数（且没有 C 扩展）时应当报"指令地址非对齐"异常。本核没有实现这个检查，bug 就被取指"掩盖"了。这说明比对的对象应该是架构状态（PC、寄存器、内存），而不只是程序的最终结果。

**常见错误**：

| 错误 | 后果 |
|------|------|
| `alu_op` 在 I 型指令上用了 `instr[30]` | 立即数 bit 10 为 1 的 `addi`/`andi`/`ori`... 变成别的运算 |
| `sra` 写成 `a >>> b`（`a` 是无符号 wire） | 退化成逻辑右移 |
| `sltiu` 的立即数做了零扩展 | `sltiu rd, rs, -1` 结果错误 |
| B / J 立即数位序拼错 | 只有偏移的某几位为 1 时才出错，用小偏移测不出来 |
| `jalr` 在 `rd == rs1` 时先写 rd 再算目标 | 跳错地址（单周期核里写回在拍末，天然不会犯；多周期实现要注意） |
| 没有屏蔽 `x0` 的写 | `x0` 被改，之后所有用 `zero` 的指令都错 |
| store 时没有把字节复制到正确通道，或字节使能算错 | 改坏相邻字节 |

### 1.8 变体与扩展

| 扩展 | 对硬件的影响 |
|------|--------------|
| M（`mul/mulh/div/rem`） | 乘法器（1–3 拍流水）和迭代除法器（~32 拍）。流水线要处理多周期指令：停顿或记分牌（scoreboard）。除以 0 不报异常，结果有规定值（商全 1、余数 = 被除数） |
| C（16 bit 压缩指令） | 指令 2 字节对齐，一条 32 bit 指令可能跨 4 字节边界、跨 cache 行，取指需要对齐缓冲；代码体积约减 25–30% |
| Zicsr + 特权架构 | `mstatus` / `mtvec` / `mepc` / `mcause` 等 CSR；异常和中断进入 trap，保存 PC 到 `mepc`、跳到 `mtvec`，`mret` 返回。这部分在第 5 节"中断"会用到 |
| RV64I | 寄存器 64 bit，新增 `ld/sd/lwu` 和 `addw/subw/sllw...`（32 bit 运算后符号扩展到 64 bit） |
| A（原子） | `lr/sc`（load-reserved / store-conditional）和 `amoadd` 等，多核同步用 |

**本章实现的取舍**：

- `ecall` / `ebreak` 只用作"程序结束"，没有实现 CSR 和 trap 跳转；
- 非对齐访存直接 trap；
- `fence` 当 nop（单核、无 cache 一致性问题时是合法的）。

### 1.9 面试要点

1. **RISC-V 编码的四个用心之处**：
   - 源 / 目的寄存器位置固定 → 读寄存器与译码并行；
   - 符号位固定在 `instr[31]` → 符号扩展最早可用；
   - B / J 立即数位打乱 → 各格式共用位置，减少 MUX；
   - 跳转偏移省略 `imm[0]` → 范围翻倍。
2. **`li` 一个 32 bit 常数**：最多两条，`lui` + `addi`；`%hi = (v + 0x800) >> 12`，因为 `addi` 的立即数是有符号的。
3. **`la` / `call` 用 `auipc`**：PC 相对，位置无关；`call` 可跳 ±2 GB，近的会被链接器松弛成 `jal`。
4. **调用约定**：`ra`、`t*`、`a*` 调用者保存；`sp`、`s*` 被调用者保存；参数和返回值用 `a0–a7` / `a0–a1`。
5. **没有条件码**：分支直接比较两个寄存器，省掉了 flags 寄存器这个隐式的写后读依赖，乱序实现更容易。
6. **没有延迟槽**：MIPS 的延迟槽是为五级流水量身定做的，换一种微架构就变成包袱；RISC-V 把控制冒险交给分支预测。
7. **只有一种访存寻址方式**（基址 + 12 bit 偏移），EX 级一个加法器就够。
8. **验证 CPU**：ISS 做参考模型，commit 接口逐条比对；应用程序覆盖不到的边界要靠定向测试和随机指令生成。

### 1.10 一句话总结

RV32I 是 40 条定长指令的 load-store 架构，编码处处为硬件着想：寄存器位置固定、符号位固定、立即数位尽量复用。记住六种格式和 `%hi` 的 +0x800，就能手工编码、译码任何一条指令。

---

## 2. 流水线与冒险

<a id="pipeline-start"></a>

本节只对照 [lab/Pipeline/rv32i_pipe.v](lab/Pipeline/rv32i_pipe.v)，它复用上一节的五个功能模块。第一遍取默认参数 **`FWD=1、BP=0`**：有 EX 前递，总预测顺序执行。读懂默认配置后，再比较关闭前递和开启分支预测的效果。

### 2.1 为什么要加流水线：周期、延迟与吞吐率

单周期核把一条指令的所有组合计算放在一个周期里。流水线（pipeline）在功能段之间插入寄存器，先保存中间结果，下一拍再继续计算；与此同时，前面的功能段可以接收下一条指令。

这里有三个不同的量：

- **时钟周期**：两个相邻上升沿之间有多长，取决于每段组合路径及寄存器开销。
- **单条指令延迟（latency）**：从开始取指到完成这条指令要多久。
- **吞吐率（throughput）**：稳定运行后，单位时间能完成多少条指令。

把一条指令拆成五级后，它通常要经过五个周期才到 WB，但流水线填满后可以每拍完成一条。不能把“每条要五拍”理解为“每五拍才允许开始下一条”。相反，多周期核如果每条也分成五拍、却必须等上一条全部完成再开始下一条，就没有这种重叠。

假设无停顿、无冲刷，下面每格表示该指令在这一拍占用哪个阶段，阶段结果在拍末传给下一级：

```text
周期        1    2    3    4    5    6    7    8
指令 A     IF   ID   EX   MEM  WB
指令 B          IF   ID   EX   MEM  WB
指令 C               IF   ID   EX   MEM  WB
指令 D                    IF   ID   EX   MEM  WB
```

第 4 拍同时存在四条不同指令：A 在 MEM、B 在 EX、C 在 ID、D 在 IF。第 5 拍 A 完成，第 6 拍 B 完成。因此 N 条指令从第一条 IF 到最后一条 WB 共用 `N+4` 拍，而不是 `5N` 拍。

程序时间仍然是：

$$
T_{\text{程序}} = N_{\text{指令}} \times \text{CPI} \times T_{\text{clk}}
$$

用一组**用于说明的假设延迟，并非本 RTL 的实测时序**：五段分别为 200、100、200、200、100 ps。忽略单周期两端寄存器开销时，单周期需要约 800 ps；若流水线每段寄存器开销为 20 ps，其周期约为 `max(200,100,200,200,100)+20=220 ps`。

一条指令在流水线中的五拍延迟约为 1100 ps，可能比单周期更长；但连续指令可以每 220 ps 完成一条。若停顿和冲刷把平均 CPI 拉到 1.3，平均每条约用 `1.3×220=286 ps`，相对 800 ps 快约 2.8 倍。流水线的主要收益来自吞吐率和时钟周期，不能只看一条指令的延迟。

### 2.2 五级、四组寄存器与一条指令携带的信息

#### 2.2.1 先把阶段名字映射到代码

| 阶段 | 本级入口寄存器 / 状态 | 这一级的组合工作 | 拍末保存到哪里 |
|---|---|---|---|
| IF：instruction fetch，取指 | `if_pc`：取指 PC 寄存器 | 用 PC 读 IMEM，预测下一 PC | IF/ID 的 `if_id_*` |
| ID：instruction decode，译码 | IF/ID 的 `if_id_*` | 译码、生成立即数、读寄存器、检测依赖 | ID/EX 的 `id_ex_*` |
| EX：execute，执行 | ID/EX 的 `id_ex_*` | 前递选择、ALU、分支解析、异常检查 | EX/MEM 的 `ex_mem_*` |
| MEM：memory access，访存 | EX/MEM 的 `ex_mem_*` | load/store 数据访问与 LSU 处理 | MEM/WB 的 `mem_wb_*` |
| WB：writeback，写回 | MEM/WB 的 `mem_wb_*` | 驱动寄存器堆写口，输出提交信息 | 架构寄存器堆；本级没有下一组流水寄存器 |

**两个阶段的前缀表示级间寄存器，前一个阶段产生信息，后一个阶段使用信息。** 例如 `id_ex_imm` 是 ID/EX 保存的立即数，当前由 EX 使用；`id_imm` 是当前 ID 组合译码产生的立即数。代码中的 `id_ex_imm <= id_imm` 就是在上升沿把后者保存到前者。流水线运行起来后，两者通常属于不同指令。

`id_ex_rs1` 是 EX 中那条指令的源寄存器**编号**，不是“通用寄存器 x1”。`id_ex_rs1_val` 是这条指令之前在 ID 读到并保存的**数值**。`ex_a_fwd` 则是 EX 本拍经过前递选择后的组合值；尽管它在 Verilog 中声明为 `reg`，其赋值位于 `always @*`，并没有额外打一拍。

四组级间寄存器保存的是“即将由下一级使用的信息”。例如 `id_ex_pc` 是 ID/EX 寄存器的输出，也是 EX 组合逻辑的输入；`ex_mem_result` 是 EX/MEM 寄存器的输出，也是 MEM 的输入。

```text
IF 组合逻辑 → [if_id_*：IF/ID] → ID 组合逻辑 → [id_ex_*：ID/EX]
  → EX 组合逻辑 → [ex_mem_*：EX/MEM] → MEM 组合逻辑 → [mem_wb_*：MEM/WB] → WB 写口
```

ALU 指令到 MEM 时不访问数据内存，但仍要带着结果通过这一阶段，按统一次序进入 WB。store 到 MEM 执行写内存，之后进入 WB 用于报告提交信息，不会再写一次内存。分支也按顺序往后传，只是不写通用寄存器。

#### 2.2.2 为什么不能只保存 ALU 的结果

假设一条 `add x3,x1,x2` 已在 EX，后面一条 `sw` 正在 ID。EX 的 ALU 必须使用 **add 自己的**操作码，WB 最后也必须使用 **add 自己的**目的寄存器和写使能。若直接使用当前 ID 的 `id_reg_we`，后面的 store 会让前面的 add 丢失写回。

因此跨级传递至少有四类信息：

1. **数据**：读出的操作数、立即数、运算结果、store 数据。
2. **控制**：ALU 操作、输入选择、是否 load/store、是否写 rd。
3. **身份**：本条 PC、指令编码、源和目的寄存器编号。PC 用于分支目标和提交，源编号用于前递比较，目的编号用于最终写回。
4. **有效性**：这一格是否装着一条应当执行的指令，即 `valid`。

在真实代码的 `ID/EX` 时序块中，可以把下面几行看作一组：

```verilog
id_ex_rs1_val <= id_rs1_val;
id_ex_imm     <= id_imm;
id_ex_rd      <= id_rd;
id_ex_alu_op  <= id_alu_op;
id_ex_reg_we  <= id_reg_we;
```

它们在同一个沿一起采样，保存同一条指令的信息。后续 `ex_mem_rd <= id_ex_rd`、`mem_wb_rd <= ex_mem_rd` 也按拍传递。所有 `<=` 右边读取的是沿前值，所以即使写在同一文件里，一条指令也不会在一个沿穿过所有阶段。

各组寄存器可以按“下一阶段还需要什么”来理解，无需先背完整声明：

| 级间寄存器 | 主要内容 | 为什么还需要 |
|---|---|---|
| IF/ID：`if_id_*` | `pc/instr/pred_next/valid` | ID 要译码；EX 以后要核对预测 |
| ID/EX：`id_ex_*` | PC、指令、源编号与旧读值、立即数、rd、控制、预测、valid | EX 要选择最新操作数并执行 |
| EX/MEM：`ex_mem_*` | `result/rs2_val/rd/funct3`、访存与写回控制、PC/指令、异常、valid | MEM 要知道地址、宽度和待写数据；后面还要写回 |
| MEM/WB：`mem_wb_*` | `wdata/rd/reg_we`、PC/指令、store 记录、异常/停机标记、valid | WB 完成写回并报告提交 |

#### 2.2.3 `ex_mem_result` 与 `mem_wb_wdata` 分别是什么

这两个名字最容易让人误以为“任何指令走到这里都已经得到了最终结果”。真实选择逻辑是：

```verilog
ex_mem_result <= (id_ex_wb_sel == 2'd2) ? ex_pc_plus4 : alu_y;
mem_wb_wdata  <= ex_mem_mem_re ? mem_ld_data : ex_mem_result;
```

- ALU 指令：`ex_mem_result` 是计算结果，下一拍直接进入 `mem_wb_wdata`。
- `jal/jalr`：`ex_mem_result` 是 PC+4 的链接地址，因此它也可以像普通结果一样被前递。
- load：`ex_mem_result` 是**访存地址**；MEM 从该地址读出数据后，`mem_wb_wdata` 才是要写 rd 的值。
- store：`ex_mem_result` 也是地址，`ex_mem_rs2_val` 是独立的待存数据；`mem_wb_reg_we=0`，不会使用 `mem_wb_wdata` 写寄存器。

以后看到前递从 `ex_mem_result` 取值，就应当继续确认：生产者是 ALU、跳转，还是尚未得到数据的 load。

#### 2.2.4 `valid`：数据位还在，不代表指令还有效

复位后流水线没有真实指令，四个 `valid` 被清为 0。一次停顿或冲刷也可能把某一级变成空位，这个空位叫**气泡（bubble）**。

气泡不必把所有数据都清零。`id_ex_instr` 可以还保留旧指令，`id_ex_reg_we` 也可能还为 1，但只要 `id_ex_valid=0`，它就不应产生架构副作用。关键入口都用有效性门控，例如：

```verilog
wire wb_we = mem_wb_valid & mem_wb_reg_we & ~mem_wb_exc;
wire mem_go  = ex_mem_valid & ~ex_mem_exc;
assign dmem_wstrb = (mem_go & ex_mem_mem_we) ? mem_strb : 4'b0000;
```

前递、依赖检测、改向也会检查生产者或当前级的 `valid`。因此读波形必须同时看 `*_valid` 和 `*_pc`，不能看到旧指令编码就认定它还在执行。

“气泡”与程序里的 `nop` 不同：`nop` 是一条有效的 `addi x0,x0,0`，会提交并计入指令数；气泡 `valid=0`，不提交、不计入指令数。

### 2.3 冒险从哪里来：资源、数据和下一 PC

**冒险（hazard）** 是多条指令重叠之后，不能让它们按理想节奏直接前进的情况。先区分三种原因：

- **结构冒险（structural hazard）**：硬件端口不够。例如 IF 取指与 MEM 访存同拍竞争一个存储器口。本实验 IMEM/DMEM 分开，寄存器堆有两读一写，因此这些资源冲突不发生。
- **数据冒险（data hazard）**：后面的指令需要某个新值，而该值还没按通常路径写回。例如 add 已算完，但寄存器堆仍保存旧值。
- **控制冒险（control hazard）**：分支结果或跳转目标尚未确定，IF 已经需要决定下一次取哪里。

寄存器堆有足够的读写端口，只解决“同拍能不能访问”；同一地址读写时读到新值还是旧值，还需要下面的写穿透。端口数量问题和数据可见时间问题要分别分析。

本核顺序进入 ID、顺序进入 WB，所有通用寄存器的读都在 ID、写都在 WB，因此需要处理 RAW（read after write，后读依赖前写）。例如 `add x3,...` 后的 `sub ...,x3,...` 必须读到新 x3。

WAR（write after read，后写覆盖前读）要求后面的写越过前面的读，本核不会这样执行；WAW（write after write，后写与前写乱序）也不会发生，因为写回次序固定。增加多周期功能单元并允许后续指令越过等待者后，这些结论需要重新检查。寄存器重命名、记分牌等是更复杂实现的方案，不是当前代码里隐藏的模块。

<a id="pipeline-data-hazards"></a>

### 2.4 数据冒险：先判断值在哪里，再决定前递还是等待

#### 2.4.1 为什么 ID 已经读过寄存器，EX 还要选一次

例如执行两条相邻指令，假设 x1 初值不是 5：

```asm
addi x1, x0, 5
add  x2, x1, x1
```

```text
周期          1    2    3    4    5    6
addi          IF   ID   EX   MEM  WB
add                IF   ID   EX   MEM  WB
```

第 3 拍 add 在 ID 读 x1，但 addi 到第 5 拍 WB 结束才写入寄存器堆，所以第 3 拍的 `id_rs1_val/id_rs2_val` 可能仍是旧值。拍末把它们存进 `id_ex_rs1_val/id_ex_rs2_val`，并不会自动变成新值。

第 4 拍情况发生了变化：addi 已经在 MEM，其上一拍算出的 5 存在 `ex_mem_result`；add 正好在 EX 需要操作数。**前递（forwarding）就是在使用前，从更老指令保存的新结果里重新选值。** 它不提前修改寄存器堆，而是让本条 EX 的输入直接拿到正确数据。

#### 2.4.2 两条 EX 前递路径与优先级

以 rs1 为例，真实代码的等价截取如下，rs2 有完全相同的一组选择：

```verilog
always @* begin
    ex_a_fwd = id_ex_rs1_val;
    ex_b_fwd = id_ex_rs2_val;
    if (FWD != 0) begin
        if (mem_wb_valid && mem_wb_reg_we && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs1)
            ex_a_fwd = mem_wb_wdata;
        if (ex_mem_valid && ex_mem_reg_we && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs1)
            ex_a_fwd = ex_mem_result;
        // 原文件随后对 rs2 做相同选择
    end
end
```

读一个前递条件时逐项解释：

- `ex_mem_valid`：MEM 里有真实指令；气泡中残留的 rd 不算生产者。
- `ex_mem_reg_we`：这条指令会写通用寄存器；store、分支不算。
- `ex_mem_rd != 0`：写 x0 不会产生新值，不能把一个被丢弃的 ALU 结果前递给读 x0 的指令。
- `ex_mem_rd == id_ex_rs1`：生产者准备写的编号，正是消费者当前需要的编号。

`mem_wb_*` 是 MEM/WB → EX，`ex_mem_*` 是 EX/MEM → EX。这两条路的选择结果叫 `ex_a_fwd/ex_b_fwd`，随后才由 ALU 输入 MUX 选择寄存器值、PC、0 或立即数。

同一组合块中使用阻塞赋值 `=`，两个 if 都成立时，后面的赋值覆盖前面的赋值，因此 **MEM 的值优先于 WB**。理由可用三条指令看清：

```asm
addi x1, x0, 1
addi x1, x1, 1
add  x2, x1, x0
```

第三条在 EX 时，第一条在 WB，第二条在 MEM；两条都声称要写 x1，但第二条在程序中更晚，最新值是 2。它虽然比第一条“年轻”，仍然比 EX 里的消费者更老。优先级必须按这个程序次序选择。

#### 2.4.3 WB→ID 写穿透：解决另一个时间位置的依赖

考虑中间隔着两条无关指令的依赖：

```asm
addi x1, x0, 5
addi x6, x0, 1
addi x7, x0, 2
add  x2, x1, x1
```

消费者处于 ID 的那一拍，生产者恰好处于 WB。WB 的写回值已在 `mem_wb_wdata` 上，但寄存器堆要到拍末才写入；消费者也要在同一个拍末把 ID 读值存进 ID/EX。若只读存储数组，采到的仍可能是沿前旧值。

流水线实例化寄存器堆时使用 `BYPASS=1`，读口显式旁路：

```verilog
wire hit1 = (BYPASS != 0) && we && (waddr == raddr1);
assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : hit1 ? wdata : rf[raddr1];
```

只要本拍 WB 允许写、读写编号相同，ID 直接读到写口上的 `wdata`。这是**写穿透（write-through）**，并没有在本代码里生成“前半拍写、后半拍读”的两个时钟。

不要把它与 EX 前递混为一条路径：写穿透服务 **WB 与 ID 同拍**；EX 前递服务 **MEM/WB 与 EX 同拍**。若缺少写穿透，消费者下一拍进入 EX 时，该生产者已经离开 WB，不能指望 EX 前递再把它找回来。

#### 2.4.4 load-use：为什么这一实现停一拍

把生产者换成 load：

```asm
lw  x1, 0(x4)
add x2, x1, x1
```

load 的 EX 算出的是地址，下一拍 MEM 才读到数据。若消费者照常进入 EX，此时 MEM 的 `ex_mem_result` 仍是地址；现有前递 MUX 没有把 `mem_ld_data` 直接送到 EX 的路径。消费者可以可靠使用的 load 结果要到下一拍的 `mem_wb_wdata`。

因此，在 load 位于 EX、消费者位于 ID 时检测依赖，让消费者多留在 ID 一拍：

```text
周期            1    2    3    4    5    6    7
lw              IF   ID   EX   MEM  WB
add                  IF   ID   ID   EX   MEM  WB
                             ^    ^
                 第3拍拍末：暂停   第4拍拍末：恢复推进

第3拍：stall=1，拍末 PC 和 IF/ID 保持；EX 的 load 进入 MEM，ID/EX 变气泡。
第4拍：load 访存，EX 是气泡；ID 中的 add 仍保留，stall 可以解除。
第5拍：add 进入 EX，load 在 WB，从 mem_wb_wdata 前递数据。
```

这里的“一拍”由**当前存储器时序和前递路径**决定，并不是 ISA 规定 load 后必停一拍。另加 MEM 组合读数据 → EX 的长旁路，或者改变存储器延迟，都需要重新分析时序和停顿规则；直接把本 RTL 的 `stall` 删掉会把地址当数据或读到旧值。

当前 MEM 前递条件没有额外排除 load，正确性依赖前面的 load-use 检测：一个真正使用 load 结果的消费者，不会在该 load 位于 MEM 时进入 EX。这两个模块必须结合起来理解。

#### 2.4.5 冒险检测为什么既检查编号，又检查用途

`rv32i_pipe.v` 用一个组合函数统一表示“后面的读依赖前面的写”：

```verilog
function dep(input [4:0] r, input use_r, input v, input we, input [4:0] rd);
    dep = use_r && v && we && (rd != 5'd0) && (rd == r);
endfunction

wire dep_ex = dep(id_rs1, id_uses_rs1, id_ex_valid, id_ex_reg_we, id_ex_rd) |
             dep(id_rs2, id_uses_rs2, id_ex_valid, id_ex_reg_we, id_ex_rd);
wire dep_mem = dep(id_rs1, id_uses_rs1, ex_mem_valid, ex_mem_reg_we, ex_mem_rd) |
             dep(id_rs2, id_uses_rs2, ex_mem_valid, ex_mem_reg_we, ex_mem_rd);

wire load_use = dep_ex & id_ex_mem_re;
wire hazard   = (FWD != 0) ? load_use : (dep_ex | dep_mem);
```

`dep_ex` 比较 ID 消费者与 EX 生产者，`dep_mem` 比较 ID 消费者与 MEM 生产者。只要 rs1、rs2 任一真实使用的源命中就算依赖。比如 `addi` 的 `[24:20]` 是立即数的一部分，虽然也接到了 `id_rs2` 这根线上，但 `id_uses_rs2=0`，不能因此制造假冒险。

`FWD=1` 时，ALU 等结果可以通过前递赶上，只有 `dep_ex & id_ex_mem_re` 需要等。`FWD=0` 时，EX 前递关闭，生产者在 EX 或 MEM 都要等，等它到 WB 时由写穿透供给 ID。

“距离”是静态指令位置之差：紧邻为 1，中间有一条无关指令为 2。假设没有其它停顿、冲刷和依赖，所需额外停顿为：

| 依赖距离 | `FWD=0`，保留 WB→ID 写穿透 | `FWD=1`，ALU 生产者 | `FWD=1`，load 生产者 |
|---|---|---|---|
| 1 | 2 拍 | 0 拍 | 1 拍 |
| 2 | 1 拍 | 0 拍 | 0 拍 |
| 3 或更远 | 0 拍 | 0 拍 | 0 拍 |

第一行可以直接推：无前递的消费者在 ID 看到生产者处于 EX 时等一次，下一拍看到它处于 MEM 时再等一次，再下一拍生产者到 WB，ID 才从写穿透读到结果。带有其它停顿时，不要机械按源码距离套表，应看该拍生产者实际在哪一级。

#### 2.4.6 store、分支与 jalr 也会消费寄存器值

数据依赖不只发生在两个 add 之间。检查消费者时，要问“它的哪个功能真正使用 rs1/rs2”：

- `sw x3,8(x1)`：rs1 用于地址，rs2 用于待存数据。ALU 的 B 口选立即数，但 store 数据仍必须前递。代码用 `ex_mem_rs2_val <= ex_b_fwd` 保存更新后的 rs2。
- `beq x1,x2,label`：比较器输入接 `ex_a_fwd/ex_b_fwd`，否则可能根据旧值决定跳不跳。ALU 则选择 `id_ex_pc/id_ex_imm` 算目标；前递值仍须送比较器，不能因 ALU 不使用 rs1/rs2 就省掉它们的依赖检测。
- `jalr x1,0(x5)`：目标地址使用前递后的 x5，经 ALU 相加后清最低位。
- load 紧跟 store，即使 load 的值只用于 store 数据，本核也会停一拍。因为 store 数据在 EX 就选好并保存，当前没有另设 WB→MEM 的 store 数据旁路。

软件也可以安排无关工作填入等待位置。`fib.s` 尾声先恢复 ra，再执行不依赖 ra 的栈指针更新，最后 `ret` 使用 ra：

```asm
lw   ra, 8(sp)
addi sp, sp, 12
ret
```

这样 load 与真正使用它的 `ret` 相距 2，在这份流水线的 `FWD=1` 配置下不产生 load-use 停顿。第 2.8 节的 fib 实测包含 696 条 load，但 load-use 停顿为 0；load 数量本身不能决定停顿数量。

<a id="pipeline-control-hazards"></a>

### 2.5 控制冒险：从“下一 PC”理解预测与冲刷

#### 2.5.1 分支自己的 PC 和当前取指 PC 不一样

单周期时 ALU 用 `pc+imm` 得到 JAL / branch 的目标。流水线中分支在 EX 时，IF 已经在取更后面的指令，因此 ALU 的 PC 输入必须使用随分支传来的 `id_ex_pc`，不能使用 `if_pc`。JAL / branch 选择 `id_ex_pc + id_ex_imm`，JALR 选择前递后的 rs1 加立即数；三者的实际目标统一来自 `alu_y`。

真实代码把“是否跳”“目标在哪里”“实际下一 PC”分开计算：

```verilog
assign ex_taken  = id_ex_is_jal | id_ex_is_jalr | (id_ex_is_branch & br_cond);
assign ex_target = id_ex_is_jalr ? {alu_y[31:1], 1'b0} : alu_y;
wire [31:0] ex_next = ex_taken ? ex_target : ex_pc_plus4;
```

`br_cond` 来自使用前递操作数的比较器，与 ALU 计算目标并行；条件分支成立才跳，`jal/jalr` 无条件跳。`ex_next` 是“紧接在 EX 这条指令之后，程序真正应执行哪个地址”。PC+4 仍独立计算，既用于顺序执行，也作为 JAL / JALR 的链接值进入 EX/MEM；它与 ALU 算出的目标不能混用。

这个安排复用了执行阶段的 ALU，不会改变指令经过的阶段或冲刷规则。IF 的静态预测器仍有自己的 PC+偏移计算：同一拍 IF 和 EX 处理不同指令，不能直接把 EX 的 ALU 结果当成 IF 的预测目标。是否改善面积或频率需要综合和时序验证，不能仅凭 RTL 中少写一个加法表达式下结论。

但是 IF 不能一直等到 EX 才决定取指，否则分支附近会不断空等。因此 IF 先生成 `if_pred_next`，作为**预测的下一地址**，并把这次预测和本条指令一起保存：

```text
if_pred_next → if_id_pred_next → id_ex_pred_next
```

到 EX 时比较预测和实际：

```verilog
wire redirect = id_ex_valid & (ex_next != id_ex_pred_next);
```

这里判断的是完整下一地址是否不同，既能发现方向错，也能发现“都预测跳，但目标错”。取指可以猜，架构结果必须由 EX 的实际计算纠正。

#### 2.5.2 先看 BP=0：为什么冲掉两条年轻指令

`BP=0` 只有 `if_pred_next=if_pc+4`，即一直沿顺序地址取指。假设一条位于 `0x100` 的 `beq` 实际应跳到 `0x120`：

```text
周期                  1    2    3    4    5    6    7    8
0x100 的分支          IF   ID   EX   MEM  WB
0x104 的错误路径指令       IF   ID   ×
0x108 的错误路径指令            IF   ×
0x120 的目标指令                     IF   ID   EX   MEM  WB
```

第 3 拍 EX 得到真实目标，发现与当初预测的 `0x104` 不同，于是 `redirect=1`。在该拍拍末同时做三件事：

1. `if_pc` 改成 `ex_next=0x120`，第 4 拍开始取目标指令。
2. `id_ex_valid` 清 0，阻止当前 ID 的 `0x104` 指令进入 EX。
3. `if_id_valid` 清 0，丢弃当前 IF 的 `0x108` 指令，不让它成为下一拍的有效 ID 指令。

分支自己从 EX 继续进入 MEM，更老的 MEM/WB 指令也继续完成。所谓“冲掉 IF/ID 与 ID/EX”，指的是**让沿后的两个寄存器槽位无效**；并没有把当前 EX 的分支取消。

与正确预测相比，目标本可第 2 拍就开始取，现在第 4 拍才开始，损失两拍。`BP=0` 下通常一次实际跳转带来两拍损失，但严格条件是下一地址预测错误：若实际目标恰好就是本条 PC+4，则 `redirect=0`。

#### 2.5.3 再看 BP=1：提前看出一部分目标

静态 BTFN（backward taken, forward not taken）按方向作固定预测：

- `jal` 的目标只由本条 PC 和立即数决定，在 IF 预译码后就可以预测跳转。
- 条件分支的偏移为负时预测跳转，偏移非负时预测不跳。循环末尾常向后回跳，所以这个规则对循环有用。
- `jalr` 目标依赖寄存器，本实现的 IF 没有取得该值，因此仍预测 PC+4。

“预译码”只识别必要的 opcode 和立即数位，不在 IF 执行完整的寄存器比较。预测正确就不冲刷，预测错误仍由同一个 `redirect` 比较纠正。能在 IF 看到当前指令，依赖本实验的组合读 IMEM；换存储器模型时必须重排这条路径。

#### 2.5.4 BP=2：记住目标，再学习方向

动态预测器分两个问题：**往哪里跳**和**这次要不要跳**。BTB（branch target buffer，分支目标缓冲）保存目标；方向预测用 2 位饱和计数器。当前实现把它们放在同一组数组里：

| 数组 | 意义 |
|---|---|
| `v` | 表项是否有效 |
| `tag` | PC 的高位标签；与索引一起区分完整的字对齐 PC |
| `tgt` | 上次记录的跳转目标 |
| `cnt` | 2 位方向计数器 |
| `jmp` | 该表项是否为 `jal`，命中后不需要方向判断 |

`BTB_BITS=6` 表示 64 项。索引用 `if_pc[7:2]`，低两位因为字对齐而省略，其余高位存 tag。索引相同但 tag 不同只算未命中，不会直接用另一个地址的目标；两条分支仍可能互相替换，产生容量/冲突损失。

```verilog
wire if_hit = v[if_idx] && (tag[if_idx] == if_pc[31:BTB_BITS+2]);
assign if_pred_next = (if_hit && (jmp[if_idx] || cnt[if_idx][1])) ? tgt[if_idx] : if_pc_plus4;
```

未命中走 PC+4；命中后，如果是 jal 或计数器高位为 1，就选保存的目标。EX 解析后更新表项，只处理条件分支和 jal，**本实现不记录 jalr 的目标，也没有返回地址栈 RAS**。

2 位计数器的状态为 `00` 强不跳、`01` 弱不跳、`10` 弱跳、`11` 强跳；实际跳转则加 1，实际不跳则减 1，到边界后保持。这就是“饱和”，不能从 `11` 加一回绕成 `00`。

从 `11` 遇到一次不跳会变成 `10`，下次仍预测跳；再一次不跳才变成 `01`。所以**从强状态要两次反向结果才改变预测方向**，从弱状态只需一次。不能笼统说任何状态都要连续错两次才改变预测。

本 RTL 在分支首次实际跳转时分配表项，初值设为弱跳 `10`；不跳且未命中时不分配。已有命中项按实际方向饱和更新。计数器只能学习偏向，未必学会交替模式：`10` 遇到不跳降为 `01`，随后遇到跳升为 `10`，可能反复猜错。第 2.8 节的 `branchy` 就展示了这种情况。

gshare、局部历史、RAS、间接跳转预测是可扩展方案，当前代码没有实现。先看清现有表何时查、何时写、命中后选择什么，再去比较更复杂的预测器。

### 2.6 精确停机：先阻止年轻指令，再让老指令完成

#### 2.6.1 为什么不能只等 ecall 到 WB 再停

“年轻/老”指程序顺序：更早出现的是老指令。假设 `ecall` 后紧跟一条 store，当 ecall 进入 WB 时，年轻 store 已经在 MEM；若只在这时设置 `halted`，同一拍末 store 仍可能改写内存。

本实现提前在 EX 检出终止条件：

```verilog
wire ex_exc  = id_ex_illegal | ((id_ex_mem_re | id_ex_mem_we) & ex_misalign);
wire ex_kill = id_ex_valid & (id_ex_is_system | ex_exc);
```

`ex_misalign` 由 EX 已算出的地址和访存宽度决定。因为当前模型没有总线返回错误等更晚的异常来源，可以在 EX 就确定需要停止接收年轻指令。

#### 2.6.2 kill、fetch_stop、halted 各负责哪一步

沿着一条 ecall 的位置看：

```text
本拍：ecall 在 EX，老指令在 MEM/WB，年轻指令在 ID/IF
  ex_kill=1 → 拍末清 if_id_valid/id_ex_valid，置 fetch_stop，PC 保持
下一拍：ecall 在 MEM，老指令继续完成，前端不再加入有效指令
再下一拍：ecall 在 WB，拍末置 halted
```

- `ex_kill` 是本拍的取消事件，用于冲掉年轻指令并启动停止取指。
- `fetch_stop` 是保持下去的状态，防止下一拍又把新指令塞进 ID。
- `halted` 在终止指令到 WB 后置位，表示这次流水线排空与结束处理到达终点。

为什么终止指令也要继续前进？这样在它之前的老指令有机会完成；同时异常标记 `ex_mem_exc/mem_wb_exc` 可以沿流水线传到最终处理点。

对于非法指令或非对齐访存，故障指令的内存写被 `ex_mem_valid & ~ex_mem_exc` 屏蔽，寄存器写被 `mem_wb_valid & mem_wb_reg_we & ~mem_wb_exc` 屏蔽；它到 WB 时置 `trap` 和 `halted`。`commit_valid` 同样排除 `mem_wb_exc`，因此**故障指令到达 WB，不等于作为一条成功指令提交**。作为测试终止约定的 ecall 则会被计入本实验的正常提交轨迹。

精确性的目标是：终止/异常点之前的指令全部完成，更年轻的指令没有架构副作用；故障指令本身也不能写坏寄存器和内存。本核实现的是这个有限模型下的精确停机，不包含保存 `mepc/mcause`、跳入处理程序或 `mret` 返回；这些属于第 5 节。

#### 2.6.3 对照已有的定向测试

`programs/hazards.s` 的结尾先把成功标志写成 1，随后故意放一条不该执行的 store：

```asm
sw   t0, 0(t1)       # 此时 t0=1，t1 指向 tohost
ecall
sw   zero, 0(t1)     # 必须被取消，否则成功标志会被改成 0
```

不要只观察最后 `halted=1`，还要看 ecall 在 EX 时是否发生 `ex_kill`、年轻指令的 valid 是否被清掉，以及后续是否产生了不该出现的 `dmem_wstrb`。

### 2.7 把控制信号落到 RTL：正常、保持、插气泡、冲刷

#### 2.7.1 先区分事件条件与各级的响应

读控制代码时分两步：先看本拍发生了什么事件，再看每组寄存器在下一个沿执行什么动作。事件先集中为：

```verilog
wire flush_young = redirect | ex_kill;
wire stall       = if_id_valid & hazard & ~flush_young;
```

`hazard` 只是依赖条件，`stall` 才是本拍真的执行的停顿。`flush_young` 让错误路径或终止点之后的指令作废，所以它出现时不再为这些指令继续等待。

在默认配置下，普通 load-use 与普通分支改向来自不同种类的 EX 指令，通常不会同时成立；但一条非对齐 load 可以同时产生依赖和 `ex_kill`。用 `~flush_young` 屏蔽停顿能明确优先级，并避免把被取消的等待计入性能统计。

随后集中生成寄存器的控制条件，时序块只使用这些有明确用途的名字：

```verilog
wire pc_redirect = redirect & ~ex_kill;
wire pc_hold     = stall | fetch_stop | ex_kill;
wire if_id_clear = flush_young | fetch_stop;
wire if_id_hold  = stall;
wire id_ex_clear = flush_young | fetch_stop | stall | ~if_id_valid;
```

`clear` 表示清 `valid`，使槽位变成气泡；`hold` 表示有效位和全部数据保持；接收则把上游内容装入本级寄存器。PC 没有 `valid`，只在纠正、保持、采用预测这三种动作中选择。所有条件都是组合信号，直接控制下一个沿，不再另打一拍。

优先级写在各时序块的分支顺序里：PC 是复位 → 纠正 → 保持 → 采用预测；IF/ID 是复位 → 清空 → 保持 → 接收；ID/EX 是复位 → 清空 → 接收。**统一的是动作的命名和写法，不是强迫每一级执行相同动作。** 当前实现的 ID/EX 没有保持需求，数据停顿时应插气泡。

#### 2.7.2 PC：复位、纠正、保持、采用预测

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        if_pc <= RESET_PC;
    end else if (pc_redirect) begin
        if_pc <= ex_next;
    end else if (pc_hold) begin
        if_pc <= if_pc;
    end else begin
        if_pc <= if_pred_next;
    end
end
```

`ex_kill` 出现时令 `pc_redirect=0、pc_hold=1`，同时另一时序块置 `fetch_stop`。正常预测错时 PC 改成 EX 算出的真实下一地址；数据停顿或停止取指时保持；没有这些事件才采用 IF 的预测值。`BP=0` 时最后一路就是 PC+4。

`ex_kill` 负责刚发生事件的本拍，`fetch_stop` 负责之后持续停止：同一个沿里 PC 逻辑看到的是旧的 `fetch_stop`，不能提前使用该沿才写入的 1。普通分支纠正不会置 `fetch_stop`，下一拍仍要从正确目标继续取指。

这里的 PC 保持不会自动停止所有硬件计算。它只是使下一拍继续看到同一个取指地址；前面已经进入 EX/MEM/WB 的老指令是否前进，由各自的时序块决定。

#### 2.7.3 IF/ID 与 ID/EX：为什么停顿时动作不同

IF/ID 的关键分支为：

```verilog
// 摘自 IF/ID 时序块，省略复位分支
if (if_id_clear) begin
    if_id_valid <= 1'b0;
end else if (if_id_hold) begin
    if_id_valid     <= if_id_valid;
    if_id_pc        <= if_id_pc;
    if_id_instr     <= if_id_instr;
    if_id_pred_next <= if_id_pred_next;
end else begin
    if_id_valid     <= 1'b1;
    if_id_pc        <= if_pc;
    if_id_instr     <= if_instr;
    if_id_pred_next <= if_pred_next;
end
```

当 `stall=1` 且没有冲刷或停止取指时，`if_id_hold=1`，代码显式保留整组 `if_id_*`，与 PC 的保持写法一致。ID 中正在等待操作数的指令不会丢失，IF 的下一条也不会把它覆盖。时序块中省略赋值原本也表示保持；这里写出自赋值是为了让三种动作一眼可见，不是多加一级寄存器。

ID/EX 的规则不同：

```verilog
// 摘自 ID/EX 时序块，省略复位和数据字段
if (id_ex_clear) begin
    id_ex_valid <= 1'b0;
end else begin
    id_ex_valid <= 1'b1;
    // 原文件在这里同时保存 if_id_pc、id_rs1_val、id_rd、id_reg_we 等
end
```

ID 还在等待时，不能把它当成可执行指令送到 EX，所以给下一拍 EX 插一个无效空位。当前 EX 的老指令仍由 EX/MEM 时序块捕获并向前推进。

`id_ex_clear` 的四个来源分别是：冲掉当前 ID 指令、停止取指、等待数据、ID 本来就是气泡。这里显式列出 `fetch_stop`，让两组前端寄存器的停止规则直接可见。原来的写法依靠“停止时 IF/ID 必为无效，再由 `!if_id_valid` 传递气泡”；现在直接写明意图，正常运行的行为不变。

**这就是局部停顿的完整动作：留住消费者，让生产者继续走，在二者之间插气泡。** 如果把 EX/MEM 也冻结，load 就无法进入 MEM 取得消费者要等的数据；如果 IF/ID 不保持，消费者会丢失；如果 ID/EX 不清 valid，消费者可能用旧值提前执行或重复执行。

#### 2.7.4 后两级：数据、控制和有效性一起前进

EX/MEM 和 MEM/WB 的时序块在非复位时每拍接收上一级：

```verilog
// 分别摘自两个时序块
ex_mem_valid <= id_ex_valid;
ex_mem_rd    <= id_ex_rd;
ex_mem_reg_we <= id_ex_reg_we;

mem_wb_valid <= ex_mem_valid;
mem_wb_rd    <= ex_mem_rd;
mem_wb_reg_we <= ex_mem_reg_we;
```

上面几行不是将同一条指令在一个沿连续拷贝两次。`mem_wb_*` 接到的是沿前已经在 MEM 的那条，`ex_mem_*` 接到的是沿前已经在 EX 的那条。

当前模型的 MEM 没有 `ready` 等待，因而这两组寄存器持续前进，气泡也随 valid 向后传播。若加入 cache miss 或外部总线反压，就必须新增保持与“请求仅执行一次”的控制，不能把当前规则直接套过去。

对一个有效流水线，用这张表复查拍末动作：

| 事件 | PC | IF/ID 的 `if_id_*` | ID/EX 的 `id_ex_*` | EX/MEM、MEM/WB |
|---|---|---|---|---|
| 正常 | 采用 `if_pred_next` | 接收 IF | 接收 ID（ID 无效则传气泡） | 接收各自上一级 |
| 数据停顿 | 保持 | 整组保持 | `id_ex_valid=0` | 继续前进 |
| 预测错且无 kill | 改为 `ex_next` | `if_id_valid=0` | `id_ex_valid=0` | 分支及老指令继续前进 |
| EX 终止/异常 | 保持，置 `fetch_stop` | `if_id_valid=0` | `id_ex_valid=0` | 终止标记及老指令继续前进 |

清 valid 时，部分数据寄存器可能保持旧值，后两级数据也可能继续更新；是否生效由 valid 和副作用使能共同决定。

#### 2.7.5 带着问题回读代码

第一遍阅读可以按“级间寄存器声明 → 四组时序块 → ID 与寄存器堆 → EX 前递/ALU → MEM → WB → 控制事件”的顺序。IF 里的 `generate` 先只看 `g_nt`，以后再展开 `g_btfn/g_btb`。

每读一个信号，都问四件事：它属于哪条指令、在哪一级产生、在哪个沿被保存、哪一级最终使用。下面几道题可以检查是否真正接上了数据与时序：

1. `id_ex_rd=3` 和 `id_ex_rs1_val=3` 的两个 3 含义一样吗？
2. `ex_mem_mem_re=1` 时，为什么不能把 `ex_mem_result` 直接当作 load 数据？
3. ID 因 load-use 等待时，为什么不能同时冻结 EX/MEM？
4. `id_ex_valid=0`，但波形里的 `id_ex_reg_we=1`，会不会一定写坏寄存器？
5. 连续两条写 x1，第三条读 x1，MEM 和 WB 都命中时该选谁？
6. `sw` 在 MEM 已经写了内存，为什么 WB 仍然带着 `mem_wb_st_addr/mem_wb_st_data/mem_wb_wstrb`？

<details>
<summary>展开参考答案</summary>

1. 前者是目的寄存器编号，后者是保存下来的操作数值。
2. load 的 ALU 结果是有效地址；读出的数据是 `mem_ld_data`，拍末进入 `mem_wb_wdata`。
3. 要让前面的 load 进入 MEM 取得数据，等待才有机会结束。
4. 不会。该槽位是气泡，后续 valid 随它传播，寄存器写口用 `mem_wb_valid` 门控。应结合有效性解释波形。
5. 选 MEM，因为它在程序顺序上比 WB 的生产者更新，且仍早于消费者。
6. 这些是给 WB 提交接口的记录，供 testbench 与 ISS 比较；不是再次执行 store 的写请求。

</details>

常见错误也能按同一思路定位：先检查值从哪里来，再检查指令是否还有效，最后检查在哪个沿产生了副作用。第 2.8 节的变异测试分别破坏前递优先级、x0 屏蔽、load-use、写穿透、冲刷、store 数据和精确停机，观察哪个定向程序能抓住错误。

### 2.8 验证与实测

#### 2.8.1 先跑默认配置，再用波形解释一拍

在 WSL root 的 Bash 中执行：

```bash
cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/13_Computer_Architecture_SoC'
bash lab/Pipeline/run_sim.sh
```

脚本对 `FWD=0/1 × BP=0/1/2` 共六种组合做 lint，实际仿真四种配置 `(1,0)、(0,0)、(1,1)、(1,2)`，每种跑五个程序。不要把“参数有六种组合”误读成“当前回归仿真覆盖全部六种”。

回归通过后，单独跑冒险程序的默认配置，重新生成方便阅读的波形：

```bash
cd lab/Pipeline
source /root/oss-cad-suite/environment
vvp -n build/pipe_f1_b0 +prog=../RV32I/build/hazards +exp_cycles=218
```

本次输出应为 162 条提交、218 拍、6 拍停顿、23 次改向；`218=162+4+6+2×23`。波形是当前目录的 `rv32i_pipe.vcd`，指令地址对照 `../RV32I/build/hazards.lst`，汇编分组注释对照 [hazards.s](lab/RV32I/programs/hazards.s)。

先将下面三组信号分开加入波形，而不是一开始展开所有总线：

1. **指令位置**：`clk/rst_n`，以及 `u_core.if_pc`、`if_id_valid/if_id_pc`、`id_ex_valid/id_ex_pc`、`ex_mem_valid/ex_mem_pc`、`mem_wb_valid/mem_wb_pc`。除时钟复位外都在 `u_core` 下。选定一条 PC，观察它如何逐拍移动；valid=0 的槽位忽略残留 PC。
2. **数据依赖**：`u_core` 下的 `id_rs1/id_rs2`、`id_ex_rd/ex_mem_rd/mem_wb_rd`、`id_ex_rs1_val/id_ex_rs2_val`、`ex_a_fwd/ex_b_fwd`、`ex_mem_result/mem_wb_wdata`、`load_use/hazard/stall`。比较“ID 当时读到的值”和“EX 最终采用的值”。
3. **控制与副作用**：先看 `u_core` 下的事件 `redirect/flush_young/ex_kill/fetch_stop/stall`，再看动作 `pc_redirect/pc_hold/if_id_clear/if_id_hold/id_ex_clear`；用 `id_ex_pred_next/ex_next` 对照改向原因，用顶层 `dmem_wstrb`、`c_valid/c_pc/c_rd_we/c_wdata` 确认被取消的指令没有产生写请求或提交。

按测试程序分组逐次检查：

- 第 1/2 组：无停顿时，EX 操作数是否从 MEM/WB 选到最新值，双重命中是否 MEM 优先。
- 第 4 组：WB 与 ID 的读写编号相同时，ID 是否已拿到写穿透的值。
- 第 5 组：`stall=1` 的沿前记下各级位置；沿后 PC 与 `if_id_*` 保持，`id_ex_valid=0`，原来的 load 进入 MEM。下一拍应恢复推进，随后从 WB 前递。
- 第 6/7 组：load 的结果分别作 store 数据和地址，检查 `ex_mem_rs2_val` 与 `ex_mem_result` 是否各自正确。
- 第 10 组：预测错的沿后 `if_id_valid/id_ex_valid=0`，PC 改成目标；原分支继续进入 MEM，错误路径 store 不产生写使能。
- 结尾 ecall：`fetch_stop` 先置位，终止指令到 WB 才 `halted`，后面的 store 不改变 `tohost`。

testbench 在 `posedge clk` 观察沿前的提交/性能事件，再让 RTL 的非阻塞赋值更新状态。观察波形时要区分“沿前事件条件”和“沿后寄存器结果”，不要把沿后刚切换的 PC 当成刚提交的旧指令。

#### 2.8.2 功能正确与周期正确分别怎样检查

**验证方法**有三层：

1. **lockstep**：和第 1 节一样，WB 级的 commit 接口与 ISS 轨迹逐条比对（PC、写回、store）。流水线、单周期核、ISS 三者的架构行为必须完全一致。
2. **周期恒等式**：testbench 统计停顿拍数和改向次数，要求

$$
\text{cycles} = \text{instret} + 4 + \text{stalls} + 2 \times \text{redirects}
$$

   也就是每一个空拍都能归因到一次停顿或一次冲刷，没有"来历不明"的气泡。多出来的气泡往往就是性能 bug。
3. **解析时序模型**：`rv32_iss.py --pipe` 不看 RTL，只根据提交序列推算周期数。设 $t(i)$ 为第 i 条指令完成 ID、准备在拍末进入 EX 的那个周期；发生停顿时是它最后一个 ID 周期：
   - 正常情况下 $t(i) = t(i-1) + 1$；
   - 上一条预测错，再加 2；
   - 有前递时，若它依赖第 $p$ 条指令产生的 load 数据，要求 $t(i) \ge t(p) + 2$；
   - 无前递时，若第 $p$ 条是某个真实源寄存器的最近生产者，要求 $t(i) \ge t(p) + 3$；
   - 总周期 = $t(\text{最后一条}) + 3$。

   对 `BP=0/1`，testbench 用 `+exp_cycles` 要求 RTL 实测与模型**完全相等**。`BP=2` 的预测结果依赖表的状态，模型不做；但 lockstep 和恒等式照样检查。

`hazards.s` 的 12 组定向测试，每组对准一种冒险或一个常见 bug：

1. 距离 1 / 2 前递；
2. 两级写同一寄存器（前递优先级）；
3. 写 `x0` 不能前递；
4. 距离 3 写穿透；
5. load-use；
6. load 结果做 store 数据；
7. load 结果做 store 地址；
8. load 后马上分支；
9. ALU 结果马上用于分支和 `jalr` 目标、链接值的前递；
10. 预测错后错误路径上的 store 不能执行；
11. load-use 与双重前递混合；
12. 循环（给预测器一点东西）。

最后是精确停机测试。

#### 2.8.3 实测结果与如何解释差异

**实测结果**（`bash lab/Pipeline/run_sim.sh`，真实输出节选；2026-10-27 复跑单周期 5 个程序和流水线 5 个程序 × 4 种配置，均通过，与下面的周期记录一致）：

```
===== sort =====
FWD=1 BP=0  instret=1037 cycles=1576 CPI=1.520  stalls=135 redirects=200  ctrl(br/jal/jalr)=289/15/0  =model
PASS
FWD=0 BP=0  instret=1037 cycles=2061 CPI=1.987  stalls=620 redirects=200  ctrl(br/jal/jalr)=289/15/0  =model
PASS
FWD=1 BP=1  instret=1037 cycles=1340 CPI=1.292  stalls=135 redirects=82  ctrl(br/jal/jalr)=289/15/0  =model
PASS
FWD=1 BP=2  instret=1037 cycles=1302 CPI=1.256  stalls=135 redirects=63  ctrl(br/jal/jalr)=289/15/0
PASS
===== hazards =====
FWD=1 BP=0  instret=162 cycles=218 CPI=1.346  stalls=6 redirects=23  ctrl(br/jal/jalr)=38/1/1  =model
PASS
FWD=0 BP=0  instret=162 cycles=341 CPI=2.105  stalls=129 redirects=23  ctrl(br/jal/jalr)=38/1/1  =model
PASS
FWD=1 BP=1  instret=162 cycles=180 CPI=1.111  stalls=6 redirects=4  ctrl(br/jal/jalr)=38/1/1  =model
PASS
FWD=1 BP=2  instret=162 cycles=184 CPI=1.136  stalls=6 redirects=6  ctrl(br/jal/jalr)=38/1/1
PASS
```

`=model` 表示 RTL 实测周期数与 ISS 解析模型的预测完全相等。随便验算一条恒等式：`sort` 在 `FWD=1 BP=0` 下，1037 + 4 + 135 + 2 × 200 = 1576。

五个程序、四种配置的周期数（括号内为 CPI；单周期核的 CPI 全部是 1.000）：

| 程序 | 指令数 | FWD=0 BP=0 | FWD=1 BP=0 | FWD=1 BP=1 | FWD=1 BP=2 |
|------|--------|------------|------------|------------|------------|
| `isa_test` | 220 | 424（1.927） | 242（1.100） | 240（1.091） | 242（1.100） |
| `sort` | 1037 | 2061（1.987） | 1576（1.520） | 1340（1.292） | 1302（1.256） |
| `fib` | 5355 | 10715（2.001） | 7687（1.435） | 7685（1.435） | 7681（1.434） |
| `hazards` | 162 | 341（2.105） | 218（1.346） | 180（1.111） | 184（1.136） |
| `branchy` | 5163 | 10975（2.126） | 8367（1.621） | 7269（1.408） | 7677（1.487） |

停顿拍数和改向次数：

| 程序 | 停顿 FWD=0 | 停顿 FWD=1 | 改向 BP=0 | 改向 BP=1 | 改向 BP=2 | 分支 / jal / jalr 条数 |
|------|------------|------------|-----------|-----------|-----------|-------------------------|
| `isa_test` | 184 | 2 | 8 | 7 | 8 | 57 / 1 / 2 |
| `sort` | 620 | 135 | 200 | 82 | 63 | 289 / 15 / 0 |
| `fib` | 3028 | 0 | 1164 | 1163 | 1161 | 467 / 1 / 930 |
| `hazards` | 129 | 6 | 23 | 4 | 6 | 38 / 1 / 1 |
| `branchy` | 2608 | 0 | 1600 | 1051 | 1255 | 851 / 201 / 800 |

**读这两张表**：

- **前递的收益最大。** 没有前递时，平均每条指令要停 0.5–0.8 拍（`isa_test` 184/220、`sort` 620/1037、`fib` 3028/5355），再加上冲刷，CPI 都在 2 左右。有了前递，停顿只剩 load-use：`sort` 135 拍，`fib` 0 拍（编译器式调度，2.4 节）。
- **`hazards` 的 6 拍 load-use** 正好是第 5、6、7（两处）、8、11 组：`lw` 后面紧跟着用它。
- **静态 BTFN 对循环很有效。** `sort` 的改向从 200 降到 82，`hazards` 从 23 降到 4。少掉的 19 次里，18 次来自第 12 组的循环：19 次回跳全部预测对，只有出口那一次错。另 1 次是第 10 组的 `jal` 被预译码。
- **`fib` 几乎不受预测器影响**，因为 1164 次改向里有 930 次是 `jalr`：每个 `call`（`auipc + jalr`）和每个 `ret` 都是。本章的预测器都不预测 `jalr`。
  - 剩下的 233 次是 `blt a0, t0, fib_ret`（前向分支，跳 233 次，BTFN 预测不跳，全错），加 1 次 `j pass`。
  - 要改善 `fib`，需要两样东西：BTB 也记录 `jalr`（`call` 的目标在每个调用点是固定的），以及 RAS（`ret`）。
  - 估算：930 次改向全部消除，`fib` 可以从 7681 拍降到约 7681 − 2 × 930 = 5821 拍，CPI ≈ 1.09。这是按恒等式推算的，没有实现。

**`branchy` 里 BTB + 2 bit 计数器比静态 BTFN 还差。** 按程序结构把改向次数拆开（与实测总数一致）：

| 改向来源 | 执行次数 | BP=0 | BP=1（BTFN） | BP=2（BTB + 2 bit） |
|----------|----------|------|--------------|---------------------|
| 奇偶交替的前向分支 `beqz`（跳 / 不跳交替） | 400 | 200 | 200 | **400** |
| `j next`（`jal`） | 200 | 200 | 0 | 1（第一次未命中） |
| `call twice` 的 `jalr` | 400 | 400 | 400 | 400 |
| `ret` | 400 | 400 | 400 | 400 |
| 内层回跳 `blt`（跳 350 次） | 400 | 350 | 50 | 51 |
| 外层回跳 `blt`（跳 49 次） | 50 | 49 | 1 | 2 |
| `j pass` | 1 | 1 | 0 | 1 |
| **合计** | | **1600** | **1051** | **1255** |

交替分支第一次跳转时分配表项，计数器从"弱跳"（`10`）开始。之后的过程是：

- 下一次不跳，预测跳，错，计数器降到 `01`；
- 再下一次跳，预测不跳，又错，计数器回到 `10`……

计数器永远在 `01` 和 `10` 之间来回，**每次都错**（400 次）。静态"前向不跳"至少能对一半。

这是 2 bit 计数器的经典病态模式。解决办法是用历史：局部历史预测器能看出"上次跳了这次就不跳"，gshare 用全局历史也能做到。这正是两级预测器存在的理由。

**变异测试**（`bash lab/Pipeline/mutation.sh`，`FWD=1 BP=0`，每个变异跑 5 个程序）：

```
===== M1: 前递优先级反了 =====
 isa_test:FAIL sort:FAIL fib:FAIL hazards:FAIL branchy:FAIL
===== M2: 前递不排除 x0 =====
 isa_test:FAIL sort:PASS fib:PASS hazards:FAIL branchy:PASS
===== M3: 没有 load-use 停顿 =====
 isa_test:FAIL sort:FAIL fib:PASS hazards:FAIL branchy:PASS
===== M4: 寄存器堆没有写穿透 =====
 isa_test:FAIL sort:FAIL fib:FAIL hazards:FAIL branchy:PASS
===== M5: 预测错只冲 ID/EX，不冲 IF/ID =====
 isa_test:FAIL sort:FAIL fib:FAIL hazards:FAIL branchy:FAIL
===== M6: store 数据不用前递值 =====
 isa_test:FAIL sort:PASS fib:PASS hazards:FAIL branchy:PASS
  首个错误: ERROR #191 pc=0000031c: store addr / data mismatch  got(... sd=ff00ff00) exp(... sd=ffffffff)
===== M7: ecall 不杀更年轻的指令 =====
 isa_test:PASS sort:PASS fib:PASS hazards:FAIL branchy:PASS
  首个错误: ERROR: tohost = 0（程序自检查失败，测试号 0）
```

每个变异都至少被一个程序抓到，而且 `hazards` 抓到了全部 7 个。几点观察：

- **M3 在 `fib` 上 PASS**：`fib` 本来就没有 load-use，少了停顿逻辑也无所谓。同理，`branchy` 没有 load，M3、M6 都测不到。
- **M7 只有 `hazards` 抓得到**，靠的就是 `ecall` 后面紧跟的那条 `sw zero`。变异后 `ecall` 不再停止取指，要走到 WB 才停机。停机那一拍，它后面第 1 条指令正好在 MEM，于是那条 store 写了内存；第 2 条以后的指令还在 EX 或更早的级，到不了 MEM。其它程序 `ecall` 后面是 `fail:` 的 `slli` / `ori` / `la`，store 排在第 5 条，所以 bug 被掩盖了。精确停机的测试必须把"不该执行的 store"紧贴在 `ecall` 后面。
- **M6 曾经是一个"测试本身的 bug"。** `hazards` 第 6 组最初的写法是：

  ```
  lw   t1, 0(t0)     # t1 = 1234
  sw   t1, 4(t0)
  ```

  而 `t1` 在前面第 5 组已经被 load 成了 1234。store 数据漏了前递，用的是 ID 读出来的旧 `t1`，旧值恰好也是 1234，于是测不出来。在 `lw` 前加一条 `li t1, 0` 先把旧值改掉，`hazards` 就抓到了 M6。

  教训是：定向测试要保证"错误的值"和"正确的值"不一样，否则测试只是看起来覆盖了。变异测试正是用来发现这种情况的。

### 2.9 变体与扩展

**同步读 SRAM。** 当前两套 testbench 都是地址给出后本拍组合返回数据。接入带时钟的 SRAM 宏时，必须先确认该宏何时采地址、何时返回数据、有没有额外输出寄存器，不能仅把 `imem/dmem` 数组替换成宏而保留原时序。

例如，若选用的宏在一个上升沿采地址，之后在该周期内返回可供下一沿采样的数据，可以考虑让 EX 的 `alu_y` 在进入 MEM 的边界被宏采样，使读数据在 MEM 拍内可用。地址、rd、宽度、valid、异常标记仍须与同一条请求对齐。若宏再多一级输出寄存器，就要增加阶段或等待拍，load-use 规则也随之改变。

指令口同样要把“请求地址”和“返回指令所属的 PC”配对，停顿时防止覆盖未消费的响应，冲刷时丢弃旧路径响应。把下一 PC 送到同步读地址口是一种可能的安排，但依赖具体边界划分和使能行为；静态预译码还会把“读指令 → 目标计算 → 下一请求地址”连成长路径。这些都属于接口改造，不是当前代码已经验证的能力。

**cache 与访存停顿。** 当数据存储器不能固定在一拍内完成时，需要请求/响应握手。较简单的实现可以保持 MEM 及更年轻的阶段，让 WB 的老指令排空；也可以设计全局保持，但要确保停顿期间不会重复写寄存器、重复提交或反复发出同一个 store。I-cache 等待则通常保留取指请求，已有后端指令继续前进；只有没有有效返回指令时才向 ID 传气泡。第 03 章的保持/握手机制可以复用，但 CPU 的 valid、异常和副作用门控仍须统一设计。

**更深的流水线和超标量。**

| 方向 | 好处 | 代价 |
|------|------|------|
| 更多级（超流水，superpipelining） | 每级更短，频率更高 | 分支在更晚的级解析，罚得更多；load-use 距离变长；寄存器开销占比变大 |
| 多发射（超标量，superscalar） | 每拍取、发多条，CPI < 1 | 寄存器堆读写口翻倍，前递网络平方增长，冒险检测要在同拍的指令之间也做 |
| 乱序执行（out-of-order） | 用后面不相关的指令填停顿 | 寄存器重命名（解决 WAR/WAW）、发射队列、重排序缓冲（ROB）保证按序提交和精确异常 |

**多周期指令（M 扩展）。** 乘法 3 拍流水、除法 32 拍迭代时，结果写回的时间与普通指令不同。做法有两种：

- 简单做法：EX 级停住整条流水线，直到结果出来；
- 进阶做法：记分牌（scoreboard），记录每个寄存器"还在等谁写"，不相关的指令可以继续，但要处理 WAW。

### 2.10 面试要点

1. **五级流水线**：IF 取指 → ID 译码读寄存器 → EX 运算 / 分支解析 → MEM 访存 → WB 写回；理想 CPI = 1，N 条指令 N + 4 拍。
2. **三类冒险**：
   - 结构冒险靠资源复制（哈佛、多端口）；
   - 数据冒险靠前递 + 停顿；
   - 控制冒险靠预测 + 冲刷。
   - 顺序五级流水线没有 WAR / WAW。
3. **前递条件**：`valid && reg_we && rd != 0 && rd == rs`，EX/MEM 优先于 MEM/WB；store 数据也要前递。
4. **load-use**：本核的 load 数据经 MEM/WB 后才进入 EX 前递路径，所以相邻消费者停 1 拍；检测条件是“EX 里是 load 且 rd 等于 ID 里真正要读的 rs”；这是一种实现选择，不能脱离存储器延迟和旁路结构套用。
5. **分支在 EX 解析**：预测错罚 2 拍；用"预测的下一条 PC ≠ 实际下一条 PC"判断，一次覆盖方向错、目标错和别名。冲刷优先于停顿。
6. **预测器**：
   - BTFN 对循环有效；
   - 2 bit 计数器能容忍一次偶然，但在交替模式上 100% 错（本章实测 400/400）；
   - 两级 / gshare 用历史解决相关性；
   - BTB 给出目标；
   - RAS 预测返回地址。
   - `jalr` 不预测时，函数调用密集的程序（`fib`）改向次数几乎不随预测器变化。
7. **精确异常**：异常指令之前的全部完成，故障指令及更年轻指令不产生架构副作用。本核的异常都可在 EX 确定，提前取消年轻指令并让老指令排空；加入更晚的异常来源后，要重新设计异常选择和提交时机。
8. **验证流水线**：与 ISS 逐条比对保证功能；"周期 = 指令数 + 4 + 停顿 + 2 × 冲刷"的恒等式与解析模型保证性能；变异测试检查测试本身的检出能力。

### 2.11 一句话总结

流水线用寄存器把指令切成五段换来频率，代价是冒险：数据冒险靠前递，只剩 load-use 停 1 拍；控制冒险靠预测，预测错罚 2 拍。实测里前递把 CPI 从约 2 降到 1.1–1.6；预测器的收益取决于程序：循环靠 BTFN，交替模式要历史，函数返回要 RAS。

---

## 3. Cache

### 3.1 解决什么问题，面试怎么考

第 2 节的流水线假设存储器一拍返回数据，但 DRAM 的访问延迟是几十纳秒，相当于几十到上百个 CPU 周期。这就是 CPU 与内存之间的速度鸿沟，常被称为"存储墙"（memory wall）。

**Cache（高速缓存）** 是靠近 CPU 的一块小而快的 SRAM，保存最近用过的数据副本。它之所以有效，是因为程序有**局部性（locality）**：

- **时间局部性**：刚用过的数据很快会再用，比如循环变量、栈、热点代码。
- **空间局部性**：用了某个地址，附近的地址很快也会用，比如顺序执行的指令、数组遍历。

Cache 以**行（line / block，常见 32–64 B）** 为单位搬运数据：空间局部性靠行大小来利用，时间局部性靠"留在 cache 里"来利用。

面试考法：

1. 给容量、相联度、行大小和地址宽度，算 tag / index / offset 各几位，以及 tag 存储开销。
2. 直接映射、组相联、全相联的区别和取舍；给一串地址，手算命中 / 缺失。
3. 替换策略：LRU、伪 LRU（PLRU）、FIFO、随机；4 路 LRU 要几个 bit。
4. 写策略：写回 vs 写直达、写分配 vs 写不分配，各自怎么搭配、为什么。
5. 3C 模型：强制、容量、冲突缺失，各自怎么减少。
6. AMAT 与 CPI 的计算题；为什么行越大不一定越好。
7. 代码题：矩阵行优先 / 列优先遍历的命中率，数组 padding 为什么有效。

### 3.2 地址划分

一个地址被切成三段：

```
31                                    0
+--------------------+-------+--------+
|        tag         | index | offset |
+--------------------+-------+--------+
  比较是不是这一行     选组   行内字节
```

| 字段 | 位数 | 作用 |
|------|------|------|
| offset | $\log_2(\text{行大小})$ | 行内字节地址 |
| index | $\log_2(\text{组数})$，组数 = 容量 / (行大小 × 路数) | 选哪一组（set） |
| tag | 地址宽度 − index − offset | 存进 tag 阵列，用来判断"这一行是不是我要的地址" |

**例题 1**：32 bit 地址，32 KB、8 路组相联、64 B 行。

- offset = log2(64) = 6 位；
- 组数 = 32768 / (64 × 8) = 64 组，index = 6 位；
- tag = 32 − 6 − 6 = 20 位。
- 共 512 行，每行另存 20 bit tag + 1 bit valid + 1 bit dirty = 22 bit，合计 11264 bit = 1408 B，约为数据阵列的 4.3%（再加 LRU 位）。

这里 index + offset = 12 位，正好是 4 KB 页内偏移。L1 可以用虚拟地址的低 12 位选组，同时 TLB 并行翻译出物理地址来比较 tag（VIPT，虚拟索引物理标签），而不会产生别名问题。这就是"32 KB 8 路"这种 L1 配置那么常见的原因之一。

### 3.3 三种映射方式

```
直接映射（1 路）            2 路组相联                     全相联
 组0 [行]                    组0 [路0][路1]                [行][行][行][行]...
 组1 [行]                    组1 [路0][路1]                任何地址可以放任何行
 组2 [行]   ← index 决定       ...                          所有行同时比较 tag
 组3 [行]     唯一位置       index 决定组，组内任选一路
 比较器：1 个                比较器：2 个                   比较器：行数个
```

| 方式 | 命中判断 | 优点 | 缺点 |
|------|----------|------|------|
| 直接映射（direct-mapped） | 一个 tag 比较 | 最快、最省面积和功耗；不需要替换策略 | 两个"同 index 不同 tag"的热点会互相踢（冲突缺失） |
| N 路组相联（N-way set-associative） | 组内 N 个 tag 并行比较 + N 选 1 MUX | 冲突大幅减少；L1 常用 4–8 路 | 比较器和 MUX 增加命中延迟和功耗；需要替换策略 |
| 全相联（fully associative） | 所有行并行比较（CAM） | 没有冲突缺失 | 只适合很小的结构：TLB、victim cache、写缓冲 |

直接映射就是 1 路组相联，全相联就是只有 1 组的组相联。本章的 RTL 用同一份代码覆盖三种：`WAYS = 1` 是直接映射，`SETS = 1` 是全相联。

**例题 2（手算命中）**：64 B 的 cache，16 B 行，依次读字节地址 `0x00 0x04 0x40 0x00 0x10 0x50 0x14 0x40`。

块号 = 地址 / 16：`0 0 4 0 1 5 1 4`。

| 地址 | 块号 | 直接映射（4 组）组 / tag | 结果 | 2 路组相联（2 组）组 / tag | 结果 |
|------|------|--------------------------|------|----------------------------|------|
| 0x00 | 0 | 0 / 0 | 缺失 | 0 / 0 | 缺失 |
| 0x04 | 0 | 0 / 0 | **命中** | 0 / 0 | **命中** |
| 0x40 | 4 | 0 / 1（踢掉 tag 0） | 缺失 | 0 / 2（放另一路） | 缺失 |
| 0x00 | 0 | 0 / 0（踢掉 tag 1） | 缺失 | 0 / 0 | **命中** |
| 0x10 | 1 | 1 / 0 | 缺失 | 1 / 0 | 缺失 |
| 0x50 | 5 | 1 / 1（踢掉 tag 0） | 缺失 | 1 / 2 | 缺失 |
| 0x14 | 1 | 1 / 0（踢掉 tag 1） | 缺失 | 1 / 0 | **命中** |
| 0x40 | 4 | 0 / 1（踢掉 tag 0） | 缺失 | 0 / 2 | **命中** |

直接映射命中 1/8，2 路组相联命中 4/8；4 行全相联也是 4/8。用 `cache_sim.py` 的 `Cache` 类复算的结果相同。

### 3.4 替换策略

组相联缺失时，要选组内一路换出去（牺牲行，victim）：

| 策略 | 做法 | 每组状态位（4 路 / 8 路） | 特点 |
|------|------|---------------------------|------|
| 真 LRU | 换出最久没被访问的 | 年龄计数器：4×2 = 8 / 8×3 = 24；信息论下限 log2(N!)：5 / 16 | 效果好，路数多时开销大 |
| 树形伪 LRU（tree-PLRU） | N−1 个 bit 组成二叉树，每个节点指向"较久没用"的那半边 | 3 / 7 | L1 最常用；近似 LRU |
| FIFO | 换出最早进来的 | log2(N) 的轮转指针 | 简单；不考虑命中 |
| 随机 | 伪随机数（LFSR）选一路 | LFSR | 路数多时与 LRU 差不多，硬件最简单 |
| NRU / RRIP | 每行 1–2 bit"最近用过 / 重用距离预测" | N 或 2N | L2 / L3 常用，抗扫描（一次性的大数据流不会把热数据冲掉） |

**树形 PLRU（4 路）**：3 个 bit `b0 b1 b2`。

```
            b0
         0/    \1          bit = 0 表示"牺牲行在左边"，= 1 表示"在右边"
        b1      b2
      0/ \1   0/ \1
     路0 路1  路2 路3

访问路 1：沿路径把节点设成"指向另一边"：b0 = 1（右边较旧），b1 = 0（路 0 较旧）
换出：从根沿 bit 指向走：b0 = 1 → b2 → ...
```

**本章 RTL 的真 LRU** 用每路一个"年龄"：0 = 最近用过，WAYS−1 = 最久没用。复位时第 w 路的年龄等于 w，各路年龄构成一个排列。之后每次访问做如下更新，各路年龄始终是一个排列：

- 被访问的路年龄清 0；
- 比它年轻的各加 1；
- 比它老的不变。

```verilog
if (access) begin
    // 真 LRU：被访问的路年龄清 0，比它年轻的各加 1，比它老的不变
    for (w2 = 0; w2 < WAYS; w2 = w2 + 1)
        if (w2[AGEW-1:0] == hit_way)
            age[{w2[AGEW-1:0], r_idx}] <= {AGEW{1'b0}};
        else if (age[{w2[AGEW-1:0], r_idx}] < hit_age)
            age[{w2[AGEW-1:0], r_idx}] <= age[{w2[AGEW-1:0], r_idx}] + 1'b1;
    if (r_we && WRITE_BACK != 0) dirty[{hit_way, r_idx}] <= 1'b1;
end
```

选牺牲行：有无效路就先填编号最小的无效路，否则选年龄为 WAYS−1 的那一路。

### 3.5 写策略

写有两个独立的选择：

| | 写命中时 | 写缺失时 |
|--|----------|----------|
| 写回（write-back） | 只改 cache，置脏位（dirty）；被换出时才把整行写回内存 | — |
| 写直达（write-through） | 同时改 cache 和内存 | — |
| 写分配（write-allocate） | — | 先把整行读进 cache，再按写命中处理 |
| 写不分配（no-write-allocate） | — | 直接写内存，不读进 cache |

常见搭配：

- **写回 + 写分配**：L1 / L2 的主流。同一行的多次写只在换出时写回一次，内存流量小；写缺失读入整行，是赌后面还会访问这一行。
- **写直达 + 写不分配**：实现简单，cache 和内存永远一致（不需要脏位，掉电或一致性处理简单）。代价是每次写都占内存带宽，一般要配一个**写缓冲（write buffer）**，让 CPU 不必等写完成。早期的 L1 和一些嵌入式核用这种。

本章 RTL 用参数 `WRITE_BACK` 切换两种搭配，第 3.8 节和 E5 实验对比了它们的内存流量。

### 3.6 3C 模型

缺失按原因分三类（Hill 的 3C 模型）：

| 类型 | 定义（怎么数） | 减少的办法 |
|------|----------------|------------|
| 强制缺失（compulsory / cold） | 第一次访问某一行，任何 cache 都躲不掉 | 更大的行、预取（prefetch） |
| 容量缺失（capacity） | 同容量的**全相联 LRU** cache 也会缺失的部分，减去强制缺失 | 更大的 cache；改算法让工作集变小（分块，tiling / blocking） |
| 冲突缺失（conflict） | 实际 cache 的缺失，减去同容量全相联 LRU 的缺失 | 更高的相联度、victim cache、改数据布局（padding） |

多核还有第四个 C：**一致性缺失（coherence）**，即别的核写了这一行，导致本核的副本失效。

`cache_sim.py` 的 `three_c()` 就按上表的定义数：先统计强制缺失，再跑一个同容量全相联 LRU 得到"强制 + 容量"，实际缺失减去它就是冲突。

### 3.7 AMAT 与性能计算

**平均访存时间（AMAT，Average Memory Access Time）**：

$$
\text{AMAT} = \text{命中时间} + \text{缺失率} \times \text{缺失代价}
$$

多级 cache 时递归展开：

$$
\text{AMAT} = t_{L1} + m_{L1} \times \left( t_{L2} + m_{L2,\text{局部}} \times t_{\text{mem}} \right)
$$

**例题 3**：L1 命中 1 拍、缺失率 5%；L2 命中 10 拍、局部缺失率 20%；内存 100 拍。

- AMAT = 1 + 0.05 × (10 + 0.2 × 100) = 1 + 0.05 × 30 = **2.5 拍**。
- L2 的全局缺失率 = 5% × 20% = 1%：每 100 次访存有 1 次要到内存。

**例题 4（CPI）**：基础 CPI = 1，30% 的指令是 load/store；I-cache 缺失率 2%，D-cache 缺失率 5%，缺失代价都是 50 拍。

$$
\text{CPI} = 1 + \underbrace{1 \times 0.02 \times 50}_{\text{取指}} + \underbrace{0.3 \times 0.05 \times 50}_{\text{数据}} = 1 + 1 + 0.75 = 2.75
$$

存储停顿让 CPU 慢了 2.75 倍，比第 2 节的数据冒险和控制冒险加起来还严重。

**例题 5（循环顺序）**：`int A[64][64]` 按行优先存储（每行 256 B），求和；cache 1 KB、2 路、16 B 行（32 组）。

- **行优先遍历**：顺序访问，每行 cache 装 4 个 int，每 4 次访问 1 次缺失，**缺失率 25%**（全是强制缺失）。
- **列优先遍历**：相邻两次访问相距 256 B = 16 行。组号 = (地址 / 16) mod 32 = (16i + j/4) mod 32，i 变化时只在 2 个组之间来回。
  - 一列的 64 个元素挤在 2 组 × 2 路 = 4 个位置里，下一列再用到这些行时早就被踢掉了；
  - **缺失率 100%**，而且其中 3/4 是冲突缺失。一列只碰 64 个 cache 行（1 KB，正好是 cache 容量），每一行本可以被后面 3 列复用（一行装 4 个 int）；但这 64 行只落在 4 个位置上，复用不了。
- **padding**：每行补 4 个 int，`A[64][68]`，行距 272 B = 17 行。组号 = (17i + j/4) mod 32，连续 32 行落在 32 个不同的组，64 行正好占满 32 组 × 2 路。同一个 cache 行在后面 3 列里被复用，缺失率回到 **25%**。

下面 E1、E3 的实验结果与这里的手算一致。

### 3.8 RTL 解读：`lab/Cache/cache.v`

**接口与参数**：

| 参数 | 含义 |
|------|------|
| `LINE_WORDS` | 每行字数（2 的幂，≥ 2） |
| `SETS` | 组数（2 的幂，1 = 全相联） |
| `WAYS` | 路数（2 的幂，1 = 直接映射） |
| `WRITE_BACK` | 1 = 写回 + 写分配；0 = 写直达 + 写不分配 |

- CPU 口：valid/ready 请求 + 只有 valid 的响应（读写都回响应）。
- 内存口：整行宽度的 valid/ready 请求；读数据在 `mem_resp_valid` 时整行返回。
- 统计输出：`perf_hit`、`perf_miss`、`perf_writeback`。

**状态机**（阻塞式：一次只处理一个缺失）：

```
            accept
   IDLE ────────────► LOOKUP ── 命中 ──► 回响应；同一拍可以接收下一个请求（背靠背命中）
    ▲                   │
    │                   ├── 缺失，牺牲行是脏的 ──► WB ──（整行写回握手）──► REQ
    │                   ├── 缺失，牺牲行干净 ─────────────────────────────► REQ
    │                   │                                                   │（读请求握手）
    │                   │                                                   ▼
    │                   │◄────────── 回到 LOOKUP 重查（必然命中）◄── WAIT（数据返回，填充）
    │                   │
    │                   └── 写直达模式的写 ──► WT ──（写一个字，握手即响应）──┐
    └─────────────────────────────────────────────────────────────────────────┘
```

缺失时填充完成后回到 LOOKUP"重查一遍"，而不是在 WAIT 里直接回响应。这样读缺失、写缺失（写分配后要合并写数据）、LRU 更新都走和命中完全相同的路径，代码只有一份。代价是缺失多 1 拍。`r_retry` 标记第二次 LOOKUP，不重复计入命中统计。

**命中判断：所有路并行比较 tag。** 存储体按 `{路, 组}` 拼接寻址，组数和路数都是 2 的幂，所以不需要乘法：

```verilog
always @* begin
    hit = 1'b0; hit_way = {AGEW{1'b0}};
    has_inv = 1'b0; inv_way = {AGEW{1'b0}}; lru_way = {AGEW{1'b0}};
    for (w = WAYS - 1; w >= 0; w = w - 1) begin     // 倒序：最后留下的是编号最小的无效路
        if (valid[{w[AGEW-1:0], r_idx}] && tag[{w[AGEW-1:0], r_idx}] == r_tag) begin
            hit = 1'b1; hit_way = w[AGEW-1:0];
        end
        if (!valid[{w[AGEW-1:0], r_idx}]) begin
            has_inv = 1'b1; inv_way = w[AGEW-1:0];
        end
        if (age[{w[AGEW-1:0], r_idx}] == OLDEST) lru_way = w[AGEW-1:0];
    end
end
wire [AGEW-1:0] victim = has_inv ? inv_way : lru_way;
```

**背靠背命中**：LOOKUP 命中的那一拍 `cpu_req_ready` 也为 1，可以同时接收下一个请求，命中吞吐是每拍一个：

```verilog
wire serve_hit  = lookup & hit & ~wt_write;           // 本拍直接完成
assign cpu_req_ready = (state == S_IDLE) | serve_hit;
```

**写回地址用牺牲行自己的 tag**，不是当前请求的 tag：

```verilog
assign vict_addr = {tag[{r_victim, r_idx}], r_idx, {OFFW{1'b0}}};
```

**复位策略**：`valid`、`dirty`、`age` 要复位，数据和 tag 阵列不复位，这样可以映射到 SRAM 宏。有效位为 0 的行，其 tag 和数据从不被使用，所以不复位是安全的。

**常见错误**（对应下面的变异测试）：

| 错误 | 后果 |
|------|------|
| 命中时不更新 LRU（只在填充时更新） | 实际变成 FIFO 替换。**数据完全正确**，只有命中率变差 |
| 写命中不置脏位 | 被换出时修改丢失 |
| 填充新行时不清脏位 | 多出无用的写回（数据仍正确，只浪费带宽） |
| 写命中时不看字节使能，整字覆盖 | `sb` / `sh` 改坏相邻字节 |
| 写回地址用了当前请求的 tag | 脏数据写到错误地址 |
| LRU 年龄复位成全 0（不是排列） | 年龄比较失效，替换退化 |
| 填充过程中牺牲路被重新计算 | 填充和写回的不是同一路（本 RTL 在缺失那拍锁存 `r_victim`） |

### 3.9 验证与实测

**testbench（`tb_cache.v`）的参考模型有两层**：

1. **平坦内存 `ref_mem`**：请求被接收时按序更新。读响应的数据必须与它一致，这一层检查数据正确性。
2. **行为级 tag / LRU 模型**：请求被接收时就预测"这次命中还是缺失、会不会写回脏行"，与 RTL 的 `perf_hit` / `perf_miss` / `perf_writeback` 逐个请求比对，这一层检查策略正确性。

激励把四种模式随机混合，40% 写、随机字节使能，请求之间随机插空拍，内存延迟 8 拍 + 0–2 拍随机抖动：

- 顺序流；
- 热点区（半个 cache 大小）；
- 同组冲突（WAYS + 1 个 tag 轮流访问，专测 LRU）；
- 全范围随机（地址范围是 cache 容量的 4 倍）。

20000 个请求之后，再把整个地址范围读一遍，确认被换出的脏数据都正确写回了。

第三层独立校验：testbench 把请求序列写成文件，`cache_sim.py replay` 用完全独立的 Python 实现（每组一个 LRU 列表）重放，复算命中、缺失、写回次数，要求与 RTL 一致。

**实测**（`bash lab/Cache/run_sim.sh`，5 种配置，容量都是 512 B、16 B 行；真实输出节选）：

```
===== SETS=32 WAYS=1 LINE_WORDS=4 WRITE_BACK=1 =====
cfg SETS=32 WAYS=1 LINE=16B WB LAT=8 | size=512B range=2048B
reqs=20000 (R 12022 / W 7978)  hits=10833 misses=9167  hit_rate=54.16%  writebacks=4982
latency: in-cache=1.00  needs-mem=19.46  avg(AMAT)=9.46 cycles   mem traffic: rd=146672B wr=79712B
PASS
cache_sim: reqs=20000 hits=10833 misses=9167 writebacks=4982
MATCH: 与 RTL 计数完全一致
...
===== SETS=8 WAYS=4 LINE_WORDS=4 WRITE_BACK=0 =====
cfg SETS=8 WAYS=4 LINE=16B WT LAT=8 | size=512B range=2048B
reqs=20000 (R 12044 / W 7956)  hits=12190 misses=7810  hit_rate=60.95%  writebacks=0
latency: in-cache=1.00  needs-mem=10.03  avg(AMAT)=6.70 cycles   mem traffic: rd=74832B wr=16971B
PASS
cache_sim: reqs=20000 hits=12190 misses=7810 writebacks=0
MATCH: 与 RTL 计数完全一致
```

| 配置 | 命中率 | 缺失 | 写回 | 需访存的请求平均延迟 | AMAT（拍） | 内存读 / 写（B） |
|------|--------|------|------|----------------------|------------|------------------|
| 直接映射（32 组 × 1 路），写回 | 54.16% | 9167 | 4982 | 19.46 | 9.46 | 146672 / 79712 |
| 2 路（16 组），写回 | 57.31% | 8538 | 4587 | 19.38 | 8.84 | 136608 / 73392 |
| 4 路（8 组），写回 | 59.13% | 8173 | 4622 | 19.67 | 8.63 | 130768 / 73952 |
| 全相联（1 组 × 32 路），写回 | 76.61% | 4677 | 2959 | 20.33 | 5.52 | 74832 / 47344 |
| 4 路（8 组），写直达 | 60.95% | 7810 | 0 | 10.03 | 6.70 | 74832 / 16971 |

所有配置都 PASS，并且 RTL 的计数与 Python 复算完全一致（MATCH）。读这张表：

- **相联度越高，命中率越高**：直接映射 54% → 4 路 59% → 全相联 77%。激励里专门有"WAYS + 1 个 tag 轮流访问同一组"的冲突模式。全相联没有冲突缺失，这一块收益最大。
- **AMAT 与公式吻合**：在 cache 里完成的请求 1 拍。需要访存的约 20 拍：读一行约 10 拍，而约一半的缺失还要先写回一个脏行（4982 / 9167 ≈ 54%）。直接映射：0.5416 × 1 + 0.4584 × 19.46 ≈ 9.46。
- **写直达的内存写流量反而更小**（16971 B vs 73952 B）。这与"写直达流量大"的直觉相反，原因有两个：
  - 这里统计的是字节使能为 1 的字节数。写直达每次只写被改的那几个字节，写回则每次写整行 16 B；
  - 本激励的写分散在 4 倍于 cache 的地址范围里：7978 次写对应 4622 次写回，平均每个脏行被换出前只被写过约 1.7 次，而每次写回都要写整行。

  写回省带宽的前提是"同一行被反复写"，E5 实验演示的就是这种情况。
- 各配置的请求序列并不完全相同：读写数略有差异，因为随机空拍和握手时机会改变随机数的消耗顺序。横向比较看趋势；严格同一序列的对比见下面的 `cache_sim.py` 实验。

**变异测试**（`bash lab/Cache/mutation.sh`，4 路写回，5000 个请求）：

```
===== M1: 命中不更新 LRU（变成 FIFO）=====
ERROR @7465000: addr=00000028 RTL hit，模型预测 miss
FAIL (1768 errors)
===== M2: 写命中不置脏 =====
ERROR @6705000: 读 00000014 得到 63132cc6，期望 63422cc6
FAIL (2625 errors)
===== M3: 填充不清脏位 =====
ERROR: 写回次数 RTL 2057，模型 1183（未完成 -966）
FAIL (1 errors)
===== M4: 不优先填无效路（等价变异，预期 PASS）=====
PASS
===== M5: 写命中不看字节使能 =====
ERROR @1385000: 读 00000070 得到 4ccdd499，期望 4ccdd431
FAIL (2538 errors)
===== M6: 写回地址用错 tag =====
ERROR @4805000: 读 000002f8 得到 25953c4a，期望 646678c8
FAIL (3301 errors)
===== M7: 年龄全部复位为 0 =====
ERROR @5855000: addr=00000010 RTL hit，模型预测 miss
FAIL (954 errors)
```

（每个变异只摘了第一条错误。）三点结论：

1. **M1、M3、M7 的数据完全正确**，只靠第二层"命中 / 缺失 / 写回逐个比对"抓到。只检查读回数据的 testbench 会放过这类性能 bug，而它们在真实芯片上意味着跑分掉一截。
2. **M4 是等价变异。** 去掉"优先填无效路"后，命中 / 缺失序列与原设计完全相同，所以测试 PASS。原因是：
   - 年龄复位成排列 `0, 1, …, WAYS−1`，无效路是"从没被访问过"的路；
   - 每次访问只会让比被访问路年轻的路变老，所以无效路的年龄始终大于所有有效路；
   - 年龄最大（= WAYS−1）的那一路，只要还有无效路，就一定是无效路。

   也就是说，在这个复位方式下，"优先填无效路"这段逻辑是冗余的。M7 把年龄复位成全 0 之后，这个性质不再成立，替换立刻出错。变异测试里 PASS 的变异不一定说明测试有漏洞，要分析它是否等价。
3. **M2、M5、M6 的数据错了**：结束时的全范围读回和随机读都能抓到。

### 3.10 `cache_sim.py` 实验

`python3 lab/Cache/cache_sim.py experiments`（`run_sim.sh` 最后也会跑），真实输出：

```
=== E1 循环顺序：int A[64][64]（16 KB）求和，cache 1 KB / 2 路 ===
  line= 16B  行优先: miss rate =  25.00%
  line= 16B  列优先: miss rate = 100.00%
  line= 64B  行优先: miss rate =   6.25%
  line= 64B  列优先: miss rate = 100.00%
  line= 16B  列优先，每行填充 16 B（A[64][68]）: miss rate =  25.00%

=== E2 冲突与相联度：dot(a, b)，a、b 相距 4 KB，各 256 个 int，cache 1 KB / 16B 行 ===
    1 路: miss rate = 100.00%
    2 路: miss rate =  25.00%
    4 路: miss rate =  25.00%
    全相联: miss rate =  25.00%
  直接映射，b 错开 16 B（padding）: miss rate =  25.00%

=== E3 3C 分类（cache 1 KB / 16B 行）===
  dot 相距 4KB   1 路: 总缺失    512 = 强制   128 + 容量      0 + 冲突    384
  dot 相距 4KB   2 路: 总缺失    128 = 强制   128 + 容量      0 + 冲突      0
  dot 相距 4KB   4 路: 总缺失    128 = 强制   128 + 容量      0 + 冲突      0
  列优先矩阵        1 路: 总缺失   4096 = 强制  1024 + 容量      0 + 冲突   3072
  列优先矩阵        2 路: 总缺失   4096 = 强制  1024 + 容量      0 + 冲突   3072
  列优先矩阵        4 路: 总缺失   4096 = 强制  1024 + 容量      0 + 冲突   3072
  列优先+填充       1 路: 总缺失   1024 = 强制  1024 + 容量      0 + 冲突      0
  列优先+填充       2 路: 总缺失   1024 = 强制  1024 + 容量      0 + 冲突      0
  列优先+填充       4 路: 总缺失   1024 = 强制  1024 + 容量      0 + 冲突      0
  随机 4KB 范围    1 路: 总缺失  14946 = 强制   256 + 容量  14657 + 冲突     33
  随机 4KB 范围    2 路: 总缺失  14957 = 强制   256 + 容量  14657 + 冲突     44
  随机 4KB 范围    4 路: 总缺失  14944 = 强制   256 + 容量  14657 + 冲突     31

=== E4 行大小与 AMAT（cache 1 KB / 2 路；命中 1 拍，缺失代价 = 8 + 每字 1 拍）===
  line   顺序 miss / AMAT      4 个流 miss / AMAT      随机 miss / AMAT
     8B   50.00% /  6.00       12.85% /  2.29       93.42% / 10.34
    16B   25.00% /  4.00        6.76% /  1.81       93.71% / 12.25
    32B   12.50% /  3.00        3.95% /  1.63       93.66% / 15.99
    64B    6.25% /  2.50        3.17% /  1.76       93.66% / 23.48
   128B    3.12% /  2.25        5.25% /  3.10       94.00% / 38.60
   256B    1.56% /  2.12       18.43% / 14.27       93.80% / 68.53

=== E5 写策略与内存流量：对 256 B 的数组反复读改写 20 遍，cache 1 KB / 2 路 / 16B 行 ===
  写回  : miss rate  0.62%  内存读   256 B  写     0 B  结束时 cache 里的脏行 16
  写直达: miss rate  0.62%  内存读   256 B  写  5120 B  结束时 cache 里的脏行 0
```

**E1 循环顺序。** 与 3.7 节例题 5 的手算完全一致：

- 行优先 25%，列优先 100%，padding 后回到 25%；
- 行大小加到 64 B 时，行优先降到 6.25%（每行 16 个 int）；列优先仍是 100%，因为它根本没用上空间局部性。

工程上要么换循环顺序（编译器的 loop interchange），要么 padding，要么分块（tiling）。

**E2 冲突与相联度。** `a[i]` 和 `b[i]` 相距 4 KB，是 1 KB cache 的整数倍，在直接映射 cache 里永远映射到同一组，交替访问时互相踢，缺失率 100%（乒乓效应）。有两种解法：

- 加到 2 路就足够：两行能共存，缺失率降到 25%（只剩强制缺失），再加路数没有额外收益；
- 不加相联度，把 `b` 错开 16 B，也一样是 25%。

所以编译器和库常对大数组做起始地址错开（array padding / coloring）。

**E3 3C 分类**把前两组的直觉量化了：

- `dot` 和列优先矩阵的额外缺失全是**冲突缺失**，padding 能把它们消除干净。
- 列优先矩阵的冲突在 1、2、4 路下都是 3072。行距 256 B 是 16 行，一列的 64 个 cache 行无论几路都只落在 4 个位置上：1 路时 4 组 × 1 路，2 路时 2 组 × 2 路，4 路时 1 组 × 4 路。只有全相联才装得下。相联度翻倍的同时组数减半，对这种步长毫无帮助。
- 4 KB 范围的随机访问在 1 KB cache 上几乎全是**容量缺失**（14657），加相联度毫无作用（冲突只有 31–44）。只有加大 cache 或者改算法才有用。

**E4 行大小与 AMAT。** 缺失代价 = 8 拍首字延迟 + 每字 1 拍传输：

- **顺序访问**：行越大越好，缺失率每翻一倍减半。但 AMAT 的收益递减，因为缺失代价也在涨。
- **4 个缓慢前进的访问流**（介于顺序和随机之间）：
  - 行太小，空间局部性没用上；
  - 行太大，1 KB 里只剩几行，4 个流互相挤占：256 B 行只有 4 行（2 组 × 2 路），缺失率回升到 18%。
  - **缺失率最低在 64 B（3.17%），AMAT 最低却在 32 B（1.63）**，因为 64 B 行的缺失代价是 24 拍，32 B 只有 16 拍。
  - 优化缺失率和优化 AMAT 得出的结论不一样，面试常问"行越大越好吗"，答案就在这里。
- **随机访问**：缺失率与行大小无关（约 94%），AMAT 随缺失代价线性上升，行越小越好。

**E5 写策略**：对一个 256 B 的数组反复读改写 20 遍（数组完全装得进 cache）。

- 写回：内存只读了 16 行（强制缺失），一个字节都没写，16 个脏行留在 cache 里，等将来被换出或被 flush 时才写回。
- 写直达：每次写都写内存，20 × 64 × 4 = 5120 B。

这正是写回在"热数据反复写"场景下的优势，也是 L1 / L2 普遍用写回的原因。与 3.9 节 RTL 实测的结论对照起来看：哪种写策略更省带宽，取决于访问模式。

### 3.11 变体与扩展

| 技术 | 解决的问题 | 要点 |
|------|------------|------|
| 非阻塞 cache（non-blocking / lockup-free） | 本章的 cache 缺失时整个停住 | 缺失状态保持寄存器（MSHR）记录在途缺失，命中可以继续服务（hit-under-miss），甚至多个缺失并行（miss-under-miss）；乱序核必备 |
| 关键字优先 / 提前重启（critical word first / early restart） | 等整行到齐才返回太慢 | 内存先送 CPU 要的那个字，或者那个字到了就先返回；AXI 的 WRAP burst 就是为此设计的（第 12 章第 3 节） |
| 写缓冲（write buffer） | 写直达要等内存 | 写进 FIFO 就算完成；后面的读要检查写缓冲里有没有同地址的数据 |
| victim cache | 直接映射的冲突缺失 | 被换出的行先放进一个 4–16 项的全相联小 cache |
| 硬件预取（prefetch） | 强制缺失 | 下一行预取（next-line）、步长预取（stride）；预取太多会污染 cache、浪费带宽 |
| 多级 cache | 单级无法同时做到又快又大 | L1 小而快（1–4 拍），L2 / L3 大而慢；包含（inclusive）/ 排他（exclusive）/ 非包含（NINE）三种关系 |
| VIPT / PIPT | 虚拟地址与物理地址 | VIPT 用虚拟地址索引、物理地址比较 tag，要求 index + offset ≤ 页偏移，否则会出现别名（同一物理地址出现在两组） |
| 一致性（coherence） | 多核各自 cache 同一地址 | 监听（snooping）或目录（directory）协议，MESI / MOESI 状态；DMA 与 cache 的一致性问题放到第 5、6 节 |
| 分块（tiling / blocking） | 容量缺失 | 软件把大矩阵切成能装进 cache 的小块，矩阵乘法的经典优化 |

**cache 接进第 2 节的流水线**：

- I-cache 缺失时停 IF、往 ID 送气泡；
- D-cache 缺失时停住 MEM 及之前的级（第 2.9 节）。
- 命中时间仍要 1 拍，这要求"tag 比较 + 数据选择"在一个周期内完成。这也是 L1 不能做得太大、相联度不能太高的原因：命中延迟直接决定 load-use 的距离和频率。

### 3.12 面试要点

1. **地址划分**：offset = log2(行大小)，组数 = 容量 / (行大小 × 路数)，index = log2(组数)，tag = 剩下的高位；每行另存 tag + valid（+ dirty + 替换位）。
2. **映射方式**：直接映射最快但冲突多；组相联是折中，L1 常用 4–8 路；全相联只用于 TLB 等小结构。直接映射 = 1 路组相联，全相联 = 1 组。
3. **替换**：
   - 真 LRU 路数多时开销大（年龄计数器 N log2 N bit / 组）；
   - 树形 PLRU 只要 N−1 bit，L1 常用；
   - 随机替换在高相联度下与 LRU 差别很小。
4. **写策略**：写回 + 写分配（主流，同一行多次写只写回一次，需要脏位）；写直达 + 写不分配（简单，内存始终最新，需要写缓冲）。哪种更省带宽取决于访问模式。
5. **3C**：
   - 强制缺失靠大行和预取；
   - 容量缺失靠大 cache 和分块；
   - 冲突缺失靠高相联度、victim cache 和 padding。
   - 数法：强制 = 第一次访问，容量 = 同容量全相联 LRU 的缺失 − 强制，冲突 = 实际 − 全相联。
6. **AMAT = 命中时间 + 缺失率 × 缺失代价**，多级递归展开；CPI 要加上"每条指令访存次数 × 缺失率 × 代价"。
7. **行大小不是越大越好**：缺失代价随行大小上升，行数随之减少。本章实测缺失率最低在 64 B，AMAT 最低在 32 B。
8. **验证 cache**：数据正确性（平坦参考内存 + 结束时全范围读回）和策略正确性（命中 / 缺失 / 写回逐个比对）都要查。LRU 写错、多余写回这类 bug 不影响数据，只有第二种检查抓得到。

### 3.13 一句话总结

Cache 用局部性把慢内存"伪装"成快内存：地址切成 tag / index / offset，相联度对付冲突缺失，替换策略决定踢谁，写策略决定什么时候写回内存。所有取舍最终都归结到 AMAT = 命中时间 + 缺失率 × 缺失代价。

---

## 4. 存储层次与 DDR

### 4.1 解决什么问题，面试怎么考

第 3 节把 cache 缺失的代价简单写成"内存延迟 8 拍"。真实的 DRAM 远没有这么规整：

- 同一个地址，读一次可能 20 ns，也可能 50 ns；
- 连续读一片内存能跑到峰值带宽的 90%，随机读可能只有 25%。

差别全在 DRAM 内部的组织方式（bank、行缓冲）和一长串时序约束上，而这些都由**内存控制器（memory controller）** 来管。

面试考法：

1. 存储层次各级的容量、延迟数量级；SRAM 和 DRAM 单元的区别，DRAM 为什么要刷新。
2. bank / row / column 是什么；行命中、行空、行冲突三种情况的延迟各是多少（用 tRCD / tCL / tRP 写出来）。
3. 带宽计算：DDR4-3200、64 bit 位宽的峰值带宽是多少；"预取 8n"是什么意思。
4. 时序参数：tRAS、tRC、tRRD、tFAW、tWR、tWTR 各约束什么；刷新的开销。
5. 地址映射怎么排、为什么要做 bank 交织 / XOR；开页和关页各适合什么负载。
6. 调度：FR-FCFS 是什么，读写为什么要成批切换。

### 4.2 存储层次

| 层次 | 典型容量 | 典型延迟 | 实现 |
|------|----------|----------|------|
| 寄存器 | 几百 B – 几 KB | 0 拍（流水线内） | 触发器 / 寄存器堆 |
| L1 cache | 32 – 64 KB / 核 | 3 – 5 拍（约 1 ns） | 6T SRAM |
| L2 cache | 256 KB – 2 MB / 核 | 10 – 15 拍 | SRAM |
| L3 / LLC | 几 MB – 几十 MB（共享） | 30 – 50 拍 | SRAM |
| DRAM 主存 | 几 GB – 几百 GB | 50 – 100 ns（上百拍） | 1T1C DRAM |
| SSD | 几百 GB – 几 TB | 10 – 100 µs | NAND 闪存 |

每往下一层，容量大约大一个数量级以上，延迟也慢一个数量级左右。层次结构成立靠的是第 3 节讲的局部性：大多数访问在上层就完成了。

### 4.3 SRAM 与 DRAM

```
 6T SRAM 单元                            1T1C DRAM 单元
      WL                                     WL
  ┌────┴────┐                                 │
  │         │                                 │
BL┤  背靠背 ├BLB                        BL ───┤ 访问管
  │  反相器 │                                 │
  └─────────┘                               ══╧══
 双稳态，上电即保持                          电容（电荷会漏）
```

| | SRAM（6T） | DRAM（1T1C） |
|---|---|---|
| 存储方式 | 两个交叉耦合反相器（双稳态） | 电容上的电荷 |
| 面积 | 6 个晶体管 | 1 个晶体管 + 1 个电容，密度高一个数量级左右 |
| 读 | 非破坏性，快 | **破坏性**：电荷分享到位线上，经灵敏放大器（sense amplifier）放大后要写回 |
| 保持 | 上电即保持 | 电荷会泄漏，**必须刷新**（DDR3/DDR4 常温下 64 ms 内刷完所有行） |
| 工艺 | 与逻辑工艺相同，可以做在 CPU 里 | 专用 DRAM 工艺（深沟槽 / 堆叠电容），一般在片外 |
| 用途 | 寄存器堆、cache、片上 SRAM | 主存 |

"读是破坏性的"直接决定了 DRAM 的访问方式：先把一整行（几 KB）读进灵敏放大器阵列（这一步叫**激活，ACT**），再从这一行里按列取数据；换行之前要把放大器里的数据写回阵列，并把位线预充到中间电平（**预充电，PRE**）。灵敏放大器阵列就是**行缓冲（row buffer）**。

### 4.4 DRAM 组织与命令

```
 内存控制器 ── 通道（channel，一组独立的命令 / 数据总线）
                └─ rank（共享总线、片选区分的一组芯片，一起提供 64 bit 数据）
                    └─ 芯片（x4 / x8 / x16）
                        └─ bank × 8（DDR3）/ 16（DDR4）/ 32（DDR5）
                            ├─ 阵列：row × column
                            └─ 行缓冲（灵敏放大器）：每个 bank 同一时刻只能开一行

 地址 = { 行号 row, bank 号, 列号 column }，由控制器的地址映射决定各占哪几位
```

**命令**（每个时钟最多一条）：

| 命令 | 作用 | 之后要等 |
|------|------|----------|
| ACT（激活） | 把某 bank 的一行读进行缓冲 | tRCD 后才能发 RD / WR |
| RD / WR（列读写） | 对已打开的行读写一个 burst | 读数据在 tCL 后出现；写数据在 tCWL 后由控制器送出 |
| PRE（预充电） | 关闭某 bank 当前的行 | tRP 后才能再 ACT |
| RDA / WRA | 带自动预充电的读写（auto-precharge） | 器件在满足 tRTP / tWR 后自己关行 |
| REF（刷新） | 刷新若干行，要求所有 bank 都已关闭 | tRFC 内不能 ACT |

**一次读的三种情况**（本章的分类和命名）：

| 情况 | bank 状态 | 命令序列 | 延迟（从命令到第一个数据） |
|------|-----------|----------|----------------------------|
| 行命中（row hit） | 开着的正好是要的行 | RD | tCL |
| 行空（row empty / closed） | bank 已关 | ACT → RD | tRCD + tCL |
| 行冲突（row conflict / miss） | 开着别的行 | PRE → ACT → RD | tRP + tRCD + tCL |

DDR3-1600 11-11-11 的三个数就是 tCL-tRCD-tRP = 11 拍，每拍 1.25 ns。三种情况分别是 13.75 / 27.5 / 41.25 ns，冲突是命中的 3 倍。

### 4.5 时序参数

本章实验用的是 DDR3-1600（tCK = 1.25 ns）的典型值：

| 参数 | 拍 | ns | 约束 |
|------|----|----|------|
| tRCD | 11 | 13.75 | ACT → 同 bank 的 RD / WR |
| tCL（CL） | 11 | 13.75 | RD → 第一个读数据 |
| tCWL（CWL） | 8 | 10 | WR → 第一个写数据 |
| tRP | 11 | 13.75 | PRE → 同 bank 的 ACT |
| tRAS | 28 | 35 | ACT → 同 bank 的 PRE（行至少开这么久，保证写回阵列） |
| tRC | 39 | 48.75 | ACT → 同 bank 的下一个 ACT，= tRAS + tRP |
| tRRD | 5 | 6.25 | ACT → 另一个 bank 的 ACT |
| tFAW | 24 | 30 | 任意 tFAW 窗口内最多 4 个 ACT（限制激活电流） |
| tCCD | 4 | 5 | 列命令之间（BL8 在双沿总线上占 4 拍） |
| tWR | 12 | 15 | 最后一个写数据 → PRE（写恢复） |
| tWTR | 6 | 7.5 | 最后一个写数据 → RD（写转读） |
| tRTP | 6 | 7.5 | RD → PRE |
| tRFC | 208 | 260 | REF → 任何 ACT（4 Gb 器件） |
| tREFI | 6240 | 7800 | 平均刷新间隔 = 64 ms / 8192 |

几个派生量：

- **刷新开销** = tRFC / tREFI = 208 / 6240 ≈ 3.3%。这段时间整个 rank 不能访问，而且刷新前还要把所有开着的行关掉。器件容量越大 tRFC 越长，所以 DDR4 / DDR5 引入了按 bank 刷新、细粒度刷新。温度超过 85 °C 时刷新间隔减半。
- **读转写**：读数据在 RD + tCL 出现、占 BL/2 拍；写数据在 WR + tCWL 出现。为了不在数据总线上撞车，还要留出总线换向（turnaround）的空拍。本章取 RD → WR ≥ tCL + BL/2 + 2 − tCWL = 9 拍。
- **写转读** = tCWL + BL/2 + tWTR = 18 拍，比读转写贵得多。所以控制器会把写攒起来成批地写（write batching / drain）。
- **激活速率上限**：tRRD 允许每 5 拍一个 ACT，tFAW 只允许每 6 拍一个（24 / 4），后者更紧。在关页模式下每个请求都要 ACT，所以带宽上限是 4 个 32 B / 24 拍 = 5.33 B/拍 = 4.27 GB/s，只有峰值的 2/3。

### 4.6 DDR：双沿、预取与带宽

**双倍数据率（DDR, Double Data Rate）**：数据在时钟的上升沿和下降沿各传一次。DDR3-1600 的时钟是 800 MHz，数据率 1600 MT/s（每秒百万次传输）。

**预取（prefetch）**：DRAM 阵列本身很慢，核心频率只有 100–266 MHz。办法是每次从阵列并行取出 n 倍宽的数据，再在 I/O 口串行地快速送出：

- DDR3 / DDR4 是 8n 预取：阵列每次给出 8 × 位宽的数据，对应 burst 长度 BL8。核心 200 MHz × 8 = 1600 MT/s。
- DDR5 是 16n（BL16）。

**峰值带宽 = 数据率 × 位宽 / 8**：

| 配置 | 计算 | 峰值 |
|------|------|------|
| DDR3-1600，64 bit（一根 DIMM） | 1600 M × 8 B | 12.8 GB/s |
| DDR4-3200，64 bit | 3200 M × 8 B | 25.6 GB/s |
| DDR5-4800，2 × 32 bit 子通道 | 4800 M × 8 B | 38.4 GB/s |
| 本章实验：DDR3-1600，32 bit | 1600 M × 4 B | 6.4 GB/s，即每拍 8 B |

一个 64 B 的 cache 行在 64 bit 的 DDR3 / DDR4 上正好是一次 BL8。本章用 32 bit 位宽，所以第 3 节的 32 B 行也正好是一次 BL8，在数据总线上占 4 拍。

| 代 | 电压 | 预取 / BL | bank | 要点 |
|----|------|-----------|------|------|
| DDR3 | 1.5 V | 8n / BL8 | 8 | |
| DDR4 | 1.2 V | 8n / BL8 | 16（4 个 bank group） | 同组 / 跨组的列命令间隔不同（tCCD_L > tCCD_S），地址映射要把相邻访问分到不同 bank group |
| DDR5 | 1.1 V | 16n / BL16 | 32（8 个 bank group） | 每根 DIMM 两个独立的 32 bit 子通道；片上 ECC；同 bank 刷新 |
| LPDDR4/5 | 更低 | 16n | 8–16 | 手机用，16 bit 窄通道，深度省电模式 |
| HBM | | | | 多层 DRAM 用 TSV 堆叠在硅中介层上，1024 bit 宽、频率低，GPU / AI 芯片用 |

**有效带宽**才是要关心的：峰值只是"数据总线每拍都忙"的理想值。ACT / PRE 的等待、读写换向、刷新都会让总线空着。下面的实验测的就是"数据总线忙的比例"和实际带宽。

### 4.7 地址映射

控制器决定物理地址的哪几位是 row / bank / column。实验里的器件是教学规模：8 bank × 256 行 × 256 列 × 4 B = 2 MB，字节地址 21 位，页（行）大小 1 KB。四种映射：

```
 MAP=0  RBC   [20:13] row  | [12:10] bank | [9:2] col        | [1:0]
 MAP=1  BRC   [20:18] bank | [17:10] row  | [9:2] col        | [1:0]
 MAP=2  XOR   与 RBC 相同，但 bank = a[12:10] ^ a[15:13] ^ a[18:16]（与行号低位异或）
 MAP=3  LINE  [20:13] row  | [12:8] col_hi | [7:5] bank | [4:2] col_lo | [1:0]
                                                   └ 每个 32 B 的 cache 行换一个 bank
```

| 映射 | 顺序访问 | 问题 |
|------|----------|------|
| RBC（row:bank:col） | 一行 1 KB 走完换下一个 bank | 相距 8 KB 整数倍（= bank 数 × 页大小）的地址落在同一 bank 的不同行 |
| BRC（bank:row:col） | 256 KB 都在同一个 bank | bank 并行几乎用不上 |
| XOR | 和 RBC 一样 | 把行号低位异或进 bank 号：同 bank 不同行的地址被打散到不同 bank |
| LINE（cache 行交织） | 相邻的 cache 行就换 bank | 适合关页（每次访问都能和别的 bank 重叠）；开页时同一行的连续访问被拆散 |

XOR 交织是很常见的做法。数组按 2 的幂对齐、多个数据流的起点相距 2 的幂，是程序里最常见的情况，而这正好是 RBC 的最坏情况。异或把这些地址映射到不同的 bank，硬件代价只是几个异或门。异或是可逆的（给定 row，bank 和原 bank 一一对应），所以不会有两个地址撞到同一个存储单元。

### 4.8 页策略与调度

**开页（open page）**：访问完不关行，赌下一次还访问同一行。

- 命中只要 tCL；
- 冲突要 tRP + tRCD + tCL，比关页的 tRCD + tCL 还慢。

**关页（close page）**：每次读写都带自动预充电（RDA / WRA）。

- 每次都是行空，延迟固定为 tRCD + tCL；
- 适合局部性差、多核交错的负载。

实际控制器多用自适应策略：根据最近的命中率或空闲时间，决定什么时候提前关行。

**调度**：

- **FCFS**：按到达顺序服务。
- **FR-FCFS（First-Ready FCFS）**：优先服务"已经能发列命令"的请求（行命中优先），其次才按年龄。这样提高了行命中率，代价是可能饿死老请求（要加年龄上限），而且读数据会乱序返回，需要按 ID 重新排序（AXI 的 ID 就是干这个的，第 12 章）。
- **bank 级并行**：一个 bank 在等 tRCD / tRP 的时候，可以给别的 bank 发 ACT / PRE。命令总线每拍一条，但大部分时间是空的，提前发命令几乎免费。
- **读写分组**：写先进写队列，攒到高水位再成批写，减少昂贵的写转读次数。读要检查写队列里有没有同地址的数据（写到读的前递）。
- **刷新**：可以推迟（DDR3/DDR4 最多推迟 8 个 tREFI），挑空闲时补上。

本章的控制器做了 bank 级并行（`LOOKAHEAD`），列命令严格按序发，数据按序返回。这样实现最简单，下面的实验也会量化它的代价。

### 4.9 RTL 解读：`lab/DRAM/dram_ctrl.v`

**接口**：

- 主机口与第 3 节 cache 的内存口同一风格：整行宽度的 valid/ready 请求。读在 `resp_valid` 时返回整行，按请求顺序返回；写被接收即完成（写数据进队列）。
- 命令口：`cmd`（NOP / ACT / RD / WR / PRE / REF）、`cmd_ba` / `cmd_row` / `cmd_col` / `cmd_ap`（自动预充电），每拍至多一条，组合输出。
- 数据口：抽象成每拍 64 bit（两个 32 bit 的 DDR 拍）。读数据由器件在 RD + tCL 起送回，写数据由控制器在 WR + tCWL 起驱动。

| 参数 | 含义 |
|------|------|
| `MAP` | 0 RBC / 1 BRC / 2 XOR / 3 LINE |
| `OPEN_PAGE` | 1 开页；0 关页（每次都带自动预充电） |
| `LOOKAHEAD` | 1 队列里更年轻的请求可以提前发 PRE / ACT；0 只服务队首 |
| `QD` | 请求队列深度（2 的幂，默认 4） |
| `tRCD` … `tREFI` | 时序参数（拍），默认 DDR3-1600 |

**结构**：

```
 req ──► 请求队列（QD 项，存拍地址 + 写数据）
            │  按年龄展开 bank / row / col（地址映射函数 decode）
            ▼
        分类：下一个未分类的请求，等前面同 bank 的请求都发完列命令后，
              看 bank 状态定为 行命中 / 行空 / 行冲突（只做一次）
            ▼
        命令选择（组合逻辑，每拍一条）：
          刷新 > 队首的 RD / WR > 从老到新第一个可以发的 PRE / ACT
            │              ▲
            ▼              │ 每个 bank：t_act / t_col / t_pre 倒计数器
        bank 状态 ─────────┘ 全局：t_rd / t_wr / t_rrd / 4 个 tFAW 槽
            ▼
        写数据：WR 时入 4 项缓冲，tCWL 拍后上总线
        读数据：收齐 BL/2 拍后整行返回
```

**分类：已分类的请求两两不同 bank。** 一个请求要等它前面所有同 bank 的请求都发出了列命令（出队）才分类。因此已分类的请求不会互相抢同一个 bank：给年轻请求提前发的 PRE，不会关掉老请求还要用的行。分类结果也和"按顺序一个一个访问"的简单模型完全相同，这正是 `dram_sim.py` 能独立复算的前提：

```verilog
always @* begin
    cls_go   = 1'b0;
    cls_kind = 2'd0;
    if (!ref_pending && ncls < qn) begin
        cls_go = 1'b1;
        for (cj = 0; cj < QD; cj = cj + 1)
            if (cj < ncls && e_ba[cj] == cba) cls_go = 1'b0;   // 前面还有同 bank 的请求
        if (!b_open[cba])                 cls_kind = 2'd1;
        else if (b_row[cba] != e_row[ci]) cls_kind = 2'd2;
    end
end
```

**命令选择**：只有队首能发列命令，所以数据按序返回；PRE / ACT 可以发给任何已分类的请求（`LOOKAHEAD=1`）：

```verilog
for (sk = 0; sk < QD; sk = sk + 1) begin
    sb = e_ba[sk];
    if (!picked && sk < ncls) begin
        if (b_open[sb] && b_row[sb] == e_row[sk]) begin
            // 行已打开：只有队首可以发列命令（数据按序返回）
            if (sk == 0 && t_col[sb] == 8'd0 &&
                (e_we[sk] ? (t_wr == 8'd0 && !wf_full) : (t_rd == 8'd0))) begin
                picked  = 1'b1;
                cmd     = e_we[sk] ? C_WR : C_RD;
                cmd_ba  = sb;
                cmd_col = e_col[sk];
                cmd_ap  = (OPEN_PAGE == 0);
            end
        end else if (sk == 0 || LOOKAHEAD != 0) begin
            if (b_open[sb]) begin
                if (t_pre[sb] == 8'd0) begin picked = 1'b1; cmd = C_PRE; cmd_ba = sb; end
            end else if (t_act[sb] == 8'd0 && t_rrd == 8'd0 && faw_free) begin
                picked = 1'b1; cmd = C_ACT; cmd_ba = sb; cmd_row = e_row[sk];
            end
        end
    end
end
```

**时序约束用倒计数器。** 每个约束对应一个计数器，"计数为 0"表示允许。发命令时把相关计数器更新为 max(剩余值, 新约束 − 1)，因为一个 bank 可能同时受几个约束（比如 tRC 和 tRP），取最紧的那个。自动预充电的关行时刻由器件决定：在 max(tRAS 剩余, tRTP) 时关行，再过 tRP 才能 ACT。控制器要自己算出这个时刻：

```verilog
C_ACT: begin
    n_act[nb] = mx(n_act[nb], K_RC);          // 同 bank 下一个 ACT：tRC
    n_col[nb] = mx(n_col[nb], K_RCD);         // 列命令：tRCD
    n_pre[nb] = mx(n_pre[nb], K_RAS);         // PRE：tRAS
end
C_PRE: n_act[nb] = mx(n_act[nb], K_RP);
C_RD: begin
    n_pre[nb] = mx(n_pre[nb], K_RTP);
    // 自动预充电在 max(tRTP, tRAS 剩余) 时发生，再过 tRP 才能 ACT
    if (cmd_ap) n_act[nb] = mx(n_act[nb], mx(t_pre[nb], T_RTP) + T_RP - 8'd1);
end
```

tFAW 用 4 个槽：每次 ACT 占一个空槽、装入 tFAW − 1，4 个槽都不为 0 时不能 ACT。

**刷新**：一个固定周期的定时器每 tREFI 置位 `ref_pending`。置位后：

1. 停止分类新请求，把已经分类的请求做完；
2. 把开着的 bank 逐个 PRE；
3. 所有 bank 关闭、满足 tRP 后发 REF。

第 1 步是调试中改出来的。最初的版本不等已分类请求做完就去刷新，这些请求在刷新后会重新打开自己的行，于是后面请求的分类与"刷新时所有行都关闭"的复算对不上。Python 复算每次刷新多数一个"行空"，追查后改成先做完再刷新。

**常见错误**（对应变异测试）：

| 错误 | 后果 |
|------|------|
| 时序参数差一拍（如 tRCD − 1） | 读到灵敏放大器还没稳定的数据。仿真里数据可能"碰巧"对，只有时序检查器能抓 |
| 不刷新 / 刷新间隔太长 | 数据在几十毫秒后才丢失，短仿真根本看不出数据错 |
| 判断行命中时只看 bank 开没开、不比较行号 | 读写到错误的行 |
| 写数据没对准 tCWL | 器件锁存错误的数据 |
| 忘了 tFAW / tRRD | 激活电流超标，只有 ACT 密集的负载才会触发 |
| 读写换向不留空 | 数据总线上读写冲突 |
| 刷新前没关所有 bank | 违反 REF 的前提 |
| 自动预充电只按 tRTP 算、忽略 tWR | 写数据还没写回阵列就关行 |

### 4.10 验证与实测

**`dram_model.v` 是器件模型 + 时序检查器**（只用于 testbench）。它用绝对时间记录每个 bank 最近一次 ACT / PRE / RD / WR 的时刻，每来一条命令就检查上一节表中的所有约束：

- ACT：bank 已关、tRP、tRC、tRRD、tFAW、tRFC；
- RD / WR：bank 已开、tRCD、tCCD、tWTR、读写换向；
- PRE：tRAS、tRTP、tWR；
- REF：所有 bank 已关、间隔不超过 9 × tREFI。

带自动预充电的读写，按器件规则算出实际关行时刻，再拿它检查后面的 ACT。写数据窗口要逐拍对准（`dq_wr_valid` 恰好在 WR + tCWL 起的 BL/2 拍为 1）。最后检查刷新次数够不够。

**testbench（`tb_dram.v`）的检查有三层**：

1. 时序检查器：每条命令都合法。
2. 读数据与平坦参考内存比对。参考内存的初值用 testbench **自己**实现的地址映射算出（整数除法 / 取模写法，与 RTL 的位切片不同），所以控制器的地址映射写错也会表现为读错数据。
3. 分类统计：testbench 把请求序列和刷新点写成文件，`dram_sim.py` 用独立的 Python 实现（第三份地址映射）按序复算行命中 / 行空 / 行冲突，要求与 RTL 完全一致。

负载：

- `seq`：顺序读；
- `rand`：全范围随机，30% 写；
- `streams`：4 个顺序读流轮流访问，起点相距 64 KB（模拟 `c[i] = a[i] + b[i]` 这类多数组循环）；
- `lat`：7 个间隔足够大的读，测单次延迟。

**延迟探针**（`bash lab/DRAM/run_sim.sh`，真实输出）：

```
===== 延迟探针（MAP=RBC，开页 / 关页）=====
  read 000000  row empty     latency 28 cyc = 35.00 ns (formula 28)
  read 000020  row hit       latency 17 cyc = 21.25 ns (formula 17)
  read 002000  row conflict  latency 39 cyc = 48.75 ns (formula 39)
  read 002020  row hit       latency 17 cyc = 21.25 ns (formula 17)
  read 000400  row empty     latency 28 cyc = 35.00 ns (formula 28)
  read 000000  row conflict  latency 39 cyc = 48.75 ns (formula 39)
  read 000040  row hit       latency 17 cyc = 21.25 ns (formula 17)
PASS
  read 000040  row empty     latency 28 cyc = 35.00 ns (formula 28)
PASS
```

从主机口请求被接收到整行返回：

| 情况 | 延迟（拍） |
|------|------------|
| 行命中 | 2 + tCL + BL/2 = 2 + 11 + 4 = 17 |
| 行空 | 再加 tRCD，= 28 |
| 行冲突 | 再加 tRP + tRCD，= 39 |

其中 2 拍是控制器开销（入队、分类各 1 拍），BL/2 是收齐整行。testbench 断言每个读的延迟都正好等于公式，并且分类与手算一致：`0x002000` 与 `0x000000` 同在 bank 0，行号差 1，所以是冲突。关页模式下第 7 个读（原来的行命中）也变成了行空。

**实验矩阵**（4 种映射 × 2 种页策略 × 3 种负载，每次 4000 个请求，峰值 6.40 GB/s；`lat` 是平均读延迟，单位拍；真实输出）：

```
===== 实验矩阵（每次 4000 个请求，峰值 6.40 GB/s，lat 为平均读延迟/拍）=====
RBC   open  LA=1 seq      hit= 96.8%  hit/empty/conf=3873/  24/ 103  ACT= 127  BW= 5.57 GB/s  lat=  32.3  PASS MATCH
RBC   close LA=1 seq      hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 0.66 GB/s  lat= 169.2  PASS MATCH
BRC   open  LA=1 seq      hit= 96.8%  hit/empty/conf=3872/   4/ 124  ACT= 128  BW= 5.19 GB/s  lat=  33.7  PASS MATCH
BRC   close LA=1 seq      hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 0.64 GB/s  lat= 175.1  PASS MATCH
XOR   open  LA=1 seq      hit= 96.8%  hit/empty/conf=3873/  24/ 103  ACT= 127  BW= 5.57 GB/s  lat=  32.4  PASS MATCH
XOR   close LA=1 seq      hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 0.66 GB/s  lat= 169.3  PASS MATCH
LINE  open  LA=1 seq      hit= 96.5%  hit/empty/conf=3859/  24/ 117  ACT= 141  BW= 6.08 GB/s  lat=  30.8  PASS MATCH
LINE  close LA=1 seq      hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 4.14 GB/s  lat=  38.7  PASS MATCH
RBC   open  LA=1 rand     hit=  0.2%  hit/empty/conf=   9/  80/3911  ACT=3991  BW= 1.65 GB/s  lat=  75.8  PASS MATCH
RBC   close LA=1 rand     hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 1.68 GB/s  lat=  74.8  PASS MATCH
...
LINE  close LA=1 rand     hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 1.68 GB/s  lat=  74.9  PASS MATCH
RBC   open  LA=1 streams  hit=  0.0%  hit/empty/conf=   0/  57/3943  ACT=4000  BW= 0.64 GB/s  lat= 173.7  PASS MATCH
RBC   close LA=1 streams  hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 0.64 GB/s  lat= 173.7  PASS MATCH
BRC   open  LA=1 streams  hit=  0.0%  hit/empty/conf=   0/  26/3974  ACT=4000  BW= 0.64 GB/s  lat= 175.1  PASS MATCH
BRC   close LA=1 streams  hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 0.64 GB/s  lat= 175.1  PASS MATCH
XOR   open  LA=1 streams  hit= 96.6%  hit/empty/conf=3864/  24/ 112  ACT= 136  BW= 5.99 GB/s  lat=  31.1  PASS MATCH
XOR   close LA=1 streams  hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 2.50 GB/s  lat=  55.0  PASS MATCH
LINE  open  LA=1 streams  hit=  0.0%  hit/empty/conf=   0/ 152/3848  ACT=4000  BW= 0.90 GB/s  lat= 127.8  PASS MATCH
LINE  close LA=1 streams  hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 0.90 GB/s  lat= 127.8  PASS MATCH
```

有效带宽（GB/s）汇总：

| 映射 | seq 开页 | seq 关页 | rand 开页 | rand 关页 | streams 开页 | streams 关页 |
|------|----------|----------|-----------|-----------|--------------|--------------|
| RBC | 5.57 | 0.66 | 1.65 | 1.68 | 0.64 | 0.64 |
| BRC | 5.19 | 0.64 | 1.64 | 1.68 | 0.64 | 0.64 |
| XOR | 5.57 | 0.66 | 1.65 | 1.68 | **5.99** | 2.50 |
| LINE | **6.08** | 4.14 | 1.65 | 1.68 | 0.90 | 0.90 |

24 次运行全部通过时序检查和数据比对，分类计数与 Python 复算完全一致。读这张表：

1. **顺序访问 + 开页**：每个 1 KB 的行装 32 个 cache 行，命中率 31/32 ≈ 96.9%，带宽 5.57 GB/s，达到峰值的 87%。
   - BRC 稍差（5.19）：顺序访问一直在同一个 bank 里换行，每次换行的 PRE + ACT 都没法和别的 bank 重叠。
   - RBC 换行时换的是下一个 bank，这个 bank 的 ACT 可以提前发。
   - LINE 最好（6.08，95%）：队列里的 4 个请求总是分在 4 个 bank，换行开销被完全藏住。
2. **顺序访问 + 关页 + RBC**：0.66 GB/s，只有峰值的 10%。连续 32 个请求都在同一个 bank，每个都要 ACT，同 bank 的 ACT 间隔至少 tRC = 39 拍：32 B / 39 拍 = 0.82 B/拍 = 0.66 GB/s，与实测相同。
   - 关页必须配合 bank 交织：LINE 映射下关页是 4.14 GB/s，是 4.5 节算出的 tFAW 上限 4.27 GB/s 的 97%。
3. **随机访问**：2 MB 范围、8 bank × 256 行，两个请求碰到同一行的概率约 1/256，所以开页的命中率只有 0.2%，几乎全是冲突。
   - 关页反而略好（1.68 vs 1.65），因为预充电已经提前做掉了。
   - 这就是"局部性差的负载用关页"的依据；服务器多核交错访问，往往就是这种情况。
4. **4 个数据流起点相距 64 KB**：RBC、BRC、LINE 三种映射下，4 个流在同一时刻落在同一个 bank 的不同行，互相把对方的行踢掉。命中率 0%，带宽 0.64 GB/s。
   - XOR 映射把行号低位异或进 bank 号，4 个流分到 4 个 bank：命中率 96.6%、5.99 GB/s，提升 9.4 倍。
   - 这是"XOR bank 交织"在面试里最好的例子：几个异或门换来一个数量级的带宽。
5. **延迟随带宽恶化**：随机负载的平均读延迟是 76 拍（95 ns），远高于单次冲突的 39 拍，多出来的是排队时间。

**前瞻（LOOKAHEAD）与队列深度**（真实输出）：

```
===== 前瞻：younger 请求能否提前 PRE/ACT =====
RBC   open  LA=0 rand     hit=  0.2%  hit/empty/conf=   9/ 136/3855  ACT=3991  BW= 0.99 GB/s  lat= 117.8  PASS MATCH
RBC   open  LA=1 rand     hit=  0.2%  hit/empty/conf=   9/  80/3911  ACT=3991  BW= 1.65 GB/s  lat=  75.8  PASS MATCH
LINE  close LA=0 seq      hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 2.06 GB/s  lat=  63.6  PASS MATCH
LINE  close LA=1 seq      hit=  0.0%  hit/empty/conf=   0/4000/   0  ACT=4000  BW= 4.14 GB/s  lat=  38.7  PASS MATCH
XOR   open  LA=0 streams  hit= 96.5%  hit/empty/conf=3862/  28/ 110  ACT= 138  BW= 5.38 GB/s  lat=  33.0  PASS MATCH
XOR   open  LA=1 streams  hit= 96.6%  hit/empty/conf=3864/  24/ 112  ACT= 136  BW= 5.99 GB/s  lat=  31.1  PASS MATCH
===== 队列深度：按序分类时，加深队列只加延迟、不加带宽 =====
QD=2  RBC   open  LA=1 rand     hit=  0.2%  hit/empty/conf=   9/  96/3895  ACT=3991  BW= 1.41 GB/s  lat=  50.4  PASS MATCH
QD=4  RBC   open  LA=1 rand     hit=  0.2%  hit/empty/conf=   9/  80/3911  ACT=3991  BW= 1.65 GB/s  lat=  75.8  PASS MATCH
QD=16 RBC   open  LA=1 rand     hit=  0.2%  hit/empty/conf=   9/  80/3911  ACT=3991  BW= 1.65 GB/s  lat= 259.4  PASS MATCH
```

- **bank 级并行的价值**：只服务队首时（`LA=0`），随机负载 0.99 GB/s，行交织关页 2.06 GB/s。让年轻请求提前 PRE / ACT 后分别提升到 1.65 和 4.14 GB/s，命令总线上本来空着的时间被利用起来。
  - `LA=0` 时行空更多（136 vs 80），因为跑得慢、刷新次数多，每次刷新都把所有行关掉。
- **队列从 4 项加到 16 项，带宽一点没涨，延迟从 76 拍涨到 259 拍。** 瓶颈不在队列深度，而在"按序分类"：只要队列里出现一个和前面请求同 bank 的请求，它和它后面的所有请求都得等着。8 个 bank 里随机抽，平均抽到第 4 个左右就会重复（生日问题），也就是平均只有约 3 个连续请求能分到不同的 bank，`QD=4` 已经够用，`QD=2` 不够。
  - 加深队列只是让更多请求排队：吞吐不变时，延迟 ≈ 队列长度 / 吞吐（Little 定律）。
  - 要真正利用深队列，就得允许乱序：FR-FCFS 越过被堵住的请求，去服务别的 bank、命中的行，数据乱序返回后再按 ID 重排。这是真实控制器复杂度的主要来源。

**变异测试**（`bash lab/DRAM/mutation.sh`，每个变异跑 3 种配置，真实输出）：

```
===== M1: tRCD 少一拍 =====
  MAP=0 OPEN=1 rand  ERROR @cycle 14: 违反 RD/WR tRCD（命令 2，bank 1） FAIL (1380 errors)
  MAP=3 OPEN=0 seq   ERROR @cycle 14: 违反 RD/WR tRCD（命令 2，bank 0） FAIL (4000 errors)
  MAP=0 OPEN=0 rand  ERROR @cycle 14: 违反 RD/WR tRCD（命令 2，bank 1） FAIL (1301 errors)
  => 抓到
===== M2: 不刷新 =====
  MAP=0 OPEN=1 rand  ERROR: 60344 个周期里只刷新了 0 次（至少需要 8 次） FAIL (2 errors)
  MAP=3 OPEN=0 seq   ERROR: 24061 个周期里只刷新了 0 次（至少需要 2 次） FAIL (1 errors)
  MAP=0 OPEN=0 rand  ERROR: 59065 个周期里只刷新了 0 次（至少需要 8 次） FAIL (2 errors)
  => 抓到
===== M3: 行命中不比较行号 =====
  MAP=0 OPEN=1 rand  ERROR @cycle 44: 读数据错 FAIL (2693 errors)
  MAP=3 OPEN=0 seq   PASS
  MAP=0 OPEN=0 rand  PASS
  => 抓到
===== M4: 写数据晚一拍 =====
  MAP=0 OPEN=1 rand  ERROR @cycle 138: 写数据时序错（dq_wr_valid=0，应为 1） FAIL (2071 errors)
  MAP=3 OPEN=0 seq   PASS
  MAP=0 OPEN=0 rand  ERROR @cycle 138: 写数据时序错（dq_wr_valid=0，应为 1） FAIL (2033 errors)
  => 抓到
===== M5: 不检查 tFAW =====
  MAP=0 OPEN=1 rand  ERROR @cycle 6504: 违反 ACT tFAW（命令 1，bank 1） FAIL (4 errors)
  MAP=3 OPEN=0 seq   ERROR @cycle 24: 违反 ACT tFAW（命令 1，bank 4） FAIL (3984 errors)
  MAP=0 OPEN=0 rand  ERROR @cycle 5997: 违反 ACT tFAW（命令 1，bank 2） FAIL (19 errors)
  => 抓到
===== M6: 读后写不等换向 =====
  MAP=0 OPEN=1 rand  ERROR @cycle 234: 违反 WR rd->wr（命令 3，bank 6） FAIL (2360 errors)
  MAP=3 OPEN=0 seq   PASS
  MAP=0 OPEN=0 rand  ERROR @cycle 234: 违反 WR rd->wr（命令 3，bank 6） FAIL (2463 errors)
  => 抓到
===== M7: 刷新前不预充电 =====
  MAP=0 OPEN=1 rand  ERROR @cycle 6259: 违反 REF open bank（命令 5，bank 0） FAIL (1 errors)
  MAP=3 OPEN=0 seq   PASS
  MAP=0 OPEN=0 rand  PASS
  => 抓到
===== M8: 自动预充电的写忽略 tWR =====
  MAP=0 OPEN=1 rand  PASS
  MAP=3 OPEN=0 seq   PASS
  MAP=0 OPEN=0 rand  ERROR @cycle 256: 违反 ACT tRP（命令 1，bank 6） FAIL (636 errors)
  => 抓到
```

8 个变异全部抓到。值得注意的是，**每个变异只在特定的配置下才暴露**：

- **M2（不刷新）的数据完全正确。** 仿真模型不会真的丢电荷，真实芯片要几十毫秒后才出错，只有"刷新次数够不够"的检查能抓到。
- **M3（不比较行号）只在开页下暴露。** 关页时每次访问前 bank 都是关的，这条判断从来走不到"开着别的行"的分支。
- **M7（刷新前不预充电）也只在开页下暴露**，原因相同：关页时刷新那一刻本来就没有开着的行。
- **M8（写的自动预充电忽略 tWR）只在关页且有写的负载下暴露。** 开页根本不用自动预充电，顺序负载没有写。
- **M5（不检查 tFAW）**：在随机负载里 4000 个请求只违反 4 次，而在行交织 + 关页的顺序流里几乎每个 ACT 都违反（3984 次）。时序约束只在把它"顶满"的负载下才有意义，验证要专门构造这样的负载。

所以 DRAM 控制器的验证不能只跑一种配置、一种负载：配置矩阵和负载矩阵都要覆盖。

### 4.11 变体与扩展

| 技术 | 解决的问题 | 要点 |
|------|------------|------|
| FR-FCFS 乱序调度 | 本章按序分类、按序发列命令，深队列没用 | 行命中优先、年龄兜底防饿死；读数据乱序返回，按事务 ID 重排 |
| 读写队列分离 + 写批量 | 写转读代价大（18 拍） | 写队列攒到高水位再连续写；读检查写队列（前递） |
| bank group（DDR4 / DDR5） | 同组 bank 共享部分 I/O 通路 | 同组列命令间隔 tCCD_L 大于跨组的 tCCD_S；映射要把相邻访问分到不同组 |
| 多 rank / 多通道 | 一个 rank 的 bank 并行不够 | rank 之间切换要留 tRTRS；通道之间完全独立，地址映射在通道间交织 |
| 按 bank 刷新 / 刷新调度 | 全 bank 刷新要停整个 rank 260 ns | 只锁住一个 bank；利用最多 8 个 tREFI 的推迟额度，挑空闲时刷新 |
| 自适应页策略 | 开页、关页各有适合的负载 | 按 bank 统计命中率，或空闲一定时间后提前关行 |
| 低功耗 | DRAM 静态功耗 | power-down（关输入缓冲）、self-refresh（器件自己刷新，控制器可以关时钟） |
| PHY 与训练 | 高速信号的时序偏差 | DFI 接口连控制器和 PHY；上电时做写均衡（write leveling）、读 DQS 门控、眼图中心训练 |
| ECC | 软错误、弱单元 | SECDED（64 bit + 8 bit），DDR5 还有片上 ECC |
| Rowhammer 防护 | 反复激活一行会翻转相邻行的位 | TRR（目标行刷新）、限制同一行的激活次数 |

**接到第 3 节的 cache 上**：本控制器的主机口就是 cache 内存口的形状（整行请求、整行返回）。cache 缺失的代价从此不再是常数，而是 17–39 拍外加排队。写回 cache 的脏行写回，正好走控制器的写队列。

### 4.12 面试要点

1. **SRAM vs DRAM**：
   - 6T 双稳态 vs 1T1C 电容；
   - DRAM 密度高一个数量级，但读是破坏性的（要写回），电荷会漏（要刷新，64 ms 刷完，tREFI = 7.8 µs）。
2. **三种访问情况**：
   - 行命中 tCL；
   - 行空 tRCD + tCL；
   - 行冲突 tRP + tRCD + tCL；
   - DDR3-1600 11-11-11 分别是 13.75 / 27.5 / 41.25 ns。
3. **关键时序**：
   - tRC = tRAS + tRP（同 bank 两次 ACT）；
   - tRRD / tFAW 限制激活速率（电流）；
   - tWR 是写恢复，tWTR 是写转读，读写换向要留空拍；
   - 刷新开销 tRFC / tREFI ≈ 3%。
4. **带宽**：
   - 峰值 = 数据率 × 位宽 / 8，DDR4-3200 × 64 bit = 25.6 GB/s；
   - 8n 预取 = 阵列一次给出 8 倍位宽的数据，对应 BL8；
   - 64 B cache 行正好是一次 BL8 × 64 bit。
5. **地址映射**：
   - 列放低位（顺序访问留在同一行），bank 放在列之上（换行时换 bank）；
   - 行号低位异或进 bank 号，打散 2 的幂间距的访问。本章 4 个数据流的实验：0.64 → 5.99 GB/s。
6. **页策略**：
   - 局部性好用开页（命中 tCL，本章顺序访问 87% 峰值）；
   - 局部性差用关页（固定 tRCD + tCL，省掉冲突时的 tRP）；
   - 关页必须配合 bank 交织，否则被 tRC 卡死（本章 0.66 GB/s）。
7. **调度**：
   - bank 级并行（给别的 bank 提前发 PRE / ACT）几乎免费，本章随机负载提升 67%；
   - FR-FCFS 行命中优先、需要防饿死和乱序返回；
   - 读写分组减少换向；
   - 按序调度时加深队列只加延迟、不加带宽（Little 定律）。
8. **验证 DRAM 控制器**：
   - 时序检查器（每条命令查所有约束）比数据比对更重要：差一拍的时序错误在仿真里往往数据还是对的；
   - 不刷新这种 bug 只有计数检查能抓；
   - 不同的 bug 只在特定的配置 + 负载下暴露，要跑矩阵。

### 4.13 一句话总结

DRAM 是"按行打开、按列读写"的器件：行缓冲命中 tCL，冲突要再加 tRP + tRCD。控制器的全部工作就是在几十个时序约束之下，用地址映射和调度把访问尽量变成行命中、尽量分散到不同 bank 并行起来，并且不忘记刷新。

## 5. 中断与 DMA

### 5.1 解决什么问题，面试怎么考

到第 4 节为止，CPU 只会按程序顺序一条条执行。真实的芯片还要应付两类"计划外"的事：

- 指令自己出了问题：非法指令、访问了不存在的地址、地址不对齐、主动 `ecall` 请求系统服务；
- 外面发生了事情：定时器到点、UART 发完了、DMA 搬完了。

前者叫**异常（exception）**，后者叫**中断（interrupt）**。RISC-V 把两者统称为 **trap**：都是"暂停当前程序、跳到处理程序、处理完再回来"。
另一方面，大块数据搬运如果让 CPU 一个字一个字地 `lw` / `sw`，CPU 就干不了别的。**DMA（Direct Memory Access）** 是一个能自己发起总线访问的硬件搬运工，搬完用中断通知 CPU。

面试考法：

1. 异常和中断的区别；什么叫**精确异常（precise exception）**，为什么需要。
2. RISC-V 进入 trap 时硬件做了哪些事（`mepc` / `mcause` / `mtval` / `mstatus`）、`mret` 做了哪些事；`ecall` 返回时为什么要软件把 `mepc` 加 4。
3. 在五级流水线里，中断在哪一级接收、`mepc` 填哪条指令的 PC、被打断时流水线里其它指令怎么办；中断延迟由什么决定。
4. CLINT 和 PLIC 分别管什么；PLIC 的 claim / complete 流程，处理程序里为什么要先清外设再 complete；电平触发和边沿触发。
5. DMA 怎么编程；描述符链（scatter-gather）是什么；DMA 与 cache 的一致性问题怎么处理。

### 5.2 基本概念

| | 异常（同步） | 中断（异步） |
|---|---|---|
| 来源 | 某一条指令自己 | 外部事件，与正在执行的指令无关 |
| 可重现 | 同样的输入，每次都在同一条指令上发生 | 何时到来取决于时序 |
| `mepc` | 出错的那条指令（处理完可以重新执行它，或跳过它） | 被打断时**下一条该执行**的指令 |
| 例子 | 非法指令、非对齐、访问错误、`ecall`、`ebreak` | 定时器、软件中断（核间）、外设 |

**精确**的含义：进入 trap 时，`mepc` 之前的指令全部完成，`mepc` 及之后的指令没有留下任何痕迹（没写寄存器、没写内存、没改 CSR）。
有了精确性，处理程序才能修好问题后从 `mepc` 原样继续，例如缺页之后补上页再重新执行那条 load。
非精确的 trap 只能用来报错停机。

RISC-V 有三个特权级：机器模式 M、监管模式 S、用户模式 U。本章只实现 M 模式（微控制器的典型配置），所有 trap 都由 M 模式处理。S 模式下的那套 CSR（`sepc` / `scause` …）和委托（`medeleg` / `mideleg`）结构完全相同，只是多了一层。

### 5.3 Zicsr 与机器模式 CSR

CSR（Control and Status Register）有独立的 12 bit 地址空间，用 Zicsr 扩展的 6 条指令原子地"读旧值、写新值"：

| 指令 | 语义（`t` = CSR 旧值） | 说明 |
|------|-------------------------|------|
| `csrrw rd, csr, rs1` | `rd ← t；csr ← rs1` | `rd = x0` 时不读（对有读副作用的 CSR 有意义） |
| `csrrs rd, csr, rs1` | `rd ← t；csr ← t \| rs1` | `rs1 = x0` 时不写，所以读只读 CSR 是合法的 |
| `csrrc rd, csr, rs1` | `rd ← t；csr ← t & ~rs1` | 同上 |
| `csrrwi / csrrsi / csrrci` | 同上，操作数是 5 bit 零扩展立即数 | 立即数为 0 时 `csrrsi / csrrci` 不写 |

伪指令：`csrr rd, csr` = `csrrs rd, csr, x0`；`csrw csr, rs` = `csrrw x0, csr, rs`；`csrs` / `csrc` / `csrsi` / `csrci` 同理。
CSR 地址的 [11:10] = `11` 表示只读，写只读 CSR、访问不存在的 CSR 都是非法指令。

本章实现的 CSR：

| CSR | 地址 | 内容 |
|-----|------|------|
| `mstatus` | 0x300 | bit 3 MIE（全局中断使能）、bit 7 MPIE（进 trap 前的 MIE）、[12:11] MPP（进 trap 前的特权级，本章恒为 `11` = M） |
| `misa` | 0x301 | `0x4000_0100`：MXL = 1（32 位），只有 I 扩展 |
| `mie` | 0x304 | 各中断源的使能：bit 3 MSIE、bit 7 MTIE、bit 11 MEIE |
| `mip` | 0x344 | 各中断源的待处理状态（只读，直接反映 CLINT / PLIC 的中断线） |
| `mtvec` | 0x305 | [31:2] BASE、[1:0] MODE：0 = 直接（全部进 BASE），1 = 向量（中断 n 进 BASE + 4n，异常仍进 BASE） |
| `mscratch` | 0x340 | 给处理程序用的暂存（常放"处理程序专用栈"的指针） |
| `mepc` | 0x341 | trap 时的 PC，[1:0] 恒为 0 |
| `mcause` | 0x342 | bit 31 = 1 表示中断，低位是原因编号 |
| `mtval` | 0x343 | 附加信息：出错的地址或指令本身 |
| `mcycle[h]` / `minstret[h]` | 0xB00 / 0xB02（高 32 位 0xB80 / 0xB82） | 64 位周期数、退休指令数 |
| `mvendorid` / `marchid` / `mimpid` / `mhartid` | 0xF11–0xF14 | 只读，本章都是 0 |

`mcause` 编码（本章用到的）：

| 类型 | 编号 | 含义 | `mtval` |
|------|------|------|---------|
| 异常 | 0 | 取指地址非对齐（本章：跳转目标不是 4 的倍数） | 目标地址 |
| 异常 | 2 | 非法指令 | 指令本身 |
| 异常 | 3 | 断点 `ebreak` | 它自己的 PC |
| 异常 | 4 / 6 | load / store 地址非对齐 | 访存地址 |
| 异常 | 5 / 7 | load / store 访问错误（总线返回 err） | 访存地址 |
| 异常 | 11 | M 模式 `ecall` | 0 |
| 中断 | 3 | 机器软件中断 MSI（CLINT 的 `msip`，多核里用于核间中断） | 0 |
| 中断 | 7 | 机器定时器中断 MTI（CLINT 的 `mtime ≥ mtimecmp`） | 0 |
| 中断 | 11 | 机器外部中断 MEI（来自 PLIC） | 0 |

（编号 1 是取指访问错误，8 / 9 是 U / S 模式的 `ecall`，12 / 13 / 15 是缺页，本章不涉及。）

### 5.4 trap 的硬件流程与软件处理程序

**进入 trap**（一拍之内由硬件完成）：

```
mepc    ← 出错指令的 PC（异常）或下一条该执行的 PC（中断）
mcause  ← {是否中断, 编号}
mtval   ← 地址 / 指令 / 0
MPIE    ← MIE；MIE ← 0           关中断，处理程序不会被同级中断立即再打断
MPP     ← 当前特权级（本章恒为 M）
pc      ← mtvec.BASE（向量模式下的中断：BASE + 4 × 编号）
```

**`mret`**：`MIE ← MPIE；MPIE ← 1；pc ← mepc`。

两点容易错：

- 硬件**不会**自动把 `mepc` 加 4。`ecall`、`ebreak` 和"想跳过的出错指令"都要软件 `mepc += 4`，否则 `mret` 之后又执行同一条指令，死循环。中断不需要加，因为 `mepc` 本来就是没执行的那条。
- 中断响应的条件是 `mstatus.MIE & mie[i] & mip[i]`，三者缺一不可。多个同时满足时按固定优先级：**MEI > MSI > MTI**（规范规定，外部中断最紧急，定时器最不紧急）。

一个典型的处理程序（本章三个测试程序都是这个结构）：

```asm
trap_entry:
    addi sp, sp, -16        # 1 保存现场：处理程序会用到的寄存器都要保存
    sw   t0, 0(sp)
    ...
    csrr t0, mcause         # 2 分发：最高位 = 1 是中断
    bltz t0, is_irq
    csrr t1, mepc           # 3a 异常：处理，然后跳过出错的指令
    addi t1, t1, 4
    csrw mepc, t1
    j    restore
is_irq:                     # 3b 中断：找到来源、清掉来源
    ...
restore:
    lw   t0, 0(sp)          # 4 恢复现场
    ...
    addi sp, sp, 16
    mret
```

如果被打断的程序的 `sp` 不可信（比如用户态），处理程序第一条用 `csrrw sp, mscratch, sp` 换到专用栈。
要支持中断嵌套，需要先把 `mepc` / `mcause` / `mstatus` 存到栈上，再打开 MIE。

**`wfi`**（Wait For Interrupt）：停下来等，直到存在"待处理且被 `mie` 允许"的中断。注意它**不看 `mstatus.MIE`**：MIE = 0 时 `wfi` 照样被唤醒，只是不进处理程序、继续往下执行。规范也允许把 `wfi` 实现成 `nop`，软件必须能容忍。
这决定了等中断的正确写法：

```asm
wait:
    csrci mstatus, 8        # 关 MIE
    lw    t1, flag          # 查标志（处理程序会置位）
    bnez  t1, got
    wfi                     # 中断如果在"查完标志之后"已经到了，wfi 立即返回
    csrsi mstatus, 8        # 开 MIE：待处理的中断在这里被响应
    j     wait
got:
```

如果 MIE = 1 时直接"查标志 → `wfi`"，中断恰好落在两者之间：处理程序先跑完、置了标志，`wfi` 却会一直睡到下一个中断（**丢失唤醒，lost wake-up**）。

### 5.5 在流水线里精确地接收 trap

第 2 节的流水线里同时有 5 条指令在飞。要做到精确，关键是选定**唯一的提交点**：本章所有 CSR 修改、所有 trap 进入都只发生在 **WB 级**，而且此时流水线里只有它一条有效指令。具体有四条规则。

**规则 1：串行化指令（CSR、`mret`、`wfi`、`ecall`、`ebreak`，以及 EX 级检测到异常的指令）**

它们进入 EX 时，杀掉所有更年轻的指令（IF、ID 里的）并停止取指，自己继续走到 WB 生效，再从正确的地址重新取指：

```
周期        1    2    3    4    5    6    7    8
csrw        IF   ID   EX   MEM  WB
后一条           IF   ID   ×                          被杀
后两条                IF   ×                          被杀
（停止取指）                    ·    ·
WB 重定向后                               IF   ID   EX
```

代价是每条串行化指令约多 4 拍。换来的是 CSR 的读写不需要任何前递，也不会出现"后面的指令用了旧的 `mstatus` / `mtvec`"这类问题。CSR 指令很少，这个代价可以接受。

**规则 2：中断在 EX 级采样**

中断线是异步的，任何时刻都可能变高。本章在 EX 级判断 `MIE & mie & mip`：成立时，EX 里那条指令被标记为"被中断"，不执行（不访存、不写回），连同采样到的原因一起往下走，到 WB 时以它的 PC 作为 `mepc` 进入 trap。比它老的指令（在 MEM、WB 里）正常完成，比它年轻的被杀掉。

为什么是 EX 而不是 WB？在 WB 采样的话，要判断"这条指令能不能被打断"，还要处理它已经访问过存储器等问题。在 EX 采样，被标记的指令还没有任何副作用。
代价是中断延迟至少 2 拍（EX → MEM → WB）。实测（`irq_test`）：从"中断可以被响应"到 trap 生效，最少 2 拍、平均 2.6 拍、最多 4 拍；访存有随机等待时最多 6 拍，因为 MEM 级在等存储器，整条流水线都停着。

**规则 3：访问错误在 MEM 级才知道**

总线 `err` 和 `ready` 同拍返回，那时指令已经在 MEM 了，EX 里可能已经有一条更年轻的指令，甚至带着中断标记。所以 MEM 发现 `err` 时杀掉 EX 及更年轻的指令，本条带着异常走到 WB。被杀的中断标记不要紧：中断线还是高的，重新取指后会被再次采样。

**规则 4：访存等待时整条流水线停住**

数据口有 `ready` 之后，MEM 级访存没完成时 IF–MEM 全部冻结，WB 照常排空（插气泡）。这里在调试中遇到了一个真实的 bug：EX 级的指令通过前递拿到操作数，而前递源在 WB 里；WB 排空后前递源就不在了，等冻结解除时 EX 读到的是寄存器堆里的旧值。修法是冻结期间每拍把前递后的值写回 ID/EX 寄存器。这正是变异 M1，它只在随机等待周期下才暴露。

### 5.6 中断控制器：CLINT 与 PLIC

```
                ┌─────────── CLINT ───────────┐
                │ msip                        ├────────► MSIP ─┐
                │ mtime >= mtimecmp           ├────────► MTIP ─┤
                └─────────────────────────────┘                │
                                                               ├─► 核
 外设 1 ──┐                                                    │
 外设 2 ──┼─► ┌─────────── PLIC ────────────┐                  │
          │   │ 网关 → pending → 优先级门限 ├────────► MEIP ───┘
  …    ───┘   │           ▲                 │
              │           └── claim/complete│
              └─────────────────────────────┘
```

**CLINT（Core-Local Interruptor）**：每个核私有的定时器和软件中断。

| 偏移 | 寄存器 | 说明 |
|------|--------|------|
| 0x0000 | `msip` | bit 0 写 1 触发软件中断，写 0 清除；多核里一个核写另一个核的 `msip` 就是核间中断（IPI） |
| 0x4000 / 0x4004 | `mtimecmp` 低 / 高 32 位 | `mtime ≥ mtimecmp` 时 MTIP 为高（电平）；复位为全 1 |
| 0xBFF8 / 0xBFFC | `mtime` 低 / 高 32 位 | 自由运行的 64 位计数器，频率固定（与 CPU 频率无关，本章参数 `DIV` 分频） |

MTIP 是电平：处理程序必须把 `mtimecmp` 改到将来，中断才会撤销。
在 RV32 上 64 位的 `mtimecmp` 要分两次写，中间可能出现一个"比现在小"的临时值，造成误触发。规范推荐的顺序是：先把低 32 位写成全 1，再写高 32 位，最后写低 32 位。

**PLIC（Platform-Level Interrupt Controller）**：把很多外设中断汇总成每个核的一根 MEIP。

| 偏移 | 寄存器 | 说明 |
|------|--------|------|
| 0x000000 + 4i | `priority[i]` | 0 = 永不触发；越大越优先 |
| 0x001000 | `pending` | bit i = 源 i 待处理（只读） |
| 0x002000 | `enable` | bit i = 允许源 i（每个核 / 每个特权级上下文一组） |
| 0x200000 | `threshold` | 只有 `priority > threshold` 的源能打断核 |
| 0x200004 | `claim / complete` | 读 = **claim**：返回最高优先级的待处理源号（同优先级取小号），并清它的 pending；写 = **complete**：服务完毕 |

处理一次外部中断的流程：

1. 核进入 trap，`mcause` = MEI；
2. 读 claim，得到源号 n（读到 0 说明已被别的核 claim 走了，直接返回）；
3. 服务外设 n，并**让外设撤销中断**（读它的数据寄存器、写它的状态寄存器）；
4. 把 n 写回 complete；
5. `mret`。

**网关（gateway）**负责把外设的中断信号变成 pending 位，并保证一个源在 claim 之后、complete 之前不会再次置 pending（本章用 `inflight` 位实现）。complete 之后如果源还是高，会立即再次置 pending。
所以第 3 步和第 4 步的顺序不能反：先 complete、后清外设的话，网关会看到源还是高，又产生一次多余的中断。

**电平触发 vs 边沿触发**：

| | 电平（level） | 边沿（edge） |
|---|---|---|
| 外设 | 有事就一直拉高，直到软件清掉 | 有事打一个脉冲 |
| 优点 | 不会丢：软件不清，中断就一直在；多个外设可以"线或"共享一根线 | 外设简单，不需要"清中断"寄存器 |
| 缺点 | 软件忘了清就会无限重入 | 服务期间再来的边沿要靠网关计数，否则会丢；脉冲跨时钟域要展宽 |

本章的 CLINT、PLIC 网关、DMA、UART 都是电平。

### 5.7 DMA

CPU 自己拷贝一个字至少要 `lw` + `sw` + 地址自增 + 循环判断，而且拷贝期间什么别的也干不了。DMA 是一个**总线主机（bus master）**：CPU 把源地址、目的地址、长度写进它的寄存器，它自己去总线上读写，完成后用中断通知 CPU。

本章 DMA 的寄存器：

| 偏移 | 寄存器 | 说明 |
|------|--------|------|
| 0x00 | `CTRL` | bit 0 START（写 1 启动）、bit 1 IE（完成 / 出错时中断）、bit 2 SG（描述符模式） |
| 0x04 | `STATUS` | bit 0 BUSY（只读）、bit 1 DONE、bit 2 ERR（写 1 清，W1C） |
| 0x08 / 0x0C / 0x10 | `SRC` / `DST` / `LEN` | 单段模式的参数（LEN 以字节计，4 的倍数） |
| 0x14 | `DESC` | 描述符模式下第一个描述符的地址 |
| 0x18 / 0x1C | `COUNT` / `ERRADDR` | 本次搬了多少字 / 出错的地址（只读） |

**描述符链（scatter-gather）**：要搬的数据在内存里不连续（比如网络包分散在几个缓冲区里）时，软件在内存里摆一串描述符，每个描述符 4 个字：`{src, dst, len, next}`，`next = 0` 表示最后一个。DMA 自己读描述符、搬一段、再读下一个，CPU 只需要启动一次。

```
 状态机：
 IDLE ─START─► DESC（读 4 个字的描述符）─► CHECK（对齐检查）─► RD ⇄ WR（每字一读一写）
   ▲                ▲                                            │
   │                └──────────── NEXT（next ≠ 0）◄──────────────┘ len 用完
   └── 完成：DONE = 1；出错（总线 err、地址 / 长度不对齐）：ERR = 1、记下 ERRADDR，已搬的字保留
```

**DMA 与 cache 的一致性**：这是面试最常问的点。DMA 直接访问内存，绕过 CPU 的 cache，于是：

- **DMA 读内存之前**（CPU 准备好的数据要发给外设）：源缓冲区的新数据可能还在 CPU 的写回 cache 里（脏行），内存里是旧的。软件要先 **clean**（把脏行写回内存）。
- **DMA 写内存之后**（外设收到的数据）：CPU 的 cache 里可能还有目的缓冲区的旧副本，CPU 会读到旧数据。软件要 **invalidate** 这些行。搬运期间 CPU 也不能碰目的缓冲区，否则可能把旧行重新取进 cache，或者写回一个脏行覆盖 DMA 的数据。
- 缓冲区的起止地址要按 cache 行对齐，否则行的另一半属于别的变量，invalidate 会丢掉别人的数据。
- 硬件方案：**IO 一致性**。DMA 通过一个能窥探（snoop）CPU cache 的端口访问内存（ARM 的 ACE-Lite、RISC-V 平台的一致性互联），软件就不用 clean / invalidate 了，代价是互联更复杂。

本章 SoC（第 6 节）的数据通路上没有 cache，所以没有这个问题。第 3 节的 cache 如果放到核和总线之间，DMA 驱动就必须加上 clean / invalidate。

### 5.8 RTL 解读

`rv32i_trap.v` 与基础核共用译码器，也由 ALU 计算 JAL / branch / JALR 的实际目标，分支条件由独立比较器判断。JALR 清 bit 0 后，Trap 核还检查已决定跳转的目标 bit 1，产生指令地址非对齐异常；未跳转的条件分支不会因候选目标非对齐而触发异常。第 6 节 SoC 直接复用这个核。

**中断条件与优先级**（`lab/Trap/rv32i_trap.v`）：

```verilog
wire [11:0] mip_now = {irq_ext, 3'b000, irq_timer, 3'b000, irq_soft, 3'b000};
wire [11:0] mie_v   = {ie_meie, 3'b000, ie_mtie, 3'b000, ie_msie, 3'b000};
wire [11:0] pend    = mip_now & mie_v;
wire        irq_any = st_mie & (|pend);
// 优先级：MEI > MSI > MTI
wire [3:0]  irq_code = pend[11] ? 4'd11 : pend[3] ? 4'd3 : 4'd7;
```

**EX 级的杀伤与串行化**：`x_irq` 是"EX 里这条被中断"，`x_serial` 是串行化指令，`ex_exc` 是同步异常。三者任何一个成立都杀掉更年轻的指令（`flush_young`），并在下一拍置 `fetch_stop`，直到 WB 重定向：

```verilog
wire x_irq    = x_valid & irq_any;                              // 本条被中断
wire x_serial = (x_sys != S_NONE) | x_ecall | x_ebreak;
wire ex_kill  = x_valid & (x_irq | x_serial | ex_exc);
wire redirect = x_valid & ~ex_kill & ~m_fault & ex_taken;       // 总预测不跳
wire flush_young = redirect | ex_kill | m_fault;
```

**MEM 级的访问错误与等待**：

```verilog
wire m_go     = m_valid & ~m_exc & ~m_irq;          // 被标记的指令不访存
wire mem_req  = m_go & (m_mem_re | m_mem_we);
wire mem_wait = mem_req & ~dmem_ready;
wire m_fault  = mem_req & dmem_ready & dmem_err;
wire adv      = ~mem_wait;                          // 0 = IF–MEM 冻结
```

**冻结期间保存前递值**（变异 M1 去掉的就是这两行）：

```verilog
end else if (!adv) begin
    // 访存等待时 EX 冻结、WB 却在排空：前递源下一拍就不在了，先把前递后的值存下来
    x_rs1_val <= ex_a_fwd;
    x_rs2_val <= ex_b_fwd;
end else begin
```

**WB 级进入 trap / `mret`**：

```verilog
if (w_trap) begin
    mepc    <= w_pc[31:2];
    mcause  <= trap_cause;
    mtval   <= trap_tval;
    st_mpie <= st_mie;
    st_mie  <= 1'b0;
end else if (w_valid && w_sys == S_MRET) begin
    st_mie  <= st_mpie;
    st_mpie <= 1'b1;
end else if (csr_we) begin
    ...
```

重定向目标：trap 进 `mtvec`（向量模式下的中断加 4 × 编号），`mret` 进 `mepc`，CSR 指令和 `wfi` 进 PC + 4（重新取指，让后面的指令看到新的 CSR）。

**`wfi`**：在 WB 级等，`mip & mie` 不为 0（不看 MIE）才放行：

```verilog
wire wfi_wait = w_valid & ~w_trap & (w_sys == S_WFI) & ~(|(mip_now & mie_v));
```

**PLIC 仲裁**（`lab/Trap/plic.v`）：倒序扫描，用 `>=` 让小号覆盖同优先级的大号（变异 M9 改成 `>` 就变成取大号）：

```verilog
for (i = NSRC - 1; i >= 1; i = i - 1)
    if (pending[i] && enable[i] && prio[i] != {PRIO_W{1'b0}} && prio[i] >= best_p) begin
        best_id = i[IDW-1:0];
        best_p  = prio[i];
    end
...
for (k = 1; k < NSRC; k = k + 1)
    if (src[k] && !inflight[k]) pending[k] <= 1'b1;       // 网关：服务中的源不再置 pending
if (claim) begin
    pending[best_id]  <= 1'b0;
    inflight[best_id] <= 1'b1;
end
```

**DMA 搬运**（`lab/Trap/dma.v`）：每个字一读（`S_RD`）一写（`S_WR`），读数据存在 `m_wdata` 里：

```verilog
S_WR: if (m_ready) begin
    if (m_err) begin
        err <= 1'b1; err_addr <= m_addr; state <= S_IDLE;
    end else begin
        src   <= src + 32'd4;
        dst   <= dst + 32'd4;
        len   <= len - 32'd4;
        count <= count + 32'd1;
        state <= (len == 32'd4) ? S_NEXT : S_RD;
    end
end
```

### 5.9 验证：trace-driven co-simulation

中断什么时候到来取决于 RTL 的时序（定时器、外设延迟、总线等待），离线的参考模型无法预知。
`lab/Trap/trap_iss.py` 用的是工业界 co-simulation 的做法：testbench 把每次退休（`C` 行）和每次进入 trap（`T` 行）写成日志，ISS 按日志逐条复核。

- 日志里的中断，ISS 不去猜它什么时候来，而是检查它**合法**：PC 对得上、`mstatus.MIE = 1`、`cause` 是 `mip & mie` 里优先级最高的那个。合法就跟着进入 trap。
- 读外设寄存器、读 `mcycle` / `mip` 的结果是**不确定值**，ISS 直接采用日志里的值。
- 其余一切由 ISS 自己算，与日志逐条比对：每条指令的写回、存储、CSR 读写、同步异常的 `cause` / `tval`、trap 入口地址、`mret` 恢复的 MIE。

这样既不用让模型模仿 RTL 的时序，又能抓到"在不该打断的时候打断了"和"进入 trap 后状态错了"两类问题。

第 1 节的汇编器为本节加入了 Zicsr 的 6 条指令与 7 条伪指令、`mret`、`wfi`、CSR 名字，以及 `.text` 里的 `.word`（用来放非法指令）。`asm_crosscheck.py` 用 GNU as 的 `-march=rv32i_zicsr` 逐字比对。

测试程序（`lab/Trap/programs/`，都自检查，结果写 `tohost`）：

| 程序 | 内容 |
|------|------|
| `trap_test.s` | CSR 读写语义（`csrrsi` / `csrrci` 的旧值）、只读 CSR 与 WARL 字段、`minstret` / `mcycle`、`ecall`、`ebreak`、非法指令（`mtval` = 指令）、非对齐访存、访问错误、跳转目标非对齐（异常记在跳转指令上、`rd` 不写）、向量模式下异常仍进 BASE、连续 trap 的 `mepc` / MPIE |
| `irq_test.s` | 向量模式；软件中断；周期定时器中断下的计算（同一个循环关中断跑一遍、每 150 个 `mtime` 被打断一次再跑一遍，结果必须相同）；MIE = 0 时 `wfi` 被唤醒但不进处理程序；MSI 与 MTI 同时待处理时先 MSI |
| `plic_test.s` | 7 个源同时拉高，claim 顺序必须是 4 7 5 2 3 1（优先级 7 / 5 / 3 / 2 / 2 / 1，同优先级取小号，优先级 0 的源 6 永不 claim）；门限屏蔽与降低门限后立即响应；空 claim 返回 0；`wfi` 等一个 80 拍后才来的外部中断；MEI 先于 MTI |

testbench（`tb_trap.v`）的地址映射里有一个**测试设备**：写它可以在若干拍之后把指定的 PLIC 源拉高（电平），再写它把源拉低。这就是"外设"。`+ws=1` 让每次访存随机等待 0–3 拍。

DMA 有单独的 testbench（`tb_dma.v`）：300 个随机任务，单段或 1–4 段的描述符链，每 10 个插一个出错任务（源地址非对齐 / 写到没映射的地址 / 描述符指向没映射的地址）。每个任务结束后把整个存储器与参考模型比对，并检查 `STATUS` / `COUNT` / `ERRADDR` 和 irq 的撤销。

**实测**（`bash lab/Trap/run_sim.sh`，真实输出节选）：

```
lint: 0 warning
MATCH programs/trap_test.s: 206 条指令, 20 字节数据与 GNU as 完全一致
MATCH programs/irq_test.s: 240 条指令, 1812 字节数据与 GNU as 完全一致
MATCH programs/plic_test.s: 237 条指令, 372 字节数据与 GNU as 完全一致
===== trap_test ws=0 =====
ws=0  cycles=944  instret=321  traps=15
PASS
trap_iss: 321 条退休、trap [exc 0×2, exc 11×3, exc 2×4, exc 3×1, exc 4×2, exc 5×1, exc 6×1, exc 7×1] 全部复核，tohost=1
MATCH
===== irq_test ws=0 =====
ws=0  cycles=36640  instret=26003  traps=165
irq latency (可响应 → trap 生效): n=165  min=2  avg=2.6  max=4 周期
PASS
trap_iss: 26003 条退休、trap [irq 3×2, irq 7×163] 全部复核，tohost=1
MATCH
===== irq_test ws=1 =====
ws=1  cycles=61062  instret=33247  traps=315
irq latency (可响应 → trap 生效): n=315  min=2  avg=2.8  max=6 周期
PASS
trap_iss: 33247 条退休、trap [irq 3×2, irq 7×313] 全部复核，tohost=1
MATCH
===== plic_test ws=0 =====
ws=0  cycles=1272  instret=794  traps=11
irq latency (可响应 → trap 生效): n=11  min=2  avg=3.8  max=4 周期
PASS
trap_iss: 794 条退休、trap [irq 11×10, irq 7×1] 全部复核，tohost=1
MATCH
===== DMA =====
DMA: 300 个任务（30 个出错任务），搬运 7764 字；主口读 9082 次、写 7764 次，忙 43285 周期，平均 5.58 周期/字
PASS
```

几点解读：

- `irq_test` 在 `ws=1` 下 trap 次数从 165 变成 315：访存变慢，同一个计算循环跑得更久，被定时器打断的次数也更多。程序检查的是"被打断前后结果相同"，所以照样通过。
- 中断延迟最少 2 拍就是 EX → MEM → WB。`plic_test` 平均 3.8 拍：它的中断大多是源早已待处理、由 `csrsi mstatus, 8` 打开 MIE 的那一刻才"变得可响应"。`csrsi` 是串行化指令，在 WB 生效后要重新取指，下一条指令走到 EX 还要 2 拍，所以是 4 拍。
- DMA 每字 5.58 拍：一读一写两次总线访问，每次平均随机等待 1.5 拍，即 (1 + 1.5) × 2 = 5 拍；再加上读描述符和状态转移的开销。读比写多出的 1318 次主要是读描述符（每个 4 个字），以及出错任务里"读了但没写成"的那一次。

### 5.10 变异测试

`bash lab/Trap/mutation.sh`，12 个变异，每个核变异跑 3 个程序 × 有无等待周期（真实输出节选）：

```
===== M1: 访存等待时不保存前递值 =====
  trap_test  ws=0  PASS / MATCH
  trap_test  ws=1  PASS / MATCH
  irq_test   ws=0  PASS / MATCH
  irq_test   ws=1  ERROR: tohost = 199（程序自检查失败，测试号 99） / FAIL (51 处不一致，tohost=0)
  plic_test  ws=0  PASS / MATCH
  plic_test  ws=1  ERROR: tohost = 3（程序自检查失败，测试号 1） / FAIL (38 处不一致，tohost=0)
  => 抓到
===== M2: 中断不看 MIE =====
  irq_test   ws=0  ERROR: 超时（300002 周期） / FAIL (51 处不一致，tohost=0)
  => 抓到
===== M3: mret 不恢复 MIE =====
  trap_test  ws=0  ERROR: tohost = 23（程序自检查失败，测试号 11） / FAIL (7 处不一致，tohost=0)
  => 抓到
===== M4: MTI 优先于 MSI =====
  trap_test  ws=0  PASS / MATCH
  irq_test   ws=0  ERROR: tohost = 9（程序自检查失败，测试号 4） / FAIL (51 处不一致，tohost=0)
  plic_test  ws=0  PASS / MATCH
  => 抓到
===== M5: CSR 指令不串行化 =====
  trap_test  ws=0  ERROR: tohost = 7（程序自检查失败，测试号 3） / FAIL (35 处不一致，tohost=0)
  plic_test  ws=0  PASS / FAIL (51 处不一致，tohost=0)
  => 抓到
===== M6: 访问错误不杀更年轻的指令 =====
  trap_test  ws=0  PASS / FAIL (2 处不一致，tohost=1)
  irq_test   ws=0  PASS / MATCH
  plic_test  ws=0  PASS / MATCH
  => 抓到
===== M7: wfi 当 nop =====
  irq_test   ws=0  ERROR: tohost = 7（程序自检查失败，测试号 3） / FAIL (0 处不一致，tohost=7)
  plic_test  ws=0  ERROR: tohost = 9（程序自检查失败，测试号 4） / FAIL (0 处不一致，tohost=9)
  => 抓到
===== M8: 进入 trap 不保存 MPIE =====
  trap_test  ws=0  PASS / MATCH
  irq_test   ws=0  PASS / MATCH
  plic_test  ws=0  ERROR: tohost = 3（程序自检查失败，测试号 1） / FAIL (0 处不一致，tohost=3)
  => 抓到
===== M9: PLIC 同优先级取大号 =====
  plic_test  ws=0  ERROR: tohost = 3（程序自检查失败，测试号 1） / FAIL (0 处不一致，tohost=3)
  => 抓到
===== M10: claim 后网关不挡住重复 pending =====
  plic_test  ws=0  ERROR: tohost = 3（程序自检查失败，测试号 1） / FAIL (0 处不一致，tohost=3)
  => 抓到
===== M11: DMA 每段少搬一个字 =====
  ERROR job 0: COUNT 不对（读到 0000001d） ERROR job 0: 存储器有 2 个字与参考模型不同
  => 抓到
===== M12: 描述符链只走第一个 =====
  ERROR job 0: COUNT 不对（读到 00000017） ERROR job 0: 存储器有 8 个字与参考模型不同
  => 抓到
```

12 个全部抓到。各变异由谁抓到，比"抓到了"本身更值得看：

| 变异 | 只有谁能抓到 | 说明 |
|------|--------------|------|
| M1 前递值丢失 | 随机等待（`ws=1`） | 没有访存等待就不会冻结，bug 永远不触发。这是调试时真实遇到的 bug |
| M4 MTI 优先于 MSI | `irq_test` 测试 4 | 只有两个中断**同时**待处理时优先级才有意义 |
| M5 CSR 不串行化 | ISS（`plic_test` 里程序自检查通过） | 后面的指令用了旧的 CSR 值，`plic_test` 的结果碰巧不受影响，但逐条比对立即发现写回值不同 |
| M6 访问错误不杀年轻指令 | 只有 ISS | 出错 load 后面那条指令多执行了一次，程序的检查没有覆盖到那个寄存器 |
| M8 不保存 MPIE | 只有 `plic_test` | 第一次 `mret` 之后 MPIE 恒为 1；只有"在 MIE = 0 时进 trap、`mret` 后检查 MIE"的场景能看出来 |

没有哪一种检查能单独抓住全部 12 个。程序自检查、ISS 逐条比对、随机等待周期、专门的测试场景，每一样都至少独占一个变异。

### 5.11 变体与扩展

| 技术 | 解决的问题 | 要点 |
|------|------------|------|
| S / U 模式与委托 | 操作系统需要隔离用户程序 | `medeleg` / `mideleg` 把指定的 trap 交给 S 模式处理；`sstatus` / `sepc` / `scause` 结构相同 |
| 虚拟内存与缺页 | 按需调页 | 缺页（12 / 13 / 15）必须精确，处理完重新执行那条指令 |
| CLIC（Core-Local Interrupt Controller） | PLIC 延迟大（要 claim）、不支持嵌套抢占 | 每个中断有独立的优先级和向量，硬件支持嵌套和尾链（tail-chaining），接近 ARM NVIC |
| 硬件压栈 | 处理程序入口保存寄存器费时 | ARM Cortex-M 在中断入口由硬件压 8 个寄存器，中断延迟固定为 12 拍 |
| 中断延迟优化 | 实时系统要求最坏情况延迟 | 可中断的多周期指令（除法、`lw` 等待）、在更早的级采样、专用寄存器组（shadow registers） |
| AIA / IMSIC | 大量中断、PCIe MSI | 中断变成"写一个地址"，按消息分发到各个核 |
| 多通道 DMA | 多个外设同时需要搬运 | 通道之间仲裁（轮转 / 优先级）；外设握手（DREQ / DACK），按外设节拍搬运而不是全速搬 |
| DMA 突发 | 一字一读一写效率低 | 用总线突发（AXI burst）一次读一行，内部 FIFO 缓冲；读写可以流水重叠 |
| IOMMU | DMA 用物理地址，能访问任意内存 | 给设备也做地址翻译和权限检查 |

### 5.12 面试要点

1. **异常 vs 中断**：
   - 同步 / 异步；
   - `mepc` 分别指向出错的指令 / 下一条该执行的指令；
   - 精确 = `mepc` 之前全部完成、之后毫无痕迹。
2. **进入 trap 的硬件动作**：
   - `mepc` / `mcause` / `mtval` / `MPIE ← MIE` / `MIE ← 0` / `pc ← mtvec`；
   - `mret`：`MIE ← MPIE`、`pc ← mepc`；
   - `ecall` 返回要软件把 `mepc` 加 4。
3. **中断条件**：
   - `mstatus.MIE & mie & mip`；
   - 优先级 MEI > MSI > MTI；
   - `wfi` 只看 `mip & mie`、不看 MIE，所以要用"关 MIE → 查标志 → `wfi` → 开 MIE"的写法，避免丢失唤醒。
4. **流水线里的精确 trap**：
   - 唯一提交点（WB），CSR 修改、trap 进入都在 WB；
   - CSR 等指令串行化（杀掉更年轻的、等自己到 WB），约 4 拍代价；
   - 中断在 EX 采样，被标记的指令不执行、成为 `mepc`；
   - 访问错误在 MEM 发现，杀掉 EX 及之后的指令；
   - 中断延迟本章最少 2 拍，有访存等待时最多 6 拍。
5. **CLINT / PLIC**：
   - CLINT 管定时器（`mtime ≥ mtimecmp`，电平，改 `mtimecmp` 才撤销）和软件中断（核间中断）；
   - PLIC 汇总外部中断：priority / pending / enable / threshold / claim / complete；
   - 网关保证服务中不重复置 pending；
   - 处理程序先清外设、再 complete。
6. **电平 vs 边沿**：电平不丢、可共享、忘清会重入；边沿简单，但服务期间的边沿可能丢。
7. **DMA**：
   - 总线主机，CPU 只写寄存器、等中断；
   - 描述符链把多段搬运串起来，只启动一次；
   - 出错要记下地址、保留已搬的数据、用中断报告。
8. **DMA 与 cache 一致性**：
   - DMA 读之前 clean（写回脏行），DMA 写之后 invalidate；
   - 缓冲区按 cache 行对齐；
   - 或者用 IO 一致性端口（snoop）由硬件保证。
9. **验证中断**：
   - 中断时刻不可预测，参考模型用 trace-driven 方式：检查每个中断"合法"，不确定值采用 RTL 的值，其余全部自己算；
   - 要加随机总线等待：本章最隐蔽的 bug（M1）只在有等待时出现。

### 5.13 一句话总结

trap 的本质是"在一个精确的边界上换一个 PC"：硬件保证边界之前全部完成、之后毫无痕迹，并把现场（`mepc` / `mcause` / MIE）交给软件；中断控制器决定哪个事件、什么时候能打断，DMA 则让搬数据这件事干脆不打扰 CPU，直到搬完。

## 6. SoC 集成

### 6.1 解决什么问题，面试怎么考

前五节分别做出了核、cache、内存控制器、中断控制器和 DMA。**SoC（System on Chip）集成**要解决的是把它们连成一颗能开机运行的芯片：

- 谁和谁之间怎么连（总线互联）；
- 每个部件在地址空间里的位置（地址映射）；
- 两个主机同时访问同一个从机时谁先（仲裁）；
- 访问了不存在的地址怎么办（默认从机）；
- 高速总线怎么接低速外设（桥）；
- 上电之后第一条指令从哪来、内存里的变量怎么得到初值（启动流程）；
- 不同部件的时钟和复位怎么安排。

面试考法：

1. 共享总线、crossbar、NoC 的区别和适用场景；crossbar 的面积随什么增长。
2. 地址译码怎么做；为什么必须有默认从机（default slave）。
3. 轮转仲裁和固定优先级仲裁的区别；什么是饿死（starvation）。
4. AHB / AXI → APB 桥的时序：一次 APB 访问至少几拍。
5. 从上电到 `main()` 之间发生了什么；`.data` 和 `.bss` 分别怎么初始化；LMA 和 VMA 是什么。
6. SoC 里的时钟域、复位域怎么划分；复位释放的顺序。

### 6.2 本章的最小 SoC

```
 rv32i_trap ── M0 ──┐
                    ├── soc_bus ──┬── S0 ROM    代码 + .data 初值；写 → err
 dma ───────── M1 ──┘   crossbar  ├── S1 RAM    上电内容随机
                    2 主 x 6 从   ├── S2 CLINT ──────────► MTIP / MSIP ──► 核
                                  ├── S3 PLIC ◄── 源1 DMA、源2 UART ──► 核
                                  ├── S4 APB 桥 ══ uart_tx ──► txd
                                  ├── S5 DMA 寄存器
                                  └── 默认从机：立即 ready + err
 取指不经 soc_bus：核的指令口直接读 ROM 的第二个口
```

地址映射：

| 从机 | 地址范围 | 译码用的位 | 访问延迟（核看到的） |
|------|----------|------------|----------------------|
| ROM | 0x0000_0000 – 0x0000_3FFF | `[31:14] == 0` | 1 拍 |
| RAM | 0x1000_0000 – 0x1000_3FFF | `[31:14] == 0x04000` | 1 拍 |
| CLINT | 0x0200_0000 – 0x0200_FFFF | `[31:16] == 0x0200` | 1 拍 |
| PLIC | 0x0C00_0000 – 0x0C3F_FFFF | `[31:22] == 0x030` | 1 拍 |
| APB（UART） | 0x2000_0000 – 0x2000_0FFF | `[31:12] == 0x20000` | 3 拍起（APB 两相 + 反压） |
| DMA 寄存器 | 0x2000_1000 – 0x2000_1FFF | `[31:12] == 0x20001` | 1 拍 |
| 其它 | — | — | 默认从机：1 拍，返回 err |

CLINT、PLIC 的基址与 QEMU `virt` 平台、SiFive 的芯片相同，这样同一套软件（比如 OpenSBI）不用改地址。每个外设至少占 4 KB 并按 4 KB 对齐，以后加了 MMU 可以按页给不同外设设置权限。

### 6.3 总线互联

| 结构 | 做法 | 优点 | 缺点 | 用在哪 |
|------|------|------|------|--------|
| 共享总线（shared bus） | 所有主从挂在同一组信号上，一次只有一对在传输 | 面积小、简单 | 带宽被所有主机分享；主机越多越慢 | 小 MCU（AHB-Lite 单主机）、APB 外设总线 |
| 交叉开关（crossbar） | 每个从机前一个多路器和仲裁器，不同的主-从对可以同时传输 | 并行度高；只有访问同一个从机才冲突 | 面积与连线 ∝ 主机数 × 从机数 | 中小 SoC 的主互联（AXI interconnect） |
| 片上网络（NoC） | 包交换，路由器组成网格 / 环 | 可扩展到几十上百个节点；连线规整 | 延迟大（每跳几拍）、设计复杂 | 多核服务器、大型 SoC |

本章是 2 主 × 6 从的 crossbar：核访问 UART 时，DMA 可以同时访问 RAM，互不影响。只有两者同时访问 RAM 才需要仲裁。

**地址译码**：用地址高位比较出目标从机号（独热或编码），作为多路器的选择信号。从机地址空间按 2 的幂对齐，比较就只需要看几个高位，不需要加法器。

**默认从机（default slave）**：地址没有命中任何从机时，总线必须有人回应。否则主机的请求一直等不到 `ready`，整个系统挂死。默认从机立即回 `ready + err`，核产生访问错误异常（`mcause` = 5 / 7），DMA 置 ERR。AXI 里对应的是 DECERR 响应。
本章的 ROM 对写也回 err（只读保护），UART 对未定义的寄存器偏移回 PSLVERR，都是同一个思想：**错误要报告，不能吞掉，更不能挂死**。

**仲裁**：

| 策略 | 做法 | 问题 |
|------|------|------|
| 固定优先级 | 编号小的永远先 | 高优先级主机持续访问时，低优先级的会饿死 |
| 轮转（round-robin） | 上次赢的这次排最后 | 公平，但不区分紧急程度 |
| 加权轮转 / 带宽配额 | 每个主机按权重分配份额 | 需要配置 |
| QoS / 优先级 + 老化 | 等得越久优先级越高 | 复杂，AXI 有 AxQOS 信号承载 |

本章每个从机有一位轮转指针 `rr[k]`：两个主机同时要从机 k 时，上次输的那一方赢。所有从机都是单拍完成，所以**任何一方最多连续输 1 拍**。testbench 把这条当作断言来检查（见 6.9 的变异 S1、S2）。第 3 章 `Arbiter` 实验里有更一般的多路轮转仲裁器写法。

**流水与时序**：本章的互联是纯组合的（主机请求当拍就到从机，`ready` 当拍返回），所以核访问 RAM 仍是 1 拍。真实的 AXI 互联通常在主口、从口各插一级寄存器切片（register slice）来切断长连线，每级多 1 拍延迟，但频率高得多。这就是第 2 节"流水线提高频率"的道理用在了互联上。

### 6.4 APB 桥

APB（第 12 章第 1 节）是低速外设总线：信号少、无流水、无突发，每次访问分 SETUP、ACCESS 两相。桥把系统总线的一次请求转换成一次 APB 传输：

```
周期            1        2         3         4
系统总线 sel    ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
桥状态          IDLE     SETUP     ACCESS    IDLE
PSEL            ________‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾___
PENABLE         __________________‾‾‾‾‾‾‾‾___
PREADY                             ‾‾‾‾‾‾‾      （从机拉低可插等待）
系统总线 ready  __________________‾‾‾‾‾‾‾‾___   完成，PRDATA / PSLVERR 同拍返回
```

所以从核看，一次 APB 访问最少 3 拍（请求那拍锁存、SETUP、ACCESS），从机拉低 PREADY 还可以再加。本章的 UART 在发送 FIFO 满时拉低 PREADY，这叫**总线反压（back-pressure）**：软件可以不查状态寄存器直接连续写 TXDATA，写不进去时 CPU 自动停在那条 `sw` 上。
它的缺点是 CPU 停住期间完全不能做别的，连中断也要等这次访问完成才能响应。所以对实时性要求高的系统，宁可让软件查状态、或者用中断 / DMA 喂 FIFO。

### 6.5 启动流程：从复位到 `main()`

```
上电 / 复位释放
  │  硬件：pc ← RESET_PC（本章 0x0000_0000，即 ROM 开头）
  ▼
crt0（启动代码，ROM 里，汇编）
  1 设 sp ← RAM 顶部                        之后才能调用函数
  2 把 .data 的初值从 ROM（LMA）拷到 RAM（VMA）  有初值的全局变量
  3 把 .bss 清零                            没有初值的全局变量（C 语言保证为 0）
  4 设 mtvec                                之后才能安全地发生 trap
  5 call main
  6 main 返回后：报告结果、死循环（裸机没有地方可"退出"）
```

**LMA 与 VMA**：`.data` 里的变量运行时在 RAM 里（运行地址 VMA，Virtual / run address），但 RAM 掉电就没了，初值只能存在 ROM 里（装载地址 LMA，Load address）。链接脚本里写成 `.data : { ... } > RAM AT> ROM`，并导出 `_sidata`（ROM 里的初值起点）、`_sdata` / `_edata`（RAM 里的范围）、`_sbss` / `_ebss`，crt0 用这些符号做拷贝和清零。
本章的汇编器没有链接器，用固定约定代替：`.data` 段的标号是 RAM 地址（从 0x1000_0000 起），初值镜像放在 ROM 的 0x2000，crt0 里写死 `ROM_DATA = 0x2000`。

为什么这几步缺一不可：真实芯片的 SRAM 和寄存器堆**上电是随机值**，没有复位。本章 testbench 也照此办理：RAM 和通用寄存器都用随机数填满，换 3 个种子各跑一遍。少了第 2 步，DMA 读到的描述符是乱码；少了第 3 步，标志变量一开始就"已置位"。见 6.9 的变异 S10、S11。

**真实芯片的多级启动**：

1. **Boot ROM**（掩膜 ROM，几十 KB，出厂固化）：根据启动引脚（strap pins）选择启动介质（SPI flash / eMMC / SD / USB），把下一级程序读进片上 SRAM。安全启动（secure boot）时还要校验它的签名。
2. **第一级引导**（SPL / FSBL）：在片上 SRAM 里运行，初始化时钟（PLL）和 **DDR 控制器**（包括第 4 节说的 PHY 训练），然后把下一级读进 DDR。
3. **引导程序 / 固件**（U-Boot、OpenSBI）：设置 trap 委托、设备树，加载操作系统。
4. 操作系统内核。

另一种做法是 **XIP（eXecute In Place）**：代码直接在 SPI flash 里执行，经过一个带 cache 的 flash 控制器，常见于 MCU。

### 6.6 时钟、复位与 IP 集成

本章的 SoC 只有一个时钟、一个复位，这是教学上的简化。真实 SoC 一般有：

| 域 | 典型频率 | 说明 |
|----|----------|------|
| CPU | 最高（GHz 级） | 可以独立调频（DVFS） |
| 主互联 / DDR 控制器 | CPU 的 1/2 – 1/4 | DDR 控制器的 PHY 一侧还有 DRAM 的时钟 |
| APB 外设 | 再低（几十 MHz） | 与主互联常是**同步的整数倍关系**，桥里用使能信号实现，不需要 CDC |
| UART / SPI 参考时钟、RTC | 与系统时钟无关（如 32.768 kHz） | **异步**，跨域信号要按第 6 章同步（CLINT 的 `mtime` 常由 RTC 驱动，读的时候要处理跨域） |

时钟与复位由一个 **CRG（Clock and Reset Generator）** 模块统一产生：PLL、分频、每个 IP 的门控时钟（第 5 章第 2 节的 ICG，软件可以关掉不用的外设省功耗）和软复位。

复位的几条规则（详见第 5 章第 4、5 节）：

- 每个时钟域用自己的复位同步器：**异步置位、同步释放**；
- **复位释放有顺序**：先 PLL，等锁定后释放总线和存储器，再释放 CPU。CPU 最后起来，保证它取第一条指令时 ROM 和总线都已经可用；
- 看门狗（watchdog）复位、软件触发的复位要能复位整个 SoC，调试模块（JTAG）通常不被复位，便于调试复位问题；
- 跨复位域（RDC）：一个域在复位、另一个域没复位时，两者之间的信号要隔离。

**IP 集成的约定**：

- 寄存器：每个 IP 一个寄存器块，访问类型标清楚（RW、RO、W1C 写 1 清、RC 读清），保留位读 0、写忽略。本章 DMA 的 `STATUS.DONE` 就是 W1C。寄存器描述通常用 SystemRDL / IP-XACT 写，自动生成 RTL、C 头文件和文档，避免三者不一致。
- 中断：每个 IP 输出电平中断，内部有自己的状态位和使能位；SoC 层把它们接到 PLIC 的源号上。软件看到的中断号就是 PLIC 源号，是 SoC 规格的一部分。
- 错误响应：未定义的寄存器、不支持的访问宽度，回 PSLVERR / SLVERR。

### 6.7 RTL 解读

**crossbar 的仲裁与多路**（`lab/SoC/soc_bus.v`）：每个从机一套，生成语句展开：

```verilog
for (k = 0; k < NS; k = k + 1) begin : g_slave
    assign want0[k] = r0 && t0 == k;
    assign want1[k] = r1 && t1 == k;
    assign g1[k]    = want1[k] && (!want0[k] || rr[k]);        // 从机 k 本拍给 M1
    assign s_sel[k] = want0[k] | want1[k];
    assign s_addr [32*k +: 32] = g1[k] ? m1_addr  : m0_addr;
    ...
end
```

主机看到的结果：目标是默认从机就立即 `ready + err`，否则要拿到授权、且从机 `ready`：

```verilog
wire       hit0 = (t0 != S_ERR) && !g1[t0];          // M0 拿到了它要的从机
assign m0_ready = r0 && ((t0 == S_ERR) || (hit0 && s_ready[t0]));
assign m0_err   = r0 && ((t0 == S_ERR) || (hit0 && s_err[t0]));
```

轮转指针在一次**冲突**的传输完成时更新，把优先权交给输的一方（变异 S1 把 `!g1` 改成 `g1`，就成了"赢家继续优先"）：

```verilog
for (j = 0; j < NS; j = j + 1)
    if (want0[j] && want1[j] && s_ready[j]) rr[j] <= !g1[j];
```

**APB 桥**（`lab/SoC/apb_bridge.v`）：三状态隐含在 `psel` / `penable` 两个寄存器里，完成那拍才给系统总线 `ready`（变异 S4 改成 SETUP 拍就给）：

```verilog
wire done = psel & penable & pready;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        psel <= 1'b0; penable <= 1'b0; ...
    end else if (done) begin
        psel <= 1'b0; penable <= 1'b0;
    end else if (psel) begin
        penable <= 1'b1;                    // SETUP → ACCESS；ACCESS 里等 PREADY
    end else if (sel) begin
        psel   <= 1'b1;                     // IDLE → SETUP：锁存地址和数据
        ...
    end
end
assign ready = done;
```

**UART 的反压与移位**（`lab/SoC/uart_tx.v`）：

```verilog
assign pready  = !(access && pwrite && a == 4'h0 && full);    // FIFO 满：插等待
...
if (pop) begin
    sh <= fifo[rp]; rp <= rp + 1'b1;
    nbit <= 4'd1; bit_cnt <= 16'd0; txd <= 1'b0;          // 起始位
end else if (nbit != 4'd0) begin
    if (bit_cnt == div - 16'd1) begin
        bit_cnt <= 16'd0;
        if (nbit == 4'd10) begin
            nbit <= 4'd0;                                  // 停止位发完
        end else begin
            nbit <= nbit + 4'd1;
            txd  <= (nbit == 4'd9) ? 1'b1 : sh[0];         // 低位先发；第 9 拍之后是停止位
            sh   <= {1'b0, sh[7:1]};
        end
    end ...
```

**SoC 顶层的 ROM 只读保护和中断接线**（`lab/SoC/soc_top.v`）：

```verilog
assign s_rdata[0 +: 32] = rom[s_addr[13:2]];
assign s_ready[0] = 1'b1;
assign s_err[0]   = s_we[0];                               // 写 ROM → err
...
plic #(.NSRC(4)) u_plic (..., .src({1'b0, uart_irq, dma_irq, 1'b0}), .irq(irq_ext));
```

### 6.8 软件：`programs/hello.s`

crt0 之后，`main` 依次做 5 个测试，每个都自检查，失败时返回测试号：

| 测试 | 内容 | 用到的部件 |
|------|------|------------|
| 1 | UART 打印 `hello, SoC`（不查状态，靠 PREADY 反压） | APB 桥、UART |
| 2 | 读未映射地址 0x4000_0000 → `mcause` = 5；写 ROM → `mcause` = 7 | 默认从机、ROM 保护、trap |
| 3 | DMA 按 3 个描述符（顺序打乱）搬 32 个字；搬运期间 CPU 用 8 个连续 `lw` 一组读同一块 RAM 求和；完成中断经 PLIC 源 1 到达；检查中断里读到的 STATUS、`COUNT` = 32、目标数据 | DMA、crossbar 仲裁、PLIC |
| 4 | 定时器每 300 个 `mtime` 中断一次，处理程序重设 `mtimecmp`，数够 5 次 | CLINT |
| 5 | 打印 `PASS`；打开 UART "全部发完"中断（PLIC 源 2），等它来了再返回 | UART 中断、PLIC |

测试 5 有实际意义：`sw` 写进 FIFO 不等于字符已经发出去。如果写完最后一个字符就结束，testbench 会少收几个字符。用"发完"中断等到 FIFO 和移位寄存器都空，才能放心地关电或复位。
所有"等中断"都用 5.4 节的"关 MIE → 查标志 → `wfi` → 开 MIE"写法。

DMA 描述符放在 `.data` 里（地址用标号表达式写，如 `.word srcbuf + 32, dstbuf, 32, desc1`），所以它们的正确性直接依赖 crt0 的 `.data` 拷贝。

### 6.9 验证与实测

testbench（`lab/SoC/tb_soc.v`）的检查：

1. **UART 监视器**：从 `txd` 引脚上按 8N1 独立解码。等下降沿，延迟半个比特到起始位中点并确认仍为 0，之后每个比特中点采样一次，停止位必须为 1。逐字符与 `programs/hello.expect` 比对。
2. **tohost == 1**：程序的自检查。
3. **逐条复核**：日志交给 `lab/Trap/trap_iss.py --map soc`。相对第 5 节增加了三样：
   - ROM 可读（代码 + 0x2000 处的 `.data` 镜像），写 ROM 是存储访问错误；
   - RAM 上电内容未知，ISS 记录每个字节是否被写过，**读到没写过的字节就报错**；
   - DMA 对 RAM 的每次写记一行 `D addr data`，ISS 照着更新内存，这样 CPU 读 DMA 搬来的数据也能复核。
   同一拍里先记退休、后记 DMA 写：WB 里那条 load 在上一拍就已经读过存储器了，这样排序 ISS 看到的先后才与硬件一致。
4. **仲裁公平性**：任何一个主机被另一个主机连续挡住不超过 1 拍。
5. 上电时 RAM 和通用寄存器填随机数；寄存器堆的上电值写在日志第一行（`R` 行）给 ISS。处理程序把"还没写过的寄存器"压栈是合法的，ISS 需要知道这些值才能比对那次存储。

**实测**（`bash lab/SoC/run_sim.sh`，3 个随机种子，真实输出节选）：

```
lint: 0 warning
programs/hello.s: 304 条指令, 364 字节数据 -> build/hello.*
MATCH programs/hello.s: 304 条指令, 364 字节数据与 GNU as 完全一致
===== hello seed=1 =====
上电 RAM[0] = 80010e00，x1 = c4de3e89
UART 收到：
hello, SoC
dma ok
timer ok
PASS
cycles=5148  instret=1595  traps=9  dma_words=32
CPU 因 DMA 占用同一从机而等待 28 周期（最长连续 1），DMA 被 CPU 挡最长连续 1 拍
UART 反压（PREADY=0）1049 周期
PASS
trap_iss: 1595 条退休、trap [exc 5×1, exc 7×1, irq 11×2, irq 7×5]、DMA 写 32 字 全部复核，tohost=1
MATCH
===== hello seed=2 =====
上电 RAM[0] = 80021c00，x1 = 071a8d0e
...
PASS
...
MATCH
```

三个种子的周期数完全相同（5148）：程序不依赖任何上电值，这正是要验证的。

**时间都去哪了**：1595 条指令用了 5148 拍，CPI ≈ 3.2，但这不说明核慢：

- UART 每比特 8 拍、每字符 10 比特，32 个字符至少 2560 拍；FIFO 只有 4 深，CPU 有 1049 拍停在 PREADY 反压上；
- 定时器测试 5 × 300 = 1500 拍里 CPU 基本在 `wfi`；
- DMA 与 CPU 真正冲突只有 28 拍，轮转仲裁让两边交替前进。

这正是 SoC 里常见的情况：瓶颈在外设和等待上，不在核上。所以打印大量日志的固件要用中断或 DMA 喂 UART，而不是让 CPU 停在总线上。

### 6.10 变异测试

`bash lab/SoC/mutation.sh`，11 个变异（9 个硬件、2 个启动代码；真实输出）：

```
===== S1: 轮转指针更新反了 =====
  ERROR: 仲裁不公平：CPU 最长连续被挡 0 拍，DMA 8 拍（应 ≤ 1） PASS / MATCH
  => 抓到
===== S2: 固定优先级（DMA 永远赢）=====
  ERROR: 仲裁不公平：CPU 最长连续被挡 32 拍，DMA 0 拍（应 ≤ 1） PASS / MATCH
  => 抓到
===== S3: 默认从机不回 err =====
  ERROR: tohost = 5（程序自检查失败，测试号 2） ERROR: UART 收到 6 个字符，期望 32 个 / MISMATCH 日志第 509 行 (C 000000b8 00032383 1 7 00000000 0 40000000 00000000): RTL 正常退休，ISS 产生异常 cause=5 tval=0x40000000
  => 抓到
===== S4: APB 桥在 SETUP 拍就给 ready =====
  ERROR: UART 第 6 个字符 = 53，期望 20 ERROR: UART 第 7 个字符 = 43，期望 53 / FAIL (0 处不一致，tohost=0)
  => 抓到
===== S5: UART 高位先发 =====
  ERROR: UART 第 0 个字符 = 16，期望 68 ERROR: UART 第 1 个字符 = a6，期望 65 / MATCH
  => 抓到
===== S6: UART FIFO 满时不反压 =====
  ERROR: UART 第 1 个字符 = 2c，期望 65 ERROR: UART 第 2 个字符 = 0a，期望 6c / MATCH
  => 抓到
===== S7: UART 停止位没发 =====
  ERROR: UART 停止位不是 1（字符 0） ERROR: UART 停止位不是 1（字符 1） / MATCH
  => 抓到
===== S8: ROM 可写 =====
  ERROR: tohost = 5（程序自检查失败，测试号 2） ERROR: UART 收到 7 个字符，期望 32 个 / MISMATCH 日志第 534 行 (C 000000cc 10702023 0 0 00000000 f 00000100 00000005): RTL 正常退休，ISS 产生异常 cause=7 tval=0x100
  => 抓到
===== S9: PLIC 源接反 =====
  ERROR: 超时（200002 周期） ERROR: tohost = 0（程序自检查失败，测试号 0） / FAIL (0 处不一致，tohost=0)
  => 抓到
===== S10: crt0 不清 .bss =====
  ERROR: 超时（200002 周期） ERROR: tohost = 0（程序自检查失败，测试号 0） / MISMATCH 日志第 989 行 (C 000002c0 0002a303 1 6 88c8b011 0 10000060 00000000): 读了从未写过的 RAM 10000060（RAM 上电是随机值）
  => 抓到
===== S11: crt0 不拷 .data =====
  ERROR: tohost = 7（程序自检查失败，测试号 3） ERROR: UART 收到 0 个字符，期望 32 个 / FAIL (0 处不一致，tohost=7)
  => 抓到
```

11 个全部抓到。几个值得讨论的：

- **S1、S2 功能上完全正确**：程序 PASS，ISS 也 MATCH。仲裁不公平只是让一方多等，数据一点不错。只有"最多连续输 1 拍"这条断言能抓到。
  S1 一开始**没有被抓到**：程序原来的求和循环每 5 条指令才一个 `lw`，两个主机很少连续冲突，"赢家继续优先"的 bug 不显形。改成 8 个 `lw` 连成一组之后，DMA 被连续挡了 8 拍，才暴露出来。验证公平性必须构造**持续的**竞争。
- **S4**（SETUP 拍就给 ready）：FIFO 没满时看不出问题，所以前 6 个字符都对。FIFO 满了以后，桥卡在某次写的 ACCESS 相等 PREADY，而核早在 SETUP 拍就收到了 ready，已经发出下一次写。PREADY 一来，同一个 `ready` 把两次请求都应答了，但第二次从来没有被锁存进桥，这个字符就丢了。
- **S5、S6、S7 只有 UART 监视器能抓到**：从 CPU 和 ISS 的角度看，每次 `sw` 都正常完成了，错误发生在引脚上。所以 SoC 级验证一定要在**芯片引脚**上放独立的协议监视器。
- **S9**（PLIC 源接反）：DMA 中断被当成 UART 中断处理，处理程序关掉了 UART 中断使能、complete，但 DMA 的电平中断一直没清，complete 后网关立即又置 pending，于是无限重入，直到超时。这是 5.6 节"忘清电平中断会无限重入"的实例。
- **S10**：ISS 的"读了从未写过的 RAM"直接指出地址 0x1000_0060，是 `.bss` 里的 `ticks`。没有这个检查的话，只能看到"超时"，还要自己去查原因。
- **S11**：ISS 没有报不一致。少了拷贝之后，清零循环从 `_sdata` 开始，把整个 `.data` 也清成了 0，RTL 和 ISS 读到的都是 0，彼此一致。抓到它的是程序自检查：DMA 读到全 0 的描述符，`COUNT` 不对（测试号 3），字符串是空的（UART 收到 0 个字符）。

### 6.11 变体与扩展

| 技术 | 解决的问题 | 要点 |
|------|------------|------|
| AXI 互联 | 本章是单拍握手、无 outstanding | 五个独立通道、多个 outstanding、ID 乱序；读写通道各自仲裁 |
| 寄存器切片 / 多级互联 | 大芯片里连线长、时序难收敛 | 在互联里插流水级；高速主机走主互联，外设走二级互联 |
| 一致性互联 | 多核 + DMA 共享数据 | 互联里有窥探过滤器（snoop filter）或目录，见 5.7 节 |
| QoS 与带宽保证 | 显示控制器等实时主机不能等 | 优先级 + 带宽调节器（regulator），超额的主机降级 |
| 防火墙 / 总线安全 | 不可信主机访问敏感区域 | 每次访问带安全属性（AXI 的 AxPROT），互联里按区域检查（TrustZone） |
| 低功耗域 | 不用的 IP 断电 | 电源域之间的隔离单元（isolation cell）、电平转换、保持寄存器（retention） |
| 调试子系统 | 上电后看不到内部 | RISC-V Debug Module + JTAG：暂停核、读写寄存器和内存、单步、硬件断点 |
| 中断汇总层次 | 外设很多 | IP 内部先汇总（状态位 + 使能位），再进 PLIC；多核时 PLIC 每个上下文一组 enable |

### 6.12 面试要点

1. **互联结构**：
   - 共享总线一次只有一对传输，面积小；
   - crossbar 每个从机一个仲裁器，不同从机并行，面积 ∝ 主 × 从；
   - NoC 用于几十个节点以上。
2. **地址译码与默认从机**：
   - 按 2 的幂对齐，只比较高位；
   - 未映射地址必须由默认从机回 err（AXI 的 DECERR），否则主机永远等不到 ready、系统挂死；
   - 只读区域写、未定义寄存器也回错误。
3. **仲裁**：
   - 固定优先级会饿死低优先级；
   - 轮转公平，本章单拍从机下任何一方最多连续输 1 拍；
   - 公平性 bug 功能上不出错，要用断言 + 持续竞争的激励才能抓到。
4. **APB 桥**：
   - SETUP、ACCESS 两相，从核看一次访问至少 3 拍；
   - 外设拉低 PREADY 实现反压，代价是 CPU 停在总线上、中断也要等。
5. **启动流程**：
   - 复位向量 → crt0：设 sp、拷 `.data`（LMA → VMA）、清 `.bss`、设 `mtvec`、调 `main`；
   - SRAM 上电是随机值，所以这几步缺一不可；
   - 真实芯片：Boot ROM → SPL（初始化 DDR）→ U-Boot / OpenSBI → OS。
6. **时钟与复位**：
   - CPU、互联、外设、异步参考时钟分域；同步整数倍关系不需要 CDC，异步的要同步；
   - 每个域一个复位同步器（异步置位、同步释放）；
   - 复位释放顺序：PLL → 总线 / 存储器 → CPU。
7. **IP 集成**：
   - 寄存器访问类型（RW / RO / W1C）、保留位读 0；
   - 寄存器描述用 SystemRDL / IP-XACT 生成 RTL 和头文件；
   - 中断号 = PLIC 源号，是 SoC 规格的一部分。
8. **SoC 级验证**：
   - 在引脚上放独立的协议监视器（本章 3 个 UART 变异只有它能抓到）；
   - 上电随机化 RAM 和寄存器，检查"读未初始化内存"；
   - CPU 级的 ISS 比对 + 程序自检查 + 断言，各自抓不同的 bug。

### 6.13 一句话总结

SoC 集成就是给每个部件一个地址、给每次冲突一个裁决、给每个错误一个回应，再用一段启动代码把"上电时一片随机"的芯片带到 `main()`。互联、桥、启动代码单看都不复杂，难点在它们合在一起时的时序和边界情况，所以验证要从芯片引脚和随机的上电状态入手。

---

## 7. 运行全部实验

在 PowerShell 里一次跑完本章全部实验和变异测试：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/13_Computer_Architecture_SoC/lab' && sed -i 's/\r$//' */*.sh */*.py */*.v */programs/* && for d in RV32I Pipeline Cache DRAM Trap SoC; do bash `$d/run_sim.sh 2>&1 | grep -a -E '=====|PASS|FAIL|ERROR|MATCH|SKIP|%Warning|lint'; bash `$d/mutation.sh 2>&1 | grep -a -E '=====|PASS|FAIL|=>'; done"
```

预期结果：

- `run_sim.sh`：
  - 汇编器交叉检查：RV32I 的 6 个程序、Trap 的 3 个、SoC 的 1 个都 `MATCH`；
  - 单周期 5 个程序、流水线 5 个程序 × 4 种配置都打印 `PASS`；
  - cache 5 种配置都 `PASS` 并 `MATCH`；
  - DRAM：延迟探针 `PASS`，矩阵、前瞻对比、队列深度对比的每一行末尾都是 `PASS MATCH`；
  - Trap：3 个程序 × 有无等待都是 `PASS` + `MATCH`，DMA `PASS`；
  - SoC：3 个种子都是 `PASS` + `MATCH`；
  - 没有 Verilator 告警（`%Warning`）。
- `mutation.sh`：
  - 前三个实验：每个变异至少有一个程序（cache 是唯一的那次仿真）打印 `FAIL`；唯一的例外是 cache 的 M4，它是等价变异，打印 `PASS` 是预期结果（3.9 节）；
  - DRAM、Trap、SoC：每个变异最后一行都是 `=> 抓到`。其中个别程序打印 `PASS` 是正常的，说明那个程序覆盖不到这个 bug（见 5.10、6.10 节的表）。
- 全部跑完约 13 分钟（实测 12 分 46 秒）：DRAM 的 `run_sim.sh`（31 次仿真，每次 4000 个请求）约 4 分钟，DRAM 和 Trap 的 `mutation.sh` 各约 3 分钟，其余每项不到 1 分钟。

注意：

- 汇编器交叉检查需要 GNU binutils：`apt install binutils-riscv64-unknown-elf`。没装时打印 `SKIP`，不影响其它仿真。仿真本身只需要 oss-cad-suite（iverilog、verilator）和 python3。
- Windows 下编辑过的 `.sh` / `.py` / `.s` 是 CRLF 换行，运行前要 `sed -i 's/\r$//'`，上面的命令已经带了。
- 在 PowerShell 的双引号字符串里，`$` 要写成 `` `$ ``。
- 单独看某个程序的指令级执行：`python3 lab/RV32I/rv32_iss.py lab/RV32I/build/<程序> --pipe` 打印指令统计和流水线时序模型；`lab/RV32I/build/<程序>.lst` 是带地址和机器码的列表文件。
- 产生的 `build/`、`build_mut/`、`*.vcd`、`__pycache__/` 是构建产物，不需要提交。

---

## 8. 速查表

**RV32I 指令格式**（立即数符号位一律是 `instr[31]`）：

| 格式 | 字段（高 → 低） | 立即数 | 指令 |
|------|------------------|--------|------|
| R | funct7 · rs2 · rs1 · funct3 · rd · opcode | — | `add sub sll slt sltu xor srl sra or and` |
| I | imm[11:0] · rs1 · funct3 · rd · opcode | 12 bit | `addi slti sltiu xori ori andi slli srli srai`、load、`jalr` |
| S | imm[11:5] · rs2 · rs1 · funct3 · imm[4:0] · opcode | 12 bit | `sb sh sw` |
| B | imm[12\|10:5] · rs2 · rs1 · funct3 · imm[4:1\|11] · opcode | 13 bit，±4 KB | `beq bne blt bge bltu bgeu` |
| U | imm[31:12] · rd · opcode | 高 20 bit | `lui auipc` |
| J | imm[20\|10:1\|11\|19:12] · rd · opcode | 21 bit，±1 MB | `jal` |

**常用伪指令**：`li`（`addi` 或 `lui + addi`，`%hi = (v + 0x800) >> 12`）、`la` / `call`（`auipc + addi/jalr`）、`mv`、`not`、`neg`、`j`、`ret`、`beqz`、`bgt`。

**调用约定**：

- 参数 / 返回值 `a0–a7` / `a0–a1`；
- 调用者保存 `ra t0–t6 a0–a7`；
- 被调用者保存 `sp s0–s11`；
- `x0` 恒 0。

**五级流水线冒险**：

| 冒险 | 解决 | 代价（本章） |
|------|------|--------------|
| 结构 | 哈佛结构、2R1W 寄存器堆、写穿透 | 0 |
| 数据（ALU → 使用） | EX/MEM、MEM/WB 前递，年轻者优先，排除 `x0` | 0 |
| 数据（load → 紧跟使用） | 停 1 拍 + MEM/WB 前递 | 1 拍 |
| 数据（无前递） | 等到生产者进入 WB（写穿透） | 距离 1 / 2 / 3 → 2 / 1 / 0 拍 |
| 控制 | 预测下一条 PC，EX 解析，"预测 ≠ 实际"则冲刷 IF/ID、ID/EX | 2 拍 / 次 |
| 精确停机 / 异常 | EX 杀掉更年轻的指令并停止取指，自己走到 WB 退休 | — |

周期恒等式：cycles = instret + 4 + stalls + 2 × redirects。

**分支预测**：

| 预测器 | 擅长 | 不擅长 |
|--------|------|--------|
| 总预测不跳 | 无 | 所有跳转 |
| 静态 BTFN | 循环回跳 | 前向的常跳分支 |
| BTB + 2 bit 计数器 | 偏向明显的分支 | 交替模式（实测 100% 错） |
| 两级 / gshare | 相关、周期模式 | 冷启动、别名 |
| RAS | 函数返回 | 非调用式的 `jalr` |

**Cache 公式**：

| 量 | 公式 |
|----|------|
| offset 位数 | $\log_2(\text{行大小})$ |
| 组数 | 容量 / (行大小 × 路数) |
| index 位数 | $\log_2(\text{组数})$ |
| tag 位数 | 地址宽度 − index − offset |
| AMAT | 命中时间 + 缺失率 × 缺失代价（多级递归展开） |
| 访存 CPI 增量 | 每条指令访存次数 × 缺失率 × 缺失代价 |
| 4 路替换位 / 组 | 真 LRU 年龄 8 bit（下限 5），树形 PLRU 3 bit |

**3C 与对策**：

| 缺失 | 对策 |
|------|------|
| 强制 | 大行、预取 |
| 容量 | 大 cache、分块 |
| 冲突 | 高相联度、victim cache、padding |
| 一致性（多核） | 一致性协议、避免伪共享 |

**写策略**：写回 + 写分配（主流，需要脏位，同一行多次写只写回一次）；写直达 + 写不分配（简单，需要写缓冲）。

**DRAM 访问延迟**（DDR3-1600 11-11-11，tCK = 1.25 ns）：

| 情况 | 命令序列 | 延迟 | 本章 |
|------|----------|------|------|
| 行命中 | RD | tCL | 13.75 ns |
| 行空 | ACT → RD | tRCD + tCL | 27.5 ns |
| 行冲突 | PRE → ACT → RD | tRP + tRCD + tCL | 41.25 ns |

**DRAM 关键约束**：tRC = tRAS + tRP（同 bank 两次 ACT）；tRRD、tFAW（4 个 ACT）限制激活速率；tWR 写恢复、tWTR 写转读、tRTP 读到预充；刷新开销 ≈ tRFC / tREFI = 260 ns / 7.8 µs ≈ 3%。

**DDR 带宽**：峰值 = 数据率（MT/s）× 位宽 / 8。DDR4-3200 × 64 bit = 25.6 GB/s；本章 DDR3-1600 × 32 bit = 6.4 GB/s。8n 预取 ↔ BL8；64 B cache 行 = BL8 × 64 bit。

**地址映射与页策略**：列在低位、bank 在列之上（顺序访问换行时换 bank）；行号低位异或进 bank 号打散 2 的幂间距；局部性好用开页，差用关页（关页必须配 bank 交织）。

**RISC-V 机器模式 trap**：

| 事件 | 硬件动作 |
|------|----------|
| 进入 trap | `mepc ← pc`（异常：出错指令；中断：下一条）、`mcause`、`mtval`、`MPIE ← MIE`、`MIE ← 0`、`pc ← mtvec`（向量模式的中断：BASE + 4 × 编号） |
| `mret` | `MIE ← MPIE`、`MPIE ← 1`、`pc ← mepc` |
| 中断条件 | `mstatus.MIE & mie[i] & mip[i]`，优先级 MEI(11) > MSI(3) > MTI(7) |
| `wfi` | 等 `mip & mie ≠ 0`（不看 MIE）；可以实现成 `nop` |

**`mcause` 异常编号**：0 取指非对齐、1 取指访问错误、2 非法指令、3 断点、4 / 6 load / store 非对齐、5 / 7 load / store 访问错误、8 / 9 / 11 U / S / M 模式 `ecall`、12 / 13 / 15 取指 / load / store 缺页。

**CSR 地址**：`mstatus` 0x300、`misa` 0x301、`mie` 0x304、`mtvec` 0x305、`mscratch` 0x340、`mepc` 0x341、`mcause` 0x342、`mtval` 0x343、`mip` 0x344、`mcycle` 0xB00、`minstret` 0xB02、`mhartid` 0xF14。地址 [11:10] = 11 为只读。

**CLINT / PLIC 寄存器**：

| 寄存器 | 偏移 | 说明 |
|--------|------|------|
| CLINT `msip` | 0x0000 | 软件中断（核间中断） |
| CLINT `mtimecmp` | 0x4000 | `mtime ≥ mtimecmp` → MTIP（电平）；RV32 写法：低 32 位写全 1 → 写高 → 写低 |
| CLINT `mtime` | 0xBFF8 | 64 位自由计数 |
| PLIC `priority[i]` | 4i | 0 = 永不 |
| PLIC `pending` / `enable` | 0x1000 / 0x2000 | |
| PLIC `threshold` | 0x200000 | `priority > threshold` 才能打断 |
| PLIC `claim / complete` | 0x200004 | 读 = 取走最高优先级源号；写 = 服务完毕。处理顺序：claim → 清外设 → complete |

**DMA 与 cache 一致性**：DMA 读之前 clean（写回脏行）；DMA 写之后 invalidate；缓冲区按 cache 行对齐；或用 IO 一致性端口。

**SoC 互联**：

| 项 | 要点 |
|----|------|
| 共享总线 / crossbar / NoC | 一次一对 / 不同从机并行，面积 ∝ 主 × 从 / 包交换，可扩展 |
| 默认从机 | 未映射地址立即回 err（AXI DECERR），否则系统挂死 |
| 仲裁 | 固定优先级会饿死；轮转公平（单拍从机下最多连续输 1 拍） |
| APB 访问 | SETUP + ACCESS，从系统总线看至少 3 拍；PREADY 拉低 = 反压 |
| 启动 | 复位向量 → 设 sp → 拷 `.data`（LMA → VMA）→ 清 `.bss` → 设 `mtvec` → `main` |
| 复位 | 每个时钟域一个同步器（异步置位、同步释放）；释放顺序 PLL → 总线 / 存储器 → CPU |
