# 12 总线与接口 —— 面试向

目标：片上总线（APB / AHB / AXI）和片外低速接口（UART / SPI / I2C）是数字前端岗位的高频考点。面试官一般会问三件事：**信号和时序画得出来吗**、**握手和流水的规则说得清吗**、**能不能当场写一个从机**。本章每个协议都配一份可综合 RTL 和自检查 testbench，testbench 带参考模型、协议检查器和变异测试，在 WSL 中实际跑通，README 里贴的是真实输出。

前置知识：

- valid/ready 握手、打一拍不断流、skid buffer：`../03_Common_Circuits/README.md` 第 8、13 节（AXI 的每个通道就是一个 valid/ready 接口）
- 同步 FIFO：`../03_Common_Circuits/README.md` 第 1 节（AXI 从机的命令队列）
- 仲裁器：`../03_Common_Circuits/README.md` 第 7 节（AHB 仲裁、AXI 互联）
- 位宽转换带 last/keep：`../03_Common_Circuits/README.md` 第 14 节（AXI-Stream）
- 跨时钟域：`../06_CDC/README.md`（UART/SPI/I2C 的输入同步）

建议顺序：第 1 节 APB（最简单，先把"两段式传输 + 等待"弄懂）→ 第 2 节 AHB（加上地址/数据两级流水）→ 第 3 节 AXI（再拆成五个独立通道，加上 ID 和 outstanding）。三者是一条演进线，每一步都在回答"上一个协议的吞吐瓶颈在哪"。第 4–6 节是片外接口，也是一条线：UART 不传时钟、靠过采样猜位中心 → SPI 由主机送时钟、换来速度 → I2C 用开漏两根线挂多个器件，换来寻址、应答和仲裁。面试前直接看每节末尾的"面试要点"和第 8 节速查表。

配套实验（`lab/` 下，每个文件夹 `bash run_sim.sh` 一键 lint + 仿真，`bash mutation.sh` 跑变异测试）：

| 实验 | 内容 |
|------|------|
| `lab/APB/` | APB4 主机（命令口 → SETUP/ACCESS 状态机，背靠背传输）+ 寄存器从机（RW / RO / W1C、PSTRB、可配等待、PSLVERR）；WAIT=0 / 2 两种配置；3 个变异 |
| `lab/AHB/` | AHB-Lite SRAM 从机（同步读 + 写后读旁路、随机等待）、译码器 + 响应 MUX + 默认从机（两拍 ERROR）；周期级主机 BFM 跑 8 种 burst、BUSY、窄传输；2 个变异 |
| `lab/AXI/` | AXI4 RAM 从机（FIXED/INCR/WRAP、窄传输、非对齐、WSTRB、命令队列支持 4 笔 outstanding）；五通道独立随机主机、按 ID 记分板、五通道协议检查；outstanding 1 vs 4 吞吐对比；3 个变异 |
| `lab/UART/` | 波特率发生器 + TX + 16 倍过采样 RX（两级同步、中心三取二、假起始过滤、帧 / 校验错误）；8N1 / 8E1 / 8O2；±6% 波特率偏差扫描、毛刺与假起始注入；2 个变异 |
| `lab/SPI/` | 四模式可配的主机 + 过采样从机（MISO 三态）；引脚级监视器；主从模式不匹配矩阵、分频扫描；2 个变异 |
| `lab/I2C/` | 字节命令主机（重复起始、时钟拉伸、多主机仲裁）+ 带自增指针的寄存器从机（可配拉伸）；两主机一从机开漏总线（`tri1` 线与）；2 个变异 |

本章进度：第 1–6 节全部完成。

---

## 目录

