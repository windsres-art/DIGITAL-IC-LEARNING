# 14 后端物理设计（Physical Design）—— 面试向

目标：前端 / 验证岗位面试里被问到后端时能讲清楚——一份门级网表是怎样一步步变成可以流片的版图（GDSII）的；每一步解决什么问题、看哪些指标、常见问题怎么修；读得懂后端工具的主要报告（拥塞、DRC、skew、SPEF、IR drop、LVS）；知道签核（signoff）要查哪些项、ECO 是怎么回事。不要求会调商业工具的每个参数。

前置知识：

- 建立/保持时间、时钟 latency/skew/uncertainty、recovery/removal：`../07_STA/README.md` 第 4、5、9.1 节
- PVT 与 RC corner、OCV、CRPR：`../07_STA/README.md` 第 7 节；时序修复手段：第 13.5 节
- 逻辑综合与网表、门级仿真：`../08_Logic_Synthesis/README.md` 第 1、2.4 节
- 时钟树的前端视角、复位同步：`../05_Clock_Reset_Design/README.md` 第 1.3、5 节

建议顺序：第 0 节（总览）→ 跑 `lab/PnR_Flow/run.sh`，边看报告边读第 1–8 节 → 跑 `run_experiments.sh` 对照各节的"实验"小节 → 每节末尾的面试题 → 速查表。

配套实验（全部在 WSL 中实际跑通，README 里贴的是真实输出）：

| 实验 | 内容 |
|------|------|
| `lab/PnR_Flow/run.sh` | 第 08 章的 16 bit ALU：Yosys 综合 → OpenROAD 布图/电源网络 → 布局 → CTS → 布线 → OpenRCX 三个 RC corner 抽取 → OpenSTA 三 corner 签核 → 时序 ECO → PDNSim IR drop/EM → Magic GDS + DRC → Netgen LVS → 布线后网表门级仿真，约 6 分钟 |
| `lab/PnR_Flow/run_experiments.sh` | 7 组对比实验：利用率扫描、不插天线二极管、电源条间距、关掉优化、签核周期扫描、不修补 met3 最小面积、供电点间距，约 13 分钟 |

工艺：SkyWater **Sky130**（130 nm，开源 PDK），标准单元库 `sky130_fd_sc_hd`。金属层从下往上：`li1`（局部互连）、`met1`–`met5`，`met5` 最厚。开源工具与工业工具的对应关系见第 0 节。

---

## 目录

