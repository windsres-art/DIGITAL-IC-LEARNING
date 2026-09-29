# 08 逻辑综合（Logic Synthesis）—— 面试向

目标：讲清楚综合工具把 RTL 变成门级网表时每一步在做什么；会写、会读 DC/Genus 的基本脚本和报告；知道常见优化（面积/时序取舍、边界优化、资源共享、FSM 编码、retiming、dont_touch）的原理和代价；理解网表交付前的检查（check_design、形式等价性检查）。

前置知识：

- 可综合编码风格、latch 推断：`../02_HDL_Verilog_SystemVerilog/README.md`（未写完时可先看本章第 7 节的例子）
- 建立/保持时间、SDC、时序报告：`../07_STA/README.md` 第 2、4、12、14 节
- 门控时钟与 ICG：`../05_Clock_Reset_Design/README.md` 第 2 节

建议顺序：第 1–2 节（流程）→ 跑 `lab/Yosys_Flow` 对照第 2–4 节 → 第 5–6 节（约束与优化）+ `lab/Opt_Experiments` → 第 7–8 节（检查与等价性）+ `lab/Equivalence` → 速查表 → 面试题。

配套实验（全部在 WSL 中实际跑通，README 里贴的是真实输出）：

| 实验 | 内容 |
|------|------|
| `lab/Yosys_Flow/` | 16 bit ALU：lint → RTL 仿真 → 逐步综合（每步单元统计）→ 门级仿真 → OpenSTA 时序/功耗 → 面积与时序驱动映射对比 |
| `lab/Opt_Experiments/` | 边界优化、寄存器复制与 keep、资源共享、FSM 编码、retiming，各给面积 / FF 数 / 时序对比 |
| `lab/Equivalence/` | RTL vs 网表形式等价性检查；注入 bug 后形式验证和仿真的对比；check_design（latch、多驱动、组合环、截断、悬空） |

工艺统一用 Sky130 hd 标准单元库 `sky130_fd_sc_hd__tt_025C_1v80.lib`（典型 corner，25 °C，1.8 V）。

---

## 目录

