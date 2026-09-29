# 静态时序分析（STA）教程 —— 面试向

目标：概念层面能应付数字 IC 前端 / 后端 / 验证岗位的 STA 面试，并对工业工具（PrimeTime、Tempus、OpenSTA）、SDC、脚本有基本认识。  
配套：

- `lab/`：可在本机 WSL 跑的真实 STA 实验（Yosys 综合 FIFO → Sky130 网表 → OpenSTA）。
- `INTERVIEW_QA.md`：面试题库与计算题。
- 前置知识：`../03_Common_Circuits/lab/FIFO/README.md`（亚稳态、两级同步器、Gray 码）。

建议顺序：第 1–4 章（核心公式）→ 做 lab 读报告（第 14–15 章）→ 第 5–11 章 → SDC 与工具（第 12–13 章）→ 刷题库。

---

## 目录

1. [STA 是什么，为什么需要](#1-sta-是什么为什么需要)
2. [触发器的时序参数：Tclk2q / Tsetup / Thold](#2-触发器的时序参数)
3. [亚稳态（复习）与 MTBF](#3-亚稳态与-mtbf)
4. [时序路径与 setup / hold 检查](#4-时序路径与-setup--hold-检查)
5. [时钟：latency、skew、jitter、uncertainty](#5-时钟latencyskewjitteruncertainty)
6. [延时是怎么算出来的：单元延时、线延时、slew](#6-延时是怎么算出来的)
7. [PVT、corner、OCV 与 CRPR](#7-pvtcornerocv-与-crpr)
8. [时序例外：false path、multicycle、clock groups](#8-时序例外)
9. [其它检查：recovery/removal、门控时钟、脉宽、DRV、latch](#9-其它时序检查)
10. [复位方式](#10-复位方式)
11. [CDC 与 STA 的关系](#11-cdc-与-sta-的关系)
12. [SDC 详解](#12-sdc-详解)
13. [工业工具与流程：PrimeTime / Tempus / OpenSTA，时序修复（ECO）](#13-工业工具与流程)
14. [读懂一份时序报告（用 lab 真实报告）](#14-读懂一份时序报告)
15. [lab 实验与结论](#15-lab-实验与结论)
16. [速查表](#16-速查表)

---

## 1. STA 是什么，为什么需要

**静态时序分析**：不加激励、不跑仿真，把电路拆成一条条**时序路径**，用单元库里的延时数据把每条路径的延时算出来，检查它是否满足时钟约束。

| | 动态时序仿真（带 SDF 的门级仿真） | STA |
|--|-----------------------------------|-----|
| 需要激励 | 要，覆盖率取决于测试向量 | 不要，穷举所有路径 |
| 速度 | 慢 | 快，可分析上亿门 |
| 能查功能 | 能 | 不能 |
| 能查异步 / CDC | 部分能 | 不能（要靠 CDC 工具） |
| 签核（signoff）地位 | 辅助 | **时序签核的主手段** |

STA 的前提是**同步设计**：寄存器由时钟沿驱动，数据在两个沿之间传播。  
**局限**：不查功能、不查跨时钟域正确性；结果完全依赖**约束（SDC）是否正确**——约束写错，报告再干净也没有意义。

### STA 在流程中的位置

```
RTL ──► 综合(DC/Genus) ──► 布局 ──► CTS ──► 布线 ──► 寄生参数抽取(StarRC/Quantus) ──► Signoff STA(PT/Tempus)
          │ 理想时钟         │ 估计线长   │ 真实时钟树   │ 真实走线      │ SPEF                      │ 多 corner 多模式
          └──── 每一步都跑 STA，越往后越准 ─────────────────────────────────────────────────────────┘
```

- 综合阶段：**理想时钟**（ideal clock，时钟到达所有寄存器时间相同），线延时靠 wire load model 或物理综合估计。
- CTS 之后：**propagated clock**，时钟树真实延时进入计算，skew 变成真实值。
- 布线 + 抽取之后：用 **SPEF** 里的 RC 做签核。

---

## 2. 触发器的时序参数

一个 D 触发器（DFF）的三个核心参数：

| 参数 | 含义 |
|------|------|
| **Tclk2q**（Tcq） | 时钟沿到来后，Q 端输出新值所需时间 |
| **Tsetup**（建立时间） | 时钟沿**之前**，D 必须保持稳定的最短时间 |
| **Thold**（保持时间） | 时钟沿**之后**，D 必须继续保持稳定的最短时间 |

```
              Tsetup   Thold
            |<------>|<--->|
D  ═════════X════════════════X═════   ← 窗口内 D 不许变
                     ↑
CLK ________________/‾‾‾‾‾‾‾‾‾
                     |<-Tcq->|
Q  ══════════════════════════X═══     ← 新值
```

### 物理来源（面试常追问）

主从结构 DFF = 两个锁存器（master、slave）。CLK 低时 master 透明、跟随 D；CLK 上升沿 master 关闭锁存。

- **setup**：D 要穿过 master 的传输门 / 反相器，把内部节点充放电到位，时钟沿到来前必须完成，否则 master 锁到的值不确定。
- **hold**：时钟沿到来后，master 的输入传输门要一小段时间才彻底关断；这段时间里 D 若变化，会“漏”进去破坏已锁存的值。
- 两者都在 liberty 库里以**查找表**给出，随 D 端 slew 和 CLK 端 slew 变化，可以为负值（负 hold 很常见，说明内部时钟路径比数据路径慢）。

违反 setup 或 hold → 触发器可能进入**亚稳态**。

---

## 3. 亚稳态与 MTBF

详见 `../03_Common_Circuits/lab/FIFO/README.md` 第 4 节，这里只列面试要点：

- **成因**：数据变化落在 setup/hold 窗口内，触发器内部交叉耦合反相器停在平衡点附近，输出长时间处于中间电平或很晚才落到 0/1。
- **不可消除，只能降低概率**。用 MTBF 衡量：

```
MTBF = e^(Tr / τ) / (Tw × fclk × fdata)
```

  - `Tr`：留给亚稳态恢复的时间（resolution time），多一级同步器 ≈ 多一个周期
  - `τ`：触发器的恢复时间常数（工艺相关，越小越好）
  - `Tw`：亚稳态窗口宽度
  - `fclk`、`fdata`：采样时钟频率、数据翻转频率

  `Tr` 在指数上，所以多一级同步器能把 MTBF 提升很多个数量级。

- **解决**：单 bit 用两级（或三级）同步器；多 bit 用 Gray 码指针的异步 FIFO、握手、MUX 同步等。
- **STA 的角色**：同步域内部，STA 保证不违反 setup/hold → 不会发生亚稳态。跨异步时钟域，违例不可避免，由同步器兜底，STA 用 clock groups / false path 排除这些路径。

---

## 4. 时序路径与 setup / hold 检查

### 4.1 起点与终点

- **起点（startpoint）**：寄存器的时钟引脚（CK），或输入端口。
- **终点（endpoint）**：寄存器的数据输入引脚（D，以及复位、使能等检查引脚），或输出端口。

### 4.2 四类路径

```
         ┌──────────────── 芯片 ────────────────┐
in ──①──►[FF]──②──►[组合逻辑]──►[FF]──③──► out
 │                                            ▲
 └───────────────④ 纯组合 ────────────────────┘
```

| 类型 | 说明 | 约束来源 |
|------|------|----------|
| ① in → reg | 输入端口到寄存器 | `set_input_delay` |
| ② reg → reg | 寄存器到寄存器，内部核心 | 时钟周期 |
| ③ reg → out | 寄存器到输出端口 | `set_output_delay` |
| ④ in → out | 组合穿通 | input + output delay，或 `set_max_delay` |

另外还有：时钟门控路径、异步复位的 recovery/removal 路径（见第 9 节）。

### 4.3 两条子路径：数据路径与时钟路径

一条 reg→reg 路径的检查要同时看：

```
          launch clock path              data path
CLK源 ───► 时钟树 ───► FF1/CK ──Tcq──► FF1/Q ──► 组合逻辑 ──► FF2/D
   │                                                           ▲
   └──────► 时钟树 ───────────────────────────► FF2/CK ─────────┘
          capture clock path                  （检查 setup/hold）
```

- **launch edge**：FF1 发出数据的那个时钟沿
- **capture edge**：FF2 采样数据的那个时钟沿
- **arrival time（AT）**：数据实际到达终点的时间
- **required time（RT）**：数据最晚（setup）/最早（hold）必须到达的时间
- **slack（裕量）**：
  - setup：`slack = RT − AT`（数据要来得够早）
  - hold：`slack = AT − RT`（数据不能来得太早）
  - slack ≥ 0 满足（MET），< 0 违例（VIOLATED）

### 4.4 Setup 检查（最大延时检查，max path）

**数据必须在下一个 capture 沿之前 Tsetup 到达。**

记：

- `Tlaunch`：launch 时钟从源到 FF1/CK 的延时（时钟网络延时）
- `Tcapture`：capture 时钟从源到 FF2/CK 的延时
- `Tskew = Tcapture − Tlaunch`

```
Tlaunch + Tcq + Tcomb_max  ≤  T + Tcapture − Tsetup − Tuncertainty

整理：  T ≥ Tcq + Tcomb_max + Tsetup + Tuncertainty − Tskew

setup slack = (T + Tcapture − Tsetup − Tunc) − (Tlaunch + Tcq + Tcomb_max)
```

- 用**最慢**的延时（max）：慢 corner、慢工艺
- 决定**最高频率**：`Fmax = 1 / Tmin`
- setup 违例的后果：降频可以救（芯片能用，只是跑不到目标频率）

### 4.5 Hold 检查（最小延时检查，min path）

**新数据不能太快，不能在同一个沿的 Thold 窗口内冲掉 FF2 正在采样的旧数据。**

hold 检查是在 **同一个时钟沿**上做的：launch 沿发出的新数据，不能破坏 capture 寄存器在这个沿上的采样。

```
Tlaunch + Tcq + Tcomb_min  ≥  Tcapture + Thold + Tuncertainty

hold slack = (Tlaunch + Tcq + Tcomb_min) − (Tcapture + Thold + Tunc)
```

- 用**最快**的延时（min）：快 corner
- **公式里没有周期 T** → hold 与频率无关，**降频救不了**
- hold 违例 = 芯片在任何频率下都可能出错 → 流片后基本只能返工，所以 signoff 时 hold 必须干净

### 4.6 skew 对 setup 和 hold 的影响（高频考点）

| skew 符号 | 含义 | 对 setup | 对 hold |
|-----------|------|----------|---------|
| 正 skew（Tcapture > Tlaunch） | 捕获时钟晚到，与数据同向 | **有利**（多出时间） | **不利** |
| 负 skew（Tcapture < Tlaunch） | 捕获时钟早到 | 不利 | 有利 |

一句话：**skew 对 setup 和 hold 的作用永远相反**。  
利用这一点做 **useful skew**：故意给关键路径的 capture 寄存器晚一点时钟，借时间修 setup，但要确保这条路径和下一级路径的 hold/setup 仍满足。

### 4.7 小例题

T = 10 ns，Tcq = 1，Tcomb_max = 6，Tcomb_min = 0.5，Tsetup = 0.5，Thold = 0.8，Tlaunch = 1，Tcapture = 2，忽略 uncertainty。

- setup：AT = 1 + 1 + 6 = 8；RT = 10 + 2 − 0.5 = 11.5；slack = **+3.5**
- hold：AT = 1 + 1 + 0.5 = 2.5；RT = 2 + 0.8 = 2.8；slack = **−0.3（违例）**
- 修 hold：在数据路径插 ≥ 0.3 ns 的延时单元（buffer/delay cell）；检查插入后 setup 仍有余量（3.5 − 0.3 > 0）。

更多计算题见 `INTERVIEW_QA.md`。

---

## 5. 时钟：latency、skew、jitter、uncertainty

### 5.1 时钟延时（latency）

```
  振荡器/PLL ──(source latency)──► 芯片时钟端口 ──(network latency)──► 寄存器 CK
```

- **source latency**：时钟源到设计时钟定义点的延时（芯片外、PLL 输出等），`set_clock_latency -source`
- **network latency**：定义点到寄存器 CK 的时钟树延时
  - CTS 前：用 `set_clock_latency` 估计，或视为 0（ideal）
  - CTS 后：`set_propagated_clock [all_clocks]`，由工具按真实时钟树计算

### 5.2 skew（偏差）

同一时钟到达不同寄存器的时间差。

- **local skew**：有时序关系的两个寄存器之间的 skew，对 STA 有意义
- **global skew**：全芯片最早与最晚到达的差
- 来源：时钟树各分支的线长、负载、buffer 数量不同；工艺偏差
- CTS 的目标：在可控插入延时和功耗的前提下，让 skew 尽量小（或按 useful skew 定向调整）

### 5.3 jitter（抖动）

时钟沿相对理想位置在**时间上的随机/确定性偏移**，来自 PLL 噪声、电源噪声、串扰。

| 类型 | 定义 |
|------|------|
| period jitter | 单个周期相对标称周期的偏差 |
| cycle-to-cycle jitter | 相邻两个周期长度之差 |
| long-term jitter | 多个周期累积后的偏差 |

skew 是**空间上**（不同寄存器之间）的差异，jitter 是**时间上**（同一点不同周期之间）的差异。

### 5.4 uncertainty（不确定度）

SDC 里把 jitter、尚未确定的 skew、额外的设计余量打包成一个数：

```tcl
set_clock_uncertainty -setup 0.20 [all_clocks]   ;# jitter + 估计 skew + margin
set_clock_uncertainty -hold  0.05 [all_clocks]   ;# hold 一般只含 skew + margin
```

- setup 检查：uncertainty 让 required time **提前**（更严）
- hold 检查：uncertainty 让 required time **推后**（更严）
- CTS 前 uncertainty 通常较大（包含 skew 估计）；CTS 后 skew 由真实时钟树算出，uncertainty 减小到只剩 jitter + margin
- 为什么 hold 的 uncertainty 通常不含 jitter：hold 检查的 launch 和 capture 是**同一个沿**，同一个沿上的周期抖动对两者的影响相同，可以互相抵消（仍保留 skew 和 margin）

### 5.5 时钟 transition（slew）

时钟边沿的上升/下降时间。影响寄存器的 Tcq、Tsetup、Thold（都是查表）。CTS 前用 `set_clock_transition` 估计。

### 5.6 生成时钟、虚拟时钟

- **生成时钟**（分频器、时钟门控输出、PLL 输出）：`create_generated_clock`，工具会把源时钟的延时传递过来，并知道它和源时钟的相位关系。
- **虚拟时钟**：不连接任何端口/引脚，只用来描述**片外**器件的时钟，做 IO 约束参考。

---

## 6. 延时是怎么算出来的

路径延时 = 各级**单元延时（cell delay）** + **线延时（net delay）**。

### 6.1 单元延时：NLDM 查找表

liberty（`.lib`，工业上编译成 `.db`）里，每个单元每条 timing arc（输入引脚 → 输出引脚）有两张二维表：

- **cell_rise / cell_fall**：延时 = f(输入 slew, 输出负载电容)
- **rise_transition / fall_transition**：输出 slew = f(输入 slew, 输出负载电容)

```
            输出负载 →  0.001pF  0.01pF  0.05pF
输入 slew ↓
   0.01ns            0.05     0.09     0.25
   0.10ns            0.07     0.11     0.28
   0.50ns            0.15     0.20     0.37     （单位 ns）
```

不在表格点上的值用插值（或超出范围时外推，外推结果不可信 → 这也是要限制 max transition / max cap 的原因之一）。

- **slew 会沿路径传播**：前一级的输出 slew 是后一级的输入 slew。一个大负载让 slew 变差，会拖慢后面所有单元。
- 更精确的模型：**CCS**（Composite Current Source）、**ECSM**，用电流/电压波形描述驱动能力，先进工艺签核使用。
- setup/hold/recovery/removal 等约束值本身也是查表：f(数据端 slew, 时钟端 slew)。

### 6.2 线延时

- 综合阶段：**wire load model**（按扇出估线长 → RC）或物理综合的估算
- 布局后：按估算走线长度
- 布线 + 抽取后：**SPEF** 里的真实 RC 网络，用 Elmore 或更精确的算法（如 Arnoldi）计算延时和 slew 劣化
- 先进工艺中，线延时占比很大；还要考虑**串扰（crosstalk / SI）**：相邻线同向翻转加速，反向翻转减速 → PrimeTime SI 会计算 delta delay

### 6.3 unateness（单调性）

timing arc 的输入变化方向和输出变化方向的关系：

- positive unate：输入上升 → 输出上升（buffer、AND）
- negative unate：输入上升 → 输出下降（inverter、NAND）
- non-unate：取决于其它输入（XOR）

所以报告里每级都标 `^`（rise）或 `v`（fall），同一条路径会分 rise/fall 分别分析。

---

## 7. PVT、corner、OCV 与 CRPR

### 7.1 PVT

| 因素 | 对延时的影响 |
|------|--------------|
| **P**rocess（工艺） | SS（慢 NMOS 慢 PMOS）最慢，FF 最快，TT 典型，还有 SF/FS |
| **V**oltage（电压） | 电压低 → 慢 |
| **T**emperature（温度） | 传统：温度高 → 慢；先进工艺低电压下有**温度反转**：低温反而更慢 |

库文件名体现 corner，如本机的 `sky130_fd_sc_hd__tt_025C_1v80.lib`、`ss_100C_1v60`、`ff_n40C_1v95`。

### 7.2 用哪个 corner 查什么

- **setup**：看**慢** corner（SS、低压、高温；有温度反转时还要看低温）
- **hold**：看**快** corner（FF、高压、低温）——但签核时所有 corner 的 setup 和 hold 都要查
- **RC corner**：互连也有偏差：Cworst、Cbest、RCworst、RCbest、typical。setup 常配 RCworst/Cworst，hold 常配 Cbest/RCbest
- **MCMM**（多 corner 多模式）：把 {工艺 corner × RC corner × 工作模式（功能模式、测试模式等）} 组合起来同时分析和优化

### 7.3 OCV（片上偏差）

同一颗芯片上，不同位置的晶体管也有差异（掺杂、光刻、局部电压降、局部温度）。STA 用**悲观**处理：

- setup 检查：launch 时钟路径 + 数据路径用**偏慢**（late derate，如 ×1.05），capture 时钟路径用**偏快**（early derate，如 ×0.95）
- hold 检查：反过来

```tcl
set_timing_derate -late  1.05
set_timing_derate -early 0.95
```

演进：

| 方法 | 思路 |
|------|------|
| OCV（flat derate） | 所有单元统一乘一个系数，过于悲观 |
| AOCV | 按路径逻辑深度、物理距离查表给 derate：路径越长，随机偏差越会互相抵消，derate 越小 |
| POCV / SOCV | 每个单元带统计延时（均值 + σ），沿路径做统计合成，按 3σ 取值；先进工艺主流 |

### 7.4 CRPR / CPPR（时钟重汇聚悲观去除）

launch 和 capture 的时钟路径通常有一段**公共部分**。OCV 对公共部分同时用了慢值（launch）和快值（capture），但同一段物理走线不可能同时又快又慢——这是虚假的悲观量。

```
          公共时钟路径（同一组 buffer）
CLK ───►[B1]──►[B2]──┬──►[B3]──► FF1/CK   (launch：B1、B2 按 late)
                     └──►[B4]──► FF2/CK   (capture：B1、B2 按 early)
```

CRPR 把公共段 late 与 early 的差值加回 slack。lab 报告里的 `clock reconvergence pessimism` 一行就是它（理想时钟下为 0）。

---

## 8. 时序例外

默认情况下，STA 认为所有路径都是单周期同步路径。例外（exception）用于告诉工具“这条路径不按默认规则算”。

### 8.1 false path（伪路径）

结构上存在、功能上不会发生或不需要满足时序的路径：

- 异步时钟域之间（更推荐用 `set_clock_groups`）
- 上电后只配置一次的静态寄存器（准静态信号）
- 互斥 MUX 选择下不可能同时成立的路径
- 测试模式专用路径（在功能模式里）

```tcl
set_false_path -from [get_clocks clk_a] -to [get_clocks clk_b]
set_false_path -from [get_ports cfg_mode*]
```

**风险**：false path 写错 = 把真实路径藏起来，芯片会坏。要尽量窄、要评审。

### 8.2 multicycle path（多周期路径）——必考

数据每 N 个周期才更新一次、下游也 N 个周期才采样一次（例如带使能的慢速运算）。

```tcl
set_multicycle_path 2 -setup -from [get_cells src_reg*] -to [get_cells dst_reg*]
set_multicycle_path 1 -hold  -from [get_cells src_reg*] -to [get_cells dst_reg*]
```

为什么 hold 要写 `N−1`：

```
沿:       0        1        2
launch    ●
setup 默认检查沿：        1      → MCP setup 2 后移到 2
hold  默认检查沿：setup 沿的前一个沿
      setup 移到 2 后，hold 也跟着移到 1（太严，工具会要求数据在沿 1 之后才变）
      -hold 1 把 hold 检查拉回沿 0  ← 这才是我们想要的
```

- 只写 `-setup 2` 不写 hold：hold 检查沿随之后移一个周期，变成极难满足的 hold，工具会疯狂插 buffer。
- 同频同相时：setup N ⇒ hold N−1。
- 跨频率时要注意 `-start` / `-end`：setup 默认以 capture 时钟（`-end`）计周期，hold 默认以 launch 时钟（`-start`）计。

### 8.3 max / min delay

直接给路径指定最大/最小延时，覆盖默认的周期推导：

```tcl
set_max_delay 2.0 -from [get_ports a] -to [get_ports y]       ;# in→out 组合路径
set_max_delay 3.0 -datapath_only -from $gray_src -to $sync1   ;# CDC：只算数据路径（PrimeTime 支持）
```

### 8.4 clock groups

```tcl
set_clock_groups -asynchronous -group {clk_w} -group {clk_r}                   ;# 互为异步
set_clock_groups -logically_exclusive  -group {clk_a} -group {clk_b}         ;# MUX 选择，逻辑上不同时存在
set_clock_groups -physically_exclusive -group {clk_func} -group {clk_test}   ;# 物理上不可能同时存在
```

- asynchronous：两组时钟间不做时序分析；**SI 分析仍会考虑它们的串扰**（相位任意）
- physically_exclusive：连串扰也不考虑（同一根线上不会同时出现）

### 8.5 case analysis

把某个信号固定为常量，工具据此把无效的路径剪掉（例如 `test_mode = 0` 做功能模式分析）：

```tcl
set_case_analysis 0 [get_ports test_mode]
```

### 8.6 例外优先级

大致：`false path` > `max/min delay` > `multicycle`；同类中越具体（`-from pin` 比 `-from clock` 具体）优先级越高。

---

## 9. 其它时序检查

### 9.1 recovery / removal（异步复位/置位）

异步复位**释放**（deassert）时，相对时钟沿也有类似 setup/hold 的要求：

- **recovery**：复位释放必须在时钟沿**之前**多久完成（类比 setup）
- **removal**：复位释放必须在时钟沿**之后**多久才能发生（类比 hold）

违反 → 某些寄存器在这个沿退出复位、某些在下个沿退出，或进入亚稳态。复位**拉起**（assert）是异步的，不需要检查。

lab 报告里：`library recovery time -0.724`、`library removal time 0.443`，路径组叫 `**async_default**`。

### 9.2 时钟门控检查（clock gating check）

用 AND 门做门控：`gclk = clk & en`。en 必须在 clk 为**低**时变化，否则 gclk 上出现毛刺/截断脉冲。

- 工具在门控单元的 enable 引脚上自动推断 **gating setup / gating hold** 检查
- 工业上用 **ICG**（集成门控单元 = latch + AND），latch 在 clk 低时透明，把 en 锁住，天然无毛刺；ICG 本身有 setup/hold 要求

### 9.3 最小脉宽、最小周期

`min_pulse_width`：时钟高/低电平不能太窄（库给出寄存器、存储器要求）。时钟树上 rise/fall 不对称会压缩脉宽。

### 9.4 DRV（设计规则违例）

不是时序检查，但 STA 工具一并报告：

| 规则 | 为什么限制 |
|------|------------|
| max transition（slew） | slew 太大 → 延时查表外推不准、功耗高、噪声敏感 |
| max capacitance | 驱动能力不足，超出库表格范围 |
| max fanout | 间接控制负载与线长 |

lab 中的真实例子：`rst_w` 一个 buf_2 直接驱动几百个触发器的 RESET_B，slew 3.74 ns，远超 1.0 ns 限制——真实流程会由综合/布局插 buffer 树修复（第 15 节）。

### 9.5 latch 与时间借用（time borrowing）

latch 在使能期间透明。若数据到达 latch 时 latch 已打开，数据可以直接穿过，**借用**下一级的时间：

- 借用上限：大约到 latch 关闭沿前 Tsetup
- 好处：路径间动态平衡延时；坏处：分析复杂、hold 更难（透明期长），所以 ASIC 里主要逻辑还是用 DFF

### 9.6 半周期路径

上升沿 FF → 下降沿 FF：setup 只有半个周期；时钟占空比误差直接吃掉裕量。报告里 capture 会显示 `(fall edge)`。

---

## 10. 复位方式

### 10.1 同步复位 vs 异步复位

```verilog
// 同步复位：复位只在时钟沿生效，本质是 D 前面一个 MUX/AND
always @(posedge clk)            if (!rst_n) q <= 0; else q <= d;

// 异步复位：复位立即生效，接触发器的 RESET 引脚
always @(posedge clk or negedge rst_n) if (!rst_n) q <= 0; else q <= d;
```

| | 同步复位 | 异步复位 |
|--|----------|----------|
| 需要时钟才能复位 | 是 | 否 |
| 对毛刺 | 不敏感（只在沿采样） | 敏感，复位线毛刺会误复位 |
| 时序 | 复位是普通数据路径，占用 D 端组合逻辑 | 释放需满足 recovery/removal |
| 面积 | 多一级逻辑，但可用普通 DFF | 需带复位端的 DFF（稍大） |
| 复位脉宽 | 必须 ≥ 一个时钟周期 | 可以很短 |
| 上电时时钟未起振 | 无法复位 | 可以复位 |

### 10.2 异步复位、同步释放（最常用，必考）

问题：异步复位的**释放**是异步的，可能落在时钟沿附近 → recovery/removal 违例 → 亚稳态、不同寄存器在不同周期退出复位。

解决：复位**拉起**直接异步；**释放**先经两级同步器与时钟对齐：

```verilog
module reset_sync (
    input  clk,
    input  arst_n,       // 外部异步复位
    output srst_n        // 给本时钟域使用
);
    reg r1, r2;
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            r1 <= 1'b0;
            r2 <= 1'b0;
        end else begin
            r1 <= 1'b1;   // 释放时，1 从 D 端逐级打进来
            r2 <= r1;
        end
    end
    assign srst_n = r2;
endmodule
```

- `arst_n` 拉低：r1、r2 立刻清 0 → 复位立即生效（异步拉起）
- `arst_n` 释放：r1 的 D 是常量 1，可能亚稳态，r2 再打一拍 → `srst_n` 在时钟沿后干净地释放
- `srst_n` 到各寄存器 RESET 端的路径是同步路径，STA 用 recovery/removal 检查它
- 每个时钟域各自一个复位同步器（跨域复位同样是 CDC 问题）

### 10.3 复位树

复位网扇出巨大（lab 里一个端口驱动全部寄存器），需要像时钟树一样做 buffer 树，满足 slew 和 recovery/removal。复位树不需要像时钟那样平衡 skew，但延时要满足检查。

---

## 11. CDC 与 STA 的关系

- STA 假设 launch 和 capture 时钟有**确定的相位关系**。两个异步时钟之间没有，所以 STA 对跨域路径的结果**没有意义**。
- 如果不告诉工具，它会在两个时钟的所有沿里找**最近的一对**来检查——lab 实验 2 里 5 ns 和 7 ns 两个时钟，工具找到了只相距 1 ns 的沿，报出大量假违例。
- 正确做法：
  1. 设计上用同步器、异步 FIFO、握手保证功能正确
  2. CDC 静态检查工具（SpyGlass CDC、Questa CDC、Conformal CDC 等）检查同步结构是否完整
  3. SDC 里用 `set_clock_groups -asynchronous` 或 `set_false_path` 排除跨域路径
  4. 对 Gray 码指针这类多 bit 同步，推荐用 `set_max_delay -datapath_only`（约为目的时钟一个周期）代替完全 false path，保证各 bit 之间的延时差不至于大到破坏 Gray 码“一次只变一位”的性质

---

## 12. SDC 详解

SDC = Synopsys Design Constraints，本质是 Tcl。综合、布局布线、STA 共用同一套（各阶段略有差异）。

### 12.1 时钟

```tcl
# 主时钟：100 MHz，默认 0 时刻上升、半周期下降
create_clock -name clk -period 10 -waveform {0 5} [get_ports clk]

# 分频时钟（在分频寄存器输出上定义）
create_generated_clock -name clk_div2 -source [get_ports clk] -divide_by 2 \
    [get_pins u_div/q_reg/Q]

# 虚拟时钟：片外器件的时钟
create_clock -name vclk -period 10

# 延时、不确定度、边沿
set_clock_latency -source 0.5 [get_clocks clk]   ;# 片外源延时
set_clock_latency 1.0 [get_clocks clk]           ;# CTS 前估计网络延时
set_clock_uncertainty -setup 0.3 [get_clocks clk]
set_clock_uncertainty -hold  0.1 [get_clocks clk]
set_clock_transition 0.1 [get_clocks clk]
set_propagated_clock [all_clocks]                ;# CTS 之后用
```

### 12.2 IO 约束

```
    片外芯片A           本芯片                     片外芯片B
[FF]──Tcq+线──► in ──► 内部逻辑 ──►[FF]──► out ──线+Tsetup──►[FF]
 └── input delay ──┘                       └── output delay ──┘
```

```tcl
# input delay：外部数据在时钟沿后多久到达端口（-max 用于 setup，-min 用于 hold）
set_input_delay  -clock clk -max 4.0 [get_ports din*]
set_input_delay  -clock clk -min 1.0 [get_ports din*]

# output delay：外部需要多少时间（外部组合 + 外部 Tsetup）
set_output_delay -clock clk -max 3.0 [get_ports dout*]
set_output_delay -clock clk -min -0.5 [get_ports dout*]   ;# 外部 hold 要求

# 同一端口对两个时钟都约束，第二条要 -add_delay，否则覆盖
set_input_delay -clock clk_b 2.0 -add_delay [get_ports din*]

# 端口电气环境
set_driving_cell -lib_cell BUFX2 [all_inputs]
set_load 0.02 [all_outputs]
```

- **时序预算**：不清楚外部情况时常用经验值，例如 input/output delay 取周期的 40%–60%，给内部留足空间。
- 时钟端口不要设 input delay；`[all_inputs]` 包含时钟端口，常用 `remove_from_collection [all_inputs] [get_ports clk]`。

### 12.3 设计规则与环境

```tcl
set_max_transition 0.5 [current_design]
set_max_capacitance 0.2 [current_design]
set_max_fanout 20 [current_design]
set_operating_conditions ss_0p72v_125c
```

### 12.4 例外

```tcl
set_false_path -from [get_clocks a] -to [get_clocks b]
set_multicycle_path 2 -setup -through [get_pins u_mul/*]
set_multicycle_path 1 -hold  -through [get_pins u_mul/*]
set_max_delay 5 -from [get_ports a] -to [get_ports y]
set_clock_groups -asynchronous -group [get_clocks {clk_a*}] -group [get_clocks {clk_b*}]
set_case_analysis 0 [get_ports scan_en]
set_disable_timing [get_cells u_loop_break] -from A -to Y   ;# 打断组合环
```

### 12.5 对象查询（PrimeTime / DC / OpenSTA 通用风格）

```tcl
get_ports clk*           get_pins u1/A        get_cells u_core/*_reg*
get_nets n123            get_clocks           all_inputs / all_outputs
all_registers -clock clk all_fanin -to [get_pins u1/D]   all_fanout -from [get_ports din]
```

### 12.6 本 lab 的 SDC

见 `lab/fifo.sdc`，覆盖：两个时钟、uncertainty、异步时钟组、IO delay（含复位端口以启用 recovery/removal 检查）、驱动单元、负载、DRV 限制。

---

## 13. 工业工具与流程

### 13.1 工具

| 厂商 | STA 签核 | 综合（内置 STA 引擎） | 布局布线 |
|------|-----------|------------------------|----------|
| Synopsys | **PrimeTime (PT / PT-SI)** | Design Compiler / Fusion Compiler | ICC2 / Fusion Compiler |
| Cadence | **Tempus** | Genus | Innovus |
| 开源 | **OpenSTA**（OpenROAD 内置） | Yosys + ABC | OpenROAD |

OpenSTA 命令与 PrimeTime 高度相似，本 lab 学到的命令迁移到 PT 基本只需改几个名字。

### 13.2 PrimeTime 典型签核脚本

```tcl
# ---------- 设置 ----------
set search_path    ". ./lib"
set link_path      "* std_ss_0p72v_125c.db sram_ss.db"

# ---------- 读入 ----------
read_verilog       top_routed.v
current_design     top
link_design                                   ;# 网表与库链接，检查缺失单元

read_parasitics    -format spef top_rcworst.spef
read_sdc           top_func.sdc
set_propagated_clock [all_clocks]             ;# 布线后使用真实时钟树

# ---------- OCV ----------
set timing_remove_clock_reconvergence_pessimism true    ;# 开 CRPR
set_timing_derate -late 1.05 -cell_delay
set_timing_derate -early 0.95 -cell_delay
# （先进工艺改用 POCV：read_ocvm / set timing_pocvm_enable_analysis true）

# ---------- SI ----------
set si_enable_analysis true

update_timing

# ---------- 检查与报告 ----------
check_timing -verbose                         ;# 未约束端点、无时钟寄存器、组合环……
report_global_timing                          ;# 各类路径 WNS/TNS/违例数总览
report_timing -delay_type max -max_paths 20 -nosplit \
              -input_pins -nets -transition_time -capacitance > setup.rpt
report_timing -delay_type min -max_paths 20 > hold.rpt
report_constraint -all_violators > viol.rpt   ;# 含 DRV
report_clock_timing -type skew
report_analysis_coverage                      ;# 有多少检查没被约束覆盖

# ---------- 可选：ECO ----------
fix_eco_timing -type setup
fix_eco_timing -type hold
write_changes -format icctcl -output eco.tcl  ;# 交给 ICC2/Innovus 实施
```

签核时这样的脚本会对每个 corner × mode 各跑一次（DMSA：分布式多场景分析）。

### 13.3 OpenSTA 对照（本 lab）

```tcl
read_liberty  build/lib.lib           ;# ≈ PT 的 link_path 里的 .db
read_verilog  build/fifo_netlist.v
link_design   FIFO_async
read_sdc      fifo.sdc
# read_spef   design.spef             ;# 布线后
check_setup   -verbose                ;# ≈ check_timing
report_checks -path_delay max -format full_clock_expanded   ;# ≈ report_timing -delay_type max
report_checks -path_delay min
report_wns ; report_tns
report_check_types -max_slew -max_capacitance -max_fanout -violators  ;# ≈ report_constraint
```

### 13.4 关键指标

- **WNS**（Worst Negative Slack）：最差一条的 slack
- **TNS**（Total Negative Slack）：所有违例端点 slack 之和，反映违例的“面积”
- **NVP**（Number of Violating Paths/endpoints）：违例端点数

### 13.5 时序修复手段（面试常问）

**修 setup（数据太慢）**

1. 换大驱动（upsize）或低阈值单元（LVT/ULVT，快但漏电大）
2. 插 buffer 断开大负载、优化扇出，减小 slew
3. 逻辑重构：把晚到信号挪到靠近输出的一级，化简关键路径
4. 缩短走线：布局上把相关单元靠近
5. useful skew：推迟 capture 时钟
6. 架构层面：流水线切分、retiming、多周期路径（功能允许时）
7. 降频（最后手段）

**修 hold（数据太快）**

1. 在数据路径插 buffer / delay cell（最常见）
2. 数据路径换 HVT 或更小驱动的单元
3. 调整时钟：让 capture 时钟早一点（会影响 setup）
4. 注意：修 hold 时不能把同一路径的 setup 修坏；一般先修 setup 再修 hold，最后在多 corner 下复查

**修 DRV**：插 buffer、upsize、拆分大扇出网络。

---

## 14. 读懂一份时序报告

以下来自 `lab/reports/sta.rpt`（Sky130 tt 25°C 1.8V，clk_r = 7 ns，理想时钟）。

```
Startpoint: _1286_ (rising edge-triggered flip-flop clocked by clk_r)
Endpoint: _1287_ (rising edge-triggered flip-flop clocked by clk_r)
Path Group: clk_r
Path Type: max                                     ← setup 检查

     Cap     Slew    Delay     Time   Description
---------------------------------------------------------------------------
            0.100    0.000    0.000   clock clk_r (rise edge)          ← launch 沿 0 ns
                     0.000    0.000   clock network delay (ideal)      ← 理想时钟，Tlaunch=0
            0.100    0.000    0.000 ^ _1286_/CLK (sky130_fd_sc_hd__dfrtp_1)
   0.405    3.442    2.724    2.724 ^ _1286_/Q (sky130_fd_sc_hd__dfrtp_1)
                                     ↑ Tcq 高达 2.724：Q 端负载 0.405 pF、slew 3.442 ns
                                       说明这个寄存器扇出很大（读指针驱动 32 深 RAM 的读 MUX）
            3.442    0.002    2.726 ^ _0614_/A (sky130_fd_sc_hd__xor3_1)
   0.003    0.103    0.705    3.431 ^ _0614_/X (sky130_fd_sc_hd__xor3_1)
            ...（逐级：引脚→输出，Delay 列是这一级的延时，Time 列是累计）
            0.063    0.004    4.900 v _1287_/D (sky130_fd_sc_hd__dfrtp_1)
                              4.900   data arrival time                ← AT

            0.100    7.000    7.000   clock clk_r (rise edge)          ← capture 沿 = 下一个周期
                     0.000    7.000   clock network delay (ideal)
                    -0.200    6.800   clock uncertainty                ← SDC 里的 setup uncertainty
                     0.000    6.800   clock reconvergence pessimism    ← CRPR（理想时钟下为 0）
                              6.800 ^ _1287_/CLK (sky130_fd_sc_hd__dfrtp_1)
                    -0.109    6.691   library setup time               ← 查表得到的 Tsetup
                              6.691   data required time               ← RT
---------------------------------------------------------------------------
                              6.691   data required time
                             -4.900   data arrival time
---------------------------------------------------------------------------
                              1.790   slack (MET)                      ← RT − AT
```

读报告的步骤：

1. 看 **Path Type**（max = setup，min = hold）和 **Path Group**（哪个时钟、是否 async_default）
2. 看起点、终点属于哪类路径
3. 看 launch/capture 沿是否符合预期（跨时钟、半周期、多周期路径会在这里露馅）
4. 在数据路径中找**延时大的级**，再看它的 Cap 和 Slew：大负载 / 大 slew 往往是根因
5. 看 required 侧：uncertainty、setup 时间、output delay 是否合理
6. 最后才看 slack 数值

hold 报告同理，只是 capture 沿与 launch 沿**相同**（0 ns），比较方向相反：

```
   0.330  _1384_/Q → _1378_/D 直连（同步器两级之间，没有组合逻辑）   AT = 0.334
   0.050  clock uncertainty(hold)  −0.027 library hold time          RT = 0.023
   slack = AT − RT = 0.311 (MET)
```

同步器两级之间没有逻辑，是最容易出 hold 问题的路径类型——这里靠 Tcq 本身就满足了。

---

## 15. lab 实验与结论

### 15.1 运行

```bash
# WSL（工具在 /root 下，需要 root）
sudo -i
cd "/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/07_STA/lab"
bash run.sh               # 综合 + 完整 STA 报告 → reports/sta.rpt
bash run_experiments.sh   # 两个对比实验 → reports/exp*.rpt
```

文件：

| 文件 | 作用 |
|------|------|
| `synth.ys` | Yosys：FIFO → Sky130 hd 门级网表 |
| `fifo.sdc` | 约束 |
| `sta.tcl` | 完整报告 |
| `sta_summary.tcl` | 精简报告（每组最差 3 个端点 + WNS/TNS） |
| `run.sh` / `run_experiments.sh` | 一键运行 |

### 15.2 基线结果（clk_w = 5 ns，clk_r = 7 ns）

| 路径组 | 最差 setup slack | 最差路径 |
|--------|------------------|----------|
| clk_r | +1.790 | 读侧 reg → reg（高扇出读指针） |
| clk_w | +1.639 | reg → 输出端口 `full` |
| async_default | +0.498 | `rst_w` → RESET_B 的 **recovery** 检查 |

hold 全部满足（最差 +0.311，同步器两级之间）。`check_setup` 无输出 = 没有未约束端点。

**但 DRV 不干净**：`rst_w`、`rst_r` 端口 slew 3.74 ns > 1.0 ns 限制，几百个 RESET_B 违例。原因是一个 buf_2 驱动全部寄存器复位端，Yosys 这一步没有做扇出修复。真实流程里综合（DC 的 `set_max_fanout`、`compile`）或布局后的 repair_design 会插 buffer 树。这正是第 10.3 节说的**复位树**问题；同时它也让 recovery slack 只剩 0.498 ns（2.578 ns 延时都耗在大负载上）。

### 15.3 实验 1：收紧时钟 clk_r = 3.0 ns

```
_1287_/D   required 2.691   actual 4.900   slack -2.210 (VIOLATED)
empty      required 1.800   actual 4.003   slack -2.203 (VIOLATED)
wns -2.21   tns -26.70
```

- 数据路径延时不变（4.900），required 从 6.691 降到 2.691 → 违例
- hold 结果**完全不变**（仍 +0.311）：验证了“hold 与周期无关”
- 修法思路：给读指针寄存器的扇出插 buffer（Tcq 2.7 ns 基本是负载造成的）、换更大驱动、重构 empty 比较逻辑，或者流水化

### 15.4 实验 2：去掉 `set_clock_groups`

```
clk_w 组： _1375_/D  required 14.739  actual 17.210  slack -2.471 (VIOLATED)
clk_r 组： _1386_/D  required 20.732  actual 21.251  slack -0.519 (VIOLATED)
wns -2.47
```

- 工具把跨域路径当同步路径分析：5 ns 和 7 ns 的公共周期是 35 ns，它在其中找到**最近的一对**沿：clk_r 在 14 ns 发出，clk_w 在 15 ns 捕获——只给 1 ns
- required 14.739 = 15 − 0.2（uncertainty）− setup；arrival 17.21 = 14 + 路径延时
- 终点是同步器第一级、以及 RAM 读出寄存器——正是跨域点
- 结论：**这些是假违例**。异步时钟必须声明 clock groups（或 false path / datapath_only max delay），否则工具会为不存在的约束去“修”电路，浪费面积还可能改坏设计

### 15.5 可以继续做的实验

- `LIB` 换成 `ss_100C_1v60.lib` 看 setup 变差，换 `ff_n40C_1v95.lib` 看 hold
- 在 `fifo.sdc` 里给某条路径加 `set_multicycle_path 2 -setup`，不加 hold，观察 hold 检查沿后移
- 删掉复位端口的 `set_input_delay`，观察 recovery/removal 检查变成未约束（`check_setup` 会报）

---

## 16. 速查表

```
setup:  Tcq + Tcomb_max + Tsetup + Tunc ≤ T + Tskew          (Tskew = Tcap − Tlaunch)
hold:   Tcq + Tcomb_min ≥ Thold + Tunc + Tskew
setup slack = RT − AT       hold slack = AT − RT
正 skew：利 setup 害 hold          hold 与频率无关，降频救不了
setup → 慢 corner(SS/低V/高T*)     hold → 快 corner(FF/高V/低T)    *温度反转时低温慢
MCP：-setup N 配 -hold N−1
OCV：setup 时 launch+data 慢、capture 快；CRPR 去除公共时钟路径悲观
异步复位：拉起异步，释放同步（两级同步器）；释放检查 recovery/removal
异步时钟：set_clock_groups -asynchronous；CDC 正确性靠设计 + CDC 工具，不靠 STA
input delay -max/-min → setup/hold；output delay 同理
理想时钟(CTS前) → set_propagated_clock(CTS后)
WNS 最差一条，TNS 违例总和
```
