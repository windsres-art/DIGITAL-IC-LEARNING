# 12 总线与接口 —— 面试向

目标：片上总线（APB / AHB / AXI）和片外低速接口（UART / SPI / I2C）是数字前端岗位的高频考点。面试官一般会问三件事：**信号和时序画得出来吗**、**握手和流水的规则说得清吗**、**能不能当场写一个从机**。本章每个协议都配一份可综合 RTL 和自检查 testbench，testbench 带参考模型、协议检查器和变异测试，在 WSL 中实际跑通，README 里贴的是真实输出。

前置知识：

- valid/ready 握手、打一拍不断流、skid buffer：`../03_Common_Circuits/README.md` 第 8、13 节（AXI 的每个通道就是一个 valid/ready 接口）
- 同步 FIFO：`../03_Common_Circuits/README.md` 第 1 节（AXI 从机的命令队列）
- 仲裁器：`../03_Common_Circuits/README.md` 第 7 节（AHB 仲裁、AXI 互联）
- 位宽转换带 last/keep：`../03_Common_Circuits/README.md` 第 14 节（AXI-Stream）
- 跨时钟域：`../06_CDC/README.md`（UART/SPI/I2C 的输入同步）

建议顺序：第 1 节 APB（最简单，先把"两段式传输 + 等待"弄懂）→ 第 2 节 AHB（加上地址/数据两级流水）→ 第 3 节 AXI（再拆成五个独立通道，加上 ID 和 outstanding）。三者是一条演进线，每一步都在回答"上一个协议的吞吐瓶颈在哪"。面试前直接看每节末尾的"面试要点"和第 8 节速查表。

配套实验（`lab/` 下，每个文件夹 `bash run_sim.sh` 一键 lint + 仿真，`bash mutation.sh` 跑变异测试）：

| 实验 | 内容 |
|------|------|
| `lab/APB/` | APB4 主机（命令口 → SETUP/ACCESS 状态机，背靠背传输）+ 寄存器从机（RW / RO / W1C、PSTRB、可配等待、PSLVERR）；WAIT=0 / 2 两种配置；3 个变异 |
| `lab/AHB/` | AHB-Lite SRAM 从机（同步读 + 写后读旁路、随机等待）、译码器 + 响应 MUX + 默认从机（两拍 ERROR）；周期级主机 BFM 跑 8 种 burst、BUSY、窄传输；2 个变异 |
| `lab/AXI/` | AXI4 RAM 从机（FIXED/INCR/WRAP、窄传输、非对齐、WSTRB、命令队列支持 4 笔 outstanding）；五通道独立随机主机、按 ID 记分板、五通道协议检查；outstanding 1 vs 4 吞吐对比；3 个变异 |

本章进度：第 1–3 节（APB、AHB、AXI4 与 AXI-Stream）已完成；第 4–6 节（UART、SPI、I2C）待写。

---

## 目录