1. [综合是什么，在流程中的位置](#1-综合是什么在流程中的位置)
2. [综合流程：翻译 → 优化 → 映射](#2-综合流程翻译--优化--映射)
3. [DC / Genus 基本脚本](#3-dc--genus-基本脚本)
4. [读综合报告：面积、时序、功耗](#4-读综合报告面积时序功耗)
5. [综合约束](#5-综合约束)
6. [优化手段与取舍](#6-优化手段与取舍)
7. [网表检查：check_design 与 lint](#7-网表检查check_design-与-lint)
8. [形式等价性检查（LEC）](#8-形式等价性检查lec)
9. [运行全部实验](#9-运行全部实验)
10. [速查表](#10-速查表)
11. [面试题](#11-面试题)

---

## 1. 综合是什么，在流程中的位置

**逻辑综合**：在给定的**单元库**和**约束**下，把 RTL 描述转换成由标准单元组成的**门级网表**，并在面积、时序、功耗之间做优化。

```
                      约束 SDC（时钟、IO、DRV）
                               │
 RTL (.v/.sv) ──►  综合（DC / Genus / Yosys）  ──► 门级网表 (.v) + SDC + SDF/报告
                               ▲                        │
                  单元库 .lib/.db（功能、时序、面积、功耗）   ├──► 形式等价性检查（RTL vs 网表）
                                                        ├──► STA / 门级仿真
                                                        └──► 布局布线（../14_Physical_Design_Backend）
```

三个输入缺一不可：

| 输入 | 作用 | 缺了会怎样 |
|------|------|------------|
| RTL | 描述功能 | — |
| 单元库（liberty） | 每个单元的逻辑功能、面积、延时表、功耗表、引脚电容 | 工具不知道能用什么门、每个门多快 |
| 约束（SDC） | 时钟频率、IO 时序、驱动/负载、设计规则 | 工具不知道要多快，只会做最小面积；结果没有意义 |

面试里常问“综合做了什么”，标准回答是三步：**翻译（translation）→ 优化（optimization）→ 映射（mapping）**，并且优化和映射在工业工具里是交替迭代、以约束为目标的。

**前端与后端的分界**：综合输出的网表交给后端做布局布线。综合阶段看不到真实走线，线延时靠 wire load model（线负载模型）或物理综合（DC topographical / Genus physical，读入 floorplan 估线长）估计，所以综合后的时序只是估计值（见 `../07_STA/README.md` 第 1 节）。

---

## 2. 综合流程：翻译 → 优化 → 映射

以 `lab/Yosys_Flow/alu.v` 为例（16 bit，8 种运算，输入寄存器 → 组合 ALU → 输出寄存器）。`synth.tcl` 把 Yosys 的 `synth` 命令拆开执行，每步之后统计一次单元，下面是真实结果：

| 步骤 | 做了什么 | 单元数 | 单元类型（节选） |
|------|----------|--------|------------------|
| 1. 翻译 | always 块、运算符 → 字级单元 | 35 | 3 `$add`、7 `$adff`、5 `$mux`、1 `$pmux`、7 `$eq`、`$shl`、`$shr` |
| 2. 字级优化 | 常量传播、FSM 提取、位宽缩减、加减合并、资源共享、使能识别 | 29 | 2 `$alu`、2 `$adff`、5 `$adffe` |
| 3. 拆成通用门 | 字级单元展开成与工艺无关的 1 bit 门 | 653 | 189 `$_AND_`、174 `$_OR_`、144 `$_MUX_`、64 `$_XOR_`、52 `$_DFFE_PN0P_` |
| 4. 工艺映射 | 触发器和组合逻辑映射到 Sky130 单元 | 559 | 54 `dfrtp_1`、80 `a21oi_1`、71 `nand2_1`、28 `mux2_1`… |

映射后面积 **4302.9 µm²**，其中时序单元 1351.3 µm²（31.4%）。

### 2.1 翻译（elaborate）

把 HDL 解析成工具内部的数据结构：

- 展开参数、generate，确定层次（`hierarchy`，DC 里是 `analyze` + `elaborate`）
- always 块 → 寄存器 + 组合逻辑（Yosys 的 `proc`）。`always @(posedge clk or negedge rst_n)` 变成 `$adff`（带异步复位的 DFF）
- 运算符变成字级单元：`+` → `$add`，`case` → `$pmux`（并行多路选择），`==` → `$eq`
- **这一步就会发现** latch 推断、多驱动、组合环等结构问题（第 7 节）

DC 在这一步把设计转成 **GTECH**（通用工艺无关单元）加 **DesignWare** 算子（加法器、乘法器等可选多种实现的 IP）。

### 2.2 优化（字级 + 门级）

从第 1 步到第 2 步单元数从 35 降到 29，日志里能看到具体发生了什么：

- `alumacc`：`a + b`、`a + ~b + 1` 三个 `$add` 合并成 2 个 `$alu`（ALU 单元同时给出和、进位，比较也能复用）
- `opt_dff`：`if (in_valid) a_q <= a;` 这种“保持”的 MUX 被识别成触发器使能，`$adff + $mux` → `$adffe`
- `fsm`：识别状态机并重新编码（第 6.5 节）
- `wreduce`：删掉恒为 0 的高位，缩小位宽
- `share`：互斥使用的大算子合并（第 6.4 节）
- 常量传播、删除无负载逻辑（dead logic）、合并等价单元（`opt_merge`）

第 3 步把字级单元展开成 1 bit 门（653 个），之后交给 ABC 做门级的逻辑优化（布尔化简、结构重写）。

### 2.3 映射

**时序单元映射**（Yosys `dfflibmap`）：按 liberty 里 `ff` 组的功能匹配。Sky130 hd 库里有异步复位 DFF（`dfrtp`），但**没有“异步复位 + 使能”的 DFF**，所以 52 个 `$_DFFE_PN0P_` 被拆成 `dfrtp` + 前面一个保持用的 MUX（映射结果里 28 个 `mux2_1`，其余被 ABC 吸收进 `a21oi` 等复合门）。这也是为什么大量使能寄存器会让面积变大，而门控时钟（ICG）能把这部分 MUX 省掉（见 `../05_Clock_Reset_Design/README.md` 第 2 节、`../09_Low_Power_Design`）。

**组合逻辑映射**（Yosys `abc`）：把门级网络切成小块，与库里单元的功能模式匹配，按代价（面积或延时）选择覆盖方式。复合门 `a21oi`（= !((A1&A2)|B1)）一个单元顶替了三个通用门，这是映射后单元数反而比第 3 步少的原因。

**tie 单元**：常量 0/1 映射到 `conb_1`（tie-hi/tie-lo 单元），后端不允许信号线直接接电源网（`hilomap`）。

### 2.4 验证第 4 步的网表：门级仿真

同一个 testbench，只把 DUT 换成网表 + Sky130 单元的 Verilog 模型：

```
==== 2. RTL 仿真 ====
PASS: 1528 个有效结果全部与参考模型一致
==== 4. 门级仿真（网表 + Sky130 功能模型）====
PASS: 1528 个有效结果全部与参考模型一致
```

门级仿真只能覆盖测到的向量；证明“对所有输入都一样”要靠形式等价性检查（第 8 节）。

---

## 3. DC / Genus 基本脚本

商业工具本机没有，下面是典型写法（命令名以各工具文档为准）。本 lab 的 `synth.tcl` 每一步都能对上。

### 3.1 Design Compiler

```tcl
# ---------- 库 ----------
set_app_var search_path      ". ./lib ./rtl"
set_app_var target_library   "std_ss_0p72v_125c.db"        ;# 映射用的单元库
set_app_var link_library     "* std_ss_0p72v_125c.db"      ;# 解析引用（含 RAM 等宏单元的 .db）
set_svf alu.svf                                           ;# 记录优化过程，给 Formality 用

# ---------- 读入与翻译 ----------
analyze   -format verilog {alu.v}
elaborate alu -parameters "W=16"
current_design alu
link
check_design > reports/check_design.rpt                    ;# 多驱动、悬空、未连接端口……
uniquify                                                   ;# 多次例化的子模块各自一份（新版本多为自动）

# ---------- 约束 ----------
source alu.sdc
set_dont_use [get_lib_cells */*_lvt*]                      ;# 例如禁止用某类单元
set_max_fanout 32 [current_design]
set_ideal_network [get_ports rst_n]                        ;# 大扇出复位先当理想网络，后端再建树

# ---------- 综合 ----------
compile_ultra -no_autoungroup                              ;# 或加 -retime / -gate_clock
# compile_ultra -incremental                               ;# 增量优化

# ---------- 报告 ----------
report_qor                     > reports/qor.rpt           ;# 面积、WNS/TNS、单元数总览
report_area -hierarchy         > reports/area.rpt
report_timing -max_paths 20    > reports/timing.rpt
report_constraint -all_violators > reports/viol.rpt
report_power                   > reports/power.rpt

# ---------- 输出 ----------
change_names -rules verilog -hierarchy                     ;# 统一命名，避免后端工具不认的字符
write -format verilog -hierarchy -output alu_netlist.v
write -format ddc     -hierarchy -output alu.ddc
write_sdc alu_mapped.sdc
write_sdf alu.sdf                                          ;# 门级仿真反标用
```

要点：

- **target_library vs link_library**：前者是映射时能挑的单元；后者是解析网表引用时查找的范围（`*` 表示内存里已有的设计），宏单元（SRAM、PLL）的 `.db` 只放 link_library。
- **compile vs compile_ultra**：`compile_ultra` 打开更强的时序/面积优化（自动 ungroup、边界优化、数据通路优化如 CSA 树、更积极的逻辑重构），面积和运行时间更大；现在大多数项目直接用 `compile_ultra`。
- **wire load model 与 topographical**：传统模式按扇出查表估计线长；DC topographical（`dc_shell -topo`）/ Genus physical 读入 floorplan 与物理库估线长，综合结果与后端更一致。

### 3.2 Genus

```tcl
set_db init_lib_search_path ./lib
read_libs  std_ss_0p72v_125c.lib
read_hdl   alu.v
elaborate  alu
check_design -unresolved
read_sdc   alu.sdc

set_db syn_generic_effort medium
syn_generic                        ;# 翻译 + 通用优化（≈ 本 lab 第 1–3 步）
syn_map                            ;# 工艺映射（≈ 第 4 步）
syn_opt                            ;# 映射后优化

report_area; report_timing; report_power; report_qor
write_hdl  > alu_netlist.v
write_sdc  > alu_mapped.sdc
write_do_lec -revised_design alu_netlist.v > lec.do   ;# 直接生成 Conformal LEC 脚本
```

### 3.3 与本 lab 的对照

| 概念 | DC | Genus | Yosys（本 lab） |
|------|----|-------|-----------------|
| 读 RTL、展开层次 | `analyze` / `elaborate` | `read_hdl` / `elaborate` | `read_verilog` / `hierarchy` |
| 通用优化 | `compile` 内部 | `syn_generic` | `proc`、`opt`、`fsm`、`alumacc`、`share`、`techmap` |
| 映射 | `compile` 内部 | `syn_map` | `dfflibmap` + `abc` |
| 时序驱动 | 读 SDC 自动进行 | 读 SDC 自动进行 | 需手工给 ABC 延时目标 `-D`（ABC 不读 SDC） |
| 结构检查 | `check_design` | `check_design` | `check` |
| 报告 | `report_area/timing/power` | 同名 | `stat -liberty` + OpenSTA |

**Yosys 与商业工具最大的区别**：Yosys 不读 SDC，映射时只知道一个组合逻辑延时目标；综合后的时序要靠 OpenSTA 另外检查（本 lab 就是这么做的）。

---

## 4. 读综合报告：面积、时序、功耗

### 4.1 面积（`stat -liberty` / `report_area`）

`lab/Yosys_Flow/reports/step4_mapped.stat` 节选：

```
      559  4.3E+03 cells
       54 1.35E+03   sky130_fd_sc_hd__dfrtp_1
       80  400.384   sky130_fd_sc_hd__a21oi_1
       71  266.506   sky130_fd_sc_hd__nand2_1
       28  315.302   sky130_fd_sc_hd__mux2_1
       ...
   Chip area for module '\alu': 4302.876800
     of which used for sequential elements: 1351.296000 (31.40%)
```

看什么：

- **总面积、组合/时序占比**：54 个 DFF 占了 31% 面积（单个 `dfrtp_1` 25 µm²，约是 `nand2_1` 的 7 倍）。减少寄存器数量（尤其是带复位的）是省面积的直接手段。
- **单元种类分布**：出现很多大驱动单元（`_4`、`_8`）说明工具在为时序 upsize；出现 `buf` 很多说明在修扇出或 hold。
- DC 的 `report_area` 还会分 combinational / noncombinational / buf/inv / net interconnect（线负载模型估计）面积，`-hierarchy` 按模块列出。

面积单位是 µm²，工业上也常换算成**等效门数**：总面积 ÷ 最小驱动 2 输入与非门面积（本库 `nand2_1` 为 3.75 µm²，4302.9 / 3.75 ≈ 1150 门）。

### 4.2 时序（OpenSTA / `report_timing`）

`lab/Yosys_Flow/reports/sta_area.rpt`，时钟 4 ns（250 MHz），理想时钟：

```
Startpoint: _1050_ (rising edge-triggered flip-flop clocked by clk)
Endpoint: _1015_ (rising edge-triggered flip-flop clocked by clk)
Path Type: max

   Delay     Time   Description
   0.000    0.000 ^ _1050_/CLK (sky130_fd_sc_hd__dfrtp_1)
   1.144    1.144 ^ _1050_/Q (sky130_fd_sc_hd__dfrtp_1)      ← Tcq 1.144：Q 端负载很大
   0.601    1.745 v _0512_/Y (sky130_fd_sc_hd__clkinv_1)      ← 小反相器驱动大扇出，又慢
   0.215    1.961 ^ _0578_/Y (sky130_fd_sc_hd__nand2_1)
   ...（共 17 级）
   0.004    4.966 v _1015_/D (sky130_fd_sc_hd__dfrtp_1)
            4.966   data arrival time
   4.000    4.000   clock clk (rise edge)
  -0.200    3.800   clock uncertainty
  -0.099    3.701   library setup time
            3.701   data required time
           -1.265   slack (VIOLATED)
```

读法与 `../07_STA/README.md` 第 14 节完全相同。综合阶段特有的两点：

- **理想时钟**：clock network delay 为 0，skew 只能靠 uncertainty 预留
- **线延时是估计的**：这里网表没有任何线信息，只有引脚电容；真实布线后会更慢（第 14 章 lab 会看到）

这条路径的根因是**起点寄存器扇出大**：Tcq 1.144 ns 加上第一级反相器 0.601 ns，前两级就用掉 1.7 ns。修法见第 6.2 节（时序驱动映射会 upsize、插 buffer）。

### 4.3 功耗（`report_power`）

没有仿真波形时，给输入一个假定翻转率（每周期翻转概率 0.2），工具沿网表传播翻转率再算功耗：

```
Group                  Internal  Switching    Leakage      Total
Sequential             6.20e-04   2.10e-04   4.72e-10   8.31e-04  49.7%
Combinational          4.27e-04   4.15e-04   9.98e-10   8.42e-04  50.3%
Total                  1.05e-03   6.26e-04   1.47e-09   1.67e-03 100.0%
                          62.6%      37.4%       0.0%
```

- **internal**：单元内部短路电流 + 内部节点充放电（查 liberty 的 internal_power 表）
- **switching**：驱动线网和下一级引脚电容，`½·C·V²·f·α`
- **leakage**：静态漏电。Sky130 130 nm 典型 corner 下漏电只有 nW 级，所以占比 0.0%；先进工艺漏电可以占到可观比例（见 `../09_Low_Power_Design`）
- 时序单元功耗占一半：54 个 DFF 每周期都有时钟翻转，这正是门控时钟的收益来源
- 精度：假定翻转率只能做相对比较；可信的功耗要用仿真得到的 **SAIF / VCD**（DC `read_saif`，PrimePower/Voltus 等签核工具）

---

## 5. 综合约束

综合用的 SDC 与 STA 同一套语法（`../07_STA/README.md` 第 12 节），这里只讲综合阶段的特殊考虑。`lab/Yosys_Flow/alu.sdc`：

```tcl
create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty 0.20 [get_clocks clk]
set_input_delay  -clock clk [expr {$CLK_PERIOD * 0.5}] [get_ports {in_valid op[*] a[*] b[*]}]
set_output_delay -clock clk [expr {$CLK_PERIOD * 0.5}] [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X [get_ports {in_valid op[*] a[*] b[*] rst_n}]
set_load 0.01 [all_outputs]
```

| 约束类别 | 命令 | 综合阶段的作用 |
|----------|------|----------------|
| 时钟 | `create_clock`、`create_generated_clock` | 确定所有 reg→reg 路径的目标 |
| 时钟不确定度 | `set_clock_uncertainty` | CTS 前 skew 未知，要预留（常比后端大） |
| 理想网络 | 时钟默认理想；`set_ideal_network` 用于复位、scan enable | 大扇出网先不修，交给后端建树（07 章 lab 里 `rst_w` 驱动几百个 DFF 就是这类网） |
| IO 延时 | `set_input_delay`、`set_output_delay` | 端口路径的预算；不设则端口路径**不受约束** |
| 驱动与负载 | `set_driving_cell`、`set_load` | 端口的 slew 和负载；不设则输入 slew 为 0、输出无负载，过于乐观 |
| 设计规则（DRV） | `set_max_transition`、`set_max_fanout`、`set_max_capacitance` | 工具会插 buffer / upsize 满足 |
| 工作条件 | `set_operating_conditions`、库选择 | 综合一般用**最慢 corner**（ss、低压、高温）保证 setup |
| 线负载 | `set_wire_load_model`、`set_wire_load_mode` | 非物理综合时估计线延时 |
| 面积目标 | `set_max_area 0`（旧写法） | 时序满足后继续压面积 |
| 例外 | `set_false_path`、`set_multicycle_path`、`set_clock_groups` | 同 STA；异步时钟必须声明，否则工具会“修”不存在的违例 |

常见追问：

- **为什么综合用最慢 corner？** 综合主要解决 setup；hold 与频率无关，而且综合时时钟是理想的、hold 还没法准确评估，通常留到 CTS 之后修（见第 14 章）。
- **过约束（over-constrain）**：综合时把周期收紧 10%–20% 给后端留余量，因为布线后线延时会增加。代价是面积和功耗上升，过度收紧还会让工具在不可能的路径上浪费时间。
- **约束写漏了会怎样**：没约束的路径工具不会优化，STA 也不会报违例；签核前要用 `check_timing`（DC）/ `check_setup`（OpenSTA）确认没有 unconstrained endpoint。

---

## 6. 优化手段与取舍

全部数据来自 `lab/Yosys_Flow`（第 6.2 节）和 `lab/Opt_Experiments`（其余各节）的 `bash run.sh`。

### 6.1 面积优先 vs 时序优先

综合是**多目标优化**：同一功能有很多种门级实现。

| 实现 | 面积 | 延时 |
|------|------|------|
| 行波进位加法器 | 小 | O(n) |
| 超前进位 / 前缀加法器 | 大 | O(log n) |
| 小驱动单元 | 小 | 带大负载时慢 |
| 大驱动单元 | 大 | 快，但输入电容大，拖慢前一级 |

工具的策略：先满足时序（关键路径用快结构、大驱动），再在**非关键路径**上回收面积（换小结构、downsize）。所以约束越紧，面积越大、功耗越高。

### 6.2 实验：时序驱动映射的面积-时序曲线

`lab/Yosys_Flow/run.sh` 第 6 步：同一个 ALU，4 ns 时钟，ABC 用不同的组合逻辑延时目标 `D` 映射：

```
mapping      area_um2    cells   setup_ws
area           4302.9      559      -1.27
D=4000         4376.7      700      -0.11
D=3000         4380.5      703       0.02
D=2500         4438.0      696       0.56
D=2000         4571.9      725       1.09
```

- 面积优先（默认 `&nf` 映射器）WNS −1.27 ns；只加 1.8% 面积（D=3000）时序就收敛
- 继续收紧，面积上升加快：D=2000 多 6.3% 面积换 1.09 ns 裕量
- 单元数从 559 涨到 700 多，但面积只涨几个百分点：多出来的主要是 buffer 和尺寸调整
- ABC 的 `D` 只针对组合逻辑，它**看不到** Tcq（本例 1.1 ns）、setup 和 uncertainty，所以 D=4000 仍然违例。商业工具直接读 SDC，没有这个问题。
- 实测中 ABC 的默认映射器 `&nf` 对这个设计基本忽略 `-D`（D 从 500 到 2500 面积完全不变）；要换成经典的 `map -D` 加 `buffer/upsize/dnsize`，并用 `-constr` 告诉它驱动单元和输出负载（`abc.constr`），`synth.tcl` 里就是这么写的。

### 6.3 边界优化与层次（ungroup / flatten）

`boundary.v`：通用子模块 `arith_unit` 的 `mode` 为 1 做乘法、为 0 做加法；顶层把 `mode` 接成常量 0。

```
  A_flatten    area=  432.9  cells=  35  FF=  9  打平：常量穿过边界，乘法器被删
  A_hier       area= 2658.8  cells= 318  FF= 16  保留层次：子模块看不到常量
       Chip area for module '\boundary_top': 400.384000
       Chip area for module '$paramod\arith_unit...': 2258.416000
```

- 打平后，常量 0 **穿过层次边界**传播进子模块，乘法器整个被删掉；输出高 7 位恒为 0（8 bit + 8 bit 最多 9 bit），对应寄存器也被删掉，只剩 9 个 FF。面积差 **6 倍**。
- 保留层次时，子模块被当作独立设计综合，它不知道 `mode` 恒为 0，乘法器保留下来。
- DC 里：`compile_ultra` 默认会自动 ungroup 小模块并做边界优化；`-no_autoungroup`、`-no_boundary_optimization`、`set_ungroup`、`set_boundary_optimization` 控制它。

**为什么有时要保留层次**：

- 后端做层次化设计（分块布局、分块签核）需要边界不动
- 形式验证、ECO、调试时希望网表名字能对应到 RTL 模块
- 要对某个模块单独约束或单独替换

代价就是像本例这样丢掉跨边界的优化机会。常见折中：顶层的大块保留层次，块内小模块打平。

### 6.4 资源共享（resource sharing）

`share.v`：`y = sel ? a*b : c*d`（字面上两个乘法器）与手写的 `y = (sel?a:c) * (sel?b:d)`（一个乘法器）。

```
  C_mul2_default  area= 4047.6  cells= 544   默认：alumacc 先把 $mul 变成 $macc，share 不处理
    最差路径终点 y[15]    arrival=3.69
  C_mul2_share    area= 2074.5  cells= 295   -noalumacc：share 把两个乘法器合成一个
    最差路径终点 y[14]    arrival=4.37
  C_mul2_noshare  area= 3987.6  cells= 532   -noalumacc -noshare：两个乘法器
    最差路径终点 y[14]    arrival=3.70
  C_mul1          area= 2074.5  cells= 295   手写：先选操作数再乘
    最差路径终点 y[14]    arrival=4.37
```

- 共享后面积减半，和手写版**完全相同**（工具做的正是“把 MUX 从乘法器后面挪到前面”）
- **代价是延时**：3.70 → 4.37 ns，因为 `sel` 现在要先经过 MUX 再进乘法器。资源共享本质上是用时序换面积，工业工具会在时序紧的路径上不共享
- 共享的前提：两个算子**不会同时被用到**（这里由 `sel` 保证互斥）。Yosys 日志里能看到它用 SAT 求出的激活条件：`Activation pattern for cell $mul...: \sel = 1'1` / `\sel = 1'0`
- 实测的 Yosys 细节：默认流程里 `alumacc` 在 `share` 之前执行，把 `$mul` 转成 `$macc` 后 `share` 就不再处理它，所以默认没有共享。这类“工具在什么条件下才做某优化”的细节，商业工具同样存在，**关键路径上不要指望工具替你共享，想要就手写**。

### 6.5 FSM 编码

`fsm.v`：序列检测 1011（可重叠），5 个状态，RTL 用二进制常量。同一份 RTL，用 `setattr -set fsm_encoding` 指定编码：

```
  D_fsm_auto      area= 198.9  cells= 15  FF= 6
    log: mapping auto encoding to `one-hot` for this FSM.
  D_fsm_binary    area= 121.4  cells= 11  FF= 3
  D_fsm_one-hot   area= 198.9  cells= 15  FF= 6
```

| 编码 | 状态 FF 数（N 个状态） | 次态逻辑 | 适用 |
|------|------------------------|----------|------|
| 二进制（binary） | ⌈log₂N⌉ | 需要译码，较深 | 状态多、面积敏感（ASIC 常用） |
| 独热（one-hot） | N | 每个 FF 只看少数几个状态位，浅、快 | 高速、FPGA（FF 多） |
| Gray | ⌈log₂N⌉ | 相邻状态只变一位 | 顺序跳转的状态机，降翻转功耗 |

- Yosys 默认 `auto` 为这个 FSM 选了 one-hot（5 个状态 FF + `hit` = 6）
- binary 只有 3 个 FF：状态寄存器中有一位与 `hit` 的 D 端逻辑完全相同（都是“次态 == S1011”），被 `opt_merge` 合并掉了——这是合并等价寄存器的又一例（第 6.7 节）
- 在这个小状态机上 binary 反而更小；one-hot 的优势在状态多、转移条件复杂时的**速度**
- one-hot 的安全性：非法状态（多位同时为 1）不会自己回到合法状态，需要时要加恢复逻辑，工具的“safe FSM”选项会做这件事

### 6.6 retiming（寄存器重定时）

**retiming**：在不改变电路输入输出行为（每个输出相对输入的周期数）的前提下，把寄存器跨过组合逻辑前后移动，平衡各级流水线的延时。

```
原始：  in ─►[R]─► 乘法1 ─► 乘法2 ─►[p1]─►[y]      第 2 级很长，第 3 级为空
手工：  in ─►[R]─► 乘法1 ─►[t_hi]─► 乘法2 ─►[y]
                   c ────►[c_d] ──┘               寄存器跨过乘法器 2 的两个输入往回搬，
                                                    c 这一路也要补寄存器
```

`retime.v` 实验（y = ((a·b) 取高 8 位) · c，3 拍延迟，时钟 3 ns）：

```
  E_orig     area= 5141.2  cells= 573  FF= 56    最差路径终点 _1078_/D arrival=7.09  slack=-4.21
  E_abcdff   area= 5036.1  cells= 592  FF= 48    最差路径终点 _0576_/D arrival=4.04  slack=-1.17
  E_manual   area= 4827.1  cells= 526  FF= 56    最差路径终点 _935_/D  arrival=3.87  slack=-1.00
    E_abcdff 门级仿真: PASS: 496 个结果正确
```

- 手工 retiming：最长路径 7.09 → 3.87 ns，频率几乎翻倍，FF 数不变（16 bit 的 `p1` 换成 8 bit `t_hi` + 8 bit `c_d`），面积反而略小
- ABC 自动 retiming（`abc -dff`）：7.09 → 4.04 ns，FF 从 56 降到 48。它把输入寄存器往逻辑里推，同时改变了端口的 I/O 时序（输入端口到第一级寄存器的路径变长）；功能经门级仿真确认不变
- 两者都没满足 3 ns（单个 8×8 乘法器本身约 3.5 ns），说明 retiming 只能**平衡**，不能让单级逻辑变快

要点：

- **写 RTL 的常用套路**：把流水线寄存器“堆在后面”，打开工具的 retiming 让它自己搬（DC：`compile_ultra -retime` 或 `set_optimize_registers`；Genus 有对应的 retime 选项，以工具文档为准）
- **限制**：带异步复位的寄存器搬动后复位值要重新推导，很多工具不搬或受限——所以数据通路寄存器常不带复位；跨时钟域、同步器、`dont_touch` 的寄存器不能搬；输出端口前的寄存器一般不允许跨端口搬
- **对验证的影响**：寄存器名字、数量都变了，按名字匹配比较点的等价性检查会失败，需要综合工具生成的 guidance（DC 的 SVF）或**时序（sequential）等价性检查**（第 8 节）

### 6.7 合并等价寄存器与 dont_touch

`boundary.v` 的 `dup_nokeep`：`en` 负载很大，设计者手工复制了两份寄存器 `en_a`、`en_b`，各带一半负载。

```
  B_nokeep      area= 605.6  cells= 33  FF= 17  默认：en_a/en_b 被合并成一个
  B_keep_wire   area= 605.6  cells= 33  FF= 17  (* keep *) 写在 reg 上：仍被合并
  B_keep_cell   area= 630.6  cells= 34  FF= 18  keep 设在寄存器单元上：两份都保住
```

- 两个寄存器的 D、时钟、复位完全相同，工具认为它们等价，合并掉一个（省面积，但扇出又回到原样）
- **坑**：Yosys 里 `(* keep *) reg en_a;` 的属性落在 **wire** 上，寄存器单元照样被合并；要把 keep 设在**单元**上（`setattr -set keep 1 <选中的寄存器单元>`）
- DC 里的对应：`set_dont_touch [get_cells en_a_reg]`（单元）、`set_dont_touch [get_nets n1]`（线网）、`set_dont_touch <design>`（整个模块）；与寄存器合并相关的开关是 `compile_seqmap_identify_shift_registers` / `compile_enable_register_merging` 之类（以工具文档为准）

常见的 dont_touch 场景：

| 场景 | 为什么不让工具动 |
|------|------------------|
| 同步器寄存器 | 不能被合并、复制或 retiming，否则 CDC 结构被破坏 |
| 手工例化的 ICG、时钟 MUX、延时单元 | 结构有特殊用途，工具可能“优化”掉 |
| 手工复制的寄存器 | 降扇出的意图会被合并破坏 |
| 为 ECO 预留的备用单元（spare cells） | 没有负载，会被当成无用逻辑删掉 |
| 已经签核过的硬核模块 | 不允许改动 |

相关命令还有：`set_dont_use`（禁止使用某些库单元，例如 lab 里的 `-dont_use *lpflow*`）、`set_size_only`（只允许改尺寸，不允许改逻辑）。

### 6.8 其它常见优化（了解即可）

- **常量传播与无用逻辑删除**：第 6.3 节里输出恒 0 的寄存器被删；综合日志里的 “Removed N unused cells” 就是这一类
- **数据通路优化**：多个加法合成一个进位保留加法树（CSA tree），乘加融合（Yosys 的 `$macc`、DC 的 DesignWare）
- **自动插入门控时钟**：DC `compile_ultra -gate_clock`、`insert_clock_gating`，把大量带使能的寄存器换成 ICG + 普通 DFF（第 2.3 节里 `dfrtp + mux2` 就是它能省掉的部分）；见 `../09_Low_Power_Design`
- **multi-bit banking**：多个单 bit DFF 合成多位 DFF 单元，省面积和时钟功耗
- **多阈值单元**：关键路径用 LVT（快、漏电大），非关键路径用 HVT（慢、漏电小）

---

## 7. 网表检查：check_design 与 lint

综合前后都要做结构检查。`lab/Equivalence/bad_design.v` 故意放了 5 类问题，Yosys `check` 与 Verilator lint 的真实输出：

```
-- Yosys check：
     Warning: Latch inferred for signal `\bad_design.\q_latch' from process ...
     Warning: multiple conflicting drivers for bad_design.\b [3]:
     ...
     Warning: Wire bad_design.\floating_out is used but has no driver.
     Warning: found logic loop in module bad_design:
     Found and reported 6 problems.
-- Verilator lint：
     %Warning-WIDTHTRUNC: bad_design.v:39:20: Operator ASSIGNW expects 4 bits on the Assign RHS, but ... 'sum' generates 8 bits.
     %Warning-UNDRIVEN: bad_design.v:20:18: Signal is not driven: 'floating_out'
     %Warning-UNUSEDSIGNAL: bad_design.v:38:16: Bits of signal are not used: 'sum'[7:4]
     %Warning-LATCH: bad_design.v:23:5: Latch inferred for signal 'q_latch' (not all control paths ...)
     %Warning-MULTIDRIVEN: bad_design.v:17:18: Bits [3:0] of signal 'y_multi' have multiple combinational drivers. ...
     %Warning-UNOPTFLAT: bad_design.v:18:18: Signal unoptimizable: Circular combinational logic: 'loop_out'
```

| 问题 | 例子 | 后果 | 谁能抓到 |
|------|------|------|----------|
| latch 推断 | 组合 always 里 `if` 无 `else` | 多出 latch，时序分析复杂、可能有毛刺 | Yosys、Verilator、DC（elaborate 时报 inferred latch） |
| 多驱动 | 两个 `assign` 驱动同一根线 | 综合报错或短路 | 都能 |
| 组合环 | 与非门首尾相接 | 振荡或锁存，STA 无法分析（要打断） | Yosys `check`、Verilator、DC `report_timing -loops` |
| 位宽截断 | 8 bit 赋给 4 bit | 高位被悄悄丢掉，仿真也不报错 | Verilator（Yosys `check` 不报） |
| 悬空 / 未用端口 | 输出没驱动、输入没用 | 输出为 X 或常量；可能是连线遗漏 | 悬空输出两者都报；本例 Verilator 5.051 对顶层未用输入 `unused_in` 没有报警 |

注意 Yosys 报多驱动时指向的是 `b`：`assign y_multi = a;` 让 `y_multi` 和 `a` 成了同一根线，第二个 `assign` 又把 `b` 接上来，工具看到的是 `a`/`b` 被短在一起。

DC 的 `check_design` 还会报：未连接的输入引脚、常量驱动的端口、多次例化未 uniquify 的模块、找不到定义的模块（unresolved references）等。**签核前 check_design 与 lint 必须清零或逐条豁免（waiver）**。

---

## 8. 形式等价性检查（LEC）

### 8.1 为什么需要

综合、插 scan、ECO、布局布线后的优化都会改网表。怎么证明新网表和 RTL 功能完全一样？

- **仿真**：只能覆盖测到的向量；门级仿真很慢
- **形式等价性检查（Logic Equivalence Checking，LEC）**：用数学方法证明两个设计对**所有**输入都产生相同输出，不需要激励。工具：Synopsys **Formality**、Cadence **Conformal LEC**；开源有 Yosys `equiv_*` 系列与 `eqy`

每次网表变动都要跑：RTL vs 综合网表、综合网表 vs 插 scan 后网表、综合网表 vs 布局布线后网表、ECO 前 vs ECO 后。

### 8.2 原理：比较点匹配 + 组合等价

```
    reference (RTL)                    implementation (网表)
   ┌─────────────────┐                ┌─────────────────┐
in─┤ 组合 ─►[a_q]─► 组合 ─►[y]├─out   in─┤ 门   ─►[_1047_]─► 门 ─►[_1031_]├─out
   └─────────────────┘                └─────────────────┘
          ▲      ▲                          ▲       ▲
          └──────┴──── 比较点配对（a_q ↔ _1047_，y ↔ _1031_）
```

1. **找比较点（compare point / key point）**：主输出、每个寄存器的输入、黑盒的输入
2. **匹配（matching）**：把两边的比较点一一配对。先按名字，再按功能签名、结构等方法。匹配不上的叫 unmatched / unmapped point
3. **验证（verify / compare）**：寄存器切断了时序，每个比较点的逻辑都变成“以寄存器输出和主输入为变量的组合函数”，用 BDD / SAT 证明两边函数相同
4. 结果：equivalent / non-equivalent（给出反例）/ aborted（太复杂没算完）

这就是**组合等价检查**：要求两边寄存器一一对应。它快、可扩展到上亿门，是工业流程的主力。

### 8.3 实验

`lab/Equivalence/run.sh`，RTL 与 `lab/Yosys_Flow` 的两份网表比较：

```
==== 1. 等价性检查 ====
-- area: Found 54 $equiv cells in equiv:
       Of those cells 54 are proven and 0 are unproven.
       Equivalence successfully proven!
-- D2000: Found 54 $equiv cells in equiv:
       Of those cells 54 are proven and 0 are unproven.
       Equivalence successfully proven!
   两份网表的单元数：559 vs 725
```

54 个比较点 = `a_q`(16) + `b_q`(16) + `op_q`(3) + `v_q`(1) + `y`(16) + `zero`(1) + `out_valid`(1)，正好是全部寄存器。两份网表结构差很多（559 vs 725 个单元），功能都被证明与 RTL 一致。能按名字匹配，是因为 Yosys 映射后保留了寄存器输出线网的 RTL 名字（`.Q(a_q[3])`）；日志里的 `Presumably equivalent wires: a_q_gold ..., a_q_gate ({ \_1047_.IQ_gate ... })` 就是匹配结果。

再往网表里注入一个 bug——第 583 行的 `nand2_1` 换成 `nor2_1`：

```
==== 2. 注入 bug：第一个 nand2_1 换成 nor2_1 ====
   第 583 行 原：sky130_fd_sc_hd__nand2_1 _0517_ (
   第 583 行 改：sky130_fd_sc_hd__nor2_1 _0517_ (
-- bug: Found 54 $equiv cells in equiv:
       Of those cells 53 are proven and 1 are unproven.
   equiv_status 列出的未证明比较点：
     Unproven $equiv ...: \b_q_gold [12] \b_q_gate [12]
   同一个 bug 网表跑门级仿真（2000 个随机向量）：
     FAIL: 403 个错误（检查了 1528 个结果）
```

- 形式验证直接指出是 `b_q[12]` 这个比较点不等价（被改的门在 `b_q[12]` 的使能/保持逻辑里），调试范围一下缩到一个寄存器的输入锥
- 仿真这次也抓到了，但只能告诉你“输出错了”，还要自己往回追；如果 bug 在很少被激活的逻辑里，随机仿真可能根本碰不到

### 8.4 常见的不等价 / 匹配失败原因

| 现象 | 原因 | 处理 |
|------|------|------|
| unmatched 寄存器 | 综合合并了等价寄存器（第 6.7 节）、删了常量寄存器（第 6.3 节）、改了名字 | 综合工具写出 guidance：DC 的 **SVF**（`set_svf`）、Genus 的 `write_do_lec`；LEC 工具自动识别常量寄存器 |
| retiming 后匹配不上 | 寄存器被搬动、数量变化，没有一一对应关系 | guidance 文件；或做**时序等价性检查**（sequential equivalence，从复位状态展开多个周期比较，慢得多） |
| RTL 中的 X / don't care | `default: y = 'x;`、`full_case`/`parallel_case` 注释 | RTL 侧的 X 可被综合成任意值，LEC 一般把它当 don't care 处理；`// synopsys full_case` 会造成**仿真与综合不一致**，应避免使用 |
| 黑盒不一致 | SRAM、模拟 IP 两边都当黑盒，但端口连接不同 | 检查黑盒引脚连接 |
| scan 插入后不等价 | 测试模式下行为不同 | 把 `scan_enable`/`test_mode` 约束为功能模式的常量 |
| 时钟门控 | ICG 插入后寄存器从“使能”变成“门控时钟” | LEC 工具需要识别门控结构（相关选项以工具文档为准） |

### 8.5 商业工具脚本（参考）

```tcl
# Formality
set_svf alu.svf
read_verilog -r alu.v                  ; set_top r:/WORK/alu     ;# reference
read_db      -i std_ss.db
read_verilog -i alu_netlist.v          ; set_top i:/WORK/alu     ;# implementation
match
verify
report_unmatched_points
report_failing_points
analyze_points -failing
```

```tcl
# Conformal LEC
read library std_ss.lib -liberty
read design alu.v         -golden
read design alu_netlist.v -revised
set system mode lec                    ;# 进入比较模式时自动做 mapping
report unmapped points
add compared points -all
compare
report compare data -class nonequivalent
```

---

## 9. 运行全部实验

```bash
# WSL（工具在 /root 下，需要 root）
sudo -i
cd "/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/08_Logic_Synthesis/lab"
bash Yosys_Flow/run.sh          # 约 20 秒
bash Opt_Experiments/run.sh     # 约 40 秒
bash Equivalence/run.sh         # 依赖 Yosys_Flow 的网表，没有会自动先跑
```

Windows 下编辑过脚本后先 `sed -i 's/\r$//' 文件` 去掉 CRLF。

| 目录 | 文件 | 作用 |
|------|------|------|
| `Yosys_Flow/` | `alu.v`、`tb_alu.v` | RTL 与自检查 TB（RTL 和门级共用） |
| | `synth.tcl` | 逐步综合（`ABC_D` 环境变量切换时序驱动映射） |
| | `alu.sdc`、`abc.constr`、`sta.tcl` | 约束、ABC 驱动/负载、OpenSTA 时序与功耗 |
| | `reports/step*.stat`、`sta_*.rpt` | 每步单元统计、时序报告 |
| `Opt_Experiments/` | `boundary.v`、`share.v`、`fsm.v`、`retime.v` | 5 组优化实验电路 |
| | `tb_opt.v`、`tb_retime.v` | RTL 自检查；`tb_retime.v` 也用于 retiming 网表的门级仿真 |
| | `sta_generic.tcl` | 通用 STA（有 clk 用真时钟，纯组合用虚拟时钟） |
| `Equivalence/` | `equiv.tcl` | Yosys 形式等价性检查 |
| | `bad_design.v` | check_design 练习 |

`build/`、`reports/`、`*.vcd` 是生成物，不需要提交。

---

## 10. 速查表

```
综合 = 翻译(elaborate) → 优化 → 映射(target_library)，在约束下迭代
输入三件套：RTL + liberty(.lib/.db) + SDC        输出：网表 + SDC + SDF + 报告 (+ SVF)
target_library：映射可用的单元     link_library："*" + 所有被引用的库（含宏单元）
compile_ultra：自动 ungroup + 边界优化 + 数据通路优化；-retime / -gate_clock
综合用最慢 corner 修 setup；hold 留到 CTS 后；时钟理想、大扇出网 set_ideal_network
约束越紧 → 面积、功耗越大（lab：+1.8% 面积 WNS -1.27→0；+6.3% → +1.09）
打平/边界优化：常量跨边界传播（lab：面积差 6 倍）；保留层次方便层次化后端与调试
资源共享：面积↓ 延时↑（lab：面积减半，3.70→4.37 ns），前提是两个算子互斥
FSM：binary 省 FF，one-hot 次态浅、快；非法状态要考虑恢复
retiming：搬寄存器平衡各级，不改变周期数；异步复位/同步器/dont_touch 的寄存器不搬
dont_touch 设在 cell 上；同步器、ICG、手工复制寄存器、spare cell 要保护
check_design / lint：latch、多驱动、组合环、截断、悬空 —— 签核前清零
LEC：比较点(PO / 寄存器 D / 黑盒输入) → 匹配 → 组合等价证明；retiming 要 SVF 或时序等价
Formality: match / verify     Conformal: set system mode lec / compare
```

---

## 11. 面试题

**Q1. 综合的三个步骤是什么？**  
翻译：把 RTL 转成工艺无关的中间表示（DC 的 GTECH + DesignWare）；优化：在约束下做逻辑化简、结构选择；映射：映射到目标库单元，再做尺寸调整、buffer 插入等映射后优化。工业工具里优化和映射是迭代进行的。

**Q2. target_library 和 link_library 的区别？**  
target_library 是映射时可以选用的单元；link_library 是解析设计引用时搜索的库，第一项 `*` 表示内存中已读入的设计，宏单元（SRAM）的 `.db` 只需要放进 link_library。

**Q3. 综合时为什么用 worst corner？hold 为什么通常不在综合阶段修？**  
综合主要保证 setup（最高频率），最慢 corner 下满足才能保证所有 corner 满足 setup。hold 与时钟周期无关，而综合时时钟是理想的，真实 skew 要到 CTS 之后才知道，这时修 hold 既不准又会白白插 buffer，所以一般在 CTS 之后修。

**Q4. set_ideal_network 用在哪里？为什么？**  
复位、scan enable、时钟这类大扇出网络。综合阶段如果修它们的 slew/扇出，会插大量 buffer，而且没有物理位置信息、插得也不对；标成理想网络，留给后端做 buffer 树（复位树、时钟树）。

**Q5. compile 和 compile_ultra 有什么区别？**  
compile_ultra 打开更强的优化：自动 ungroup 和边界优化、数据通路优化（CSA 树等）、更积极的时序驱动重构，并可选 `-retime`、`-gate_clock`。结果更好，运行时间和对层次的改动更大。

**Q6. 什么是 boundary optimization？有什么风险？**  
跨层次边界的优化：常量传播、删除未用端口逻辑、端口反相器吸收等。本章 lab 里子模块输入接常量后，打平可以把乘法器删掉，面积差 6 倍。风险是子模块的端口行为变了：如果后面有人按子模块端口做单独验证、ECO 或层次化实现，会与预期不一致；形式验证也需要 guidance 才能匹配。

**Q7. 资源共享的条件和代价？**  
两个算子在任何时刻最多只有一个结果被使用（互斥），才能共用一个硬件，用 MUX 选择操作数。代价是 MUX 挪到了算子前面，控制信号到输出的路径变长。lab 里面积减半、延时从 3.70 增加到 4.37 ns。

**Q8. one-hot 和 binary 编码怎么选？**  
binary 用 ⌈log₂N⌉ 个 FF，面积小但次态逻辑要译码；one-hot 用 N 个 FF，每个状态位的次态逻辑只依赖少数几位，速度快，FPGA 上 FF 充足时常用。ASIC 上状态多时多用 binary，高速控制路径可用 one-hot。Gray 码适合顺序跳转的状态机，翻转少、功耗低。

**Q9. 什么是 retiming？有哪些限制？**  
在不改变输入输出周期关系的前提下，把寄存器跨过组合逻辑前后移动，平衡流水线各级的延时。限制：带异步复位的寄存器搬动后复位值要重新推导；同步器、dont_touch 的寄存器不能动；一般不跨端口；搬动后寄存器名字和数量变化，等价性检查需要 guidance 或时序等价检查。它只能平衡，不能让单级逻辑变快。

**Q10. 为什么数据通路的寄存器常常不带复位？**  
不带复位的 DFF 面积更小（Sky130 `dfxtp_1` 20.0 µm² vs `dfrtp_1` 25.0 µm²），复位网扇出更小，而且方便 retiming。数据通路的有效性由 valid 信号控制，valid 寄存器带复位即可，数据寄存器上电是什么值无所谓。

**Q11. dont_touch、dont_use、size_only 分别是什么？**  
dont_touch：不许修改（删除、合并、重构）某个单元、线网或模块；dont_use：映射时不许使用某些库单元；size_only：只允许换同功能不同驱动的单元，不允许改逻辑。

**Q12. 手工复制了寄存器降扇出，综合后发现又被合并了，怎么办？**  
对复制出的寄存器单元设 dont_touch（或关闭等价寄存器合并），注意要设在单元上而不是线网上——lab 里 Yosys 的 `(* keep *)` 写在 reg 声明上就不起作用。另外也可以直接让综合/后端工具按扇出约束自动复制。

**Q13. 综合报告里一条路径违例，你怎么分析？**  
先确认约束对不对（时钟、IO delay、是否应该是 false path/multicycle）；再看路径类型和起终点；逐级看延时，找大 Tcq、大 slew、大负载的级（lab 里起点寄存器扇出大，Tcq 1.144 ns）；再决定修法：upsize、插 buffer、逻辑重构、流水线切分、retiming，或者 RTL 改结构。

**Q14. 综合后的时序和布线后的时序为什么不一样？**  
综合时时钟理想、线延时用线负载模型或粗略估计；布局布线后有真实时钟树（skew）、真实走线 RC、串扰，通常更慢。所以综合时要过约束留余量，或者用物理综合（DC topographical / Genus physical）缩小差距。

**Q15. 什么是形式等价性检查？和仿真比有什么优势？**  
用数学方法证明两个设计对所有输入都等价，不需要激励，覆盖率 100%，速度快，失败时能直接定位到不等价的比较点并给出反例。仿真只能覆盖测到的向量。lab 里注入的一个门级 bug，形式检查直接指出是 `b_q[12]`。

**Q16. LEC 的比较点有哪些？匹配失败常见原因？**  
比较点：主输出、寄存器数据输入、黑盒输入。匹配失败常见原因：寄存器被合并或删除（常量寄存器）、改名、retiming、scan 插入、门控时钟插入。解决办法：综合工具输出的 guidance（SVF 等）、常量寄存器识别、约束测试模式、时序等价检查。

**Q17. RTL 里写 `default: y = 'x;` 对综合和 LEC 有什么影响？**  
综合把 X 当 don't care，可以选任何值以简化逻辑；LEC 通常也把 reference 里的 X 当 don't care，所以不会报不等价。但 RTL 仿真里 X 会传播，门级仿真里却是确定值，会造成仿真与网表行为不一致，调试时要注意。

**Q18. `// synopsys full_case parallel_case` 有什么问题？**  
这些注释只影响综合，不影响仿真：综合按“所有情况都已覆盖/各分支互斥”优化，而仿真按原始语义执行，出现未覆盖或重叠的情况时两者不一致。应该用完整的 `default` 和明确互斥的写法代替。

**Q19. 怎么估算一个设计有多少门？**  
总面积除以等效门面积（通常是最小驱动的 2 输入与非门）。lab 里 4302.9 µm² / 3.75 µm²（Sky130 `nand2_1`）≈ 1150 门。

**Q20. 综合网表交给后端之前要检查什么？**  
check_design 干净（无多驱动、悬空、unresolved 引用、意外 latch）；check_timing 无未约束路径；时序、DRV 在综合 corner 下满足（带余量）；LEC 通过；输出网表命名规范（`change_names`），配套 SDC、SVF 一起交付。