0. [后端流程总览](#0-后端流程总览)
1. [布图与电源规划](#1-布图与电源规划)
2. [布局](#2-布局)
3. [时钟树综合](#3-时钟树综合)
4. [布线](#4-布线)
5. [寄生参数抽取](#5-寄生参数抽取)
6. [物理验证（DRC / LVS / 天线）](#6-物理验证drc--lvs--天线)
7. [IR drop 与电迁移](#7-ir-drop-与电迁移)
8. [签核与 ECO](#8-签核与-eco)
9. [运行全部实验](#9-运行全部实验)
10. [速查表](#10-速查表)

---

## 0. 后端流程总览

**物理设计**（physical design，俗称"后端"）：给定门级网表、时序约束和工艺库，决定每个单元放在芯片的哪个位置、每根连线走哪一层金属的哪条轨道，并保证结果满足时序、功耗、面积，以及代工厂的制造规则。

```
 门级网表 (.v) + SDC + liberty (.lib) + LEF (tech LEF + 单元 LEF)
        │
        ▼
 ① 布图与电源规划 ── 芯片尺寸、IO、宏单元、row、电源网络
        ▼
 ② 布局 ─────────── 全局布局 → 合法化 → 详细布局；布局优化（修 DRV、时序）
        ▼
 ③ 时钟树综合 ───── 建时钟树，修 hold
        ▼
 ④ 布线 ─────────── 全局布线（查拥塞）→ 详细布线（查 DRC）
        ▼
 ⑤ 寄生参数抽取 ─── 走线 → RC 网络（SPEF）
        ▼
 ⑥ 签核 ─────────── STA（多 corner）｜ 物理验证 DRC/LVS/天线 ｜ IR drop/EM ｜ LEC ｜ 门级仿真
        │                    │
        │ 有违例 ◄───────────┘
        ▼
 ⑦ ECO ──────────── 小改动 → 增量布局布线 → 回到 ⑤ ⑥
        ▼
      GDSII / OASIS ──► 流片（tape-out）
```

### 0.1 后端里的文件格式

| 格式 | 内容 | 本 lab 里的文件 |
|------|------|-----------------|
| **tech LEF** | 每层金属的方向、线宽、间距、via 定义、方块电阻、天线规则 | `sky130_fd_sc_hd__nom.tlef` |
| **单元 LEF**（Library Exchange Format） | 每个单元的抽象视图：尺寸、引脚形状和所在层、内部障碍（obstruction）。后端只看这个，不看晶体管 | `sky130_fd_sc_hd.lef` |
| **liberty** | 时序、功耗、功能（第 07 章第 6 节） | `sky130_fd_sc_hd__{tt,ss,ff}*.lib` |
| **DEF**（Design Exchange Format） | 设计的物理状态：die 尺寸、row、单元位置、pin、走线 | `build/alu.def` |
| **SPEF**（Standard Parasitic Exchange Format） | 抽取出的每条网的 RC | `build/alu.{min,nom,max}.spef` |
| **GDSII / OASIS** | 最终版图的多边形，交给代工厂 | `build/alu.gds` |
| **SDF**（Standard Delay Format） | 每个单元/每条线的延时，给带时序的门级仿真用 | 本 lab 未做 |
| OpenDB（`.odb`） | OpenROAD 的内部数据库，相当于 Innovus 的 `.enc` / ICC2 的 NDM | `build/*.odb` |

### 0.2 工具对照

| 步骤 | 工业工具 | 本 lab（开源） |
|------|----------|----------------|
| 布局布线（P&R） | Cadence Innovus、Synopsys ICC2 / Fusion Compiler | OpenROAD（ifp / pdngen / gpl / rsz / dpl / cts / grt / drt） |
| 寄生抽取 | Synopsys StarRC、Cadence Quantus | OpenRCX |
| 签核 STA | PrimeTime、Tempus | OpenSTA |
| 物理验证 | Siemens Calibre、Synopsys ICV、Cadence Pegasus | Magic（DRC、抽取）+ Netgen（LVS） |
| IR drop / EM | Ansys RedHawk、Cadence Voltus | OpenROAD PDNSim |
| 形式验证 | Formality、Conformal | Yosys（第 08 章） |

Innovus 常用命令和本 lab 命令的对应：`floorPlan` ↔ `initialize_floorplan`，`addRing`/`addStripe`/`sroute` ↔ `add_pdn_ring`/`add_pdn_stripe`/`pdngen`，`place_opt_design` ↔ `global_placement` + `repair_design` + `detailed_placement`，`ccopt_design` ↔ `clock_tree_synthesis`，`routeDesign` ↔ `global_route` + `detailed_route`，`optDesign -postRoute -hold` ↔ `repair_timing -hold`，`ecoRoute` ↔（本机无，见第 8 节），`streamOut` ↔ Magic `gds write`。

### 0.3 本 lab 的设计

第 08 章的 16 bit ALU（`../08_Logic_Synthesis/lab/Yosys_Flow/alu.v`），带输入输出寄存器、异步复位，54 个触发器。约束 `alu.sdc`：时钟 5 ns（200 MHz），IO delay 取周期的 30%，最大扇出 16、最大 transition 1.0 ns。

整个流程各阶段的面积和 tt corner 时序变化（都来自 `run.log`，单位 ns）：

| 阶段 | 面积 µm² / 利用率 | 寄生来源 | setup WS | hold WS |
|------|------------------|----------|---------:|--------:|
| 综合 | 4339（555 单元） | — | — | — |
| 布图（加 tap/endcap） | 4514 / 42% | — | — | — |
| 全局布局后 | | 按布局估线长 | -0.844 | 0.491 |
| 修 DRV + 详细布局后 | 5102 / 48% | 按布局估线长 | -0.296 | 0.165 |
| CTS 后 | | 真实时钟树 | -0.099 | -0.180 |
| CTS 后修复 | 5206 / 49% | | 0.004 | 0.097 |
| 全局布线后 | | 按全局布线估 | -0.371 | 0.149 |
| 详细布线 + 抽取（签核） | | SPEF | -0.104 | 0.129 |
| 时序 ECO 后（签核） | 5354 / 50% | SPEF | **0.087** | 0.126 |

两点值得记住：**每一步的时序数字都会变**，越往后越接近真实；**估算不一定偏乐观也不一定偏悲观**（全局布线估计 -0.371，真实抽取 -0.104），所以签核必须用抽取后的 SPEF。

---

## 1. 布图与电源规划

### 1.1 为什么需要，在流程中的位置

布图（floorplan）是后端第一步，决定芯片多大、形状如何、IO 在哪、宏单元（SRAM、PLL、模拟 IP）放在哪、电源怎么送进来。后面每一步都在这个框架里做优化：布图没做好（宏单元挡住了通道、电源条太稀），布局布线再怎么调也救不回来，只能重新布图。

### 1.2 核心概念

```
 ┌──────────────── die（芯片边界）────────────────┐
 │  IO pin ▪ ▪ ▪ ▪ ▪ ▪ ▪ ▪ ▪ ▪ ▪ ▪                 │
 │   ┌═══════════ 电源环 ring (met4/met5) ═══════┐ │
 │   ║ ┌───────────── core（核心区）──────────┐ ║ │
 │   ║ │ E|  row  ▭▭▭ ▭▭ T ▭▭▭▭ ▭ T ▭▭   |E │ ║ │ ← met1 followpin（VDD）
 │   ║ │ E|  row  ▭▭ T ▭▭▭▭ ▭▭▭ T ▭▭▭    |E │ ║ │ ← met1 followpin（VSS）
 │   ║ │ E|  row  ▭▭▭▭ ▭ T ▭▭ ▭▭▭▭ T ▭   |E │ ║ │
 │   ║ │    ║          ║          ║          │ ║ │ ║ = met4 竖向 strap
 │   ║ └───────────────────────────────────────┘ ║ │ E = endcap，T = tap
 │   └═════════════════════════════════════════╝ │
 └─────────────────────────────────────────────────┘
```

| 概念 | 含义 |
|------|------|
| **die / core** | die 是整颗芯片（或整个 block）的边界；core 是能放标准单元的区域，core 与 die 之间留给 IO 和电源环 |
| **row / site** | 标准单元等高（Sky130 hd 高 2.72 µm），排成一行行 row；每行由 site（hd 的 `unithd` 宽 0.46 µm）组成，单元宽度是 site 的整数倍。相邻两行上下翻转，共用电源轨 |
| **track** | 每层金属上允许走线的格点线，间距（pitch）来自 PDK，比如 met1 0.34 µm、met2 0.46 µm |
| **利用率**（utilization） | 标准单元面积 / core 面积。太高布不通，太低浪费面积、线长变长 |
| **宏单元摆放**（macro placement） | 一般靠边或靠角放，引脚朝向核心；宏单元之间留足通道（channel）给布线；加 halo（周围一圈禁止放单元的区域）；按数据流摆放，减少长线 |
| **placement blockage** | 禁止或限制放单元的区域：hard（完全禁止）、soft（只允许优化时放 buffer）、partial（限制密度，比如 ≤ 50%） |
| **tap cell**（阱接触单元） | 把 N 阱接 VDD、P 衬底接 VSS，防止**闩锁效应**（latch-up）。有些库的普通单元里没有阱接触，必须按固定间距插入 |
| **endcap** | 每行两端的边界单元，保证阱在行尾正确闭合、满足边界 DRC |

**电源网络**（PDN，Power Delivery Network）从外到内三级：

| 层级 | 本 lab | 作用 |
|------|--------|------|
| 电源环（ring） | met4 竖、met5 横，宽 1.6 µm | 围住 core，把芯片外（pad/bump）来的电流分配到四周 |
| 条带（strap / stripe） | met4 竖、met5 横，宽 1.6 µm，间距 27.2 µm | 把电流送到核心内部 |
| 跟随轨（followpin / rail） | met1，宽 0.48 µm，每个 row 边界一条 | 单元的 VPWR/VGND 引脚直接接在上面 |

电源用上层金属的原因：上层金属厚、方块电阻小（Sky130 tech LEF：met1/met2 为 0.125 Ω/□，met3/met4 为 0.047 Ω/□，met5 为 0.0285 Ω/□）。strap 越密 IR drop 越小，但占用的布线资源越多——这是电源规划的基本取舍（第 7 节实验 C）。

### 1.3 公式与数值例子

按目标利用率反推 core 尺寸：

```
A_core = Σ A_cell / U          W_core = H_core = √A_core   （aspect ratio = 1）
```

本 lab：综合后单元面积 4339 µm²，目标 U = 40%：

- A_core = 4339 / 0.40 = 10848 µm²，边长 ≈ 104.2 µm；
- 高度要取整到 row 高 2.72 µm 的整数倍：38 行 × 2.72 = 103.36 µm；宽度取整到 site 宽 0.46 µm：225 个 site × 0.46 = 103.50 µm；
- die = core + 两边各 8 µm（`-core_space 8`，放电源环和 IO）≈ 120.16 µm；
- 实际利用率 = (4339 + tap/endcap 175) / (103.50 × 103.36) = 4514 / 10698 = 42%。

利用率的经验值：一般标准单元 block 起始 50%–70%，拥塞严重或时序很紧的设计要更低；布局优化、CTS、hold 修复都会继续加单元（本 lab 从 42% 涨到 50%），所以要预留余量。

### 1.4 工具与脚本

`lab/PnR_Flow/1_floorplan.tcl` 的核心部分：

```tcl
# 按目标利用率反推核心面积；core_space = 核心区到芯片边的距离，给电源环和 IO 留地方
initialize_floorplan -utilization $UTIL -aspect_ratio 1 -core_space 8 -site unithd
```

```tcl
define_pdn_grid -name core_grid -voltage_domains CORE -starts_with POWER
# 电源环：核心区四周一圈 met4（竖）/ met5（横）
add_pdn_ring   -grid core_grid -layers {met4 met5} -widths {1.6 1.6} \
               -spacings {1.6 1.6} -core_offsets {1.6 1.6}
# followpin：沿每一行上下边的 met1 电源轨，单元的 VPWR/VGND 直接接在上面
add_pdn_stripe -grid core_grid -layer met1 -width 0.48 -followpins
# 条带（strap）：met4 竖向、met5 横向，把电流从环送到核心内部
add_pdn_stripe -grid core_grid -layer met4 -width 1.6 -pitch $STRAP_PITCH \
               -offset [expr {$STRAP_PITCH / 2}] -extend_to_core_ring
add_pdn_stripe -grid core_grid -layer met5 -width 1.6 -pitch $STRAP_PITCH \
               -offset [expr {$STRAP_PITCH / 2}] -extend_to_core_ring
add_pdn_connect -grid core_grid -layers {met1 met4}
add_pdn_connect -grid core_grid -layers {met4 met5}
pdngen
```

真实输出（`reports/1_floorplan.log`，节选）：

```
[WARNING IFP-0028] Core area lower left (8.000, 8.000) snapped to (8.280, 8.160).
[INFO IFP-0001] Added 38 rows of 225 sites.
[INFO PPL-0002] Number of I/O            56
[INFO TAP-0004] Inserted 76 endcaps.
[INFO TAP-0005] Inserted 140 tapcells.
Type: stdcell, core_grid
    Core Rings
      Layer: met4  -  width: 1.600  spacing: 1.600  core_offset: 1.600
      Layer: met5  -  width: 1.600  spacing: 1.600  core_offset: 1.600
    Stdcell Rails
      Layer: met1  -  width: 0.480  pitch: 5.440
    Straps
      Layer: met4  -  width: 1.600  pitch: 27.200  offset: 13.600
      Layer: met5  -  width: 1.600  pitch: 27.200  offset: 13.600
    Connect: {met1 met4} {met4 met5}
FLOORPLAN die  120.16 x 120.16 um
FLOORPLAN core 103.50 x 103.36 um  rows 38
Design area 4514 u^2 42% utilization.
```

- 左下角从 (8.000, 8.000) 被吸附到 (8.280, 8.160)：core 边界必须落在 site / row 的格点上。
- 76 个 endcap = 38 行 × 每行两端；met1 rail 的 pitch 5.44 µm = 两个 row 高（VDD 和 VSS 轨交替）。

### 1.5 速查

| 项 | 要点 |
|----|------|
| 利用率 | 单元面积 / core 面积；起始 50%–70%，要给优化、CTS、hold buffer 留余量 |
| 宏单元 | 靠边、引脚朝内、留通道、加 halo、按数据流 |
| tap / endcap | 防 latch-up / 行尾阱闭合，布图时插入，之后不能动 |
| PDN | ring → strap → rail；上层厚金属走电源；密度与布线资源取舍 |

### 1.6 面试题

**Q1. 利用率怎么定？太高、太低分别有什么问题？**  
按单元面积和目标利用率反推 core 面积，起始一般 50%–70%。太高：布局没有空间做优化和插 buffer，局部拥塞导致布不通、DRC 收敛不了（本 lab 实验 A：75% 目标在 CTS 合法化时直接失败）。太低：面积浪费，单元分散、线长变长，功耗和延时都变差。

**Q2. 宏单元摆放有哪些原则？**  
放在 core 边缘或角落，引脚朝向标准单元区；宏单元之间、宏单元与边界之间留足布线通道，避免狭窄的缝（notch）；周围加 halo；按数据流就近摆放相互通信的宏单元；注意宏单元对电源网络的遮挡，给它单独加电源环或 strap。

**Q3. 为什么要插 tap cell？**  
CMOS 的寄生 PNPN 结构可能被触发形成低阻通路（latch-up）。阱和衬底必须以足够小的间距接到 VDD/VSS，让寄生三极管的基极电阻足够小。很多标准单元库为了省面积不在每个单元里做阱接触，改用 tap cell 按规定间距插入。

**Q4. 电源网络由哪些部分组成？为什么电源走上层金属？**  
电源环、strap、followpin rail，加上它们之间的 via。上层金属厚、方块电阻小，适合大电流；而且下层金属要留给信号线（单元引脚在下层）。

**Q5. 电源 strap 越密越好吗？**  
不是。更密的 strap IR drop 更小、EM 更安全，但占用布线资源、增加拥塞。要在 IR drop 预算和可布线性之间取舍。

---

## 2. 布局

### 2.1 为什么需要，在流程中的位置

布局（placement）决定每个标准单元的位置。它直接决定线长，从而决定时序、功耗和能不能布通。布局阶段也是**做物理优化最方便的时候**：单元还能自由移动，插 buffer、换尺寸的代价小。

### 2.2 核心概念

布局分三步：

| 步骤 | 做什么 |
|------|--------|
| **全局布局**（global placement） | 把单元当作可以重叠的点，最小化总线长，同时用密度约束把单元摊开；工业和 OpenROAD 都用解析法（analytical，OpenROAD 的 RePlAce 基于静电场模型 + Nesterov 优化） |
| **合法化**（legalization） | 把单元挪到 row 上、对齐 site、消除重叠，尽量少移动 |
| **详细布局**（detailed placement） | 在合法的前提下做局部交换、翻转（mirroring），进一步减少线长 |

线长用 **HPWL**（Half-Perimeter Wire Length，半周长线长）估计：一条网所有引脚的外接矩形的半周长。

```
HPWL = (x_max − x_min) + (y_max − y_min)
```

例：一条 3 引脚网，引脚在 (0, 0)、(10, 4)、(6, 12) µm，HPWL = (10 − 0) + (12 − 0) = 22 µm。对 2、3 引脚的网，HPWL 就等于最短的直角斯坦纳树长度；引脚更多时 HPWL 是下界。

在此基础上，布局还要考虑：

- **时序驱动**（timing-driven）：对关键路径上的网加权，让它们更短。
- **拥塞驱动**（routability-driven）：估计每个区域的布线需求，太挤的地方把单元摊开（cell padding、降低局部密度）。
- **布局优化**：修 **DRV**（slew / cap / fanout，见第 07 章第 9.4 节）——插 buffer 或换大驱动；修 setup——upsize、插 buffer、逻辑重构；综合阶段设成 ideal network 的高扇出网（复位、scan enable）在这里做 buffer 树。
- 其它：扫描链重排（scan chain reordering，按位置重新串链以缩短线长）、spare cell（撒一些备用单元，给后期功能 ECO 用）。

### 2.3 工具与脚本

`lab/PnR_Flow/2_place.tcl` 的主干：

```tcl
# -timing_driven：按关键路径给网加权重，把关键路径上的单元拉近
# -density：每个 bin 的目标填充率；越低越“松”，给布线和后续插 buffer 留空间
global_placement -timing_driven -density $PLACE_DENSITY
estimate_parasitics -placement
timing_summary "after global_place"

report_check_types -max_slew -max_capacitance -max_fanout -violators
if {$DO_REPAIR} {
    repair_design
}

detailed_placement
optimize_mirroring
check_placement -verbose
```

真实输出（`reports/2_place.log`，节选）。全局布局后、修复前的 DRV：

```
[INFO GPL-0100] worst slack -1.67e-10
[INFO GPL-0103] Weighted 60 nets.
TIMING after global_place     setup_ws   -0.844  tns   -3.232  hold_ws    0.491
---- DRV before repair_design ----
max slew
Pin                                    Limit    Slew   Slack
------------------------------------------------------------
_0657_/A                                1.00    1.44   -0.44 (VIOLATED)
...
max fanout
Pin                                   Limit Fanout  Slack
---------------------------------------------------------
_1041_/Q                                 16     60    -44 (VIOLATED)
rst_n                                    16     54    -38 (VIOLATED)
_1042_/Q                                 16     54    -38 (VIOLATED)
_1040_/Q                                 16     48    -32 (VIOLATED)
in_valid                                 16     42    -26 (VIOLATED)
_1003_/Q                                 16     32    -16 (VIOLATED)
_1006_/Q                                 16     17        (VIOLATED)
[INFO RSZ-0034] Found 2 slew violations.
[INFO RSZ-0035] Found 7 fanout violations.
[INFO RSZ-0038] Inserted 20 buffers in 7 nets.
[INFO RSZ-0039] Resized 124 instances.
```

- `Weighted 60 nets`：时序驱动布局给最差的 60 条网加了权重。
- 扇出违例来自 `rst_n`（54 个触发器）和操作码寄存器（一个 Q 驱动 60 个门）。综合阶段不修这些（第 08 章 Q4），布局时按位置建 buffer 树。

合法化和详细布局：

```
original HPWL           11565.0 u
legalized HPWL          12992.0 u
delta HPWL                   12 %
[INFO DPL-0022] HPWL after            12656.1 u
[INFO DPL-0023] HPWL delta               -2.6 %
TIMING after detailed_place   setup_ws   -0.296  tns   -0.601  hold_ws    0.165
Design area 5102 u^2 48% utilization.
```

合法化让线长增加 12%（单元必须对齐 row 并去掉重叠），详细布局的翻转又收回 2.6%。

### 2.4 实验

**实验 D：关掉布局优化**（`DO_REPAIR=0`，不做 `repair_design` 和 CTS 后的 `repair_timing`），`reports/exp_summary.txt`：

```
no repair : TIMING after CTS              setup_ws   -0.746  tns   -2.589  hold_ws    0.241
            DRV 违例行数（slew/cap/fanout）: 237
主流程    : TIMING after CTS repair       setup_ws    0.004  tns    0.000  hold_ws    0.097
```

不修 DRV，`rst_n` 和操作码寄存器直接带几十个负载，slew 超过 1.0 ns 的限值，后面每一级都被拖慢，setup 从 +0.004 恶化到 -0.746。

**实验 A：利用率扫描**（布局密度取利用率 + 10%）：

```
UTIL  die_um           HPWL_um    GR_usage(met1/met2/total)  overflow  DRT_iter0  DRT_final  WL_um    GR_ws
30    136.26x136.26    14712.9    24.42%/19.60%/14.48%       0         718        0          18007    -0.287
45    114.19x114.19    12973.9    29.05%/26.80%/18.59%       0         796        0          16070    -0.326
60    101.04x101.04    12082.5    37.64%/30.45%/23.00%       0         1083       0          15662    -0.301
75    92.06x92.06      在 3_cts 失败: [ERROR DPL-0036] Detailed placement failed.
      利用率变化: 80% 89%
```

- 利用率越高，线长越短，但布线资源使用率越高，详细布线第一轮的 DRC 违例越多（718 → 1083），收敛越难。
- 75% 目标：插了 tap 之后已经 80%，修 DRV 后 89%，CTS 要插时钟 buffer 时已经没有合法位置，详细布局失败。这就是"利用率要给后面的步骤留余量"的直接证据。
- 小设计里时序对利用率不敏感（-0.287 ~ -0.326），大设计里线长的影响会明显得多。

### 2.5 速查

| 项 | 要点 |
|----|------|
| 三步 | 全局布局（解析法，最小化 HPWL + 密度）→ 合法化 → 详细布局 |
| HPWL | 外接矩形半周长；2–3 引脚网等于最短斯坦纳树 |
| 布局优化 | 修 DRV（buffer/resize）、修 setup；高扇出网建 buffer 树 |
| 拥塞 | 降密度、cell padding、blockage、调整宏单元通道 |

### 2.6 面试题

**Q1. 布局有哪几个步骤？**  
全局布局（允许重叠，优化线长和密度）→ 合法化（放到 row 和 site 上，去重叠）→ 详细布局（局部交换、翻转）。布局过程中和之后穿插做时序和 DRV 优化。

**Q2. 什么是 HPWL？为什么用它估计线长？**  
网所有引脚外接矩形的半周长。计算快、可微（解析布局要求导），并且与最终布线长度强相关；2、3 引脚的网 HPWL 就是精确的最短直角斯坦纳树长度。

**Q3. 布局阶段发现拥塞怎么办？**  
先定位拥塞来源：局部单元密度太高（降低密度、cell padding、partial blockage）、高引脚密度单元扎堆（如大 MUX、AOI，给它们加 padding）、宏单元之间通道太窄（调整布图）、PDN 占用太多资源（调整 strap）。也可以在 RTL 或综合阶段减少大扇入的逻辑结构。

**Q4. 为什么复位、scan enable 这类高扇出网在综合阶段不修，到布局才修？**  
综合没有位置信息，插的 buffer 不知道该放哪；布局后知道每个负载在哪，可以按位置聚类建 buffer 树，更小、更准。本 lab 里 `rst_n` 扇出 54，在布局阶段由 `repair_design` 插 buffer 修复。

**Q5. 时序驱动布局是怎么做的？**  
先做一轮布局和时序估计，找出关键路径上的网，提高它们在线长目标函数里的权重，再继续迭代，使关键网更短。OpenROAD 日志里的 `Weighted 60 nets` 就是这一步。

---

## 3. 时钟树综合

### 3.1 为什么需要，在流程中的位置

布局之前时钟被当作**理想时钟**：同时到达所有触发器。实际上时钟端口的一个驱动带不动几十上千个触发器，线也很长。**CTS**（Clock Tree Synthesis）在时钟源和触发器之间插一棵 buffer 树，把时钟以可控的延时送到每个触发器。前端视角的介绍见 `../05_Clock_Reset_Design/README.md` 第 1.3 节；latency、skew、uncertainty 的定义见 `../07_STA/README.md` 第 5 节。

CTS 放在布局之后、布线之前：要知道触发器的位置才能建树；时钟线又要优先于信号线拿到好的布线资源。CTS 之后有了真实 skew，才能**修 hold**。

### 3.2 核心概念

**CTS 的目标**：

| 目标 | 说明 |
|------|------|
| skew 小 | 同一时钟下相关触发器之间的到达时间差 |
| latency 适中 | 时钟源到触发器的延时；太大会放大 OCV 的影响（第 07 章第 7.3 节），跨芯片接口也受影响 |
| transition 好 | 时钟边沿要陡，否则触发器的 Tcq、setup/hold 变差，短路功耗增大 |
| 功耗低 | 时钟网每个周期翻转两次，常占动态功耗的 30%–40% |
| 占空比 | 时钟 buffer 的上升/下降延时要平衡，所以用专门的 `clkbuf`、`clkinv` |

**拓扑**：

```
H-tree（对称，skew 天然小）         clock mesh（网格，skew 最小、功耗最大）

    ┌────┴────┐                     ─┬──┬──┬──┬─   由多个驱动同时驱动一张网格，
  ┌─┴─┐     ┌─┴─┐                   ─┼──┼──┼──┼─   对工艺偏差不敏感；
  FF  FF    FF  FF                  ─┴──┴──┴──┴─   高性能 CPU 常用
```

还有常规的平衡树（balanced tree，按负载聚类后自底向上建树）和多源 CTS（multi-source：先用 H-tree 或 mesh 把时钟送到若干个 tap 点，再从 tap 点各自建小树）。

**时钟线的特殊处理**：**NDR**（Non-Default Rule）——时钟线用双倍线宽（电阻小）、双倍间距（耦合小），重要的时钟线两侧加地线屏蔽（shielding）。

**useful skew**（有用偏差）：故意让某个触发器的时钟晚到，给前一级路径"借"时间。

```
setup:  T ≥ Tcq + Tlogic + Tsetup + Tunc − (L_capture − L_launch)
hold:   Tcq + Tlogic_min ≥ Thold + Tunc + (L_capture − L_launch)
```

例：周期 5 ns，FF_A → FF_B 的路径需要 5.2 ns，FF_B → FF_C 的路径只需要 3 ns。把 FF_B 的时钟推迟 0.3 ns：A→B 的 setup 余量多 0.3 ns（修好了），B→C 的余量少 0.3 ns（还剩很多），但 **A→B 的 hold 余量也少了 0.3 ns**，要重新检查。工业工具（Innovus CCOpt、ICC2 CCD）会把时钟树和数据路径一起优化（concurrent clock and data optimization）。

**CTS 约束**（spec）一般包括：最大 skew、最大 transition、最大扇出、可用的 buffer/inverter 列表、root 驱动、不需要平衡的引脚（exclude pin）、停止传播点（stop pin）等。

### 3.3 工具与脚本

```tcl
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_8 \
    -buf_list {sky130_fd_sc_hd__clkbuf_2 sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8} \
    -sink_clustering_enable -sink_clustering_size 20 -sink_clustering_max_diameter 60
```

真实输出（`reports/3_cts.log`，节选）。CTS 前，时钟端口直接驱动全部触发器：

```
CTS_BEFORE clk 网直接驱动的 sink 数: 54
Clock clk
Latency      CRPR       Skew
_1025_/CLK ^
   0.42
_1019_/CLK ^
   0.42      0.00       0.00
```

CTS：

```
[INFO CTS-0027] Generating H-Tree topology for net clk.
[INFO CTS-0029]  Sinks will be clustered in groups of up to 20 and with maximum cluster diameter of 60.0 um.
[INFO CTS-0018]     Created 5 clock buffers.
[INFO CTS-0012]     Minimum number of buffers in the clock path: 2.
[INFO CTS-0013]     Maximum number of buffers in the clock path: 2.
[INFO CTS-0016]     Fanout distribution for the current clock = 10:1, 12:1, 13:1, 19:1..
[INFO CTS-0017]     Max level of the clock tree: 2.
---- 时钟树 ----
Clock clk
Latency      CRPR       Skew
_1003_/CLK ^
   0.40
_1016_/CLK ^
   0.37      0.00       0.03
```

- 一个根 buffer + 4 个叶子 buffer，两级。叶子 buffer 分别带 10、12、13、19 个触发器。
- CTS 前 skew 也是 0，因为所有触发器挂在同一根网上；但那是端口的一个驱动带 54 个负载，latency 0.42 ns，比建了两级 buffer 之后还大。CTS 后 skew 0.03 ns，latency 0.37–0.40 ns。设计再大一些，一个驱动就完全带不动了。
- 签核报告里 `clkbuf_2_0__f_clk` 扇出 19 超过了 SDC 的 `max_fanout 16`（第 8 节）。它的 slew 只有 0.074 ns，远低于 1.0 ns 的限值，时序没问题；工业流程一般给时钟网单独设 CTS 约束，不用逻辑优化的 `max_fanout`。本机 TritonCTS 的 H-tree 分组不受 `-sink_clustering_size` 控制（改成 12、直径 40 µm，结果完全不变）。

**CTS 后 hold 违例**——切换到 propagated clock 之后：

```
TIMING after CTS              setup_ws   -0.099  tns   -0.099  hold_ws   -0.180
```

最差 hold 是 `rst_n` 的 **removal 检查**（第 07 章第 9.1 节）：

```
                     0.500    0.500 ^ input external delay
   0.047    0.230    0.163    0.663 ^ rst_n (in)
            0.230    0.000    0.663 ^ _1023_/RESET_B (sky130_fd_sc_hd__dfrtp_2)
                              0.663   data arrival time

   0.017    0.064    0.047    0.047 ^ clk (in)
   0.033    0.070    0.155    0.202 ^ clkbuf_0_clk/X (sky130_fd_sc_hd__clkbuf_8)
   0.066    0.124    0.199    0.400 ^ clkbuf_2_0__f_clk/X (sky130_fd_sc_hd__clkbuf_8)
            0.124    0.000    0.400 ^ _1023_/CLK (sky130_fd_sc_hd__dfrtp_2)
                     0.050    0.450   clock uncertainty
                     0.392    0.843   library removal time
                              0.843   data required time
                             -0.180   slack (VIOLATED)
```

理想时钟下 required = 0.05 + 0.392 = 0.442 < 0.663，没有问题。CTS 后时钟晚到 0.400 ns，required 变成 0.843，复位撤销"太早"了。这说明 **CTS 引入的 latency 会直接吃掉输入端口的 hold 余量**。修复：`repair_timing -hold` 在复位路径上插 delay buffer：

```
[INFO RSZ-0041] Resized 2 instances.
[INFO RSZ-0046] Found 7 endpoints with hold violations.
[INFO RSZ-0032] Inserted 3 hold buffers.
TIMING after CTS repair       setup_ws    0.004  tns    0.000  hold_ws    0.097
```

真实芯片里外部复位应该先经过片内的复位同步器（第 05 章第 5 节），这样复位撤销与片内时钟同步，不会出现这个问题。

### 3.4 速查

| 项 | 要点 |
|----|------|
| 目标 | skew、latency、transition、功耗、占空比 |
| 拓扑 | H-tree / 平衡树 / mesh / 多源 |
| 时钟线 | clkbuf/clkinv（上升下降对称）、NDR（双宽双距）、屏蔽 |
| useful skew | capture 晚到：本级 setup +，下一级 setup −，本级 hold − |
| 修 hold | 在 CTS 之后；插 delay 单元，注意别把 setup 修坏 |

### 3.5 面试题

**Q1. CTS 的目标是什么？为什么不追求 skew 为 0？**  
控制 skew、latency、transition，并兼顾功耗和面积。skew 为 0 既做不到（工艺偏差），也不一定最优：时钟树越平衡，buffer 越多、功耗越大；而 useful skew 可以主动利用偏差改善关键路径。签核关心的是 setup/hold 是否满足，而不是 skew 本身。

**Q2. 为什么 hold 要在 CTS 之后才修？**  
hold 取决于 launch 和 capture 时钟的相对到达时间，理想时钟下 skew 是 0，修出来的结果不准，还会白白插 buffer。CTS 之后有了真实 skew 才能修。本 lab 里 CTS 前 hold +0.165，CTS 后 -0.180，就是时钟树延时造成的。

**Q3. 时钟 buffer 和普通 buffer 有什么区别？**  
时钟 buffer 的上升/下降延时和驱动能力更对称，保证占空比；通常驱动更强、边沿更陡。时钟反相器同理。

**Q4. 什么是 useful skew？有什么风险？**  
故意让关键路径 capture 端的时钟晚到（或 launch 端早到），把后一级（或前一级）路径的余量借过来。风险：下一级路径的 setup 余量变小，本级路径的 hold 余量变小，而且对 OCV 更敏感，要全局评估。

**Q5. 时钟网为什么要用 NDR 和屏蔽？**  
双倍线宽降低电阻、减小延时和 EM 风险；双倍间距和屏蔽减小耦合电容，避免串扰让时钟边沿抖动或改变延时。时钟网翻转最频繁、负载最多，一旦受干扰影响全部时序路径。

**Q6. 时钟树的 latency 大有什么坏处？**  
OCV 的 derate 按延时比例计算，latency 越大，launch 和 capture 时钟路径非公共部分的悲观量越大；时钟树功耗也越大；对输入输出端口，latency 会改变片内寄存器相对于端口的时序（本 lab 的复位 removal 违例）。

---

## 4. 布线

### 4.1 为什么需要，在流程中的位置

布线（routing）把每条网的引脚用金属和 via 实际连起来，结果既要满足代工厂的所有几何规则（DRC），又要满足时序和信号完整性。现代布线分两步：

| 步骤 | 做什么 | 看什么 |
|------|--------|--------|
| **全局布线**（global routing） | 把芯片切成 GCell 网格，每个 GCell 每层有若干条 track 的容量；为每条网在网格上找路径、分配层 | 拥塞：usage、**overflow**（需求 > 容量） |
| **详细布线**（detailed routing） | 在全局布线给出的通道（route guide）里，在 track 上画出真实的线和 via | DRC 违例数，迭代 rip-up and reroute 直到 0 |

两者之间还有 track assignment。布线后做 post-route 优化（修 setup/hold/SI），改动后增量布线。

### 4.2 核心概念

**布线规则**（来自 tech LEF，签核规则更全）：优选方向（Sky130 met1 横、met2 竖、met3 横、met4 竖、met5 横，交替走向，减少同层交叉）；最小线宽、最小间距（宽线和平行长线要求更大间距）；via 覆盖（enclosure）；最小面积（min area）；线端间距（end-of-line）。

**拥塞**：

```
usage = demand / resource          overflow = max(0, demand − capacity)   （按 GCell、按层统计）
```

全局布线有 overflow，详细布线基本不可能 DRC 清零；只有 usage 高但无 overflow，详细布线也会更难收敛。

**串扰**（crosstalk，SI）：相邻平行走线之间的**耦合电容** Cc。

- **delta delay**：受害线（victim）翻转时，邻近的攻击线（aggressor）同时翻转。等效电容 Ceff = Cg + k·Cc：同向翻转 k ≈ 0（变快），攻击线不动 k = 1，反向翻转 k ≈ 2（变慢）。setup 要考虑变慢，hold 要考虑变快。
- **glitch（噪声）**：受害线本来静止，攻击线翻转在它上面耦合出一个毛刺；毛刺如果超过接收单元的噪声容限并被寄存器锁存，就是功能错误。
- 修法：加大间距或屏蔽、换层、给受害线的驱动 upsize、给攻击线的驱动 downsize、插 buffer 切断长的平行段。
- 签核用 PrimeTime SI 一类工具计算（第 07 章第 6.2 节），本 lab 的 OpenSTA 不做 SI 分析。

数值例（本 lab 的真实 SPEF，第 5 节）：输出端口网 `y[0]` 在 nom corner 的对地电容 2.36 fF，耦合电容 4.16 fF。静态：Ceff = 2.36 + 4.16 = 6.52 fF；所有攻击线反向翻转：2.36 + 2 × 4.16 = 10.7 fF（+64%）；所有攻击线同向翻转：约 2.36 fF。耦合电容占了总电容的 64%，这就是 SI 分析不能省的原因。

### 4.3 工具与脚本

`lab/PnR_Flow/4_route.tcl` 的主干（天线二极管部分见第 6 节）：

```tcl
# 信号线用 met1–met4，时钟线只用 met3–met4；met5 留给电源网络
set_routing_layers -signal met1-met4 -clock met3-met4

# 行里的空隙必须填满：保证 N 阱、电源轨连续，满足密度规则
filler_placement {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 \
                  sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}

global_route -guide_file $BUILD/route.guide -congestion_iterations 50 -verbose
estimate_parasitics -global_routing
timing_summary "after global_route"

detailed_route -guide $BUILD/route.guide -output_drc $REPORTS/4_route_drc.rpt \
               -bottom_routing_layer met1 -top_routing_layer met4 \
               -droute_end_iter 20 -verbose 1
check_antennas -report_file $REPORTS/4_antenna.rpt
```

全局布线的拥塞报告（`reports/4_route.log`）：

```
[INFO GRT-0096] Final congestion report:
Layer         Resource        Demand        Usage (%)    Max H / Max V / Total Overflow
---------------------------------------------------------------------------------------
li1                  0             0            0.00%             0 /  0 /  0
met1              3856           960           24.90%             0 /  0 /  0
met2              4144          1000           24.13%             0 /  0 /  0
met3              2768            54            1.95%             0 /  0 /  0
met4              1776            20            1.13%             0 /  0 /  0
---------------------------------------------------------------------------------------
Total            12544          2034           16.21%             0 /  0 /  0
```

li1 资源为 0 是故意的（li1 只用于单元内部和进出引脚）。大部分线在 met1/met2，因为这个设计很小、线都短。

详细布线的迭代（每一轮把有违例的区域拆掉重布）：

```
[INFO DRT-0199]   Number of violations = 868.
[INFO DRT-0199]   Number of violations = 520.
[INFO DRT-0199]   Number of violations = 602.
[INFO DRT-0199]   Number of violations = 139.
[INFO DRT-0199]   Number of violations = 18.
[INFO DRT-0199]   Number of violations = 4.
[INFO DRT-0199]   Number of violations = 0.
[INFO DRT-0198] Complete detail routing.
Total wire length = 15940 um.
Total wire length on LAYER met1 = 6170 um.
Total wire length on LAYER met2 = 7712 um.
Total wire length on LAYER met3 = 1617 um.
Total wire length on LAYER met4 = 440 um.
Total wire length on LAYER met5 = 0 um.
Total number of vias = 4802.
```

违例数不是单调下降的（520 → 602）：后面几轮会逐步加大违例处的代价，把线挤到别的地方。

**一个真实的坑**：限制信号线只用到 met4 之后，全局布线日志显示 `Max routing layer: met4`，但它存进数据库的 route guide 会给个别网多扩一层到 met5（给过孔接入留余地）。详细布线如果直接用数据库里的 guide，要么报 `DRT-0155 Guide in net _0055_ uses layer met5 ... outside the allowed routing range`，要么真的在 met5 上走出一小段线——而 met5 最小线宽 1.6 µm，签核 DRC 报了 2 个 `met5.1` 违例（线宽 0.09 µm 的窄条）。最后改为让详细布线读 `-guide_file` 写出的文件版 guide（只含 met1–met4）解决。布线器报 0 违例不代表签核 DRC 干净，第 6 节还有一个例子。

### 4.4 速查

| 项 | 要点 |
|----|------|
| 全局布线 | GCell 网格、容量/需求、overflow、层分配 |
| 详细布线 | 在 guide 里画真实几何；迭代 rip-up and reroute 到 0 DRC |
| 串扰 | 耦合电容；delta delay（同向快、反向慢）、glitch；间距/屏蔽/换层/调驱动 |
| 规则 | 优选方向、线宽、间距、via 覆盖、min area、end-of-line |

### 4.5 面试题

**Q1. 全局布线和详细布线有什么区别？**  
全局布线在粗网格上为每条网规划通道和层，目标是控制拥塞和线长，不画真实几何；详细布线在全局布线的 guide 范围内把线画到 track 上，处理所有几何规则，目标是 DRC 清零。

**Q2. 全局布线报 overflow，怎么处理？**  
先看位置和层：局部热点多半是布局密度或高引脚密度单元造成的，回到布局调密度/padding；宏单元周围的问题要改布图通道；整体 overflow 高说明利用率太高或金属层不够。也可以调 PDN 让出资源、限制某些层的使用率。

**Q3. 什么是串扰？对 setup 和 hold 各有什么影响？怎么修？**  
相邻线之间的耦合电容使一条线的翻转影响另一条。攻击线反向翻转使受害线变慢，恶化 setup；同向翻转使其变快，恶化 hold。静止的受害线上还可能出现毛刺。修法：加间距或屏蔽、换层、减短平行长度、调大受害线驱动、调小攻击线驱动、插 buffer。

**Q4. 为什么金属层要交替优选方向？**  
同一层的线都朝一个方向，相互不交叉，布线规整、密度高；换方向时通过 via 换层。交替方向让横竖两个方向都有足够的资源。

**Q5. 详细布线 DRC 收敛不了怎么办？**  
看违例类型和位置：集中在某个区域 → 局部拥塞，回到布局；集中在某类单元的引脚 → 引脚接入问题（pin access），给该单元加 padding 或换单元；集中在宏单元边缘 → 通道问题；某层的短路或间距 → 检查该层是否被 PDN 占得太满。

---

## 5. 寄生参数抽取

### 5.1 为什么需要，在流程中的位置

布线之前的时序都是**估算**（第 0.3 节的表格）。签核 STA 要用真实走线的电阻和电容：**寄生参数抽取**（parasitic extraction，RC extraction）根据版图几何和工艺的层厚度、介电常数，计算每条网的 RC 网络，写成 **SPEF** 交给 STA。第 07 章第 6.2 节讲了线延时怎么用，本节讲它怎么来。

### 5.2 核心概念与公式

**电阻**：

```
R = ρ · L / (W · T) = Rs · L / W          Rs = ρ / T（方块电阻，sheet resistance，Ω/□）
```

Sky130 met1 的 Rs = 0.125 Ω/□：一根 0.14 µm 宽、100 µm 长的 met1，R = 0.125 × 100 / 0.14 ≈ 89 Ω。先进工艺线越来越窄，还要考虑铜的尺寸效应（晶界散射），电阻上升很快。

**电容**：对地电容（面积项 + 边缘 fringe 项）+ 与相邻线之间的**耦合电容**。平板近似 C = ε·A / d 只是其中的面积部分；在细线里边缘和耦合电容占主导。

**RC corner**：金属的宽度、厚度、介质厚度都有工艺偏差，抽取按不同 corner 做。

| RC corner | 含义 | 通常配合 |
|-----------|------|----------|
| Cworst / Cmax | 电容最大 | setup |
| Cbest / Cmin | 电容最小 | hold |
| RCworst | RC 乘积最大（线变窄变薄：R 最大，C 比 Cworst 小） | 长线主导的 setup |
| RCbest | RC 乘积最小 | hold |
| typical | 典型 | 功耗、参考 |

本 lab 用 PDK 的 OpenRCX 规则文件 min / nom / max 三个 corner，签核时 max 配 ss、nom 配 tt、min 配 ff（第 8 节）。

**Elmore 延时**：RC 树上从驱动点到节点 i 的延时近似为

```
τ_i = Σ R_k × C_downstream(k)      （k 取驱动点到节点 i 路径上的每段电阻）
```

即路径上每段电阻乘以它下游的全部电容之和。签核工具用更精确的方法（如 AWE/Arnoldi 降阶），但 Elmore 用来估数量级足够。

**工具**：工业上 StarRC、Quantus 用基于场求解器（field solver）标定的查表模型，关键网可以直接用场求解器；这里的 OpenRCX 用 PDK 提供的标定规则。耦合电容小于阈值（本 lab 0.1 fF）的并到对地电容里，减小 SPEF 规模。

### 5.3 工具与脚本

`lab/PnR_Flow/5_extract.tcl` 的关键命令：`define_process_corner -ext_model_index 0 $RC_CORNER` → `extract_parasitics -ext_model_file rules.openrcx.sky130A.$RC_CORNER.calibre -lef_res` → `write_spef`。真实输出（`reports/5_extract_nom.log`）：

```
[INFO RCX-0435] Reading extraction model file /root/micromamba/envs/orfs/share/pdk/sky130A/libs.tech/openlane/rules.openrcx.sky130A.nom.calibre ...
[INFO RCX-0436] RC segment generation alu (max_merge_res 50.0) ...
[INFO RCX-0040] Final 2745 rc segments
[INFO RCX-0440] Coupling threshhold is 0.1000 fF, coupling capacitance less than 0.1000 fF will be grounded.
[INFO RCX-0043] 5458 wires to be extracted
[INFO RCX-0045] Extract 627 nets, 3371 rsegs, 3371 caps, 6663 ccs
```

SPEF 里的一条网（`build/alu.nom.spef`，输出端口 `y[0]`，由寄存器 `_1137_` 驱动，同时接到 `_1015_`；单位 pF 和 Ω，`*577` 是名字映射后的 `y[0]`）：

```
*D_NET *577 0.00652145
*CONN
*P y[0] O
*I *1015:B I *D sky130_fd_sc_hd__nor2_1
*I *1137:Q O *D sky130_fd_sc_hd__dfrtp_2
*CAP
1 y[0] 0.000933864
2 *1015:B 0.000201314
3 *1137:Q 4.36033e-05
4 *577:7 0.00117878
5 y[0] y[13] 0.000429481
6 y[0] y[8] 0
7 y[0] *578:11 0.00014542
...
21 *569:7 y[0] 0.000309018
*RES
1 *1137:Q *577:7 14.4725
2 *577:7 y[0] 48.7424
3 *577:7 *1015:B 22.8658
*END
```

读法：

- `*D_NET` 后面是总电容 6.52 fF（对地 + 耦合）。
- `*CAP` 里一个节点的是对地电容（第 1–4 行，合计 2.36 fF），两个节点的是耦合电容（到 `y[13]` 等邻线，合计 4.16 fF）。
- `*RES` 描述 RC 树：驱动端 `_1137_/Q` → 分叉点 `*577:7` → 分别到端口 `y[0]` 和 `_1015_/B`。

**Elmore 估算**（只用对地电容，节点电容：Q 端 0.044 fF，分叉点 1.179 fF，`y[0]` 0.934 fF，`_1015_/B` 0.201 fF）：

```
τ_y[0] = 14.47 Ω × (1.179 + 0.934 + 0.201) fF + 48.74 Ω × 0.934 fF
       ≈ 0.034 ps + 0.046 ps = 0.08 ps
```

线本身的 RC 延时只有 0.08 ps，而单元延时是 0.1–0.4 ns 量级。在 130 nm、线长几十 µm 的小设计里，**线的电阻几乎可以忽略，线的作用主要是给驱动单元加电容负载**（通过 NLDM 表增加单元延时）。先进工艺里线又窄又长，R 大得多，线延时本身就是主要矛盾。

**三个 corner 的对比**（同一条网 `y[0]` 的总电容）：min 5.88 fF、nom 6.52 fF、max 7.40 fF，相对 nom 为 −10% / +13%。

### 5.4 速查

| 项 | 要点 |
|----|------|
| R | Rs·L/W；met1 0.125 Ω/□，met5 0.0285 Ω/□ |
| C | 对地（面积 + fringe）+ 耦合；细线里耦合占主导 |
| RC corner | Cworst/Cbest/RCworst/RCbest/typical；setup 配 worst，hold 配 best |
| SPEF | `*D_NET` 总电容；`*CAP` 对地/耦合；`*RES` RC 树 |
| Elmore | 每段 R × 下游总 C，求和 |

### 5.5 面试题

**Q1. 为什么要做 RC 抽取？抽取结果给谁用？**  
布线前线的 RC 只能估算；签核要用真实走线计算延时、slew、SI 和功耗。抽取结果（SPEF）给 STA、功耗分析、SI 分析用，也用来生成 SDF 给门级仿真。

**Q2. 有哪些 RC corner？setup 和 hold 各用哪个？**  
Cworst、Cbest、RCworst、RCbest、typical。setup 用 Cworst/RCworst（配慢的 PVT），hold 用 Cbest/RCbest（配快的 PVT）；签核时各种组合都要看。

**Q3. SPEF 里有什么？**  
每条网的总电容、连接的端口和单元引脚、对地电容、耦合电容（两节点）、电阻段组成的 RC 树；文件头有单位和名字映射表。

**Q4. 什么是 Elmore 延时？**  
RC 树上从驱动点到某节点的一阶延时近似：路径上每段电阻乘以其下游所有电容之和。计算简单，是很多估算和优化算法的基础。

**Q5. 为什么先进工艺里线延时越来越重要？**  
线宽和厚度缩小，电阻按面积反比上升（再加上铜的尺寸效应），而线长并不随工艺同比例缩短；晶体管反而越来越快。所以线的 RC 延时占比越来越大，需要更多 buffer、更多金属层和更厚的上层金属。

---

## 6. 物理验证（DRC / LVS / 天线）

### 6.1 为什么需要，在流程中的位置

版图要交给代工厂制造，必须证明两件事：**能造出来**（DRC：满足所有制造几何规则）和**造的是对的电路**（LVS：版图的连接关系与网表一致）。这些检查在合并了标准单元内部版图的完整 GDS 上，用代工厂认证的规则文件（Calibre / ICV / Pegasus 的 runset）做，称为签核 DRC/LVS。布线器自带的 DRC 只覆盖它知道的布线规则，不能代替。

### 6.2 DRC（Design Rule Check）

常见规则：最小线宽、最小间距、最小面积、最小孔洞面积、via 覆盖、线端间距、**金属密度**（每个窗口内金属占比要在上下限之间，否则化学机械抛光 CMP 后厚度不均——所以最后要插 metal fill）、天线规则。

**实验 F**：Magic 在最终 GDS 上用 Sky130 全套规则做 DRC。关掉修补脚本时：

```
    37  Metal3 minimum area < 0.24um^2 (met3.6)
    TOTAL DRC errors: 37
修补后（主流程）: DRC TOTAL errors: 0  (details: reports/8_drc.rpt)
```

OpenROAD 详细布线报 0 违例，签核 DRC 却查出 37 处 met3 最小面积违例。原因：met2 → met3 → met4 的叠孔（stacked via）在 met3 上只留下一块 via 覆盖大小的金属，面积不到 0.24 µm²；而本机 tech LEF 的 met3 层**没有写 `MINAREA` 规则**，布线器根本不知道这条规则。这里的修法（`magic_patch.tcl`）是把每块太小的 met3 沿长边延长到 0.26 µm²；工业流程里这类问题由完整的布线规则 + 签核 DRC 后的修复流程解决。**"布线器 0 DRC" ≠ "签核 DRC 干净"**，这是面试时值得举的例子。

### 6.3 LVS（Layout Versus Schematic）

```
版图 GDS ──► 抽取器件和连接关系 ──► 版图网表（SPICE）──┐
                                                        ├──► 比较（图同构）──► 匹配 / 不匹配报告
设计网表（Verilog + 电源地连接）──► 转成 SPICE ────────┘
```

常见 LVS 错误：短路（两个不同的网被连到一起，最常见的是信号和电源短路）、开路（同一个网断成两段）、器件不匹配（缺单元、多单元、参数不对）、引脚/端口不匹配、电源地没连。

真实输出（`reports/8_lvs.log`、`reports/8_lvs.rpt`）：

```
Circuit 1 contains 626 devices, Circuit 2 contains 626 devices.
Circuit 1 contains 629 nets,    Circuit 2 contains 629 nets.
Cell pin lists are equivalent.
Device classes alu and alu are equivalent.

Final result: Circuits match uniquely.
```

**调试过程中真实遇到的 LVS 失败**：第一次比较时两边网数是 701 vs 837。原因是电源地连接：`pdngen` 只给当时已存在的单元连 VPWR/VGND；之后布局优化（20 个 buffer）、CTS（5 个时钟 buffer）、hold 修复（3 个）、ECO（6 个）新加的 34 个单元，电源引脚在网表里是悬空的，每个单元 4 个电源脚（VPWR/VGND/VPB/VNB）各算一个独立的网，34 × 4 = 136 = 837 − 701。版图上这些单元的电源脚其实接在 met1 rail 上，所以是**网表错了、版图没错**。修法是每一步结束时把所有单元的电源脚重新连到 VDD/VSS（`config.tcl` 的 `connect_pg_pins`）。这类问题在工业流程里对应"新增单元没有做 global net connect"，LVS 能查出来，STA 查不出来。

### 6.4 天线效应（antenna effect）

制造时金属是一层一层做的。做到某一层时，如果一段金属只连到晶体管栅极、还没有连到任何扩散区（源漏），等离子刻蚀过程中积累在这段金属上的电荷只能通过薄栅氧泄放，可能击穿或损伤栅氧。

**天线比**（antenna ratio）：

```
PAR = 连到栅极、尚未接到扩散区的某层金属面积（或侧面积） / 栅面积
```

超过规则上限就是违例。Sky130 tech LEF 里 met1–met5 的侧面积比（side area ratio）规则是分段线性的：没有扩散区时上限 400；接了扩散区（比如一个二极管）后上限升到 2609 以上。

修法：

| 方法 | 原理 |
|------|------|
| **插二极管**（antenna diode） | 在栅极旁接一个反偏二极管，给电荷提供泄放通路 |
| **跳线**（jumper / layer hopping） | 在靠近栅极处跳到更上层金属，使下层的长金属在制造时先不和栅极相连 |
| 插 buffer | 把长网切成两段，每段连的金属变短 |

**实验 B**：不插二极管，其它与主流程相同：

```
no diodes : [INFO ANT-0002] Found 3 net violations in 621 nets.
with diodes (主流程): [INFO ANT-0002] Found 0 net violations in 621 nets.
    a[4] met3: PAR: 471.80* limit 400.00
    b[0] met2: PAR: 443.28* limit 400.00
    b[3] met3: PAR: 569.55* limit 400.00
```

`reports/exp_no_diode/4_antenna.rpt` 里的原始格式：

```
Net - a[4]
  _0989_  (sky130_fd_sc_hd__mux2_1)  A1
[1]  met3:
  PAR:   87.78  Ratio:    0.00       (Area)
  PAR:  471.80*  Ratio:  400.00       (S.Area)
  CAR:   88.47  Ratio:    0.00       (C.Area)
  CAR:  475.60  Ratio:    0.00       (C.S.Area)
```

违例都在**输入端口网**上：端口在 die 边上，线要走很远才到栅极；而在这个 block 内部，输入端口没有驱动单元，也就没有扩散区可以泄放电荷。本机 OpenROAD（2022 版）的 `repair_antennas` 会崩溃，所以主流程采用预防式做法（OpenLane 也有这个选项）：在每个数据输入端口的第一个负载旁边插一个 `diode_2`，共 36 个。`CAR` 是累积天线比（cumulative），把下面各层的比值累加起来。

### 6.5 其它物理验证项

ERC（电气规则：悬空栅、电源地短路、阱没接）、金属密度和 fill、DFM（可制造性：双 via、线端延长、光刻热点）。

### 6.6 速查

| 项 | 要点 |
|----|------|
| DRC | 线宽/间距/面积/覆盖/密度/天线；在完整 GDS 上用代工厂规则签核 |
| LVS | 版图抽网表 vs 设计网表；短路、开路、器件、引脚、电源地 |
| 天线 | 刻蚀电荷经栅氧泄放；PAR = 金属面积 / 栅面积；二极管、跳线、buffer |
| 本 lab | 布线器 0 DRC，签核查出 37 处 met3 最小面积；LVS 查出新增单元电源脚悬空 |

### 6.7 面试题

**Q1. DRC 和 LVS 分别检查什么？**  
DRC 检查版图几何是否满足制造规则（能不能造）；LVS 检查版图的电路连接是否与设计网表一致（造的对不对）。两者都在签核阶段、完整 GDS 上用代工厂规则做。

**Q2. LVS 常见错误有哪些？怎么定位？**  
短路、开路、器件多/少/不匹配、端口不匹配、电源地没连。短路最难查，通常用工具的短路路径定位功能找两个网之间的最短连接；开路看同一个网在版图里被拆成了几部分；网数、器件数的差值往往能直接提示原因（本 lab：差 136 个网 = 34 个单元 × 4 个电源脚）。

**Q3. 什么是天线效应？怎么修？**  
制造过程中只连到栅极的金属在刻蚀时积累电荷，通过栅氧放电造成损伤。按"金属面积 / 栅面积"的比值检查。修法：在栅极附近插反偏二极管、跳到上层金属（jumper）、插 buffer 缩短金属。

**Q4. 为什么跳到上层金属能修天线？**  
天线是按制造顺序逐层检查的：做到第 n 层时，只有 n 层及以下已连到栅极的金属才算。在栅极附近跳到上层，下层那段长金属在制造时就不再与栅极直接相连（要等上层做好才连通，而那时已经连上了驱动端的扩散区）。

**Q5. 布线工具已经 DRC 清零了，为什么还要跑 Calibre？**  
布线工具只用简化的规则（tech LEF 里的布线规则），不看单元内部版图，也不查密度、复杂的线端/多边形规则等。签核 DRC 在合并了单元版图的完整 GDS 上用完整规则检查。本 lab 就是例子：tech LEF 缺 met3 最小面积规则，布线器 0 违例，签核 DRC 查出 37 处。

---

## 7. IR drop 与电迁移

### 7.1 为什么需要，在流程中的位置

电源网络有电阻，电流流过时会产生压降：单元实际得到的电压低于标称 VDD（VSS 一侧则高于 0，称为 ground bounce）。电压低 → 单元变慢 → 时序违例，严重时功能错误。电源线上长期的大电流还会造成**电迁移**（EM），线变细甚至断开。这两项分析在签核阶段做，但结论要反馈到布图的电源规划上——等到签核才发现电源网络不够，改动代价很大。

### 7.2 核心概念与公式

**静态 IR drop**：用平均电流计算。

```
I_avg = P_avg / VDD          ΔV = I × R_grid
```

**动态 IR drop**：用瞬态电流计算（大量单元在同一时钟沿附近同时翻转），峰值远大于静态；需要翻转率（vectorless）或真实的 VCD 波形。去耦电容（decap cell）在局部提供瞬时电流、降低动态压降。电源关断设计里还有唤醒时的冲击电流（rush current）问题。

**IR drop 对延时的影响**：按 α-power 模型 td ∝ V / (V − Vt)^α。假设 Vt = 0.45 V、α = 1.3，VDD 从 1.8 V 降 10% 到 1.62 V：

```
td(1.62) / td(1.80) = [1.62 / 1.17^1.3] / [1.80 / 1.35^1.3] = 1.321 / 1.219 ≈ 1.08
```

延时增加约 8%。常见的预算是静态 IR drop 为 VDD 的几个百分点，动态总共不超过 10% 左右（具体按项目定），签核 STA 的电压 corner 也要覆盖这部分压降。

**均匀负载的电源轨**：长度 L、总电阻 R 的一段 rail 两端供电，沿线均匀抽取总电流 I，最大压降在中点：

```
ΔV_max = R × I / 8

推导：单位长度电流 i = I/L，单位长度电阻 r = R/L，两端电压都是 VDD
      V(x) = VDD − (r·i/2) · x · (L − x)
      x = L/2 处压降最大：r·i·L² / 8 = R·I / 8
```

只从一端供电时最大压降是 R·I / 2，大 4 倍——所以电源要多点、双向供电。

本 lab 的数量级：翻转率 0.2 时总功耗 2.08 mW，I = 2.08 / 1.8 ≈ 1.16 mA，分到 38 行、每行被 met4 strap 切成约 4 段，每段约 8 µA；一段 met1 rail（27.2 µm 长、0.48 µm 宽）电阻 R = 0.125 × 27.2 / 0.48 ≈ 7.1 Ω，最大压降 7.1 × 8 µA / 8 ≈ 7 µV。rail 上的压降可以忽略，总压降主要在 strap 和 via 上（到供电点的距离）。

**电迁移（EM）**：电子流撞击金属原子，使原子沿电子流方向迁移，在上游形成空洞（void，电阻变大直至断开）、在下游形成小丘（hillock，可能与邻线短路）。寿命用 Black 方程：

```
MTTF = A · J^(−n) · exp(Ea / kT)
```

J 是电流密度，n 通常取 2 左右，Ea 是激活能。电流密度越大、温度越高，寿命越短。

- 电源线是单向直流，主要看**平均电流**（DC EM）；信号线电流双向，主要看 **RMS 电流**（发热）和峰值电流。
- 修法：加宽金属、加 via（双 via、via 阵列）、多条并联、降低局部电流（分散驱动）。
- 数值例：本 lab 电流最大的一段 0.43 mA。若这 0.43 mA 都流在一根 met4 strap（宽 1.6 µm，tech LEF 厚度 0.8 µm）里，J = 0.43 mA / (1.6 × 0.8 µm²) ≈ 0.34 mA/µm² = 3.4 × 10⁴ A/cm²。是否超标要查 PDK 的 EM 规则（按层、线宽、温度给出允许的电流密度或每 µm 线宽的电流）。

### 7.3 工具与脚本

`lab/PnR_Flow/7_irdrop.tcl`：`set_power_activity -input -activity 0.2` → `report_power` → `check_power_grid` → `analyze_power_grid -net VDD -enable_em`（VSS 同理）。电压源按 `BUMP_PITCH`（默认 20 µm）在 core 上棋盘式放置，模拟倒装芯片的 bump 或上层电源网络的接入点。

真实输出（`reports/7_irdrop.log`，节选）：

```
Total                  1.06e-03   1.02e-03   2.04e-09   2.08e-03 100.0%
[WARNING PSM-0030] VSRC location at (48.280um, 28.160um) and size 10.000um, is not located on an existing power stripe node. Moving to closest node at (49.880um, 22.560um).
[INFO PSM-0031] Number of PDN nodes on net VDD = 704.
[INFO PSM-0064] Number of voltage sources = 5.
[INFO PSM-0040] All PDN stripes on net VDD are connected.
########## IR report #################
Worstcase voltage: 1.80e+00 V
Average IR drop  : 1.05e-04 V
Worstcase IR drop: 3.70e-04 V
######################################
########## EM analysis ###############
Maximum current: 4.29e-04 A
Average current: 2.37e-05 A
Number of resistors: 785
######################################
```

- `All PDN stripes on net VDD are connected`：先查电源网络连通性，有断开的 strap 会单独报出来（`check_power_grid` 同理）。
- 最差 VDD 压降 0.37 mV，只有 VDD 的 0.02%——这是一个 1 mA 量级的小 block，电源网络是按大设计的规格做的，余量很大。
- 最差的单元（`reports/7_ir_VDD.rpt`，按电压排序）：`_1047_, 37.8, 27.2, 1.79963`，离最近的供电点较远。
- 电流最大的电阻段（`reports/7_em_VDD.rpt`）：`seg_42, 0.000429, VDD_77080_49760_6, VDD_77080_49760_5`，就在一个供电点正下方的 met5 → met4 连接处：所有电流都从供电点注入，**EM 风险集中在供电点附近**。

### 7.4 实验

**实验 C：电源条间距**（布局后分析，供电点间距 40 µm）：

```
strap_um     VDD_nodes  VDD_worst_mV   VDD_avg_mV     VSS_worst_mV
13.6         977        0.284          0.164          0.243
27.2         704        0.357          0.221          0.496
54.4         542        0.661          0.398          1.590
```

13.6 → 27.2 µm 时 VDD 最差压降增加 26%；27.2 → 54.4 µm 时接近翻倍，VSS 一侧增加到 3 倍（strap 变少后，strap 与供电点的相对位置也变差了）。strap 越稀，电流要在 met1 rail 上走得越远。

**实验 G：供电点间距**（最终设计，布线后）：

```
bump_um    VDD_sources  VDD_worst_mV   VSS_worst_mV   VDD_Imax_mA
5          67           0.342          0.395          0.225
10         17           0.342          0.396          0.240
20         5            0.370          0.445          0.429
40         2            0.530          0.613          0.811
```

供电点从 5 个减到 2 个，最差压降增加 43%，而单个电阻段的最大电流几乎翻倍（0.43 → 0.81 mA）：供电点越少，每个供电点附近的电流越集中，EM 越危险。供电点多于 strap 交叉点数量之后（10 µm 以下），再加也没有收益。

### 7.5 速查

| 项 | 要点 |
|----|------|
| 静态 IR | I_avg·R；均匀负载两端供电 R·I/8，单端 R·I/2 |
| 动态 IR | 同时翻转的峰值电流；decap、错开翻转、加密电源 |
| 影响 | 电压降 → 延时增加（例：降 10% → 慢约 8%） |
| EM | Black 方程 MTTF ∝ J^(−n)·exp(Ea/kT)；电源看 DC，信号看 RMS/峰值 |
| 修法 | 加宽/加密 strap、加 via、加供电点、decap、分散大驱动 |

### 7.6 面试题

**Q1. 什么是 IR drop？静态和动态有什么区别？**  
电源网络电阻上的压降，使单元实际电压低于 VDD。静态 IR drop 用平均电流计算，反映电源网络的电阻是否足够小；动态 IR drop 考虑瞬时电流峰值（同一时刻大量翻转），通常大得多，需要翻转率或 VCD，并考虑 decap 和封装电感。

**Q2. IR drop 太大怎么修？**  
加密或加宽 strap、增加电源层、增加供电点（bump/pad）、多加 via；局部热点处降低单元密度、把大驱动单元分散；插 decap（针对动态）；时钟门控、错开翻转时刻降低峰值电流。

**Q3. IR drop 对时序有什么影响？签核怎么考虑？**  
电压降低使单元延时增加、时钟树延时也变化，可能造成 setup 违例；时钟和数据受影响程度不同时还会影响 hold。签核时可以按预算把 IR drop 计入 STA 的电压 corner（例如 ss corner 用 VDD − 10%），或者用带 IR 反标的 STA（每个单元用自己的实际电压）。

**Q4. 什么是电迁移？电源线和信号线的 EM 有什么不同？**  
电流中的电子把动量传给金属原子，使其迁移形成空洞和小丘，最终开路或短路。电源线电流单向，主要看平均电流密度；信号线电流双向，平均值抵消，主要看 RMS 电流造成的发热和峰值电流。

**Q5. 为什么 EM 问题常出现在供电点和 via 附近？**  
电流从少数几个供电点注入，再向四周分流，供电点附近的金属和 via 承载的电流最大（本 lab 实验 G：供电点减少，最大段电流从 0.43 mA 升到 0.81 mA）。via 的截面积小，电流密度更高，所以要做 via 阵列。

---

## 8. 签核与 ECO

### 8.1 为什么需要，在流程中的位置

**签核**（signoff）：流片前用签核级工具和代工厂规则确认设计满足全部要求。任何一项不通过都不能流片。签核发现的问题用 **ECO**（Engineering Change Order）修：在不推倒重来的前提下对设计做局部修改。

**签核清单**：

| 类别 | 内容 | 本 lab |
|------|------|--------|
| 时序 | 所有模式 × PVT × RC corner（MCMM）的 setup / hold / recovery / removal / DRV / SI / 最小脉宽 | OpenSTA 三 corner，无 SI |
| 物理验证 | DRC、LVS、天线、ERC、密度 | Magic + Netgen |
| 电源 | 静态/动态 IR drop、EM（电源和信号） | PDNSim 静态 IR + 电源 EM |
| 功能 | 形式验证（布线后网表 vs 综合网表 / RTL）、门级仿真（带 SDF） | 布线后网表零延时门级仿真 |
| 其它 | 功耗、DFT 覆盖率、可靠性 | 功耗报告 |

corner 的选择见第 07 章第 7 节。本 lab 的配对：

| corner | 库 | SPEF | 主要看 |
|--------|----|------|--------|
| ss | `ss_100C_1v60` | max | setup |
| tt | `tt_025C_1v80` | nom | 典型 |
| ff | `ff_n40C_1v95` | min | hold |

### 8.2 ECO 的种类

| 种类 | 内容 |
|------|------|
| **时序 ECO** | 修 setup/hold/DRV/SI：换单元尺寸（sizing）、换阈值电压（Vt swap：换 LVT 更快、HVT 更省漏电）、插 buffer / delay 单元、调整时钟（useful skew）。详见第 07 章第 13.5 节 |
| **功能 ECO** | 修 RTL bug：比较新旧 RTL 找出改动，用网表级的小改动实现（Conformal ECO、Formality ECO 能自动生成补丁） |
| **pre-mask ECO** | 流片前，可以自由加单元、改所有层 |
| **post-mask / metal-only ECO** | 已经做了掩膜（或已流片）后，只改金属层以节省掩膜费用：只能用预先撒好的 **spare cell** 或可编程的 ECO 单元，把它们用金属连进电路 |

工业流程：PrimeTime 的 `fix_eco_timing` / `fix_eco_drc` 生成改动脚本 → Innovus / ICC2 执行，`ecoPlace` 做增量合法化、`ecoRoute` 只重布改动过的网 → 重新抽取、签核 → 形式验证确认功能不变。

### 8.3 签核结果

`reports/6_signoff_sta_pre_eco.rpt`（布线后第一次签核）与 `reports/6_signoff_sta.rpt`（ECO 后）的 corner 汇总：

```
ECO 前：
CORNER ss  setup_ws   -5.135   hold_ws   -0.225
CORNER tt  setup_ws   -0.104   hold_ws    0.129
CORNER ff  setup_ws    1.879   hold_ws    0.254

ECO 后（最终）：
CORNER ss  setup_ws   -4.726   hold_ws   -0.232
CORNER tt  setup_ws    0.087   hold_ws    0.126
CORNER ff  setup_ws    1.977   hold_ws    0.252
```

tt corner 的最差 setup 路径（ECO 后，节选）：

```
Startpoint: _1040_ (rising edge-triggered flip-flop clocked by clk)
Endpoint: _1007_ (rising edge-triggered flip-flop clocked by clk)
Corner: tt
   0.015    0.061    0.044    0.044 ^ clk (in)
   0.029    0.064    0.149    0.192 ^ clkbuf_0_clk/X (sky130_fd_sc_hd__clkbuf_8)
   0.035    0.074    0.158    0.350 ^ clkbuf_2_1__f_clk/X (sky130_fd_sc_hd__clkbuf_8)
            0.074    0.002    0.353 ^ _1040_/CLK (sky130_fd_sc_hd__dfrtp_1)
   0.014    0.088    0.419    0.771 v _1040_/Q (sky130_fd_sc_hd__dfrtp_1)
   0.049    0.076    0.202    0.974 v repeater131/X (sky130_fd_sc_hd__buf_4)
   0.043    0.095    0.211    1.185 v repeater130/X (sky130_fd_sc_hd__clkbuf_4)
   0.047    0.074    0.205    1.390 v repeater129/X (sky130_fd_sc_hd__buf_4)
   ...
   0.002    0.053    0.187    5.103 ^ _0981_/X (sky130_fd_sc_hd__a32o_1)
            0.053    0.000    5.103 ^ _1007_/D (sky130_fd_sc_hd__dfrtp_2)
                              5.103   data arrival time

                     5.000    5.000   clock clk (rise edge)
   ...
            0.074    0.001    5.351 ^ _1007_/CLK (sky130_fd_sc_hd__dfrtp_2)
                    -0.100    5.251   clock uncertainty
                     0.000    5.251   clock reconvergence pessimism
                    -0.061    5.190   library setup time
                              5.190   data required time
                              0.087   slack (MET)
```

起点寄存器后面串了 3 个 `repeater`：这是布局阶段 `repair_design` 为高扇出网建的 buffer 树，修 DRV 的代价是关键路径上多了约 0.6 ns。报告格式的逐列解读见第 07 章第 14 节。

**ss corner 为什么差这么多？** 这个设计只在 tt 下做了优化（综合、布局、CTS 都用 tt 库）。ss 100 °C 1.60 V 下，同一条路径的数据到达时间是 10.126 ns，tt 是 5.103 ns，慢了约一倍。**实验 E**：同一份布线后网表只改约束周期：

```
CLK_PERIOD=5.0     CORNER ss  setup_ws   -4.726   hold_ws   -0.232
CLK_PERIOD=8.0     CORNER ss  setup_ws   -1.726   hold_ws   -0.232
CLK_PERIOD=10.0    CORNER ss  setup_ws    0.274   hold_ws   -0.232
CLK_PERIOD=11.0    CORNER ss  setup_ws    1.274   hold_ws   -0.232
```

- 这个网表在 ss 下只能跑 100 MHz 左右。要在 ss 下跑 200 MHz，必须从综合开始就用 ss 库做优化（第 08 章 Q3）。
- **hold 不随周期变化**（-0.232 在各个周期下都一样）：hold 检查的是同一个时钟沿，与周期无关，放慢时钟修不了 hold（第 07 章第 4.5 节）。

**ss corner 的 hold 违例**是 `rst_n` 的 removal（`reports/6_signoff_sta.rpt` 的"Hold 最差路径（ss）"）：

```
                     0.500    0.500 ^ input external delay
   0.003    0.048    0.025    0.525 ^ rst_n (in)
   0.018    0.297    0.315    0.840 ^ hold3/X (sky130_fd_sc_hd__dlymetal6s2s_1)
   0.046    0.158    0.343    1.184 ^ repeater138/X (sky130_fd_sc_hd__buf_6)
            0.158    0.001    1.184 ^ _1029_/RESET_B (sky130_fd_sc_hd__dfrtp_4)
                              1.184   data arrival time
   ...
            0.144    0.001    0.658 ^ _1029_/CLK (sky130_fd_sc_hd__dfrtp_4)
                     0.050    0.708   clock uncertainty
                     0.708    1.416   library removal time
                              1.416   data required time
                             -0.232   slack (VIOLATED)
```

CTS 后修 hold 时只看了 tt，插的 `hold3` 在 tt 下够用；到了 ss，时钟树延时（0.66 ns）和 removal 时间（0.71 ns）都变大，而输入延时是 SDC 里固定的 0.5 ns，不跟着 corner 变。同一个设计里数据路径的 hold 在 ss 下还有 +0.98 ns，只有这条端口复位路径违例。**hold 要在所有 corner 上修**（MCMM 优化），并且复位端口的时序预算要和系统一起定。

### 8.4 时序 ECO 实验

`lab/PnR_Flow/9_eco.tcl`：读入布线后数据库和 nom SPEF → `repair_timing -setup -slack_margin 0.10` → 重新合法化 → 重新布线 → 回到第 5、6 步重新抽取和签核。

```
TIMING ECO before             setup_ws   -0.104  tns   -0.113  hold_ws    0.129
[INFO RSZ-0040] Inserted 6 buffers.
[INFO RSZ-0041] Resized 3 instances.
ECO cells before 1687  after 1693
TIMING ECO after sizing (old routes) setup_ws    0.161  tns    0.000  hold_ws    0.129
removed 852 fillers
[INFO ANT-0001] Found 0 pin violations.
[INFO ANT-0002] Found 0 net violations in 627 nets.
```

- 插 6 个 buffer、改 3 个单元尺寸，按旧走线估计修到 +0.161；真正重新布线、重新抽取后是 **+0.087**。修的时候留的 0.10 ns 余量（`-slack_margin`）被重新布线吃掉了一大半——**ECO 要留余量**，否则签核来回迭代。
- 1687 个单元里只有 583 个是逻辑单元，其余是填充单元（852）、tap（140）、endcap（76）、天线二极管（36）。ECO 要先拆掉填充单元，才有地方放新单元。
- 本机 OpenROAD 没有增量 ECO 布线，这里是清掉所有信号线后整体重布（设计小，约 2 分钟）；工业流程用 `ecoRoute` 只重布改动过的网，其余走线不动，时序才可预期。

**布线后门级仿真**：用第 08 章同一个自检查 testbench 仿真布线后的网表（`build/alu_route.v`，去掉填充/tap 等物理单元）：

```
PASS: 1528 个有效结果全部与参考模型一致
```

这里用的是单元库的功能模型（零延时 / 单位延时），验证的是后端过程中插入的 buffer、hold 单元、时钟树、二极管没有改变功能；带 SDF 反标的时序仿真本 lab 没有做。

### 8.5 速查

| 项 | 要点 |
|----|------|
| 签核清单 | MCMM STA、DRC/LVS/天线/ERC/密度、IR/EM、LEC、门级仿真、功耗 |
| corner 配对 | setup：ss + Cmax/RCmax；hold：ff + Cmin，但所有 corner 都要看 |
| 时序 ECO | sizing、Vt swap、buffer、delay 单元、useful skew；增量布线；留余量 |
| 功能 ECO | 新旧 RTL 比较 → 网表补丁；post-mask 只改金属、用 spare cell |
| 本 lab | tt 收敛（+0.087）；ss 只能跑约 10 ns；ss 复位 removal 违例 |

### 8.6 面试题

**Q1. 签核要检查哪些项？**  
时序（MCMM 下的 setup/hold/DRV/SI 等）、物理验证（DRC、LVS、天线、ERC、密度）、电源（IR drop、EM）、功能（形式验证、门级仿真）、功耗，以及 DFT 覆盖率等。任何一项不过都不能流片。

**Q2. 什么是 ECO？时序 ECO 和功能 ECO 分别怎么做？**  
在设计基本完成后做的局部修改。时序 ECO 用 sizing、Vt swap、插 buffer/delay 单元修违例，由签核 STA 工具生成改动，P&R 工具增量实现。功能 ECO 修逻辑 bug：比较新旧 RTL，找出最小的网表改动（可用 Conformal/Formality ECO），再在版图上实现，最后做形式验证。

**Q3. 什么是 metal-only ECO？为什么需要 spare cell？**  
掩膜已经做好（或已流片）后，为节省费用只改金属层的掩膜。晶体管层不能改，所以不能新增单元，只能用事先撒在芯片里的备用单元（spare cell，常见 NAND、NOR、INV、DFF 等），通过改金属连线把它们接进电路。

**Q4. 修 hold 插的 delay 单元会不会影响 setup？**  
会。hold 修复要在 setup 有余量的路径上做，并且要在所有 corner 下检查：快 corner 下修 hold 插的延时，在慢 corner 下会变得更大，可能造成 setup 违例。反过来，只在一个 corner 修 hold 也不够（本 lab：tt 下修好的复位 removal，在 ss 下仍然违例）。

**Q5. 签核时 setup 在 ss 下违例、tt 下满足，能流片吗？**  
不能。芯片的工艺、电压、温度会落在规定范围内的任何位置，签核要求在所有规定的 corner 下都满足。要么修到 ss 满足，要么降低工作频率（本 lab：约 10 ns），要么通过 AVS/DVFS 等手段限制实际工作条件（需要系统配合）。

**Q6. 为什么 ECO 后时序和预期不一样？**  
ECO 估算用的是旧走线，新单元插入后要重新合法化、重新布线，周围单元位置和走线都会变，耦合也会变。所以修的时候要留余量（本 lab：估计 +0.161，实际 +0.087），并尽量用增量布线减少扰动。

---

## 9. 运行全部实验

```bash
# WSL（工具在 /root 下，需要 root）
sudo -i
cd "/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/14_Physical_Design_Backend/lab/PnR_Flow"
sed -i 's/\r$//' *.sh *.tcl *.ys *.sdc     # Windows 下编辑过的话先去掉 CRLF
bash run.sh                  # 主流程，约 6 分钟；屏幕输出同 run.log
bash run_experiments.sh      # 7 组对比实验，约 13 分钟；汇总在 reports/exp_summary.txt
ONLY=EF bash run_experiments.sh   # 只跑其中几项
```

可调参数（环境变量）：`UTIL`（利用率，默认 40）、`PLACE_DENSITY`（0.60）、`STRAP_PITCH`（27.2 µm）、`DO_REPAIR`（1）、`ANTENNA_DIODES`（1）、`CLK_PERIOD`（5.0 ns）、`ECO_MARGIN`（0.10）、`BUMP_PITCH`（20 µm）、`DRC_PATCH`（1）。

| 文件 | 作用 |
|------|------|
| `synth.ys` | Yosys 综合第 08 章的 ALU（tt 库） |
| `alu.sdc` | 约束；`::POST_CTS` 切换理想时钟 / propagated clock 和 uncertainty |
| `config.tcl` | 公共设置：PDK 路径、线 RC、dont_use、读各阶段数据库、电源脚连接、天线二极管、时序汇总 |
| `1_floorplan.tcl` | 布图、track、IO、tap/endcap、PDN |
| `2_place.tcl` | 全局布局、`repair_design`、详细布局 |
| `3_cts.tcl` | CTS、CTS 后修 setup/hold |
| `4_route.tcl` | 天线二极管、填充单元、全局布线、详细布线、天线检查 |
| `5_extract.tcl` | OpenRCX 抽取（`RC_CORNER=min/nom/max`），写 SPEF、DEF、网表 |
| `6_signoff_sta.tcl` | OpenSTA 三 corner 签核 |
| `7_irdrop.tcl` | 功耗、PDNSim 静态 IR drop 与 EM |
| `8_magic_gds.tcl`、`magic_patch.tcl` | DEF + 单元 GDS → 完整 GDS；修补 met3 最小面积 |
| `8_magic_drc.tcl` | Magic 全规则 DRC |
| `8_magic_extract.tcl`、`8_lvs.tcl` | 版图抽 SPICE 网表；Netgen LVS |
| `9_eco.tcl` | 时序 ECO + 重新布线 |
| `run.sh`、`run_experiments.sh` | 主流程、对比实验 |
| `reports/` | 每一步的日志和报告（README 里的输出都来自这里） |

`build/`（数据库、DEF、GDS、SPEF、网表，约 30 MB）、`reports/`、`run.log`、`run_exp.log` 是生成物，不需要提交。`build/alu.gds` 可以用 KLayout 打开查看版图。

本机工具的已知限制（脚本里已绕开）：OpenROAD 是 2022 年的版本，`repair_antennas` 会崩溃（改为预先插二极管）、没有增量 ECO 布线（改为整体重布）、没有 `global_connect`（自己写了 `connect_pg_pins`）；数据库里的 route guide 会越过最高布线层（改读文件版 guide）。

---

## 10. 速查表

```
流程：floorplan → place → CTS → route → extract → signoff(STA/PV/IR-EM/LEC/GLS) → ECO → GDS
文件：tech LEF(层/规则) 单元 LEF(抽象) liberty DEF(物理状态) SPEF(RC) GDS(版图) SDF(延时)
利用率 = 单元面积/core 面积，起始 50–70%；后面每步都加单元（lab 42%→50%；75% 目标 CTS 失败）
PDN：ring → strap → followpin rail；上层厚金属；密 → IR 小但占布线资源（lab 27.2→54.4 µm 压降近翻倍）
tap 防 latch-up；endcap 行尾；宏单元靠边、留通道、halo
布局：全局(解析法，HPWL+密度) → 合法化 → 详细；布局时修 DRV、建高扇出 buffer 树
HPWL = Δx + Δy；2–3 引脚 = 最短斯坦纳树
CTS：skew/latency/transition/功耗；H-tree/mesh/多源；clkbuf、NDR、屏蔽；CTS 后修 hold
useful skew：capture 晚到 → 本级 setup+、下级 setup−、本级 hold−
全局布线看 overflow；详细布线迭代到 0 DRC；优选方向交替
串扰：Ceff = Cg + k·Cc，k≈0 同向 / 1 静止 / 2 反向；setup 看慢、hold 看快；glitch
R = Rs·L/W（met1 0.125 Ω/□）；Elmore τ = Σ R_k·C_下游；小设计里线电阻可忽略，主要是电容负载
RC corner：Cworst/RCworst → setup，Cbest/RCbest → hold
DRC：线宽/间距/面积/覆盖/密度；布线器 0 DRC ≠ 签核干净（lab：37 处 met3 min area）
LVS：短路/开路/器件/端口/电源地（lab：新增单元电源脚悬空，差 136 个网）
天线：PAR = 金属面积/栅面积；二极管、跳线、buffer；输入端口长线最容易违例
IR：ΔV = I·R；均匀负载两端供电 RI/8、单端 RI/2；降 10% → 慢约 8%；decap 对付动态
EM：MTTF ∝ J^-n·e^(Ea/kT)；电源看 DC，信号看 RMS；供电点和 via 处电流最集中
签核：MCMM；setup ss+Cmax，hold ff+Cmin，但所有 corner 都要看；hold 与周期无关
ECO：时序（sizing/Vt/buffer）、功能（RTL diff → 网表补丁）、metal-only（spare cell）；要留余量
```