1. [APB](#1-apb)
2. [AHB](#2-ahb)
3. [AXI4 与 AXI-Stream](#3-axi4-与-axi-stream)
4. UART（待写）
5. SPI（待写）
6. I2C（待写）
7. [运行全部实验](#7-运行全部实验)
8. [速查表](#8-速查表)

---

## 1. APB

### 1.1 解决什么问题，面试怎么考

SoC 里有大量低速外设：UART、SPI、I2C、GPIO、定时器、看门狗，以及各种 IP 的控制/状态寄存器。它们一次只读写一个 32 bit 寄存器，对带宽没有要求，但数量多、面积和功耗敏感。**APB（Advanced Peripheral Bus）** 就是为它们设计的：没有流水、没有 burst、只有一个主机（通常是 AHB/AXI 到 APB 的桥），协议简单到一个从机只需要几十行 RTL。

```
CPU ──AXI/AHB──► 桥（APB 主机）──APB──┬── UART 寄存器
                                    ├── SPI 寄存器
                                    └── GPIO / Timer / ...
         高速、流水                     低速、每笔 ≥ 2 拍
```

面试考法：

1. 画 APB 读写时序，说明 SETUP 和 ACCESS 阶段、PREADY 怎么插等待。
2. 手写一个 APB 从机（寄存器读写），常追问 W1C、只读寄存器、PSLVERR。
3. 为什么一笔 APB 传输至少 2 拍；APB 为什么不做流水。
4. APB2 / APB3 / APB4 的区别（每一代加了哪些信号）。

### 1.2 原理

**信号**（主机 → 从机，除非标注）：

| 信号 | 说明 | 引入版本 |
|------|------|----------|
| `PCLK` / `PRESETn` | 时钟、低有效复位 | APB2 |
| `PADDR` | 地址 | APB2 |
| `PSELx` | 从机选择，每个从机一根，由桥里的地址译码产生 | APB2 |
| `PENABLE` | 第二拍及以后为 1，标志进入 ACCESS 阶段 | APB2 |
| `PWRITE` | 1 = 写，0 = 读 | APB2 |
| `PWDATA` / `PRDATA` | 写数据 / 读数据（从机 → 主机） | APB2 |
| `PREADY` | 从机 → 主机，ACCESS 阶段为 0 表示插等待 | APB3 |
| `PSLVERR` | 从机 → 主机，传输出错 | APB3 |
| `PSTRB` | 写字节使能，每字节 1 bit；**读传输时必须为 0** | APB4 |
| `PPROT` | 保护属性（特权 / 安全 / 指令） | APB4 |

APB5 又加了 `PWAKEUP`、用户信号和奇偶校验等，面试一般只问到 APB4。

**两段式传输**：每笔传输分两个阶段。

- **SETUP**（1 拍）：`PSEL=1, PENABLE=0`，地址、方向、写数据放上总线。
- **ACCESS**（≥ 1 拍）：`PSEL=1, PENABLE=1`，从机用 `PREADY` 决定何时结束。`PREADY=0` 就是等待拍，这期间主机的所有信号必须保持不变。
- `PSEL & PENABLE & PREADY` 同为 1 的那个上升沿，传输完成：写数据在这个沿写入，读数据 `PRDATA` 和 `PSLVERR` 在这个沿被主机采样。

状态机（本章 `apb_master.v` 直接用 `{PSEL, PENABLE}` 当状态）：

```
            有命令                    （固定 1 拍）
  ┌──────┐ ────────► ┌───────┐ ─────────────────► ┌────────┐
  │ IDLE │           │ SETUP │                    │ ACCESS │ ◄─┐ PREADY=0（等待）
  └──────┘ ◄──────── └───────┘ ◄──────────────── └────────┘ ──┘
      ▲   PREADY=1 且没有新命令    PREADY=1 且还有命令（背靠背，不回 IDLE）
      └───────────────────────────────────────────────┘
```

**时序**（每列是一个时钟周期，"沿"指该周期结束时的上升沿）：

零等待写，接一个两拍等待的读（`WAIT=0` 写、`WAIT=2` 读只为了示意，实际一个从机的等待数固定）：

| 周期 | 1 | 2 | 3 | 4 | 5 | 6 |
|------|---|---|---|---|---|---|
| 阶段 | SETUP 写 | ACCESS 写 | SETUP 读 | ACCESS | ACCESS | ACCESS |
| PSEL | 1 | 1 | 1 | 1 | 1 | 1 |
| PENABLE | 0 | 1 | 0 | 1 | 1 | 1 |
| PWRITE | 1 | 1 | 0 | 0 | 0 | 0 |
| PADDR | A0 | A0 | A1 | A1 | A1 | A1 |
| PREADY | x | **1**（写入） | x | 0 | 0 | **1**（采样 PRDATA） |

- 第 2 周期末写入完成；第 3 周期直接进入下一笔的 SETUP，`PSEL` 保持为 1、`PENABLE` 回到 0。
- 读在第 4、5 周期被插了两个等待，第 6 周期末主机采样 `PRDATA`。
- **一笔传输至少 2 拍**，因为 SETUP 和 ACCESS 不能重叠；背靠背时吞吐是每笔 `2 + 等待数` 拍（第 1.4 节实测 2.00 / 4.00）。

**为什么要有 SETUP 阶段**：`PSEL` 和地址先稳定一拍，从机的地址译码、读 MUX 有一整拍时间建立；`PENABLE` 再告诉从机"现在执行"。这让从机可以做成纯组合译码 + 简单寄存器，并且只有被选中的从机在 ACCESS 拍才翻转，省功耗。代价是没法流水，所以 APB 只用在低带宽场合。

**PSLVERR**：只在传输的最后一拍（`PSEL & PENABLE & PREADY`）有意义，其它时候建议驱动为 0。常见用法：访问未映射地址、写只读寄存器、外设处于不能访问的状态。注意规范并不保证出错的写"一定没有改变外设状态"，出错语义由外设自己定义；本章从机的做法是写只读寄存器报错且不修改内容。

**寄存器的几种访问类型**（APB 从机面试常追问）：

| 类型 | 软件写 | 软件读 | 典型用途 |
|------|--------|--------|----------|
| RW | 按 PSTRB 写入 | 读回写入值 | 控制寄存器、配置 |
| RO | 无效（可报 PSLVERR） | 读硬件值 | 状态寄存器 |
| W1C（write 1 to clear） | 写 1 的位清零，写 0 不变 | 读当前值 | 中断状态：读出后把要清的位写回 1 |
| W1S / RC / WO | 写 1 置位 / 读后清零 / 只写 | — | 置位寄存器、FIFO 数据口、命令寄存器 |

W1C 的好处：软件"读—写回"就能清掉自己看到的那几位，**不会误清在读和写之间新来的中断**（那些位读的时候是 0，写回的也是 0）。如果用普通 RW 写 0 来清，读—改—写之间新置位的中断会被覆盖掉。

### 1.3 RTL 讲解

**主机**（`lab/APB/apb_master.v`）：命令口是 valid/ready，内部就是上面的三状态机。

```verilog
wire done = psel & penable & pready;        // 本拍 ACCESS 完成

// 总线空闲，或者当前传输这拍就结束，都能接新命令
assign cmd_ready = ~psel | done;
wire   cmd_fire  = cmd_valid & cmd_ready;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        psel    <= 1'b0;
        penable <= 1'b0;
    end else if (cmd_fire) begin            // IDLE/ACCESS 完成 → SETUP
        psel    <= 1'b1;
        penable <= 1'b0;
    end else if (psel & ~penable) begin     // SETUP → ACCESS
        penable <= 1'b1;
    end else if (done) begin                // ACCESS 完成且没有新命令 → IDLE
        psel    <= 1'b0;
        penable <= 1'b0;
    end
end

// 地址和控制只在接收命令时更新：SETUP 和整个 ACCESS（含等待）期间保持不变
always @(posedge clk) begin
    if (cmd_fire) begin
        paddr  <= cmd_addr;
        pwrite <= cmd_write;
        pwdata <= cmd_wdata;
        pstrb  <= cmd_write ? cmd_wstrb : {(DW/8){1'b0}};   // APB4：读传输 PSTRB 必须为 0
    end
end
```

- `cmd_ready = ~psel | done`：完成拍就能接下一条，下一拍直接是 SETUP，这就是背靠背不回 IDLE。
- 地址/数据寄存器只在 `cmd_fire` 时装载，所以 SETUP 和等待期间自然保持不变。变异 M2 把它改成 `if (cmd_valid)`，协议检查器立刻报 "addr/ctrl changed in SETUP/wait"。

**从机**（`lab/APB/apb_regs.v`）：5 个寄存器，覆盖 RW / RO / W1C 三种类型。

```verilog
// 等待状态：ACCESS 阶段数到 WAIT 才给 PREADY
wire access = psel & penable;
assign pready = (wcnt == WAIT_C);
always @(posedge pclk or negedge presetn) begin
    if (!presetn)              wcnt <= {CW{1'b0}};
    else if (access & pready)  wcnt <= {CW{1'b0}};
    else if (access)           wcnt <= wcnt + 1'b1;
end

wire xfer   = access & pready;              // 传输完成拍
wire wr     = xfer & pwrite;
wire bad_wr = pwrite & hit_stat;            // 写只读寄存器

// PSLVERR 只在传输完成拍有意义，其它时候保持 0
assign pslverr = xfer & (~hit_any | bad_wr);

// W1C：软件写 1 的位清零；硬件置位写在后面，同拍冲突时置位优先（不丢中断）
wire [31:0] w1c = (wr & hit_int) ? (pwdata & bmask) : 32'h0;
always @(posedge pclk or negedge presetn) begin
    if (!presetn) int_stat <= 32'h0;
    else          int_stat <= (int_stat & ~w1c) | irq_set_i;
end
```

- 写使能必须是 `psel & penable & pready`。只看 `psel & pwrite` 的写法（变异 M3）会在 SETUP 拍就执行写，零等待时每笔写提前一拍生效；寄存器最终值一样，但硬件侧 `ctrl_o` 早变一拍，testbench 逐拍比对 `ctrl_o` / `irq_o` 抓到了 434 处错误。
- 读数据 `prdata` 是组合 MUX（按 `paddr` 选寄存器），在完成拍被主机采样。时序紧张时也可以在 SETUP 拍就把读数据寄存起来，再用 `PREADY` 多给一拍。
- W1C 的冲突优先级：同一拍硬件置位、软件清零同一个 bit，要让置位赢，否则这次中断就丢了。变异 M1 把表达式改成 `(int_stat | irq_set_i) & ~w1c`（清零优先），testbench 报了 126 处读回不一致。

常见错误：

| 错误 | 后果 |
|------|------|
| 写使能用 `psel & pwrite`，不看 `penable` / `pready` | SETUP 拍就写；有等待时还会重复写；对 W1C、FIFO 数据口这类有副作用的寄存器是功能错误 |
| 读传输 `PSTRB` 不清零 | 违反 APB4 规范，严格的从机或 VIP 会报错 |
| 等待期间主机改地址 / 数据 | 从机采到的不是这笔传输的值 |
| 完成后 `PENABLE` 不拉低就开始下一笔 | 没有 SETUP 阶段，从机把下一笔当成前一笔的延续 |
| `PSLVERR` 在非完成拍乱跳 | 规范只要求完成拍有效，但很多桥 / VIP 建议其它时候为 0，便于调试 |
| W1C 用"写 0 清零"或清零优先 | 读—改—写之间新来的中断被清掉 |
| 未映射地址不报错、读回随机值 | 软件地址写错时很难排查 |

### 1.4 仿真

```bash
cd 12_Bus_Interfaces/lab/APB && bash run_sim.sh      # WAIT=0 和 WAIT=2 各跑一次
bash mutation.sh                                     # 3 个变异，应全部 FAIL
```

`tb_apb.v` 的检查分四层：

- **寄存器参考模型**：每个上升沿先用模型算期望的 `prdata` / `pslverr` 与总线比对，再按本拍的写和 `irq_set_i` 更新模型；另外逐拍比对硬件侧输出 `ctrl_o`、`irq_o`。
- **命令记录**：命令口握手时入队，总线传输完成时比对地址 / 方向 / 数据 / strobe，确认主机没把命令改掉。
- **响应记录**：总线完成时入队，`rsp_valid` 时比对，确认主机把结果正确带回。
- **协议检查**：SETUP 后必须是 ACCESS、SETUP 与等待期间信号不变、完成后 `PENABLE` 必须拉低、读传输 `PSTRB = 0`。

激励：定向阶段（复位值、只改一个字节、写只读、未映射、W1C 全清）→ 4000 笔随机（每笔后 40% 概率空闲 1–3 拍、1/6 未映射地址、约 44% 的写是部分 strobe，硬件侧每拍随机稀疏置位中断）→ 1000 笔背靠背。

```
===== tb_apb：WAIT=0 =====
------------------------------------------------------------
WAIT=0  reads=2462  writes=2549  wait_cycles=0
PSLVERR: unmapped=633  write-RO=427
W1C clears=444  set/clear same-cycle=211  partial PSTRB=893  irq_o cycles=11589
back-to-back: 1000 xfers, PSEL high 2000 cycles -> 2.00 cycles/xfer
------------------------------------------------------------
PASS
===== tb_apb：WAIT=2 =====
------------------------------------------------------------
WAIT=2  reads=2498  writes=2513  wait_cycles=10022
PSLVERR: unmapped=638  write-RO=421
W1C clears=432  set/clear same-cycle=198  partial PSTRB=860  irq_o cycles=20016
back-to-back: 1000 xfers, PSEL high 4000 cycles -> 4.00 cycles/xfer
------------------------------------------------------------
PASS
```

- 背靠背吞吐正好是每笔 `2 + WAIT` 拍：零等待 2.00，两拍等待 4.00。**APB 的理论上限就是 50% 总线利用率**（每 2 拍传 1 个字）。
- WAIT=2 时 `wait_cycles = 10022 = (2498 + 2513) 笔 × 2`，每笔正好被插了 2 拍等待。
- `set/clear same-cycle` 约 200 次：硬件置位和软件 W1C 恰好同拍撞在同一个 bit 上，覆盖到了优先级规则。

变异测试（`mutation.sh`）：

```
===== M1: W1C 清零优先于硬件置位 =====
ERROR @4075000: prdata mismatch
ERROR @4085000: rsp mismatch
FAIL (126 errors)
===== M2: 主机提前改地址 =====
ERROR @55000: addr/ctrl changed in SETUP/wait
ERROR @75000: bus xfer != issued cmd
FAIL (8884 errors)
===== M3: 从机在 SETUP 阶段写 =====
ERROR @95000: ctrl_o mismatch
ERROR @115000: ctrl_o mismatch
FAIL (434 errors)
```

M3 值得注意：寄存器最终内容完全正确，只靠总线读回是抓不到的；抓到它的是**逐拍比对硬件侧输出**。验证寄存器模块时，除了总线侧，还要检查寄存器"什么时候"对硬件生效。

波形（`apb.vcd`，最后一次运行是 WAIT=2）：看 `psel`、`penable`、`pready`、`u_slv.wcnt`，每笔传输 `psel` 高 4 拍：SETUP 1 拍 + ACCESS 3 拍（`wcnt` 0→1→2，等于 2 时 `pready=1`）。

### 1.5 变体与扩展

- **AHB/AXI → APB 桥**：桥是上游总线的从机、APB 的主机，内部就是本节的状态机加地址译码产生多根 `PSELx`。上游的一笔传输要等 APB 完成才能响应，所以桥会让上游插等待（AHB 拉低 `HREADYOUT`，AXI 推迟 `BVALID` / `RVALID`）。
- **跨时钟域 APB**：外设在慢时钟域时，桥里用握手同步（`../06_CDC/README.md` 第 4 节）把请求送过去，`PREADY` 等对面完成后再拉高。
- **寄存器生成**：工业上寄存器很少手写，常用 SystemRDL / IP-XACT 描述，再由工具生成 RTL、C 头文件、UVM 寄存器模型和文档，保证软硬件一致。具体工具以各团队流程为准。
- **读数据寄存**：读 MUX 很宽时，可以在 SETUP 拍就寄存读数据，零等待变一拍等待，换取更好的时序。
- **APB 的"AXI 化"**：需要更高带宽的外设（DMA 描述符、大缓冲区）不挂在 APB 上，而是直接挂 AXI4-Lite 或 AXI。

### 1.6 面试要点与常见追问

- **两段式**：SETUP 1 拍（`PSEL=1, PENABLE=0`）→ ACCESS ≥ 1 拍（`PENABLE=1`），`PSEL & PENABLE & PREADY` 的沿完成。背靠背不回 IDLE，每笔至少 2 拍。
- **PREADY**：只在 ACCESS 阶段被看；等待期间主机信号不变。
- **版本**：APB3 加 `PREADY` / `PSLVERR`，APB4 加 `PSTRB` / `PPROT`（读时 `PSTRB` 必须为 0）。
- **从机写使能** = `psel & penable & pready & pwrite`；**读数据**在完成拍有效。
- **W1C**：写 1 清零，与硬件置位冲突时置位优先；为什么比"写 0 清零"好——读和写之间新来的中断不会被误清。
- **追问：APB 为什么不做流水**——为低功耗、低面积、简单的外设设计，带宽需求低；要带宽就上 AHB/AXI。
- **追问：怎么验证一个寄存器模块**——参考模型 + 复位值检查 + 每种访问类型（RW/RO/W1C）+ 部分 strobe + 未映射地址 + 硬件侧输出逐拍比对 + 协议检查。

**一句话**：APB = SETUP 一拍 + ACCESS 若干拍，`PSEL & PENABLE & PREADY` 时完成，每笔至少 2 拍、利用率上限 50%；从机写使能要带上 `PENABLE` 和 `PREADY`，W1C 冲突时置位优先。

---

## 2. AHB

### 2.1 解决什么问题，面试怎么考

APB 每笔至少 2 拍，因为一笔传输的"送地址"和"送数据"不能重叠。**AHB（Advanced High-performance Bus）** 把它们拆成两级流水：第 n 笔的**数据阶段**和第 n+1 笔的**地址阶段**在同一拍进行，于是没有等待时每拍完成一笔，再加上 burst 描述连续地址。它是 Cortex-M 系列 MCU 的主力总线，在 AXI 普及前也是 SoC 主干总线。

面试考法：

1. 画 AHB 的地址/数据流水时序，解释 `HREADY` 拉低时哪些信号要保持。
2. `HTRANS` 四种取值（IDLE / BUSY / NONSEQ / SEQ）的含义；burst 类型、WRAP 地址怎么算、为什么不能跨 1KB。
3. `HREADY` 和 `HREADYOUT` 的区别；从机为什么必须看 `HREADY` 才采样地址。
4. 为什么 ERROR 响应要两拍。
5. 多从机：译码器和响应 MUX 怎么接，MUX 选择信号为什么要打一拍。
6. 多主机：AHB 仲裁（`HBUSREQ` / `HGRANT`），AHB-Lite 和多层互联（multi-layer）。

### 2.2 原理

**AHB 的几个版本**：AMBA 2 AHB 支持多主机，带仲裁信号和 SPLIT/RETRY 响应；AMBA 3 **AHB-Lite** 简化成单主机（多主机交给互联矩阵解决），这是现在最常用、面试最常考的形式；AMBA 5 AHB（AHB5）在 AHB-Lite 基础上加了安全、独占访问等扩展。下文以 AHB-Lite 为主。

**信号**：

| 信号 | 方向 | 说明 |
|------|------|------|
| `HADDR[31:0]` | M→S | 地址（地址阶段） |
| `HTRANS[1:0]` | M→S | 传输类型：IDLE=00、BUSY=01、NONSEQ=10、SEQ=11 |
| `HWRITE` | M→S | 1 = 写 |
| `HSIZE[2:0]` | M→S | 每拍字节数 = 2^HSIZE（000 字节、001 半字、010 字…） |
| `HBURST[2:0]` | M→S | SINGLE / INCR / WRAP4 / INCR4 / WRAP8 / INCR8 / WRAP16 / INCR16 |
| `HPROT`、`HMASTLOCK` | M→S | 保护属性、锁定传输 |
| `HWDATA` | M→S | 写数据（**数据阶段**） |
| `HSELx` | 译码器→S | 从机选择（地址阶段组合译码） |
| `HRDATA` | S→M | 读数据（数据阶段） |
| `HREADYOUT` | S→MUX | 本从机的"数据阶段可以结束" |
| `HREADY` | MUX→M 和所有 S | 全局 `HREADY`：当前数据阶段所在从机的 `HREADYOUT` |
| `HRESP` | S→M | 0 = OKAY，1 = ERROR（AHB-Lite 只有 1 bit） |

**两级流水**（每列一个周期；A/D 表示某笔的地址阶段 / 数据阶段）：

```
周期          1        2        3        4        5
HADDR      | A1     | A2     | A3     | A3     | —
HTRANS     | NONSEQ | SEQ    | SEQ    | SEQ    | IDLE
HWDATA     |        | D1     | D2     | D2     | D3
HREADY     | 1      | 1      | 0      | 1      | 1
             ─A1─── ─D1────
                    ─A2──── ─D2─────────────
                             ─A3───────────── ─D3───
```

- 周期 2：第 1 笔在数据阶段（`HWDATA=D1`），同时第 2 笔在地址阶段——两笔重叠，这就是流水。
- 周期 3：第 2 笔的从机拉低 `HREADY`（等待）。**数据阶段被拉长，下一笔的地址阶段也跟着被拉长**：`HADDR=A3` 和 `HWDATA=D2` 都必须保持到周期 4。
- 地址阶段在 `HREADY=1` 的沿才算完成；从机只有在 `HSEL & HREADY & HTRANS[1]` 时才能采样地址。

**`HREADY` 与 `HREADYOUT`**：每个从机输出自己的 `HREADYOUT`，互联按"当前数据阶段属于谁"选出一个作为全局 `HREADY`，再广播给主机和**所有**从机。从机必须看全局 `HREADY`：上一笔可能在另一个从机上被拉长，这时本从机虽然 `HSEL=1`，但地址阶段还没完成，不能采样。

**HTRANS**：

| 值 | 名称 | 含义 | 从机响应 |
|----|------|------|----------|
| 00 | IDLE | 没有传输 | 零等待 OKAY，忽略 |
| 01 | BUSY | burst 中间主机暂停一拍（地址已是下一拍的地址） | 零等待 OKAY，忽略 |
| 10 | NONSEQ | 单次传输，或 burst 的第一拍 | 执行 |
| 11 | SEQ | burst 的后续拍，地址 = 上一拍地址按规则递增 | 执行 |

从机只需要看 `HTRANS[1]` 判断"有没有传输"，一般不需要看 `HBURST`（地址每拍都给了）；`HBURST` 主要给需要预取的从机（如 Flash 控制器）和互联使用。

**Burst**：固定长度 4/8/16 拍，INCR 表示长度不定。每拍地址增加 2^HSIZE；WRAP 在 `拍数 × 每拍字节数` 对齐的窗口内回绕。例：WRAP4、字传输、起始 0x38，窗口 16 字节、基址 0x30，地址序列为 0x38 → 0x3C → 0x30 → 0x34。WRAP 适合 Cache 行填充：先取 CPU 要的那个字（critical word first），再回绕把整行取完。

**不能跨 1KB 边界**：AHB 规定 burst 不能跨越 1KB 地址边界。原因是从机的地址区间最小按 1KB 划分，SEQ 传输的地址不会重新做"这是不是换了从机"的判断，跨界就可能让一个 burst 的后半段打到别的从机上。

**ERROR 响应为什么两拍**：

```
周期        n          n+1         n+2
HREADY   |  0       |  1       |
HRESP    |  1(ERROR)|  1(ERROR)|  0
```

流水线里，从机给出 ERROR 时，主机已经把下一笔的地址放上总线了。第一拍 `HREADY=0` 把下一笔地址阶段"冻住"，给主机一拍时间决定是**继续**还是**取消**后续传输（取消就在这一拍把 `HTRANS` 改成 IDLE，这是等待期间允许改 `HTRANS` 的例外之一）；第二拍 `HREADY=1` 结束本笔。本章 BFM 选择继续。

**多从机互联**（AHB-Lite 单主机）：

```
            HADDR ──► 译码器 ──► HSEL0 / HSEL1 / HSEL_default
主机 ──地址/控制/HWDATA──────────────► 所有从机
     ◄─HRDATA/HREADY/HRESP── 响应 MUX ◄─ 各从机 HRDATA / HREADYOUT / HRESP
                               ▲
                     sel_dp（地址阶段完成时寄存的 HSEL）
```

- 译码器是纯组合的，按地址阶段的 `HADDR` 产生 `HSELx`；没有命中任何从机时选中**默认从机**，对 NONSEQ/SEQ 回两拍 ERROR。
- **响应 MUX 必须用数据阶段的选择**：`HRDATA` 属于上一拍地址阶段的那笔传输，而此刻 `HADDR` 已经是下一笔了。所以要在 `HREADY=1` 时把选择寄存成 `sel_dp`。这是面试和实际项目里都常见的错误（本节变异 M2）。

**多主机仲裁**：

- **AMBA 2 AHB**：每个主机有 `HBUSREQx`（请求）和 `HGRANTx`（授予），仲裁器按优先级或轮询（`../03_Common_Circuits/README.md` 第 7 节）选一个；被授予的主机在 `HREADY=1` 时接管地址总线，仲裁器同时输出 `HMASTER` 标识当前主机，写数据 MUX 用**打一拍的** `HMASTER` 选（道理同上：数据阶段落后地址阶段一拍）。`HLOCK` 用于锁定总线做原子操作；SPLIT/RETRY 让慢从机释放总线，多主机协议复杂度主要在这里。
- **AHB-Lite + 多层互联（multi-layer / bus matrix）**：每个主机一条独立的 AHB-Lite 层，互联在每个从机端口前放一个仲裁器。不同主机访问不同从机可以同时进行，只有争同一个从机时才仲裁，被挡住的主机看到的就是 `HREADY=0`。这比共享总线吞吐高，也把复杂度从协议挪到了互联里。

### 2.3 RTL 讲解

**SRAM 从机**（`lab/AHB/ahb_sram.v`）的三个关键点。

1）地址阶段采样，寄存到数据阶段：

```verilog
wire ap_valid = hsel & hready & htrans[1];      // 必须看全局 hready

always @(posedge hclk or negedge hresetn) begin
    if (!hresetn)    dp_valid <= 1'b0;
    else if (hready) dp_valid <= ap_valid;
end

always @(posedge hclk) begin
    if (ap_valid) begin
        dp_write <= hwrite;
        dp_widx  <= ap_widx;
        dp_be    <= byte_en(hsize, haddr[1:0]);   // 小端：HSIZE + 低位地址 → 字节使能
    end
end

assign hreadyout = ~(dp_valid & stall);         // 只在自己的数据阶段插等待
```

2）写：`HWDATA` 在数据阶段才到，所以在数据阶段的最后一拍写入。

```verilog
wire wr_commit = dp_valid & dp_write & hreadyout;
always @(posedge hclk)
    if (wr_commit) mem[dp_widx] <= (mem[dp_widx] & ~wmask) | (hwdata & wmask);
```

3）读：模仿真实 SRAM 的**同步读**——在地址阶段结束的沿就读出，数据阶段零等待给出 `HRDATA`。这带来一个冒险：写 A 的数据阶段和读 A 的地址阶段在**同一个沿**完成，读出的是旧值。所以要做写后读旁路：

```verilog
wire        raw    = wr_commit & (dp_widx == ap_widx);
wire [31:0] rd_mem = mem[ap_widx];
always @(posedge hclk)
    if (ap_valid & ~hwrite)
        rdata_q <= raw ? ((rd_mem & ~wmask) | (hwdata & wmask)) : rd_mem;
```

这里的存储是触发器阵列（相当于 1R1W，能同时读写）。如果换成**单口 SRAM 宏**，同一拍根本不能又读又写，常见做法是：写先进一个写缓冲，等总线空闲拍再写进 SRAM，读时和写缓冲比地址做旁路；或者干脆在写后紧跟读时插一拍等待。这是 AHB SRAM 控制器面试的经典追问。

**互联**（`lab/AHB/ahb_decoder_mux.v`）：

```verilog
assign hsel0 = ((haddr & S0_MASK) == S0_BASE);
assign hsel1 = ((haddr & S1_MASK) == S1_BASE);

wire [1:0] sel_ap = hsel0 ? SEL_S0 : hsel1 ? SEL_S1 : SEL_DEF;
always @(posedge hclk or negedge hresetn) begin
    if (!hresetn)    sel_dp <= SEL_NONE;
    else if (hready) sel_dp <= sel_ap;          // 地址阶段完成时寄存
end

// 默认从机：第 1 拍 HREADY=0 HRESP=1，第 2 拍 HREADY=1 HRESP=1
always @(posedge hclk or negedge hresetn) begin
    if (!hresetn)       begin err1 <= 1'b0; err2 <= 1'b0; end
    else if (err1)      begin err1 <= 1'b0; err2 <= 1'b1; end
    else if (hready)    begin err2 <= 1'b0; err1 <= hsel_def & htrans[1]; end
end

always @(*) begin
    case (sel_dp)                               // 按数据阶段选择
        SEL_S0:  begin hready = hreadyout0; hresp = hresp0;      hrdata = hrdata0; end
        SEL_S1:  begin hready = hreadyout1; hresp = hresp1;      hrdata = hrdata1; end
        SEL_DEF: begin hready = ~err1;      hresp = err1 | err2; hrdata = 32'h0;   end
        default: begin hready = 1'b1;       hresp = 1'b0;        hrdata = 32'h0;   end
    endcase
end
```

复位时 `sel_dp = SEL_NONE`，保证复位后 `HREADY=1`（没有进行中的数据阶段）。

常见错误：

| 错误 | 后果 |
|------|------|
| 从机只看 `HSEL & HTRANS[1]` 采样地址，不看 `HREADY` | 前一笔在别的从机上等待时，本从机重复采样同一笔，写两次或读错 |
| 在地址阶段就用 `HWDATA` 写 | `HWDATA` 在数据阶段才有效，写进去的是上一笔的数据 |
| 响应 MUX 用地址阶段的组合 `HSEL` 选 | 连续访问不同从机时拿到下一个从机的数据（变异 M2：3506 处错误） |
| 同步读不做写后读旁路 | 写后紧跟读同一个字，读到旧值（变异 M1：237 处错误） |
| 等待期间主机改地址 / 控制 / 写数据 | 从机数据阶段看到的 `HWDATA` 不对；下一笔地址被改掉 |
| ERROR 只给一拍 | 主机没有机会取消已经在总线上的下一笔 |
| 对 IDLE / BUSY 插等待或回 ERROR | 违反规范：它们必须零等待 OKAY |
| INCR burst 跨 1KB | 后半段可能打到别的从机 |

### 2.4 仿真

```bash
cd 12_Bus_Interfaces/lab/AHB && bash run_sim.sh
bash mutation.sh
```

`tb_ahb.v` 结构：

- **主机 BFM**：先把 4000 个 burst 展开成"地址阶段条目表"（IDLE / BUSY / NONSEQ / SEQ）。`HREADY=1` 的沿上，当前地址阶段条目进入数据阶段、下一个条目上地址总线；`HREADY=0` 时全部保持。burst 覆盖 8 种 `HBURST` × byte/half/word，INCR 不跨 1KB，burst 中随机插 BUSY；40% 的写 burst 后面**紧跟**同地址读回，专门制造写后读冒险。
- **从机配置**：S0（4KB）每拍 25% 概率插等待，S1（1KB）零等待，0x2000 以上未映射 → 默认从机 ERROR。两块 SRAM 和参考模型预置相同的随机内容，保证每次读都有确定的期望值。
- **检查**：字节级参考模型比对读数据（只比 `HSIZE` 和低位地址决定的有效字节）；映射地址必须 OKAY、未映射必须 ERROR；ERROR 必须两拍；IDLE/BUSY 必须零等待 OKAY。

```
===== tb_ahb =====
------------------------------------------------------------------
items=34806  bursts=4000  SINGLE=545 INCR=531 WRAP4=504 INCR4=481 WRAP8=510 INCR8=502 WRAP16=457 INCR16=470
beats=29841 (write 10812, read 16246, ERROR 2783)  checked bytes=38435
cycles=42123  wait=7313  BUSY=3265  IDLE=1703  RAW same-word back-to-back=216
bus efficiency = beats / cycles = 0.708
------------------------------------------------------------------
PASS
```

- **每一拍要么完成一个 beat，要么是等待、BUSY 或 IDLE**：29841 + 7313 + 3265 + 1703 = 42122，与总周期 42123 只差统计边界上的 1 拍。也就是说，除去这三类"主动不传"的拍，AHB 流水是**每拍一个 beat**，这正是它相对 APB（每拍半个）的提升。
- 等待 7313 拍 = 2783 个 ERROR 的第一拍 + 4530 拍 S0 随机等待。
- 216 次"写数据阶段与同字读地址阶段在同一沿完成"，全部靠旁路读到了新值。

变异测试：

```
===== M1: 去掉写后读旁路 =====
ERROR @1215000: read data mismatch (item 101 addr 00000b28)
ERROR @2595000: read data mismatch (item 212 addr 000012a1)
FAIL (237 errors)
===== M2: 响应 MUX 用地址阶段选择 =====
ERROR @425000: read data mismatch (item 33 addr 00001370)
ERROR @425000: read data mismatch (item 33 addr 00001370)
FAIL (3506 errors)
```

M1 只在"写后紧跟同字读"时出错，如果 testbench 不刻意制造这种背靠背读回，随机地址几乎撞不上——**冒险类 bug 要有针对性的激励**。

波形（`ahb.vcd`）：看 `haddr`、`htrans`、`hready`、`hwdata`、`hrdata`、`u_ic.sel_dp`、`u_s0.dp_valid`、`u_s0.raw`。S0 插等待时能看到 `haddr` 和 `hwdata` 一起被冻住；`u_s0.raw=1` 的拍就是旁路生效的时刻。

### 2.5 变体与扩展

- **AHB → APB 桥**：见第 1.5 节；AHB 侧在 APB 完成前拉低 `HREADYOUT`。
- **写缓冲 SRAM 控制器**：适配单口 SRAM，见第 2.3 节。
- **Flash / 慢速存储控制器**：利用 `HBURST` 做预取，WRAP 用于 Cache 行填充。
- **多层互联**：每个从机端口一个仲裁器 + 各主机层的地址译码，ARM 的 AHB bus matrix IP 是典型实现。
- **AHB5**：增加安全属性（`HNONSEC`）、独占访问（`HEXCL` / `HEXOKAY`）等，细节以 AMBA 5 AHB 规范为准。
- **HSIZE 大于数据宽度、非对齐访问**：AHB 要求传输按 `HSIZE` 对齐，这点与 AXI 不同（AXI 允许首拍非对齐，见第 3 节）。

### 2.6 面试要点与常见追问

- **两级流水**：第 n 笔数据阶段与第 n+1 笔地址阶段重叠；`HREADY=0` 同时拉长当前数据阶段和下一笔地址阶段，地址 / 控制 / `HWDATA` 全部保持。
- **从机采样条件**：`HSEL & HREADY & HTRANS[1]`；写在数据阶段最后一拍（`HREADYOUT=1`）用 `HWDATA`。
- **HTRANS**：IDLE / BUSY 零等待 OKAY 忽略；NONSEQ 开始，SEQ 继续。
- **Burst**：地址按 2^HSIZE 递增，WRAP 在"拍数 × 字节数"窗口回绕；不能跨 1KB。
- **ERROR 两拍**：第一拍 `HREADY=0` 给主机取消下一笔的机会。
- **响应 MUX 用打一拍的选择**；未映射地址由默认从机回 ERROR。
- **追问：AHB 和 APB 比**——AHB 流水、burst、每拍一个 beat，APB 每笔 2 拍、无流水；AHB 从机更复杂，APB 从机几十行。
- **追问：AHB 的瓶颈**——读写共用一套地址 / 数据流水，一次只能有一笔在数据阶段；一个慢从机拉低 `HREADY` 会卡住整条总线（多层互联只能缓解不同从机之间的冲突）；没有 outstanding。这些正是 AXI 要解决的。
- **追问：同步读 SRAM 挂 AHB 的冒险**——写后紧跟读同地址，读和写在同一沿，需要旁路；单口 SRAM 要写缓冲或插等待。

**一句话**：AHB 把地址和数据拆成两级流水，`HREADY` 同时冻结两级，从机在 `HSEL & HREADY & HTRANS[1]` 时采样、在数据阶段末尾用 `HWDATA`；响应 MUX 按数据阶段选择，ERROR 两拍，burst 不跨 1KB。

---

## 3. AXI4 与 AXI-Stream

### 3.1 解决什么问题，面试怎么考

AHB 的瓶颈在于：读和写共用一条流水，同一时刻只有一笔在数据阶段；一个慢从机会卡住所有人；主机发出请求后必须等数据回来才能继续。**AXI（Advanced eXtensible Interface）** 的解法是：

- **拆成五个独立通道**：写地址 AW、写数据 W、写响应 B、读地址 AR、读数据 R，每个通道都是独立的 valid/ready 握手，读写可以同时进行。
- **地址和数据解耦**：一个 burst 只发一次地址，数据可以晚很多拍才回来；主机不用等，可以接着发下一笔地址——这就是 **outstanding**（多笔在途）。
- **ID**：每笔带 ID，不同 ID 的响应可以**乱序**返回，慢从机不会挡住快从机。

AXI 是现在 SoC 的主干总线，面试必考。考法：

1. 五个通道各有哪些信号；握手规则，尤其是 valid 和 ready 的**依赖关系**（为什么能防死锁）。
2. burst 类型 FIXED / INCR / WRAP，地址怎么算；为什么不能跨 4KB；窄传输、非对齐、WSTRB。
3. outstanding 和乱序：ID 的规则是什么，同 ID 必须保序；outstanding 为什么能提高吞吐。
4. AXI3 / AXI4 / AXI4-Lite 的区别；AXI-Stream 的信号。
5. 手写 AXI4-Lite 或 AXI4 从机；写数据先于写地址到达怎么办。

### 3.2 原理

**五个通道**：

```
            主机                                   从机
   ┌─────────────────┐   AW：AWID AWADDR AWLEN     ┌─────────────────┐
   │                 │ ──  AWSIZE AWBURST ... ──►  │                 │
   │   写            │   W ：WDATA WSTRB WLAST     │                 │
   │                 │ ─────────────────────────►  │                 │
   │                 │   B ：BID BRESP             │                 │
   │                 │ ◄─────────────────────────  │                 │
   │                 │   AR：ARID ARADDR ARLEN ... │                 │
   │   读            │ ─────────────────────────►  │                 │
   │                 │   R ：RID RDATA RRESP RLAST │                 │
   │                 │ ◄─────────────────────────  │                 │
   └─────────────────┘  （每个通道都有 VALID/READY）└─────────────────┘
```

| 通道 | 主要信号 | 方向 |
|------|----------|------|
| AW | `AWID` `AWADDR` `AWLEN`（拍数−1） `AWSIZE`（2^n 字节/拍） `AWBURST` `AWLOCK` `AWCACHE` `AWPROT` `AWQOS` `AWREGION` | M→S |
| W | `WDATA` `WSTRB`（字节使能） `WLAST` | M→S |
| B | `BID` `BRESP` | S→M |
| AR | 同 AW（`AR` 前缀） | M→S |
| R | `RID` `RDATA` `RRESP` `RLAST` | S→M |

写要三个通道：地址、数据分开发，最后从机回一个 B 表示整个 burst 写完。读只要两个通道：R 通道每拍都带响应。

**握手规则**：每个通道的规则与 `../03_Common_Circuits/README.md` 第 8 节完全一致——`VALID && READY` 的沿传输；`VALID` 拉高后在握手前不能撤、负载不能变；**`VALID` 不能依赖 `READY`**，`READY` 可以依赖 `VALID`。

**通道之间的依赖**（规范规定的，面试常问）：

- 主机**不能**等 `AWREADY` 或 `WREADY` 才拉 `AWVALID` / `WVALID`；也就是说 W 可以先于 AW 发出。
- 从机**可以**等 `AWVALID` 和/或 `WVALID` 到了再给 `AWREADY` / `WREADY`（本章从机就是 AW 没到时 `WREADY=0`）。
- `BVALID` 必须在**最后一拍 W 握手之后**（AXI4 还要求在 AW 握手之后）。
- `RVALID` 必须在对应的 AR 握手之后。

为什么这么规定：如果允许主机"等 `AWREADY` 才发 W"，而从机"等 W 到了才给 `AWREADY`"，双方互等就死锁。规定"发起方的 VALID 不许等 READY"，就保证了至少有一方先动。

**Burst**：

| `AxBURST` | 名称 | 地址 | 长度（AXI4） | 用途 |
|-----------|------|------|-------------|------|
| 00 | FIXED | 每拍相同 | 1–16 | FIFO 型外设（反复读写同一个数据口） |
| 01 | INCR | 每拍 +2^SIZE | 1–256 | 普通连续访问、DMA |
| 10 | WRAP | 在窗口内回绕 | 2 / 4 / 8 / 16 | Cache 行填充（critical word first） |

- 拍数 = `AxLEN + 1`，每拍字节数 = 2^`AxSIZE`，不能超过数据总线宽度。
- **INCR**：第一拍地址可以不对齐，之后每拍先按 SIZE 对齐再递增：`next = (addr & ~(bytes-1)) + bytes`。
- **WRAP**：起始地址必须按 SIZE 对齐；窗口 = `(AxLEN+1) × 2^AxSIZE`；`next = (addr & ~mask) | ((addr + bytes) & mask)`，`mask = 窗口 − 1`。例：WRAP、4 拍、字传输、起始 0x38 → 窗口 16 字节，地址 0x38、0x3C、0x30、0x34。
- **不能跨 4KB 边界**：AXI 从机的最小地址区间按 4KB 划分（也是常见的页大小），互联只按第一拍地址路由整个 burst，跨界会让后半段打到错误的从机上。所以 DMA 引擎要在 4KB 边界处把 burst 拆开。

**窄传输与非对齐**（32 bit 总线，小端，字节通道 0–3）：

| 传输 | 各拍地址 | 各拍有效字节通道（`WSTRB`） |
|------|----------|------------------------------|
| INCR，SIZE=字节，起始 0x101，4 拍 | 0x101, 0x102, 0x103, 0x104 | 0010, 0100, 1000, 0001 |
| INCR，SIZE=字，起始 0x103，3 拍（非对齐） | 0x103, 0x104, 0x108 | 1000, 1111, 1111 |

- 窄传输（SIZE < 总线宽度）：每拍只用一部分字节通道，通道随地址移动。
- 非对齐：第一拍只传从起始地址到"按 SIZE 对齐的块末尾"的那几个字节，之后对齐。
- **写靠 `WSTRB` 决定写哪些字节**，从机不需要自己算通道；读时从机可以返回整个字，主机按地址取有效字节（本章从机就是这样）。`WSTRB` 也可以在有效通道内进一步置 0（只写部分字节）。

**响应**：`xRESP` = OKAY(00) / EXOKAY(01，独占访问成功) / SLVERR(10，从机报错) / DECERR(11，互联译码不到从机，通常由默认从机返回)。

**ID、outstanding 与乱序**：

- **outstanding**：主机发出地址后不必等数据/响应回来就能发下一笔。能有多少笔在途，取决于主机的发起能力和从机/互联的接收能力（本章从机的命令队列深 4）。
- **吞吐为什么提高**：一笔读从发 AR 到拿到数据有固定的往返延迟 L。只允许 1 笔在途时，每 L 拍最多拿到一个 burst；允许 N 笔在途时，N 笔的延迟互相重叠。粗略地说，吞吐 ≈ min(1, N × 每笔拍数 / 往返延迟)。第 3.4 节实测：单拍读往返 3 拍，1 笔在途只有 0.333 拍/周期，4 笔在途 0.997。
- **ID 规则**：**同一个 ID 的响应必须按发出顺序返回**；不同 ID 之间可以乱序。AXI4 读数据还允许不同 ID 的 beat 交织（interleave）；写数据在 AXI4 中**不允许交织**（AXI3 的 `WID` 被去掉了），W 必须按 AW 的顺序发送。
- **为什么要乱序**：互联把一个主机的请求分发给快慢不同的从机，如果必须全局保序，快从机的数据要等慢从机。给它们不同 ID，快的先回。主机要么给每个 ID 准备独立的接收队列，要么用重排序缓冲（ROB）。
- **读写通道之间没有顺序保证**：先发写、后发读同一地址，读可能读到旧值。需要顺序时主机要等 B 回来再发读。本章 testbench 用"按字加锁"来绕开这个不确定性（见第 3.4 节）。

**AXI3 / AXI4 / AXI4-Lite**：

| | AXI3 | AXI4 | AXI4-Lite |
|--|------|------|-----------|
| INCR 最大长度 | 16 | 256 | 1（无 burst） |
| 写数据交织（`WID`） | 有 | 去掉 | — |
| `AxQOS` / `AxREGION` / `xUSER` | 无 | 有 | 无 |
| 锁定传输 | locked + exclusive | 只保留 exclusive | 无 |
| 数据宽度 | 任意 | 任意 | 32 或 64 |
| 典型用途 | 老 IP | 存储、DMA、主干 | 寄存器配置口（替代 APB 的高性能版） |

AXI4-Lite 就是"每笔一拍、全宽度、没有 ID 和 burst"的 AXI4，五通道和握手规则不变，写一个 AXI4-Lite 从机是很常见的面试题：把本章 `axi_ram.v` 的 burst 计数和地址递增去掉就是。

**AXI4-Stream**：没有地址的单向数据流接口，只有一个通道（主机 → 从机）。

| 信号 | 说明 |
|------|------|
| `TVALID` / `TREADY` | 握手，规则同上 |
| `TDATA` | 数据 |
| `TSTRB` | 字节是数据字节（1）还是位置字节（0） |
| `TKEEP` | 字节是否有效；`TKEEP=0` 的字节是空字节，可以被丢弃（常用于包尾不满一个字） |
| `TLAST` | 包（packet / frame）的最后一拍 |
| `TID` / `TDEST` | 流标识 / 路由目的地 |
| `TUSER` | 用户自定义边带信息（如包头标记、错误标志） |

AXI-Stream 用在数据通路：视频像素流、网络包、DSP 流水线、DMA 的 MM2S / S2MM 端口。它的所有设计要点（打一拍不断流、skid buffer、带 `last` / `keep` 的位宽转换）在第 03 章已经有可运行的实现，直接看：

- valid/ready 打一拍：`../03_Common_Circuits/README.md` 第 8 节（`lab/Handshake/`）
- skid buffer 与流水线反压：同上第 13 节（`lab/Pipeline_Skid/`）
- 窄转宽 / 宽转窄带 last、keep：同上第 14 节（`lab/Width_Conv/`）

### 3.3 RTL 讲解

`lab/AXI/axi_ram.v` 是一个 32 bit、4KB 的 AXI4 RAM 从机，结构如下：

```
AW ──► [AW 队列 深4] ──► 写引擎（队头命令 + 拍计数 + 地址递增）──► mem ◄── W
                                  │ 最后一拍写完
                                  ▼
                            [B 队列 深4] ──► B

AR ──► [AR 队列 深4] ──► 读引擎（队头命令 + 拍计数 + 地址递增）──► R 输出寄存器 ──► R
```

**地址递增**（三种 burst 共用一个函数）：

```verilog
function [AW-1:0] next_addr(input [AW-1:0] a, input [2:0] size, input [7:0] len, input [1:0] burst);
    reg [AW-1:0] bytes, wmask;
    begin
        bytes = {{(AW-1){1'b0}}, 1'b1} << size;
        wmask = (({{(AW-8){1'b0}}, len} + 1'b1) << size) - 1'b1;     // 窗口 = (len+1) × 字节数
        case (burst)
            FIXED:   next_addr = a;
            WRAP:    next_addr = (a & ~wmask) | ((a + bytes) & wmask);
            default: next_addr = (a & ~(bytes - 1'b1)) + bytes;     // INCR：先对齐再加
        endcase
    end
endfunction
```

变异 M1 把窗口算成 `len × 字节数`（少了 +1），WRAP 读回立刻不对（5858 处错误）。

**写通道**：

```verilog
wire [AW-1:0] w_addr      = w_first ? wc_addr : w_addr_q;   // 首拍用命令里的地址
wire          w_last_beat = (w_cnt == wc_len);

assign awready = ~awq_full;
assign wready  = ~awq_empty & ~bq_full;     // 有命令、B 队列有空位才收数据
wire   w_hs      = wvalid & wready;
wire   w_last_hs = w_hs & w_last_beat;
wire   w_err_now = w_err | (wlast != w_last_beat);

// AW 队列在最后一拍出队；B 队列在最后一拍入队
axi_fifo #(.W(CW), .AW(QAW)) u_awq (... .push(awvalid & awready), ... .pop(w_last_hs), ...);
axi_fifo #(.W(IDW + 2), .AW(QAW)) u_bq (
    .push(w_last_hs), .din({wc_id, (w_err_now ? SLVERR : OKAY)}), ...
    .pop(bvalid & bready), ...);
```

- **W 先于 AW 到达**：`wready` 要求 AW 队列非空，AW 没到时 W 就在总线上等着——规范允许从机这样做，主机则必须照常把 `WVALID` 拉起来。
- **B 在 WLAST 之后**：B 由最后一拍写握手压进队列，下一拍才可能出现 `BVALID`，天然满足依赖。变异 M2 改成每拍都压 B，协议检查器报 "B before its AW/WLAST"。
- **拍数以 `AWLEN` 为准**，`WLAST` 和计数不一致时回 SLVERR，比"相信 `WLAST`"更稳健。
- 写 `B` 队列满时停收 W，保证 B 永远有地方放。

**读通道**：R 输出是一级寄存器，只有"输出空或本拍被取走"时才装下一拍：

```verilog
wire r_load = ~arq_empty & (~rvalid | rready);

always @(posedge aclk or negedge aresetn) begin
    if (!aresetn)    rvalid <= 1'b0;
    else if (r_load) rvalid <= 1'b1;
    else if (rready) rvalid <= 1'b0;
end

always @(posedge aclk) begin
    if (r_load) begin
        rdata    <= mem[r_addr[AW-1:2]];    // 窄传输也返回整个字，主机按地址取字节
        rid      <= rc_id;
        rlast    <= r_last_beat;
        r_addr_q <= next_addr(r_addr, rc_size, rc_len, rc_burst);
    end
end
```

这就是第 03 章第 8 节"不断流的寄存器级"：`RREADY` 一直为 1 时每拍出一个 beat；被反压时 `RDATA` 保持不变。注意 `RDATA` 必须寄存：如果直接组合输出 `mem[r_addr]`，反压期间另一个通道恰好写了这个地址，`RDATA` 就会在 `RVALID` 保持期间变化，违反协议。变异 M3 把 `r_load` 改成不看 `rready`，协议检查器报 "R dropped/changed while stalled"，接着丢拍导致看门狗超时。

**这个从机没做的事**（面试可以主动说明取舍）：按接收顺序返回，没有乱序（对任何 ID 组合都合法）；读和写各自独立，不保证读写之间的顺序（AXI 本来也不保证）；没有 exclusive 访问；R 通道只有一级寄存器，时序上 `RREADY → r_load → 读地址` 是组合路径，要切断可以再加 skid buffer。

常见错误：

| 错误 | 后果 |
|------|------|
| 主机等 `AWREADY` 再发 W，从机又等 W 再给 `AWREADY` | 死锁 |
| `BVALID` 在 AW 握手时就给 | 数据还没写完就回响应，主机以为写完了（变异 M2） |
| R 输出不等 `RREADY` 就换下一拍 | 反压时数据被覆盖、丢拍（变异 M3） |
| `RDATA` 直接组合读存储 | 反压期间被并发写改变，违反"负载不变" |
| WRAP 窗口用 `len` 而不是 `len+1`；INCR 不先对齐 | 地址序列错误（变异 M1） |
| 忽略 `WSTRB`，窄传输写整个字 | 把相邻字节写坏 |
| 同一个 ID 乱序返回 | 违反规范，主机按顺序匹配会把数据对错 |
| 主机不拆分跨 4KB 的 burst | 后半段打到错误的从机 |
| 以为先发的写一定比后发的读先完成 | 读写通道之间没有顺序，要等 B |

### 3.4 仿真

```bash
cd 12_Bus_Interfaces/lab/AXI && bash run_sim.sh      # MAX_OUT=1 和 MAX_OUT=4 各跑一次
bash mutation.sh
```

`tb_axi.v` 的设计：

- **主机**：生成器把一笔写拆成 1 条 AW + N 拍 W 分别放进两个队列，一笔读放进 AR 队列；AW / W / AR 三个驱动各自随机延迟拉 `VALID`，互不等待，所以 W 经常先于 AW 出现。`RREADY` / `BREADY` 随机。主机最多有 `MAX_OUT` 笔写、`MAX_OUT` 笔读在途。
- **随机 burst**：FIXED 20%（1–8 拍）、WRAP 30%（2/4/8/16 拍）、INCR 50%（1–32 拍）；SIZE 随机字节 / 半字 / 字；INCR/FIXED 有 25% 非对齐；20% 的写拍只写部分字节；INCR 不跨 4KB；ID 随机 0–3。
- **参考模型与锁**：字节数组，写在"发出"时就更新。因为读写通道之间没有顺序，模型按字加锁：在途写覆盖的字不许再发读或写，在途读覆盖的字不许发写（`lock-retry` 是被锁挡回去的次数）。这样模型在任何时刻都是确定的。
- **记分板**：按 ID 排队。R 到来时按 `RID` 找该 ID 最早的在途读，逐拍比对有效字节和 `RLAST` 位置；B 按 `BID` 找该 ID 最早的在途写。这是按规范写的检查——即使从机做了乱序（不同 ID），记分板也能正确匹配。
- **协议检查**：五个通道 `VALID` 拉高后握手前不许撤、负载不许变；第 k 个 B 之前必须已有 k 个 AW 握手和 k 个 WLAST 握手。另有看门狗，丢拍导致卡死时报超时。
- **阶段**：P1 随机混合 1500 写 + 1500 读；P2–P5 所有 `VALID` / `READY` 恒为 1，测单拍和 16 拍 burst 的读写吞吐。

```
===== tb_axi：主机 outstanding 上限 MAX_OUT=1 =====
---------------------------------------------------------------
MAX_OUT=1 (slave queue depth 4)
P1 random mixed      | beats  34281 | cycles  30025 | beats/cycle 1.142
  P1 bursts: FIXED=602 INCR=1479 WRAP=919  narrow=2012 unaligned=184 lock-retry=45
  P1 W-before-AW cycles=1682  max outstanding at slave: read=1 write=1
P2 read  len=0       | beats   1000 | cycles   3001 | beats/cycle 0.333
P3 read  len=15      | beats   3200 | cycles   3601 | beats/cycle 0.889
P4 write len=0       | beats   1000 | cycles   3001 | beats/cycle 0.333
P5 write len=15      | beats   3200 | cycles   3601 | beats/cycle 0.889
checked read bytes=54602  max outstanding at slave (all phases): read=1 write=1
---------------------------------------------------------------
PASS
===== tb_axi：主机 outstanding 上限 MAX_OUT=4 =====
---------------------------------------------------------------
MAX_OUT=4 (slave queue depth 4)
P1 random mixed      | beats  33583 | cycles  24149 | beats/cycle 1.391
  P1 bursts: FIXED=629 INCR=1476 WRAP=895  narrow=2029 unaligned=207 lock-retry=236
  P1 W-before-AW cycles=4  max outstanding at slave: read=4 write=4
P2 read  len=0       | beats   1000 | cycles   1003 | beats/cycle 0.997
P3 read  len=15      | beats   3200 | cycles   3203 | beats/cycle 0.999
P4 write len=0       | beats   1000 | cycles   1004 | beats/cycle 0.996
P5 write len=15      | beats   3200 | cycles   3203 | beats/cycle 0.999
checked read bytes=54207  max outstanding at slave (all phases): read=4 write=4
---------------------------------------------------------------
PASS
```

把吞吐整理出来：

| 场景 | 1 笔在途 | 4 笔在途 |
|------|----------|----------|
| 单拍读 | 0.333 | 0.997 |
| 16 拍读 | 0.889 | 0.999 |
| 单拍写 | 0.333 | 0.996 |
| 16 拍写 | 0.889 | 0.999 |
| 随机读写混合 | 1.142 | 1.391 |

- **1 笔在途时，单拍读每 3 拍才完成一笔**：主机发 AR（第 1 拍握手）→ 从机装 R 寄存器（第 2 拍）→ R 握手（第 3 拍），主机看到 `RLAST` 才能发下一笔。3001 拍 / 1000 笔正好是 3 拍往返。
- **16 拍 burst 能摊薄往返延迟**：每笔 16 拍数据 + 2 拍空泡 = 18 拍，16/18 = 0.889（3601 拍 / 200 笔 ≈ 18）。这就是"burst 越长效率越高"的定量版本。
- **4 笔在途把往返延迟完全藏起来**：后面的 AR 在前面的 R 还没回来时就已经进了从机队列，读引擎每拍都有活干，接近每拍 1 个 beat。
- **随机混合超过 1 拍/周期**：读和写是独立通道，可以同一拍各传一个 beat，理论上限是 2。这是 AXI 相对 AHB 的另一个本质提升（AHB 同一拍只有一笔在数据阶段）。
- `W-before-AW` 在 1 笔在途时有 1682 拍，4 笔在途时只有 4 拍：前者每笔都从空闲开始，W 和 AW 同时出发，W 常常先到；后者 AW 早早进了队列，W 到的时候 AW 通常已经握手了。两种情况从机都正确处理了。

变异测试：

```
===== M1: WRAP 窗口少一拍 =====
ERROR @715000: RDATA mismatch
ERROR @745000: RDATA mismatch
FAIL (5858 errors)
===== M2: 每拍都回 B =====
ERROR @95000: B before its AW/WLAST
ERROR @115000: B before its AW/WLAST
FAIL (45056 errors)
===== M3: R 输出不等 RREADY =====
ERROR @115000: R dropped/changed while stalled
ERROR @145000: RDATA mismatch
FAIL (58 errors + timeout)
```

M3 第一次跑时 testbench 没有看门狗，丢拍后在途计数永远清不了零，仿真一直挂着。**总线 testbench 一定要有超时**，否则"丢数据"这类最严重的 bug 表现为仿真不结束，而不是 FAIL。

波形（`axi.vcd`，最后一次运行是 MAX_OUT=4）：看五个通道的 `*valid` / `*ready`、`u_dut.awq_empty`、`u_dut.arq_empty`、`u_dut.r_cnt`。P2 阶段 `arvalid`、`rvalid` 连续为 1；把 MAX_OUT 改成 1 重跑，能看到 `rvalid` 每 3 拍才亮一次。

### 3.5 变体与扩展

- **AXI4-Lite 从机**：去掉拍计数和地址递增，每笔一拍；寄存器模块常用 AXI4-Lite 代替 APB 以获得独立读写通道。
- **乱序从机 / 重排序缓冲**：多个存储 bank 并行处理不同 ID 的请求，谁先好谁先回；主机侧用 ROB 按 ID 还原顺序。DDR 控制器是典型的乱序从机（按 bank / row 命中重排）。
- **互联（crossbar / interconnect）**：每个主机端口做地址译码，每个从机端口做仲裁；为了区分响应属于哪个主机，互联会在 ID 高位拼上主机编号。同 ID 在途请求发往不同从机时，互联必须阻塞或保序，这是 AXI 互联设计的难点。
- **register slice**：在长距离通道上插寄存器切断时序，就是第 03 章的 pipe stage / skid buffer 应用到五个通道上。
- **位宽 / 协议转换**：64↔32 bit 宽度转换、AXI → AHB / APB 桥、AXI3 ↔ AXI4 转换（拆分长 burst、处理 `WID`）。
- **跨时钟域**：每个通道用一个异步 FIFO（`../03_Common_Circuits/README.md` 第 1 节），五个通道五个 FIFO。
- **ACE / CHI**：在 AXI 上加缓存一致性（ACE），或者改成基于包的一致性互联协议（CHI），属于体系结构方向的扩展。

### 3.6 面试要点与常见追问

- **五通道**：AW / W / B / AR / R，各自独立 valid/ready；写三个通道、读两个。
- **依赖规则**：`VALID` 不等 `READY`；主机不能等 `AWREADY` 才发 W；从机可以等 AW 到了再收 W；`BVALID` 在最后一拍 W（和 AW）握手之后；`RVALID` 在 AR 握手之后。
- **Burst**：FIXED 地址不变；INCR 首拍可非对齐，之后对齐递增，AXI4 最长 256 拍；WRAP 起始对齐，窗口 `(len+1) × 2^size`，长度 2/4/8/16。**不跨 4KB**。
- **WSTRB**：写哪些字节由 `WSTRB` 决定；窄传输的有效通道随地址移动。
- **outstanding**：地址和数据解耦，多笔在途藏往返延迟；实测单拍读 1 笔在途 0.333、4 笔在途 0.997。
- **ID**：同 ID 保序，不同 ID 可乱序；AXI4 写数据不能交织，W 按 AW 顺序。
- **读写之间没有顺序**：要保证先写后读，等 B 回来再发读。
- **AXI3 → AXI4**：INCR 16 → 256 拍、去掉 `WID`、加 QoS / REGION / USER、去掉 locked；AXI4-Lite 无 burst 无 ID。
- **AXI-Stream**：无地址单通道，`TLAST` 分包，`TKEEP` 标空字节，`TID` / `TDEST` 路由。
- **追问：为什么 AXI 比 AHB 快**——读写并行（上限 2 beat/拍）、outstanding 藏延迟、乱序避免慢从机阻塞、每个通道可独立插 register slice 提频。
- **追问：怎么验证 AXI 从机**——每个通道的协议检查（VALID 保持、负载不变、B/R 的依赖）、按 ID 的记分板、W 先于 AW 的激励、窄传输 / 非对齐 / 部分 strobe、反压、满速吞吐、看门狗。

**一句话**：AXI 把传输拆成五个独立的 valid/ready 通道，地址和数据解耦，所以能读写并行、多笔在途、按 ID 乱序；burst 分 FIXED/INCR/WRAP、不跨 4KB，写字节看 `WSTRB`，同 ID 保序，`BVALID` 必须在最后一拍写数据之后。

---

## 4. UART

待写：帧格式、波特率、过采样、收发器实现。

## 5. SPI

待写：四种模式（CPOL/CPHA）、主从实现。

## 6. I2C

待写：起止条件、应答、开漏、仲裁。

---

## 7. 运行全部实验

在 PowerShell 里一次跑完本章全部实验和变异测试：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/12_Bus_Interfaces/lab' && for d in APB AHB AXI; do sed -i 's/\r$//' `$d/*.sh; bash `$d/run_sim.sh 2>&1 | grep -E '=====|PASS|FAIL|ERROR|%'; bash `$d/mutation.sh 2>&1; done"
```

预期：`run_sim.sh` 的每次仿真都打印 `PASS`，没有 Verilator 告警（`%Warning`）；`mutation.sh` 的每个变异都打印 `FAIL`。

注意：

- Windows 下编辑过的 `.sh` 是 CRLF 换行，运行前要 `sed -i 's/\r$//'`，上面的命令已经带了。
- 在 PowerShell 的双引号字符串里，`$` 要写成 `` `$ ``。
- 产生的 `*.vcd`、`*_sim`、`build_mut/` 是构建产物，不需要提交。

---

## 8. 速查表

**三种片上总线对比**：

| | APB | AHB-Lite | AXI4 |
|--|-----|----------|------|
| 定位 | 低速外设寄存器 | MCU 主总线、中速存储 | SoC 主干、存储、DMA |
| 每笔最少拍数 | 2（SETUP + ACCESS） | 1（地址/数据流水） | 1，且读写可同拍 |
| 流水 | 无 | 两级（地址 / 数据） | 五通道独立 |
| burst | 无 | 4/8/16 或不定长，不跨 1KB | 1–256 拍，不跨 4KB |
| outstanding | 无 | 无 | 有 |
| 乱序 | 无 | 无 | 按 ID |
| 等待机制 | `PREADY` | `HREADY`（冻结两级） | 各通道 `READY` 反压 |
| 错误响应 | `PSLVERR` | `HRESP` 两拍 ERROR | `xRESP` SLVERR / DECERR |
| 字节写 | `PSTRB`（APB4） | `HSIZE` + 低位地址 | `WSTRB` |

**关键条件**：

| 协议 | 传输完成 / 采样条件 |
|------|---------------------|
| APB | `PSEL & PENABLE & PREADY` 的上升沿 |
| AHB 地址阶段 | `HSEL & HREADY & HTRANS[1]` |
| AHB 数据阶段结束 | `HREADY = 1`（写在此时用 `HWDATA`） |
| AXI 各通道 | `xVALID & xREADY` 的上升沿 |

**编码**：

| 字段 | 编码 |
|------|------|
| `HTRANS` | 00 IDLE、01 BUSY、10 NONSEQ、11 SEQ |
| `HBURST` | 000 SINGLE、001 INCR、010 WRAP4、011 INCR4、100 WRAP8、101 INCR8、110 WRAP16、111 INCR16 |
| `HSIZE` / `AxSIZE` | 每拍 2^n 字节：000 字节、001 半字、010 字、011 双字 |
| `AxBURST` | 00 FIXED、01 INCR、10 WRAP |
| `xRESP` | 00 OKAY、01 EXOKAY、10 SLVERR、11 DECERR |

**地址公式**（`bytes = 2^SIZE`）：

- INCR：`next = (addr & ~(bytes-1)) + bytes`
- WRAP：`mask = (len+1) × bytes − 1`，`next = (addr & ~mask) | ((addr + bytes) & mask)`
- AHB 的 WRAP4/8/16 同理，拍数固定为 4/8/16。