1. [APB](#1-apb)
2. [AHB](#2-ahb)
3. [AXI4 与 AXI-Stream](#3-axi4-与-axi-stream)
4. [UART](#4-uart)
5. [SPI](#5-spi)
6. [I2C](#6-i2c)
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

### 4.1 解决什么问题，面试怎么考

前三节是片上总线，从这一节开始是**片外**低速接口：芯片和芯片、芯片和板上器件之间的连线。UART（Universal Asynchronous Receiver/Transmitter）只用一根线单向传数据（收发各一根，TX 接对方 RX），**不传时钟**。收发双方事先约定波特率，接收方用自己的本地时钟去"猜"每一位的中心。它是调试串口、蓝牙 / GPS / 4G 模组、BootROM 下载口的标配。

面试考法：

1. 画一帧 UART 波形（起始、数据 LSB 先、校验、停止），8N1 是什么意思。
2. 波特率怎么由系统时钟分频得到，整数分频误差多大。
3. **接收器为什么要过采样**，16 倍过采样在哪里采、为什么在中心、为什么采三次。
4. 收发双方波特率能差多少（容限怎么算）。
5. 手写一个 UART RX：同步器、起始位检测、假起始过滤、帧错误 / 校验错误。

### 4.2 原理

**帧格式**：空闲时线为高；一帧 = 1 个起始位（0）+ 5–9 个数据位（**LSB 先发**，最常见 8 位）+ 可选校验位 + 1 / 1.5 / 2 个停止位（1）。简记为"数据位数 + 校验 + 停止位数"：8N1 = 8 数据、无校验、1 停止；8E1 = 偶校验；8O2 = 奇校验、2 停止。

以 8E1 发送 0x35（二进制 0011_0101，1 的个数为 4，偶校验位为 0）为例：

| 位 | 空闲 | 起始 | D0 | D1 | D2 | D3 | D4 | D5 | D6 | D7 | 校验 | 停止 | 空闲 |
|----|------|------|----|----|----|----|----|----|----|----|------|------|------|
| TXD | 1 | **0** | 1 | 0 | 1 | 0 | 1 | 1 | 0 | 0 | 0 | **1** | 1 |

- **起始位的下降沿**是整帧唯一的同步点：接收方从这个沿开始按约定的位宽计时，一直数到停止位。每一帧都重新对齐一次，所以误差不会跨帧累积。
- **停止位**保证下一帧的起始位一定有一个 1→0 的下降沿；停止位位置采到 0 就是**帧错误**（framing error），常见原因是波特率不对或线路噪声。线上持续低电平超过一帧叫 break，常用作特殊信号。
- **校验**：奇校验是"数据 + 校验位中 1 的个数为奇数"，偶校验为偶数，只能查出奇数个位错。

**波特率与分频**：波特率 = 每秒位数，一位宽 = 1 / 波特率（115200 bps 一位约 8.68 µs）。接收端需要比波特率快得多的采样节拍，通常是 16 倍：`tick 频率 = 16 × 波特率`，`DIV = f_clk / (16 × 波特率)`。例：50 MHz、115200 → 27.13，取 27，实际波特率偏高 0.47%。波特率越高，整数分频的舍入误差越大；需要精确时用累加器做小数分频（`../03_Common_Circuits/README.md` 第 5 节）。

**16 倍过采样接收**：

```
            起始位                           D0
rxd   ‾‾‾‾‾‾|________________________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|
tick        0 1 2 3 4 5 6 7 8 9 ... 15        0 1 2 3 4 5 6 7 8 9 ... 15
            ^              ^ ^ ^                             ^ ^ ^
     检测到 0（精度 1 tick）  三次采样多数表决 → 仍为 0 才确认起始   D0 的中心
```

1. 空闲时每个 tick 看一次线，第一次看到 0，就把这个 tick 当成起始位的第 0 个 tick。检测精度是 1 个 tick，也就是 1/16 位。
2. 从这里起每 16 个 tick 是一位，**在第 7、8、9 个 tick 采三次、三取二**，判决点就落在位中心。中心离两侧边沿最远，对波特率误差和边沿抖动的余量最大；三次表决能滤掉短于一个 tick 的毛刺。
3. 起始位中心再确认一次：如果表决结果是 1，说明刚才的 0 只是毛刺（**假起始**），回到空闲。
4. 停止位判决完立即回到空闲，不必等停止位结束。这样下一帧的起始位即使因为误差提前一点到来，也能被检测到。

**波特率容限**：接收方从起始沿开始计时，每一位的判决点都会因为波特率偏差而漂移，**越靠后的位漂得越多**。设相对偏差为 δ，第 n 位（起始位为第 0 位）的判决点在第 n + 0.5 位附近，它必须落在发送方真实的第 n 位之内：`n × (1+δ) < n + 0.5 < (n+1) × (1+δ)`。粗略估计 `|δ| < 0.5 / (n+1)`。8N1 最后一个必须判对的是停止位（n = 9），`0.5/10 = 5%`；再扣掉起始沿检测的 1/16 位不确定度，教科书上常见的估计是 `(0.5 − 1/16) / 9.5 ≈ 4.6%`。**这是收发双方误差之和**，所以实际工程里要求每一端 ≤ 2% 左右，合计 ≤ 2–3%。第 4.4 节的扫描实测了这个数字。

### 4.3 RTL 讲解

四个文件：`uart_baud.v`（每 DIV 个 clk 一个 tick）、`uart_tx.v`、`uart_rx.v`、`tb_uart.v`。参数 `PARITY`（0 无、1 奇、2 偶）和 `STOP`（1 / 2）。

**发送器**（`lab/UART/uart_tx.v`）：把整帧预先拼进移位寄存器，每 16 个 tick 移出一位。

```verilog
// 奇校验：数据 + 校验位中 1 的个数为奇数；偶校验：为偶数
wire        par   = (PARITY == 1) ? ~^data : ^data;
// 起始位之后按 LSB 先出的顺序排好；高位补 1 就是停止位
wire [10:0] frame = (PARITY == 0) ? {3'b111, data} : {2'b11, par, data};

end else if (tick) begin
    if (ovs == 4'd15) begin
        ovs <= 4'd0;
        if (bitn == NBITS - 1) begin
            active <= 1'b0;
            txd    <= 1'b1;
        end else begin
            txd  <= sh[0];
            sh   <= {1'b1, sh[10:1]};       // 右移，LSB 先出，高位补停止位
            bitn <= bitn + 1'b1;
        end
    end else begin
        ovs <= ovs + 1'b1;
    end
end
```

输入口是 valid/ready：`ready = ~active`，握手当拍 `txd` 拉低开始起始位。`txd` 是寄存器输出，不会有组合毛刺，这对异步线路很重要（毛刺会被对方当成起始位）。

**接收器**（`lab/UART/uart_rx.v`）的四个要点：

```verilog
// 1）rxd 是异步输入，两级同步；复位值为 1（空闲电平），否则复位释放瞬间就"看到"起始位
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rx_m <= 1'b1; rx_s <= 1'b1; end
    else        begin rx_m <= rxd;  rx_s <= rx_m; end
end

// 2）第 7、8 个 tick 采样存起来，第 9 个 tick 与当前值三取二
wire maj = (smp[1] & smp[0]) | (smp[1] & rx_s) | (smp[0] & rx_s);

if (tick) begin
    if (!busy) begin
        if (!rx_s) begin busy <= 1'b1; ovs <= 4'd1; bitn <= 4'd0; end   // 起始沿，精度 1 tick
    end else begin
        if (ovs == 4'd7 || ovs == 4'd8) smp <= {smp[0], rx_s};
        if (ovs == 4'd9) begin
            if (bitn == 4'd0) begin
                if (maj) busy <= 1'b0;                  // 3）起始位中心为 1：假起始
            end else if (bitn <= 4'd8) begin
                sh <= {maj, sh[7:1]};                   // LSB 先到，右移
            end else if (bitn != LASTBIT) begin
                par_bit <= maj;
            end else begin                              // 4）停止位：判决完立即回空闲
                busy <= 1'b0; valid <= 1'b1; data <= sh;
                frame_err <= ~maj; parity_err <= ~par_ok;
            end
        end
        ...                                             // ovs 0..15 循环，满 16 进下一位
```

- `LASTBIT = 9 + (有校验 ? 1 : 0)`，只检查第一个停止位。多出来的停止位对接收方来说就是空闲，所以接收器不需要 `STOP` 参数。
- 判决在第 9 个 tick 完成，此时离停止位结束还有 7 个 tick，下一帧的起始沿即使提前到来也能被检测到。
- 同步器带来 2 个 clk 的固定延迟，对所有位一样，不影响判决位置。

常见错误：

| 错误 | 后果 |
|------|------|
| rxd 不同步直接用 | 亚稳态；同一拍不同触发器看到不同的值，状态机跑飞 |
| 同步器复位为 0 | 复位释放时误检测到起始位，收到一个垃圾字节 |
| 在位的开头而不是中心判决 | 波特率容限只剩一侧，发送方稍慢就错位（变异 M2：+2% 就开始丢帧） |
| 每位只采一次 | 一个毛刺就翻转一位（变异 M1：200 个带毛刺的帧只对了 5 个） |
| 起始位不在中心再确认 | 线上一个窄脉冲就被当成一帧 |
| 等停止位完全结束才回空闲 | 发送方稍快时下一帧的起始沿落在"忙"的时间里，被错过 |
| MSB 先发 | 与所有标准 UART 不兼容 |
| TX 输出是组合逻辑 | 输出毛刺在对方看来就是起始位 |

### 4.4 仿真

```bash
cd 12_Bus_Interfaces/lab/UART && bash run_sim.sh     # 8N1、8E1、8O2 各跑一次
bash mutation.sh                                    # 2 个变异，应全部 FAIL
```

`tb_uart.v`：clk 100 MHz、`DIV = 4`，每位 64 个 clk（640 ns）。检查分两路：

- **TX 线检查器**：不看 RTL 内部，看到 `txd` 下降沿后在理想位中心采样，核对起始 / 数据 / 校验 / 停止位。
- **RX 输出检查器**：按期望队列比对 `{frame_err, parity_err, data}`。

激励分四个阶段：

- **P1 环回**：`uart_tx` 直连 `uart_rx`，背靠背 300 字节。
- **P2 波特率扫描**：改由 testbench 的发送模型按 `(1+δ)` 倍位宽发送，δ 从 −6% 到 +6%，每档 200 帧，帧间空闲 1.5 位。只统计，不判错；但要求 |δ| ≤ 3% 时全对。
- **P3 噪声**：每个数据位中心附近随机位置加一个 30 ns 的反相毛刺（比 1 个 tick 的 40 ns 还短）；另外发 100 个 1–5 个 tick 宽的低脉冲，模拟假起始。
- **P4 错误注入**：停止位发 0，期望 `frame_err`；校验位取反，期望 `parity_err`。

```
===== tb_uart：PARITY=0 STOP=1 =====
--------------------------------------------------------------
config 8N1 | P1 loopback: TX frames checked=300  RX ok=300
P2 baud offset sweep (200 frames each, 1.5-bit idle gap):
   offset  -6.0% : ok  64  bad 136  lost   0  extra  0
   offset  -5.0% : ok 200  bad   0  lost   0  extra  0
   offset  -4.5% : ok 200  bad   0  lost   0  extra  0
   offset  -4.0% : ok 200  bad   0  lost   0  extra  0
   offset  -3.0% : ok 200  bad   0  lost   0  extra  0
   offset  -2.0% : ok 200  bad   0  lost   0  extra  0
   offset   0.0% : ok 200  bad   0  lost   0  extra  0
   offset   2.0% : ok 200  bad   0  lost   0  extra  0
   offset   3.0% : ok 200  bad   0  lost   0  extra  0
   offset   4.0% : ok 200  bad   0  lost   0  extra  0
   offset   4.5% : ok 200  bad   0  lost   0  extra  0
   offset   5.0% : ok 200  bad   0  lost   0  extra  0
   offset   6.0% : ok 148  bad  52  lost   0  extra  0
P3 noise: glitched frames ok=200/200  false-start pulses -> frames=0/100
P4 error inject: flagged correctly=50/50
--------------------------------------------------------------
PASS
===== tb_uart：PARITY=2 STOP=1 =====
--------------------------------------------------------------
config 8E1 | P1 loopback: TX frames checked=300  RX ok=300
P2 baud offset sweep (200 frames each, 1.5-bit idle gap):
   offset  -6.0% : ok  29  bad 171  lost   0  extra  0
   offset  -5.0% : ok  89  bad 111  lost   0  extra  0
   offset  -4.5% : ok 180  bad  20  lost   0  extra  0
   offset  -4.0% : ok 200  bad   0  lost   0  extra  0
   ...（-3% ~ +4.5% 全部 ok 200）
   offset   5.0% : ok 200  bad   0  lost   0  extra  0
   offset   6.0% : ok  58  bad 142  lost   0  extra  0
P3 noise: glitched frames ok=200/200  false-start pulses -> frames=0/100
P4 error inject: flagged correctly=100/100
--------------------------------------------------------------
PASS
===== tb_uart：PARITY=1 STOP=2 =====
--------------------------------------------------------------
config 8O2 | P1 loopback: TX frames checked=300  RX ok=300
P2 baud offset sweep (200 frames each, 1.5-bit idle gap):
   offset  -6.0% : ok  36  bad 164  lost   0  extra  0
   offset  -5.0% : ok  97  bad 103  lost   0  extra  0
   offset  -4.5% : ok 180  bad  20  lost   0  extra  0
   offset  -4.0% : ok 200  bad   0  lost   0  extra  0
   ...（-3% ~ +4.5% 全部 ok 200）
   offset   5.0% : ok 200  bad   0  lost   0  extra  0
   offset   6.0% : ok  80  bad 120  lost   0  extra  0
P3 noise: glitched frames ok=200/200  false-start pulses -> frames=0/100
P4 error inject: flagged correctly=100/100
--------------------------------------------------------------
PASS
```

（8E1、8O2 中间几档输出与 8N1 相同，省略号是这里为了篇幅省掉的，原始输出每档都有一行。）

**容限实测**：8N1 在 −5% ~ +5% 全对，带校验位时收窄到 −4% ~ +5%。δ > 0 表示发送方位宽更长（发送方慢），δ < 0 表示发送方快。两侧不对称，可以用第 4.2 节的公式解释：

- **发送方慢（δ > 0）**：判决点相对真实位置往前漂，最后一个判决的位最先出问题。8N1 是停止位（n = 9），界限约为 `(0.5 + 检测延迟) / 9`。检测延迟是 0–1 个 tick 加上同步器的 2 个 clk，大约 0.03–0.09 位，所以界限约 5.9%–6.6%：+5% 全对，+6% 部分出错。带校验时停止位变成 n = 10，所以 +6% 出错更多（8E1 错 142 帧，8N1 只错 52 帧）。
- **发送方快（δ < 0）**：判决点往后漂。停止位后面是空闲（也是 1），判晚了也不会错，所以真正卡住的是**最后一个可能为 0 的位**：8N1 是 D7（n = 8），界限 `(0.5 − 检测延迟) / 9 ≈ 4.6%–5.2%`，实测 −5% 全对、−6% 出错；带校验时是校验位（n = 9），界限约 4.1%–4.7%，实测 −4.5% 开始出错。
- **结论**：16 倍过采样、中心判决的 UART，收发合计误差大约在 ±4% 以内是安全的。每一端各分一半，就是常说的"每端 ≤ 2%"。

P3 中 200 个带毛刺的帧全对，100 个假起始脉冲一个都没被当成帧：毛刺短于 1 个 tick，最多污染三次采样中的一次；1–5 个 tick 宽的低脉冲在起始位中心（第 7–9 个 tick）已经回到 1，表决为 1，判为假起始。

变异测试：

```
===== M1: 单点采样 =====
P2 baud offset sweep (200 frames each, 1.5-bit idle gap):
   offset  -6.0% : ok  64  bad 136  lost   0  extra  0
   offset  -5.0% : ok 200  bad   0  lost   0  extra  0
   ...（与原设计完全相同）
   offset   6.0% : ok 148  bad  52  lost   0  extra  0
ERROR @21098395000: RX frame mismatch
ERROR @21105435000: RX frame mismatch
P3 noise: glitched frames ok=5/200  false-start pulses -> frames=0/100
P4 error inject: flagged correctly=50/50
FAIL (196 errors)
===== M2: 在位开头采样 =====
P2 baud offset sweep (200 frames each, 1.5-bit idle gap):
   offset  -6.0% : ok 200  bad   0  lost   0  extra  0
   ...（-5% ~ -2% 全部 ok 200）
   offset   0.0% : ok 200  bad   0  lost   0  extra  0
   offset   2.0% : ok  92  bad 108  lost   0  extra  0
ERROR @13431425000: frames lost within +-3%
   offset   3.0% : ok  12  bad 188  lost   0  extra  0
ERROR @14944385000: frames lost within +-3%
   offset   4.0% : ok   3  bad 197  lost   0  extra  0
   offset   4.5% : ok   1  bad 199  lost   0  extra 24
   offset   5.0% : ok   2  bad 198  lost   0  extra 36
   offset   6.0% : ok   1  bad 199  lost   0  extra 32
P3 noise: glitched frames ok=200/200  false-start pulses -> frames=19/100
P4 error inject: flagged correctly=10/50
FAIL (75 errors)
```

- **M1**（去掉三取二，只用第 8 个 tick 的一次采样）：判决位置几乎没变，所以波特率扫描和原设计**逐行相同**，只有噪声阶段抓到了它（200 个带毛刺的帧只对 5 个）。每一种设计特性都需要针对它的激励，否则"多数表决"写没写对根本测不出来。
- **M2**（在第 1–3 个 tick 判决）：判决点贴着位的开头，发送方稍慢就落到前一位里，+2% 就错了一半；发送方快的一侧反而余量很大（−6% 全对）。较宽的假起始脉冲有一部分在"起始位确认"时还没结束，被当成了帧（19/100）。P4 的停止位错误只对了 10/50：接收器在停止位的第 3 个 tick 就回到空闲，停止位剩下的 13 个 tick 还是 0，于是被当成新的起始位，确认后多收了一个垃圾帧，打乱了后面的比对。原设计在第 9 个 tick 回空闲，也会把剩下的低电平当起始，但 7 个 tick 后在"起始位中心"再确认时线已经回到 1，被判为假起始。

波形（`uart.vcd`，最后一次运行 8O2，只录 P1）：看 `txd`、`u_rx.rx_s`、`u_rx.ovs`、`u_rx.bitn`、`rx_valid`。`ovs` 每位从 0 数到 15，`bitn` 在停止位（8O2 下是 10）第 9 个 tick 时 `rx_valid` 拉高一拍。

### 4.5 变体与扩展

- **收发 FIFO**：真实 UART 控制器（如 16550 兼容 IP）在 TX / RX 各放一个 FIFO，CPU 通过 APB 寄存器批量读写，并提供"FIFO 半满"中断和接收超时中断（FIFO 非空但一段时间没新数据）。
- **硬件流控 RTS/CTS**：接收方 FIFO 快满时拉高 RTS（请求对方暂停），发送方看到 CTS 无效就停在帧边界。
- **自动波特率检测**：约定对方先发一个已知字符（如 0x55 或 0x80），测起始位或若干位的宽度，反推出分频值。
- **小数分频**：用相位累加器产生 tick，平均频率精确，但 tick 间隔有 ±1 个 clk 的抖动，对 16 倍过采样影响很小。
- **更低的过采样倍数**：8 倍甚至 4 倍可以提高最高波特率，代价是检测不确定度变大（1/8 位），容限变小。
- **物理层**：UART 只定义帧格式；RS-232 是 ±电压、RS-485 是差分多点总线（半双工，要控制发送使能）；LIN 总线是 UART 帧加上 break 和同步场；9 位模式用第 9 位区分"地址字节 / 数据字节"，做多机通信。

### 4.6 面试要点与常见追问

- **帧**：空闲高，起始位 0，数据 LSB 先，可选校验，停止位 1；8N1 = 8 数据位、无校验、1 停止位，一帧 10 位。
- **每帧重新同步**：只靠起始位下降沿对齐，误差不跨帧累积；停止位保证下一帧有下降沿。
- **过采样**：16 倍 tick，检测到 0 后在第 7/8/9 个 tick 三取二；起始位中心再确认滤假起始；rxd 先两级同步、复位为 1。
- **容限**：`≈ 0.5 / (位数)`，8N1 收发合计约 ±4%–5%，每端 ≤ 2%；本章实测 8N1 为 −5% ~ +5%。
- **错误**：停止位为 0 → 帧错误；校验不符 → 校验错误；FIFO 满了还来数据 → 溢出错误（overrun）。
- **追问：为什么是 16 倍**——检测不确定度 1/16 位，足够小；再高收益不大，时钟要求却更高。
- **追问：波特率怎么选分频**——`DIV = f_clk / (16 × baud)` 四舍五入，算出误差；误差 > 1% 时换时钟或用小数分频。

**一句话**：UART 不传时钟，每帧用起始位下降沿对齐，接收方 16 倍过采样、在位中心三取二判决；收发波特率合计容差约 ±4%，所以每端要做到 2% 以内。

---

## 5. SPI

### 5.1 解决什么问题，面试怎么考

UART 不传时钟，所以速度受限于双方时钟精度，一般只到几 Mbps。**SPI（Serial Peripheral Interface）** 由主机**直接送出时钟 SCLK**，数据在 SCLK 的一个沿发出、另一个沿采样，没有波特率误差的问题，速度可以到几十 MHz。它是 Flash、ADC / DAC、显示屏、传感器最常用的接口。

四根线：`SCLK`（主机输出时钟）、`MOSI`（主出从入）、`MISO`（主入从出）、`CS_n`（片选，低有效，每个从机一根）。**全双工**：每个 SCLK 周期主机发出一位、同时收回一位，本质上是主从两个移位寄存器首尾相接组成的环。

面试考法：

1. CPOL / CPHA 四种模式分别在哪个沿采样、哪个沿变化；画出模式 0 和模式 3 的时序。
2. CPHA = 0 时第一位什么时候必须放好。
3. 手写 SPI 主机 / 从机；从机用系统时钟过采样，还是直接用 SCLK 当时钟。
4. 多从机怎么接（独立片选 / 菊花链）；MISO 为什么要三态。
5. 主从模式不一致会怎样；SCLK 最高能跑多快。

### 5.2 原理

**CPOL / CPHA**：

- **CPOL**：SCLK 空闲电平。0 = 空闲低，1 = 空闲高。
- **CPHA**：在哪个沿采样。0 = **前沿**（SCLK 离开空闲电平的沿）采样、后沿换数据；1 = 前沿换数据、**后沿**采样。

| 模式 | CPOL | CPHA | 空闲 SCLK | 采样沿 | 换数据沿 |
|------|------|------|-----------|--------|----------|
| 0 | 0 | 0 | 低 | 上升 | 下降 |
| 1 | 0 | 1 | 低 | 下降 | 上升 |
| 2 | 1 | 0 | 高 | 下降 | 上升 |
| 3 | 1 | 1 | 高 | 上升 | 下降 |

一个字节有 8 个 SCLK 周期，也就是 16 个沿（MSB 先，B7 … B0）：

| | 前沿 1 | 后沿 1 | 前沿 2 | 后沿 2 | … | 前沿 8 | 后沿 8 |
|--|--------|--------|--------|--------|---|--------|--------|
| CPHA=0 | 采 B7 | 换 B6 | 采 B6 | 换 B5 | … | 采 B0 | 不再换 |
| CPHA=1 | 放 B7 | 采 B7 | 换 B6 | 采 B6 | … | 换 B0 | 采 B0 |

- **CPHA=0 的第一位必须在 CS 拉低时就放好**：第一个前沿就要采样，之前没有"换数据沿"。所以 CPHA=0 的从机必须在 CS 下降沿就把 B7 驱动到 MISO 上。
- CPHA=1 在第一个前沿才放出 B7，最后一个后沿采完 B0。
- 画时序时记一条：**采样沿和换数据沿永远是相反的两个沿**，这样数据在采样沿前后各有半个 SCLK 周期的建立 / 保持余量。

```
模式 0（CPOL=0 CPHA=0）
CS_n   ‾‾‾\_______________________________________________/‾‾‾
SCLK   ________/‾‾‾\___/‾‾‾\___/‾‾‾\___ ... ___/‾‾‾\__________
MOSI   ----< B7    >< B6   >< B5   >< B4 ...  >< B0    >------
               ^采      ^采     ^采               ^采
```

模式 3 的采样沿同样是上升沿，只是 SCLK 空闲为高。所以**很多器件同时支持模式 0 和模式 3**（如大多数 SPI Flash），它们对从机来说采样沿相同。第 5.4 节的模式不匹配矩阵验证了这一点。

**多从机**：

- **独立片选**：MOSI / SCLK / MISO 并联，每个从机一根 CS。未选中的从机 MISO 必须高阻，否则多个从机同时驱动 MISO 会冲突，所以本章从机有 `miso_oe`。
- **菊花链**：从机的 MISO 接下一个从机的 MOSI，共用一根 CS，数据像移位寄存器一样穿过所有从机（如 LED 驱动链）。

**SCLK 能跑多快**：主机在一个沿换数据，从机在对沿采样。数据要经过"主机输出延迟 + 板级走线 + 从机建立时间"，读回方向还要加"从机时钟到输出延迟 + 回程走线"。读方向是一个完整的往返，通常是 SPI 提速的瓶颈，高速 Flash 控制器会引入"延迟采样"（在更晚的沿或内部延迟线采 MISO）来补偿。

**从机的两种实现**：

1. **过采样**（本章）：从机运行在自己的系统时钟上，把 SCLK / CS_n / MOSI 当成异步信号，先同步、再检测边沿。好处是全部逻辑在一个时钟域，易于和系统其它部分对接；代价是系统时钟必须比 SCLK 快很多倍（第 5.4 节实测 SCLK 半周期 ≥ 4 个 clk，也就是系统时钟 ≥ 8 倍 SCLK）。
2. **直接用 SCLK 当时钟**：移位寄存器用 SCLK 的沿打，能跑到接近 SCLK 物理上限；但收到的字节要跨时钟域送到系统域（握手或异步 FIFO，`../06_CDC/README.md`），而且 CS 无效时 SCLK 不翻转，从机不能靠 SCLK 做"收完后的收尾"动作。高速 SPI 从机通常这么做。

### 5.3 RTL 讲解

**主机**（`lab/SPI/spi_master.v`）：`cpol`、`cpha`、`div`（SCLK 半周期 = div 个 clk）都是运行时输入。状态 IDLE → SETUP（CS 拉低后等半周期）→ XFER（16 个 SCLK 沿）→ HOLD（等半周期再拉高 CS）→ 至少空闲半周期。

```verilog
assign mosi = sh_tx[7];                     // MSB 先出

wire half    = (cnt == 8'd0);               // 半周期到
wire leading = ~nedge[0];                   // 偶数号沿是前沿
wire samp_e  = cpha ? ~leading :  leading;
wire shift_e = cpha ?  leading : ~leading;

IDLE: ... else if (start) begin
    cs_n  <= 1'b0;
    sh_tx <= tx;                            // MSB 立即出现在 MOSI 上（CPHA=0 需要）
    ...
end
XFER: if (half) begin
    sclk  <= ~sclk;
    nedge <= nedge + 1'b1;
    if (samp_e) begin
        sh_rx <= {sh_rx[6:0], miso};
        nsamp <= nsamp + 1'b1;
    end
    // 移位沿：CPHA=0 时第 8 次采样后的后沿不再移位；CPHA=1 时第一个前沿不移位
    if (shift_e && nsamp != 4'd0 && nsamp != 4'd8)
        sh_tx <= {sh_tx[6:0], 1'b0};
    if (nedge == 5'd15) st <= HOLD;
end
```

移位规则 `nsamp != 0 && nsamp != 8` 同时覆盖了两种相位：

- **CPHA=0**：前沿采样、后沿移位。每次移位前都已经采过样，所以 `nsamp != 0` 总成立；第 8 个后沿时 `nsamp == 8`，不再移位。
- **CPHA=1**：前沿移位、后沿采样。第一个前沿时 `nsamp == 0`，不移位，因为 B7 在 CS 拉低时已经放好了，这个前沿"放 B7"的动作已经提前完成；之后每个前沿都移位。

**从机**（`lab/SPI/spi_slave.v`）：三个输入先同步，再用打一拍做边沿检测。

```verilog
always @(posedge clk ...) begin
    sclk_r <= {sclk_r[1:0], sclk};
    cs_r   <= {cs_r[1:0], cs_n};
    mosi_r <= {mosi_r[0], mosi};            // 与 sclk_r[1] 对齐：同样两级延迟
end
wire rise     =  sclk_r[1] & ~sclk_r[2];
wire fall     = ~sclk_r[1] &  sclk_r[2];
wire leading  = cpol ? fall : rise;
wire trailing = cpol ? rise : fall;
wire samp_e   = cpha ? trailing : leading;
wire shift_e  = cpha ? leading  : trailing;

assign miso    = sh_tx[7];
assign miso_oe = cs_act;                    // 片选有效才驱动 MISO

if (cs_fall) begin
    sh_tx <= tx_data;                       // CS 下降时装载，B7 立即出现在 MISO
    nsamp <= 4'd0;
end else if (cs_act) begin
    if (samp_e) begin
        sh_rx <= {sh_rx[5:0], mosi_r[1]};
        nsamp <= nsamp + 1'b1;
        if (nsamp == 4'd7) begin rx_data <= {sh_rx, mosi_r[1]}; rx_valid <= 1'b1; end
    end
    if (shift_e && nsamp != 4'd0 && nsamp != 4'd8)
        sh_tx <= {sh_tx[6:0], 1'b0};
end
```

- `mosi_r` 和 `sclk_r[1]` 都经过两级同步，延迟相同，所以 MOSI 相对 SCLK 的建立 / 保持关系在同步后保持不变：在检测到采样沿的那一拍，`mosi_r[1]` 正是 SCLK 沿那一刻的 MOSI。
- MISO 路径的延迟约 3 个 clk：SCLK 换数据沿 → 2 级同步 → 边沿检测 → `sh_tx` 移位 → MISO 变化。MISO 必须在主机的下一个采样沿（半个 SCLK 周期后）之前稳定，这就是系统时钟要比 SCLK 快很多倍的原因。
- 从机移位规则和主机相同。

常见错误：

| 错误 | 后果 |
|------|------|
| CPHA=0 时从机等第一个 SCLK 沿才放 B7 | 主机第一个前沿采到的是上一次残留的值，整字节错一位 |
| CPHA=1 时第一个前沿也移位 | B7 还没被采就被移走（变异 M1：模式 1、3 的 MISO 几乎全错） |
| 采样沿 / 换数据沿弄反 | 在数据变化的同一个沿采样，结果取决于延迟竞争（变异 M2） |
| MISO 不做三态 | 多从机共用 MISO 时互相冲突 |
| 过采样从机的系统时钟不够快 | MISO 来不及在主机采样沿前更新（第 5.4 节：div < 4 时读回全错） |
| MOSI 和 SCLK 同步级数不同 | 同步后建立 / 保持关系被破坏，采到相邻位 |
| CS 无效期间 SCLK 从空闲电平跳变 | 从机看到多余的沿；应先切好 CPOL 再拉低 CS |
| 以为模式不匹配"仿真通过就能用" | 见第 5.4 节，某些组合在仿真里侥幸通过，真实器件上是保持时间竞争 |

### 5.4 仿真

```bash
cd 12_Bus_Interfaces/lab/SPI && bash run_sim.sh
bash mutation.sh
```

`tb_spi.v`：`spi_master` 直连 `spi_slave`，每笔传输双向比对（主机收到的 = 从机发的，从机收到的 = 主机发的）。另有**引脚级监视器**，独立于 RTL，只按模式定义解码：

- CS 下降时 SCLK 必须在 CPOL 电平；CS 无效时 SCLK 不许翻转。
- 在模式规定的采样沿直接采 MOSI / MISO 引脚，每个 CS 期间正好 8 个采样沿，解码值与期望一致。

激励分三个阶段：

- **P1**：4 种模式各 250 字节，div 随机取 4–8，监视器开启。
- **P2**：主从模式不匹配矩阵，16 种组合各 50 字节。
- **P3**：div 从 1 扫到 6。

```
===== tb_spi =====
---------------------------------------------------------------
P1 mode 0 (CPOL=0 CPHA=0): M->S ok 250/250  S->M ok 250/250
P1 mode 1 (CPOL=0 CPHA=1): M->S ok 250/250  S->M ok 250/250
P1 mode 2 (CPOL=1 CPHA=0): M->S ok 250/250  S->M ok 250/250
P1 mode 3 (CPOL=1 CPHA=1): M->S ok 250/250  S->M ok 250/250
P1 pin monitor decoded 1000 frames
P2 mode mismatch (50 bytes, 'M->S/S->M' correct):
            slave m0   slave m1   slave m2   slave m3
master m0    50/50      0/ 0      0/ 1     50/50  
master m1    50/50     50/50     50/50     50/50  
master m2     1/ 0     50/50     50/50      0/ 1  
master m3    50/50     50/50     50/50     50/50  
P3 div sweep (SCLK half period = div clk; 'M->S/S->M' correct of 50):
       mode0     mode1     mode2     mode3
div=1  50/ 0     50/ 0     50/ 0     50/ 0    
div=2  50/ 0     50/ 0     50/ 0     50/ 0    
div=3  50/ 0     50/ 0     50/ 1     50/ 0    
div=4  50/50     50/50     50/50     50/50    
div=5  50/50     50/50     50/50     50/50    
div=6  50/50     50/50     50/50     50/50    
---------------------------------------------------------------
PASS
```

**P2 模式矩阵**怎么读：

- **主机 m0 / m2 两行才是真实结论**：模式 0 只和模式 3 兼容，模式 2 只和模式 1 兼容，正好是"采样沿相同"的组合（0、3 在上升沿采样，1、2 在下降沿采样）。其它格子几乎全错，偶尔的 1/50 是随机数据碰巧对上。
- **主机 m1 / m3 两行全部"通过"，这是仿真假象**。主机 CPHA=1 在后沿采样，而过采样从机的 MISO 要比 SCLK 沿晚约 3 个 clk 才更新。主机采样时，从机还没来得及响应这个沿，采到的总是"上一个沿之前放好的那一位"，不管从机按哪种模式移位，结果都凑巧对齐。反方向上，本仿真里主机的 SCLK 和 MOSI 在同一个 clk 沿变化，从机又经过相同的同步延迟看到它们，等于保持时间为零时刚好采到了新值。真实芯片上这是零保持余量的竞争，**模式不匹配就是不能用**，不能因为仿真矩阵里某格通过就依赖它。
- 所以 testbench 只要求对角线全对，其它格子只统计不判错。

**P3 分频扫描**：主机到从机方向在任何 div 下都对，因为从机对 SCLK 和 MOSI 做了相同的同步，相对关系不变。从机到主机方向要 div ≥ 4 才对：MISO 路径约 3 个 clk，必须在半个 SCLK 周期内完成，所以 **div ≥ 4，也就是系统时钟 ≥ 8 倍 SCLK**。这是过采样从机的硬约束，写从机规格时要注明"SCLK ≤ f_clk / 8"。

变异测试：

```
===== M1: 从机 CPHA=1 第一个前沿也移位 =====
P1 mode 0 (CPOL=0 CPHA=0): M->S ok 250/250  S->M ok 250/250
ERROR @295615000: MISO pin decode mismatch
ERROR @296415000: MISO pin decode mismatch
P1 mode 1 (CPOL=0 CPHA=1): M->S ok 250/250  S->M ok 1/250
P1 mode 2 (CPOL=1 CPHA=0): M->S ok 250/250  S->M ok 250/250
P1 mode 3 (CPOL=1 CPHA=1): M->S ok 250/250  S->M ok 0/250
FAIL (509 errors)
===== M2: 主机采样沿/移位沿对调 =====
ERROR @1015000: MOSI pin decode mismatch
ERROR @2525000: MOSI pin decode mismatch
P1 mode 0 (CPOL=0 CPHA=0): M->S ok 0/250  S->M ok 250/250
P1 mode 1 (CPOL=0 CPHA=1): M->S ok 250/250  S->M ok 2/250
P1 mode 2 (CPOL=1 CPHA=0): M->S ok 1/250  S->M ok 250/250
P1 mode 3 (CPOL=1 CPHA=1): M->S ok 250/250  S->M ok 1/250
FAIL (519 errors)
```

- **M1** 只影响 CPHA=1 的两种模式，而且只影响从机发送方向：B7 在被采样之前就被移走了。如果 testbench 只测模式 0（很常见），这个 bug 完全看不出来。**四种模式都要测。**
- **M2** 在每种模式下都坏掉一个方向：CPHA=0 时主机换数据的时刻错了，引脚监视器直接报 MOSI 解码错误；CPHA=1 时主机在错误的沿采 MISO。引脚级监视器的价值在于：它不依赖从机 RTL，就算主从两端犯了同样的错误，"主从互通"也照样能看出协议不对。

波形（`spi.vcd`，只录 P1）：看 `cs_n`、`sclk`、`mosi`、`miso`、`u_s.sclk_r`、`u_s.sh_tx`。能看到 `miso` 比 `sclk` 沿晚 3 个 clk 变化。

### 5.5 变体与扩展

- **用 SCLK 做时钟的从机**：见第 5.2 节，速度最高，接收字节需要跨时钟域。CPHA=0 的 B7 要在 CS 下降时就放好，这时还没有 SCLK 沿，通常用 CS 的异步置位 / 预装载，或者在上一次传输结束时预先装好。
- **可变长度 / 连续传输**：CS 保持低连续传多个字节（Flash 的"命令 + 地址 + 数据"），从机按字节计数解析命令。
- **Dual / Quad SPI（QSPI）**：命令阶段单线，地址和数据阶段 2 / 4 根线双向传，带 dummy 周期给 Flash 准备数据时间。XIP（execute in place）让 CPU 直接从 QSPI Flash 取指令。
- **三线 SPI**：MOSI / MISO 合成一根双向线，半双工。
- **主机侧 FIFO + DMA**：真实 SPI 控制器用 FIFO 缓冲，配合 DMA 连续传大块数据。
- **MISO 延迟采样**：高速时读回路径是往返延迟，控制器可以配置在更晚的沿采样。

### 5.6 面试要点与常见追问

- **四根线**：SCLK、MOSI、MISO、CS_n；主机出时钟，全双工，两个移位寄存器首尾成环。
- **CPOL** = 空闲电平；**CPHA** = 0 前沿采样、1 后沿采样；采样沿和换数据沿永远相反。
- **模式 0 / 3 采样沿都是上升沿**，所以很多器件同时支持；模式 1 / 2 同为下降沿。
- **CPHA=0 的第一位在 CS 下降时就要放好**；CPHA=1 第一个前沿才放。
- **多从机**：独立 CS，未选中的从机 MISO 高阻；或菊花链。
- **过采样从机**：同步 + 边沿检测，MOSI 和 SCLK 同步级数必须相同；MISO 延迟约 3 clk，系统时钟 ≥ 8 倍 SCLK（本章实测）。
- **追问：SPI 和 I2C 比**——SPI 快（几十 MHz）、全双工、推挽、协议简单，但线多（每个从机一根 CS）、无应答、无寻址；I2C 两根线、有地址和应答，但慢、半双工。
- **追问：SPI 最高频率受什么限制**——读回方向的往返延迟（从机时钟到输出 + 两段走线 + 主机建立时间），要在半个 SCLK 周期内完成。

**一句话**：SPI 由主机送出时钟，CPOL 定空闲电平、CPHA 定前沿还是后沿采样，采样和换数据永远在相反的沿；CPHA=0 第一位要在 CS 下降时放好，过采样从机要求系统时钟远快于 SCLK。

---

## 6. I2C

### 6.1 解决什么问题，面试怎么考

SPI 每加一个从机就要多一根片选线。**I2C（Inter-Integrated Circuit）** 只用两根线：`SCL`（时钟）和 `SDA`（数据），所有器件挂在同一对线上，靠**地址**区分从机，每个字节后有**应答**。它用来接 EEPROM、传感器、PMIC、摄像头配置口、HDMI DDC 等大量低速器件。标准模式 100 kHz、快速模式 400 kHz、快速模式+ 1 MHz。

面试考法：

1. **为什么是开漏**（open-drain）+ 上拉电阻；线与是什么意思。
2. START / STOP / 重复起始的定义；为什么 SDA 只能在 SCL 低时变化。
3. 一次"写寄存器"和"读寄存器"的完整时序（地址、R/W、ACK、重复起始、最后一个字节 NACK）。
4. **时钟拉伸**是什么，主机怎么支持。
5. **多主机仲裁**怎么做，为什么不会破坏胜者的数据。
6. 总线挂死（SDA 被从机一直拉低）怎么恢复。

### 6.2 原理

**开漏与线与**：每个器件对 SCL / SDA 只能"拉低"或"放开"，不能主动驱动高电平；线上的高电平由上拉电阻提供。所以任何一个器件拉低，线就是低，这叫**线与**（wired-AND）。这一个电气特性支撑了 I2C 的三项功能：

- **应答**：主机放开 SDA，从机拉低表示 ACK。
- **时钟拉伸**：从机没准备好时把 SCL 拉住不放。
- **多主机仲裁**：谁发 0 谁赢，发 1 的一方能检测到"我放开了线却是低的"。

如果用推挽输出，两个器件一个输出 1、一个输出 0 就是电源短路，上面三项都做不了。上拉电阻的阻值取决于总线电容和速率：阻值太大，上升沿太慢；阻值太小，拉低时电流太大。

**数据有效性与起止条件**：

- **SDA 只能在 SCL 为低时变化**，SCL 为高时 SDA 必须稳定，接收方在 SCL 高电平期间（上升沿）采样。
- 唯一的例外就是起止条件：**START = SCL 高时 SDA 下降**，**STOP = SCL 高时 SDA 上升**。它们一定不会和数据位混淆，所以任何从机在任何时刻看到 START 都能重新同步。
- **重复起始（Sr）**：不发 STOP 直接再发一个 START，主机不释放总线就切换读写方向或换从机。

**一次传输**：

```
写寄存器： S | 地址(7) W | A | 寄存器指针 | A | 数据0 | A | 数据1 | A | ... | P
读寄存器： S | 地址(7) W | A | 寄存器指针 | A | Sr | 地址(7) R | A | 数据0 | A | ... | 数据n | NA | P
           ── 主机发 ──       ─ 从机回 ─                            ─ 从机发 ─  ─ 主机回 ─
```

- 地址字节 = 7 位地址 + R/W 位（0 写、1 读）。数据手册里的"地址 0x50"和"写地址 0xA0 / 读地址 0xA1"是同一个器件，面试和调试时常混淆。
- **每个字节 9 个时钟**：8 位数据（MSB 先）+ 1 位应答。应答位由**接收方**拉低 SDA 表示 ACK，不拉低（线为高）是 NACK。
- 写时主机是发送方，从机回 ACK；读时从机是发送方，**主机回 ACK 表示"还要"，读最后一个字节回 NACK**，从机才会放开 SDA，主机才能发 STOP。
- 地址没有从机应答（NACK）说明从机不存在或忙。

**本章主机的位时序**：每一位分四个阶段，每阶段 Q 个 clk（`Q = f_clk / (4 × f_SCL)`；仿真里 Q = 8，只为了跑得快）。

```
阶段        A            B              C            D
SCL     ___________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_____________
SDA     X 改数据 ===========================================
        ^阶段开始时改 SDA
                   ^放开 SCL，等线上 SCL 真的变高（从机可能拉伸）再数 Q 拍
                                  ^阶段开始时采样 SDA，检查仲裁
                                               ^拉低 SCL
```

SCL 高 2Q、低 2Q；SDA 在 SCL 下降后 Q 拍才变（保持时间），在 SCL 上升前 Q 拍已经稳定（建立时间）。START 和 STOP 也用同样的四阶段，只是在 SCL 高时改 SDA。

**时钟拉伸**：从机把 SCL 拉低不放，主机"放开 SCL"后看到线仍然是低，就**一直等到 SCL 真的变高**再开始计高电平时间。所以主机必须回读 SCL 线，而不是只看自己的输出。同样的机制也实现了**多主机时钟同步**：多个主机同时产生 SCL 时，线上的低电平由最长的那个决定，高电平由最短的那个决定，所有主机都按线上的实际 SCL 走。

**仲裁**：两个主机同时发 START（都看到总线空闲），各自发自己的地址和数据。每一位在 SCL 高时，主机回读 SDA：

- 自己发 0，线一定是 0，不会有冲突。
- 自己发 1（放开 SDA）却读到 0，说明别人在发 0。自己**仲裁失败**，立即放开 SDA 和 SCL，退出。
- 胜者在整个过程中完全不知道有人和它竞争，它发出的每一位都原样出现在线上，所以**仲裁不破坏胜者的数据**。
- 结论：逐位比较，**数值小的一方赢**（先出现 0 的一方）。两个主机发同样的地址时，比较会延续到后面的数据字节。

**总线挂死与恢复**：主机在从机发送读数据的中途复位，从机可能正拉低 SDA 等待下一个 SCL。主机看到 SDA 为低发不出 START，总线就挂死了。标准恢复方法是主机手动打最多 9 个 SCL 脉冲，每个脉冲后检查 SDA，从机把这个字节"送完"后会放开 SDA，这时主机再发 STOP。

### 6.3 RTL 讲解

**主机**（`lab/I2C/i2c_master.v`）是字节级命令接口：`cmd` = START / WRITE / READ / STOP，每条命令完成时 `rsp_valid` 单拍有效，带回 `rdata`、`ack_n`、`arb_lost`。连续命令之间主机停在 HOLD 状态，SCL 保持低，占着总线。开漏用 `*_oe` 表示："1 = 拉低，0 = 放开"；`*_i` 是线上实际电平，先两级同步。

```verilog
// ---------- 一位 ----------
B_A: if (tdone) begin scl_oe <= 1'b0; tmr <= QM1; st <= B_B; end     // 放开 SCL
B_B: if (!scl_s) tmr <= QM1;                 // 时钟拉伸 / 多主机时钟同步
     else if (tdone) begin
         tmr <= QM1; st <= B_C;
         if (bitn == 4'd8)      ack_r <= sda_s;              // 第 9 位：读应答
         else if (is_read)      sh <= {sh[6:0], sda_s};
         else if (sh[7] && !sda_s) begin     // 发 1 却看到 0：别的主机在发 0
             scl_oe <= 1'b0; sda_oe <= 1'b0;
             arb_lost <= 1'b1; rsp_valid <= 1'b1;
             st <= IDLE;
         end
     end
B_C: if (tdone) begin scl_oe <= 1'b1; tmr <= QM1; st <= B_D; end     // 拉低 SCL
B_D: if (tdone) begin                                               // SCL 低的后半段改 SDA
    tmr <= QM1;
    if (bitn == 4'd8) begin
        sda_oe <= 1'b0; rdata <= sh; ack_n <= ack_r; rsp_valid <= 1'b1; st <= HOLD;
    end else begin
        bitn <= bitn + 1'b1; st <= B_A;
        if (bitn == 4'd7)  sda_oe <= is_read ? ~nack : 1'b0;   // 应答位：读时主机回 ACK/NACK
        else if (is_read)  sda_oe <= 1'b0;                      // 读：放开 SDA 让从机驱动
        else begin         sda_oe <= ~sh[6]; sh <= {sh[6:0], 1'b0}; end
    end
end
```

- **`if (!scl_s) tmr <= QM1`** 是时钟拉伸的全部实现：放开 SCL 后只要线上还是低，计数器就一直重装，高电平的 Q 拍从 SCL 真正变高才开始算。START（`ST_B`）和 STOP（`SP_B`）里也有同样的等待。变异 M2 去掉数据位里的这一句，从机一拉伸就错位。
- **仲裁检测在采样点**：`sh[7]` 是本位要发的值，发 1 读到 0 立即放开两根线、报 `arb_lost`。读数据和应答位不检查，因为那时 SDA 本来就是从机在驱动。
- **SDA 在 SCL 低的中间改**（B_D 结束、下一个 B_A 开始），离 SCL 两个沿都有 Q 拍的距离，满足建立 / 保持时间。

**从机**（`lab/I2C/i2c_slave.v`）：7 位地址（参数 `ADDR`），16 个寄存器，带自增指针，是传感器 / EEPROM 的典型协议。运行在系统时钟上，SCL / SDA 三级打拍后检测边沿：

```verilog
wire scl_rise =  scl_r[1] & ~scl_r[2];
wire scl_fall = ~scl_r[1] &  scl_r[2];
wire start_d  = scl_s & scl_r[2] & ~sda_r[1] &  sda_r[2];   // SCL 高时 SDA 下降
wire stop_d   = scl_s & scl_r[2] &  sda_r[1] & ~sda_r[2];   // SCL 高时 SDA 上升

assign scl_oe = (scnt != 8'd0);                               // 时钟拉伸

if (start_d) begin
    st <= S_ADDR; bitc <= 4'd0; ackph <= 1'b0; sda_oe <= 1'b0;   // 任何时候都能重新同步
end else if (stop_d) begin
    st <= S_IDLE; sda_oe <= 1'b0;
end else if (st != S_IDLE && st != S_IGNORE) begin
    if (scl_rise) ...                       // SCL 上升沿采样 SDA
    if (scl_fall) begin
        if (!ackph && bitc == 4'd8) begin   // 8 位收完，进入应答位
            ackph <= 1'b1;
            case (st)
                S_ADDR:  if (sh[7:1] == ADDR) sda_oe <= 1'b1;  // 地址匹配才 ACK
                         else                  st <= S_IGNORE;
                S_PTR:   begin ptr <= sh[3:0]; sda_oe <= 1'b1; end
                S_WDATA: begin regs[ptr] <= sh; ptr <= ptr + 1'b1; sda_oe <= 1'b1; end
                default: sda_oe <= 1'b0;                        // S_READ：放开，听主机应答
            endcase
        end else if (ackph) begin           // 应答位结束
            ackph <= 1'b0; bitc <= 4'd0;
            scnt  <= stretch;               // 拉住 SCL stretch 个 clk
            ...                             // 读：装载下一个字节（主机回 NACK 则停止发送）
        end else if (st == S_READ) begin    // 读的第 2~8 位在 SCL 下降后换
            sda_oe <= ~tsh[6];
            tsh    <= {tsh[5:0], 1'b0};
        end
    end
end
```

- **START / STOP 检测优先于一切**：不论从机处在什么状态，看到 START 就回到收地址；这也让重复起始自然成立。
- 从机只在检测到 SCL 下降之后才改 SDA，同步延迟就是它的保持时间。
- 地址不匹配进入 `S_IGNORE`，直到下一个 START / STOP，不会干扰总线。
- `stretch` 输入模拟"数据还没准备好"：每个应答位结束后把 SCL 再拉低 `stretch` 个 clk。

常见错误：

| 错误 | 后果 |
|------|------|
| SCL / SDA 用推挽输出 1 | 与其他器件的 0 冲突（电源短路）；应答、拉伸、仲裁全部失效 |
| SCL 高时改 SDA | 被所有从机当成 START / STOP |
| 主机只看自己的 SCL 输出，不回读线 | 不支持时钟拉伸（变异 M2：从机一拉伸就错位） |
| 多主机系统不做仲裁检测 | 两个主机的数据在线上被"线与"成第三个值，双方都以为自己成功（变异 M1） |
| 读最后一个字节回 ACK | 从机继续驱动下一个字节的 MSB，SDA 若为 0 主机就发不出 STOP |
| 从机在 SCL 上升沿就改 SDA | 违反"SCL 高时 SDA 稳定"，可能被看成 STOP / START |
| 从机状态机只在 STOP 时复位 | 主机用重复起始时从机不认新的地址字节 |
| 地址写成 8 位格式（0xA0）当 7 位用 | 地址差一倍，永远 NACK |
| 上电 / 复位后不做总线恢复 | 从机拉住 SDA，总线挂死 |

### 6.4 仿真

```bash
cd 12_Bus_Interfaces/lab/I2C && bash run_sim.sh
bash mutation.sh
```

`tb_i2c.v`：两个 `i2c_master` 和一个 `i2c_slave`（地址 0x50）挂在同一条总线上。总线用 `tri1 scl, sda` 模拟上拉电阻，每个器件 `assign scl = x_scl_oe ? 1'b0 : 1'bz`，Verilog 的多驱动线自然实现线与。

- **参考模型**：16 个寄存器 + 指针，按从机协议更新；仿真开始时模型和从机寄存器预置相同的随机值。
- **引脚监视器**只看 SCL / SDA：START / STOP 只能出现在字节边界。"字节边界"是指第 9k 个时钟之后的那个 SCL 高电平，因为发 Sr / P 之前主机要先放开 SCL，这会多出一个上升沿。监视器还统计 START / STOP 个数和 SCL 最长低电平。
- **P1**：m0 随机做 400 笔事务。40% 写 1–4 字节；30% 设指针后重复起始读 1–4 字节；20% 从当前指针直接读；10% 访问不存在的地址 0x23（期望 NACK）。每笔事务有 1/3 概率让从机拉伸 20–60 个 clk。
- **P2 仲裁**：m0 和 m1 同时（相差 0–3 个 clk）向同一从机写不同的 `{指针, 数据}`。两者地址字节相同，比较会延续到指针和数据字节，期望数值小的一方赢。检查输家报 `arb_lost`、赢家的写不受影响；100 次之后把 16 个寄存器全部读回比对。

```
===== tb_i2c =====
---------------------------------------------------------------
P1 m0: write=168 read=192 (bytes checked 463) wrong-addr NACK=40  stretched txns=130
   bus monitor: START(incl. Sr)=515 STOP=400  max SCL low=630 ns (nominal 160 ns)
P2 arbitration: 100/100 trials OK (winner data written, loser flagged arb_lost)
---------------------------------------------------------------
PASS
```

- 400 笔事务有 400 个 STOP，START 515 个：多出的 115 个是"设指针后读"事务里的重复起始。
- SCL 正常低电平 160 ns（2Q），最长 630 ns，主要是从机最长 60 个 clk 的拉伸，再加上同步、检测延迟和命令间隙。130 笔拉伸事务全部正确，说明主机按线上的实际 SCL 工作。
- 100 次仲裁全部是预期的一方赢。两个主机的 SCL 起始相差 0–3 个 clk，被线与同步到一起（B_B 的等待同时实现了时钟同步）；输家在第一个"发 1 读到 0"的位退出，赢家的数据完整写入，最后的全寄存器读回也证明了这一点。

**写监视器时踩过的坑**：第一版监视器要求 START / STOP 出现时"本次 START 以来的 SCL 上升沿数是 9 的整数倍"，结果报了 617 处 "START inside a byte"，而功能检查全部正确。原因是 Sr / P 之前主机先放开 SCL，产生第 9k+1 个上升沿，SDA 才在这个高电平里跳变。检查器本身写错和 RTL 写错在输出上看起来一样，**报错时先确认检查规则是按规范写的**。

变异测试：

```
===== M1: 去掉仲裁检测 =====
P1 m0: write=168 read=192 (bytes checked 463) wrong-addr NACK=40  stretched txns=130
ERROR @5615115000: arbitration result wrong
ERROR @5625125000: arbitration result wrong
P2 arbitration: 0/100 trials OK (winner data written, loser flagged arb_lost)
FAIL (114 errors)
===== M2: 数据位忽略时钟拉伸 =====
ERROR @52335000: ptr not ACKed
ERROR @55575000: addr R not ACKed
P1 m0: write=168 read=192 (bytes checked 463) wrong-addr NACK=40  stretched txns=130
P2 arbitration: 100/100 trials OK (winner data written, loser flagged arb_lost)
FAIL (553 errors)
```

- **M1**：单主机的 P1 完全正常，只有 P2 抓到。没有仲裁时两个主机都以为自己成功了，线上实际写进去的是两个值"线与"后的结果，双方都没察觉。114 处错误里有 100 处是每次仲裁各报一次的 "arbitration result wrong"。
- **M2**：从机一拉伸，主机的"SCL 高"阶段就在 SCL 实际为低时过去了，从机少看到时钟，后面的应答和数据全部错位。P2 不拉伸，所以通过。**拉伸只有在从机真的拉伸时才会暴露**，testbench 的从机一定要有可配的拉伸。

波形（`i2c.vcd`，只录 P1 前 20 笔事务）：看 `scl`、`sda`、`m0_scl_oe`、`s_scl_oe`、`s_sda_oe`、`u_m0.st`。`s_scl_oe=1` 期间 `m0_scl_oe=0` 但 `scl` 仍为低，主机停在 B_B 等待，这就是时钟拉伸。

### 6.5 变体与扩展

- **10 位地址**：首字节为 `11110 A9 A8 R/W`，第二字节为 A7–A0。
- **通用呼叫 / 设备 ID**：地址 0x00 广播；另有若干保留地址。
- **SMBus / PMBus**：在 I2C 上加超时（SCL 低超过 35 ms 即复位）、PEC 校验字节、固定的命令格式，常用于电源管理。
- **I3C**：MIPI 的后继标准，兼容 I2C 器件，支持推挽高速模式（12.5 MHz）、带内中断、动态地址分配。
- **毛刺滤波**：规范要求快速模式输入滤掉 50 ns 以下的尖峰。数字实现就是同步后再加几级一致性滤波，本章从机只做了同步。
- **从机用 SCL 做时钟**：可以做到很低功耗（没有 SCL 时不翻转），但 START / STOP 要用 SDA 的沿去检测，属于异步设计，一般避免。
- **主机的总线恢复与超时**：检测 SDA 长时间为低时自动打 9 个 SCL 脉冲；SCL 被拉伸过久时报超时。

### 6.6 面试要点与常见追问

- **两根线开漏 + 上拉**：线与，任何器件拉低即为低；这是应答、拉伸、仲裁的基础。
- **SDA 只在 SCL 低时变**；START = SCL 高时 SDA 下降，STOP = SCL 高时 SDA 上升；Sr 不释放总线换方向。
- **每字节 9 个时钟**：8 位 MSB 先 + 接收方的 ACK（拉低）；读最后一字节主机回 NACK。
- **读寄存器**：`S | ADDR+W | 指针 | Sr | ADDR+R | 数据… | NA | P`；7 位地址 0x50 = 写 0xA0 / 读 0xA1。
- **时钟拉伸**：从机拉住 SCL，主机放开 SCL 后回读线，等真变高再计时。
- **仲裁**：发 1 读到 0 即失败并退出，数值小的赢；胜者数据不受影响；同样的回读机制也实现了多主机时钟同步。
- **追问：总线挂死**——从机拉住 SDA；主机打最多 9 个 SCL 脉冲直到 SDA 放开，再发 STOP。
- **追问：上拉电阻怎么选**——上升时间（RC）满足速率等级的要求，下限由拉低电流（3 mA 等）决定。
- **追问：I2C 为什么慢**——开漏上升沿靠电阻充电，总线电容越大越慢；还有半双工和每字节一个应答位的开销。

**一句话**：I2C 靠开漏线与实现两根线上的多器件通信，SDA 只在 SCL 低时变、START / STOP 是 SCL 高时 SDA 的跳变；每字节 9 个时钟带应答，从机拉住 SCL 就是时钟拉伸，发 1 读到 0 就是仲裁失败。

---

## 7. 运行全部实验

在 PowerShell 里一次跑完本章全部实验和变异测试：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/12_Bus_Interfaces/lab' && for d in APB AHB AXI UART SPI I2C; do sed -i 's/\r$//' `$d/*.sh; bash `$d/run_sim.sh 2>&1 | grep -E '=====|PASS|FAIL|ERROR|%'; bash `$d/mutation.sh 2>&1; done"
```

预期：`run_sim.sh` 的每次仿真都打印 `PASS`，没有 Verilator 告警（`%Warning`）；`mutation.sh` 的每个变异都打印 `FAIL`。UART 的波特率扫描行里带 `%`，也会被 grep 列出来，属于正常输出。全部跑完约 1–2 分钟。

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

**三种片外接口对比**：

| | UART | SPI | I2C |
|--|------|-----|-----|
| 线数 | 2（TX、RX） | 3 + 每从机 1 根 CS | 2（SCL、SDA） |
| 时钟 | 不传，双方约定波特率 | 主机送 SCLK | 主机送 SCL，从机可拉伸 |
| 方向 | 全双工 | 全双工 | 半双工 |
| 输出类型 | 推挽 | 推挽（MISO 未选中时高阻） | 开漏 + 上拉 |
| 寻址 | 无（点对点） | 片选 | 7 / 10 位地址 |
| 应答 / 校验 | 可选校验位 | 无 | 每字节 ACK / NACK |
| 多主机 | 否 | 否 | 是（仲裁） |
| 典型速率 | 9600 bps – 几 Mbps | 几 – 几十 MHz | 100k / 400k / 1M |
| 位序 | LSB 先 | 通常 MSB 先 | MSB 先 |

**关键条件**：

| 接口 | 条件 |
|------|------|
| UART 采样 | 起始沿后每位第 7 / 8 / 9 个 tick 三取二；容限约 `0.5 / 位数` |
| SPI 采样 | CPHA=0 前沿采样；CPHA=1 后沿采样；模式 0 / 3 上升沿，1 / 2 下降沿 |
| I2C START / STOP | SCL 高时 SDA 下降 / 上升 |
| I2C 数据 | SCL 低时变，SCL 高时稳定；第 9 个时钟接收方拉低 = ACK |
| I2C 仲裁 | 发 1 读到 0 → 失败退出，数值小的赢 |
