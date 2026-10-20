# 第 09 章：低功耗设计 —— 从翻转活动到电源状态协议

目标：能区分功率与能量、推导动态功耗公式，选择门控时钟、多阈值、多电压、电源关断或 DVFS，并说明它们对功能、时序、验证和物理实现的影响。面试时不仅回答“关时钟省电”，还要解释关掉什么、什么时候安全、付出什么代价，以及结论由什么证据支持。

本章覆盖总纲五个小节。配套实验实际验证了操作数隔离、Yosys 自动门控插入、电源保存/恢复协议和两档 DVFS 顺序；**没有测量真实芯片功耗，也没有完成工艺级低功耗签核**。UPF 模板仅通过 Tcl 解析检查，不能称为 UPF 语义验证。

前置知识：[第 02 章 RTL 语义](../02_HDL_Verilog_SystemVerilog/README.md)、[第 05 章时钟与复位](../05_Clock_Reset_Design/README.md)、[第 06 章 CDC](../06_CDC/README.md)、[第 07 章 STA](../07_STA/README.md)、[第 08 章综合](../08_Logic_Synthesis/README.md)。建议先读功耗组成与门控实验，再读电源关断状态机，最后把多电压和 DVFS 放进系统级约束中。配套 [INTERVIEW_QA.md](INTERVIEW_QA.md) 共 36 题。

## 目录

1. [功耗组成与量化方法](#power)
   - [1.1 动态、短路与漏电](#components)
   - [1.2 α 的定义、功率与能量](#activity)
   - [1.3 如何使用活动文件和功耗报告](#measurement)
2. [门控时钟与 RTL 降低翻转](#clock-gating)
   - [2.1 时钟使能、ICG 与自动插入](#icg)
   - [2.2 操作数隔离实验](#operand)
   - [2.3 真实输出、收益边界与检查](#activity-lab)
3. [多阈值与多电压](#multi-voltage)
   - [3.1 Vt 与 VDD 的区别](#threshold)
   - [3.2 电平转换、隔离与跨域路径](#level-shifter)
4. [电源关断、保持与 UPF](#power-gating)
   - [4.1 电源岛与睡眠收益](#power-island)
   - [4.2 安全关断和唤醒顺序](#sequence)
   - [4.3 控制器和掉电污染实验](#sequence-lab)
   - [4.4 UPF 对象、策略与模板](#upf)
5. [DVFS](#dvfs)
   - [5.1 OPP、能量与时序约束](#opp)
   - [5.2 两档控制器和顺序实验](#dvfs-lab)
6. [整章运行、验证边界与速查](#regression)

<a id="power"></a>
## 1. 功耗组成与量化方法

<a id="components"></a>
### 1.1 动态、短路与漏电：不翻转也不等于不耗电

CMOS 数字逻辑的功耗可粗分为：

```text
Ptotal = Pswitching + Pshort_circuit + Pleakage
```

**开关功耗（switching power）**来自节点电容充放电。电容从 0 充到 VDD，电源提供的能量为 `CVDD²`，其中一半留在电容上，一半在充电路径耗散；之后放电，存储的一半也耗散。一次完整 0→1→0 循环消耗 `CVDD²`。若单位时钟周期平均有 α 次 0→1 充电：

```text
Pswitching = α × C × VDD² × f
```

多个节点应求和 `ΣαiCiVDD²f`，不能把任意一个信号的 α 乘上整个芯片总电容。C 包含单元输入、内部节点和互连等有效负载，实际工具会按模型细分，简单公式是解释方向的模型。

**短路功耗（short-circuit power）**来自输入转换过程中 PMOS 与 NMOS 同时部分导通形成的瞬态电流。其大小与输入 slew、输出负载、单元尺寸和电压有关。不能把每次逻辑翻转都简单理解为只有负载电容充放电。库中的 internal power 表可能已经包含内部电容和短路等贡献，汇总报告时要防止重复计算。

**漏电功耗（leakage power）**在稳态也存在，包括亚阈值、栅介质等漏电路径，可概括为 `Pleakage≈VDD×Ileak`。Ileak 随工艺、温度、阈值和逻辑状态变化，不是每个门固定不变的常数。关掉时钟主要减少翻转，仍然供电的逻辑依然漏电。基础电路推导可参考 [Harris：Low Power Design](https://pages.hmc.edu/harris/class/e158/01/lect20.pdf)。

工程含义是：对动态功耗主导的模块，先减少无效活动、负载或电压；对长时间空闲且漏电占主导的模块，单纯门控时钟可能不够。不能在没有活动、工艺和温度条件的情况下给出“动态占多少百分比”的通用数字。

<a id="activity"></a>
### 1.2 α 必须先说定义；功率下降不一定意味着任务能量同比下降

本章公式中的 α 计**每周期 0→1 次数**。若工具报告两种方向都计入的 toggle rate，不能直接代入而忽略定义差异；在长期稳态、上下跳变次数近似相等时，充电事件约为总跳变的一半。

对每周期独立的随机位，P(1)=p 时，`P(0→1)=(1−p)p`；p=0.5 得 α=0.25。若统计两个方向则是 0.5。周期时钟每周期一次上升一次下降，按本章定义 α=1。若组合节点一个周期内产生多个毛刺，总活动还可能超过只看周期边界得到的结果。

计算例：α=0.12、C=20 pF、V=0.8 V、f=500 MHz：

```text
P = 0.12 × 20×10^−12 × 0.8² × 500×10^6
  = 0.000768 W = 0.768 mW
```

在相同 α、C 假设下，将电压降到 0.7 V、频率降到 300 MHz，开关功率比为：

```text
Pnew/Pold = (0.7/0.8)² × (300/500) = 0.459375
```

但固定 N 个周期的计算时间为 N/f，所以 `Eswitching=P×T=αCV²N`。如果完成同一任务的周期数与活动不变，动态能量比为 `(0.7/0.8)²=0.765625`，不是 0.459375。执行时间更长还会累积更多漏电能量；系统总能量要包括存储、外设、电源转换损耗和切换开销。

**功率是每秒消耗，能量是完成任务的累计消耗。** 电池关注能量，热设计和供电峰值还关注功率；平均功耗低不表示瞬时电流或 IR drop 一定安全。

<a id="measurement"></a>
### 1.3 活动统计、VCD/SAIF 和功耗报告分别能说明什么

RTL 可以用 VCD 记录值变化；SAIF 常用于保存信号驻留时间与翻转统计。把代表性活动映射到门级网表，再结合 Liberty 的功耗模型、时序和布线电容，才可能得到有物理依据的估计。布局布线后的寄生参数与门级延迟还会改变毛刺和时钟网络负载。

合理的分析路径是：

```text
明确工作负载与测量窗口
 → 记录 RTL/门级活动
 → 检查活动映射覆盖与默认活动假设
 → 结合库、PVT、电压、时钟与寄生进行功耗分析
 → 分解 clock / register / combinational / memory / leakage
 → 修改并在同一假设下比较
```

比较前至少核对：

- 是否完成相同数量的有效工作，而不只是仿真相同时长。
- reset、初始化、空闲比例是否纳入同一窗口；短时间高活动是否被平均值掩盖。
- 未匹配的 net 是否使用了默认活动，时钟和复位是否被错误地当作普通随机信号。
- RTL 零延迟波形是否遗漏了内部毛刺，是否包含时钟树与 SRAM 的内部功耗。
- 工艺角、温度、供电与负载是否一致。

本章 Activity 实验只在输入稳定后采样**乘积输出总线的位变化**，不计算内部毛刺，也不给每个位分配电容。因此它能证明特定场景下该观察点活动减少，不能直接宣称真实芯片功耗降低相同比例。

<a id="clock-gating"></a>
## 2. 门控时钟与 RTL 降低翻转

<a id="icg"></a>
### 2.1 `if(en)`、ICG 与自动插入不是一回事

常见 RTL：

```verilog
always @(posedge clk or negedge rst_n)
    if (!rst_n) q <= 0;
    else if (en) q <= d;
```

它表达寄存器使能（clock enable）语义，不保证物理时钟已经被关掉。实现可能是 D 端反馈 mux、带使能触发器，也可能在启用相应优化后被转换为 ICG 加普通触发器。若仍是 D 端 mux，q 可以不翻转，但触发器时钟引脚和相关时钟网络继续活动。

集成门控单元 ICG（integrated clock gating）在时钟安全相位锁存使能，再控制时钟输出。不能用 `gclk=clk & en` 随意替代：若 en 在 clk 高电平变化，可能制造窄脉冲或截断时钟。第 05 章已有毛刺波形与 latch/下降沿采样比较，本章重点是门控变换与功耗含义，参见 [Clock_Gating 范例](../05_Clock_Reset_Design/lab/Clock_Gating/)。

本实验用 Yosys 进行真实的结构变换：

```text
read_verilog enable_bank.v
hierarchy -top enable_bank
proc; opt
clockgate -pos icg_model EN:CLK:GCLK -min_net_size 1
select -assert-count 1 t:icg_model
```

输出网表保存为 `lab/Activity/build/enable_bank_gated.v`，TB 同时驱动原 RTL 与自动转换后的网表比较结果；**没有手工写一个 gated 版本代替工具变换**。本机 `yosys help clockgate` 确认该命令把相同 clock/enable 的 FF 组合转换为门控单元和无使能 FF；选项可核对 [Yosys clockgate 文档](https://yosyshq.readthedocs.io/projects/yosys/en/0.47/cmd/clockgate.html)。

[icg_model.v](lab/Activity/icg_model.v) 只是“低电平透明 latch + AND”的数字仿真模型，其 latch 有意保留并局部解释 lint 豁免。没有工艺库延迟、功耗、clock-gating setup/hold 或 scan 引脚。真实 ASIC 应用目标库 ICG、测试使能、门控检查和 CTS；FPGA 应优先使用器件支持的时钟使能/专用时钟资源，不把普通 LUT 当 ASIC ICG。

门控收益可粗略理解为：

```text
收益 ≈ 被关闭时钟子树的活动功耗 − ICG 与新增使能逻辑开销
```

门控点以上的时钟树仍翻转，门控单元自身也有代价。粒度太小可能不划算；粒度太大可能因为不同寄存器需要更新而难以关闭。还要检查 gated reset、scan/test、跨门控域握手和唤醒路径；不能把必须负责唤醒自己的控制器时钟也一并关掉。

<a id="operand"></a>
### 2.2 寄存器不更新，前面的乘法器仍可能翻转

[operand_isolation.v](lab/Activity/operand_isolation.v) 对比两个功能相同的采样通路：

```text
a,b ──────────→ 乘法器 ──→ valid 时更新 q_raw
 │
 └→ valid?输入:0 → 乘法器 ──→ valid 时更新 q_isolated
```

两边都只在 valid 为 1 时更新输出。第一条路径中，无效周期即使寄存器保持，a、b 的变化仍传入组合乘法器。第二条路径将无效输入钳成 0，减少无用计算：

```verilog
wire [W-1:0] a_iso = valid ? a : {W{1'b0}};
wire [W-1:0] b_iso = valid ? b : {W{1'b0}};
assign isolated_product = a_iso * b_iso;
```

这叫操作数隔离（operand isolation），它减少的是组合逻辑的活动，与关寄存器时钟互补。成立的前提是：无效周期的组合结果不可被外部当作有效结果观察；否则把原结果改成 0 就改变了功能。输入隔离 mux 也增加面积、负载和数据路径延迟，并且 valid 的切换可能引入新的活动。

本实验固定每 64 周期前 16 周期有效，输入每周期都按固定种子 xorshift 改变。每个位宽运行 1,024 周期，使用独立期望寄存值检查两个输出的更新/保持行为，再统计稳定乘积位变化。没有用“两个错误实现彼此相同”代替参考值检查。

<a id="activity-lab"></a>
### 2.3 Activity 实验的实际结果

运行 [lab/Activity/run_sim.sh](lab/Activity/run_sim.sh)，输出：

```text
PASS activity W=4 cycles=1024 active=256 raw_bit_changes=3436 isolated_bit_changes=874
PASS activity W=8 cycles=1024 active=256 raw_bit_changes=7594 isolated_bit_changes=1928
PASS activity W=16 cycles=1024 active=256 raw_bit_changes=15895 isolated_bit_changes=4114
PASS clockgate mapped_equivalence cycles=128 enabled=32 async_reset=1
```

共 3,072 个操作数隔离周期检查，另有 128 个自动门控网表对比周期。以 W=8 为例，观察点位变化从 7,594 减到 1,928；这个比例接近有效占空比，但进入/离开空闲段也会翻转，因此不要求严格等于 25%。数字表示**两个方向都计入的采样位变化数**，不是公式中 α，也不是功耗的 mW。

门控实验使用同步变化的 en，128 个比较周期中 32 个使能周期，并在门控关闭时异步复位，确认两份寄存器都清零。该实验不单独证明所有 enable 波形下的门控时序安全，不包含真实 ICG 的 timing check。

查看：

```bash
cd lab/Activity
gtkwave build/activity.vcd
gtkwave build/clockgate.vcd
```

activity.vcd 是脚本最后运行的 W=16 波形：看 valid=0 时 raw_product 继续改变、isolated_product 变成 0，而 q_raw/q_isolated 均保持。clockgate.vcd 中展开 mapped 的 ICG 实例，检查高相位使能保持及被过滤的时钟周期。各位宽日志独立保存，但同名 VCD 会被下一次运行覆盖。

<a id="multi-voltage"></a>
## 3. 多阈值与多电压

<a id="threshold"></a>
### 3.1 Vt 是晶体管阈值，VDD 是供电电压

多阈值（multi-Vt）利用同一逻辑功能的不同阈值单元，在速度与漏电之间取舍。通常 LVT 速度更高、漏电更多；HVT 漏电更少、速度更慢；SVT 位于其间。具体名称与可用组合由工艺库决定，不能只凭文件名猜测。可参考 [Synopsys：Foundation IP for Low Power](https://www.synopsys.com/articles/using-foundation-ip.html)。

直觉上，亚阈值漏电对 Vt 很敏感，提高阈值能减少关断电流；但相同 VDD 下有效驱动裕量降低，延迟通常增加。一个仅用于解释方向的近似为 `delay ∝ VDD/(VDD−Vt)^γ`，不是可用于签核的工艺模型。低电压、温度反转等场景更应以库和 STA 为准。

常见优化策略是先满足时序，再把有余量的单元换为更低漏电版本；关键路径保留必要的快速单元。但不能只看一条 setup 路径：

- 替换后要重新检查所有相关模式/工艺角的 setup、hold、slew 和负载。
- 单元电容和路径延迟改变，动态功耗、邻接路径和时钟树也可能受到影响。
- 多 Vt 优化是库映射/物理优化问题，普通 RTL 的 `if` 不会直接指定晶体管阈值。

多电压（multi-voltage）则让不同电源域使用不同 VDD。降低 VDD 可以降低 CV² 项，但也降低性能、影响存储器可工作范围与噪声裕量，产生跨域接口和电源布线成本。**多 Vt 不等于多电压；多电压也不意味着所有域都能关断。**

<a id="level-shifter"></a>
### 3.2 电平转换、隔离和 CDC 各解决一个问题

低压域的逻辑 1 可能达不到高压接收端的 VIH，直接连接会造成识别错误或额外静态电流；高压信号驱动低压域也可能超出接收器耐压或输入规格。电平转换器（level shifter，LS）负责合法电压摆幅转换。高到低是否需要专用单元，也必须看接口耐压和库规则，不能一概省略。

隔离单元（isolation cell）则在源域失去有效供电或数据不可信时，将输出钳到安全值。LS 与 isolation 可以分开，也可能由组合单元实现，但概念并不相同：

```text
可关断域逻辑 → 隔离/电平转换边界 → 常供电接收域
                    ↑
               常供电控制与供电
```

如果两个域时钟还不同，还需 CDC 同步/异步握手。LS 不会消除亚稳态，双触发器同步也不会修复不合法电压。电源状态变化还会影响 CDC/RDC 分析：某同步器一级掉电、另一级仍工作时，普通时钟关系检查并不足够。相关方法见 [Synopsys Power-Aware CDC](https://www.synopsys.com/content/dam/synopsys/verification/white-papers/vc-spyglass-power-aware-whitepaper.pdf)。

隔离钳位必须满足协议语义。例如数据总线钳 0 不代表事务无效；valid 若错误保持为 1，接收端可能把一串 0 当作合法响应。active-low 请求/中断可能应钳 1。还要考虑 ready、返回信用、双向接口和复位信号，而不是只看 payload。

LS 的供电组合、放置位置、转换方向、边界延迟和隔离供电都需要在电源意图与物理实现中落实。低压域与高压域的时序分析必须使用相应电压表征的库，不能沿用单电压下的一份延迟数字。本章没有可用于多 Vt/多电压签核的库映射实验，因此不提供虚构的面积、漏电或频率收益。

<a id="power-gating"></a>
## 4. 电源关断、保持与 UPF

<a id="power-island"></a>
### 4.1 关掉电源岛会失去状态，唤醒也有代价

电源门控（power gating）通过 header/footer 等开关结构切断某区域的有效供电，主要降低长时间空闲时的漏电。它引入虚拟电源轨、开关导通电阻、压降、面积和上电浪涌，不能用一个 Verilog 与门模拟其物理效果。

常供电域 AON（always-on）保存电源管理控制、唤醒源和必要的保持状态。保持寄存器（retention register）通常依靠仍然有效的保持电源保存指定状态；普通寄存器掉电后不能保证保留值。保持的不是“整个模块自动复原”：需要确定哪些状态必须保存，哪些可复位重建，哪些外部事务必须在关断前完成。

一个简化的空闲收益条件：

```text
净节能 = (Pidle_on − Psleep) × Tidle − Etransition
Tbreak_even = Etransition / (Pidle_on − Psleep)
```

假设空闲但供电的功率 5 mW、睡眠保持功率 0.2 mW、一次睡眠/唤醒总能量 2 µJ，则盈亏平衡空闲时间约为 416.667 µs。只有更长的空闲才可能净节能，还必须满足唤醒 deadline。若能量模型已把转换期间的耗能计入 Etransition，就不要再次重复加同一段能量。

这说明频繁进入很短的深睡可能得不偿失。实际策略还要考虑空闲时长预测、滞回、最短驻留时间、功率峰值、缓存/存储恢复以及性能损失。

<a id="sequence"></a>
### 4.2 安全关断与唤醒是一个握手协议

本实验选择的顺序是：

```text
运行 ON
 → DRAIN：阻止新事务，等待已有事务排空
 → SAVE：保持工作时钟，发出 save_req，等待 save_ack
 → ISOLATE：打开隔离，供电与时钟仍在
 → STOP：保持隔离，停工作时钟
 → OFF：切断电源，继续保持隔离

唤醒：
OFF → RAMP：打开电源，保持隔离、停工作时钟，等待 power_good
    → RESTORE：开启恢复所需时钟，restore_req / restore_ack
    → INIT：等待未保持状态初始化完成 init_done
    → ON：解除隔离与 quiesce，允许新事务
```

这里的保存/恢复握手是假设的外部接口，不是所有 retention cell 都有 ack 引脚。真实设计需要按照单元 save/restore 脉冲、电源时序、时钟和 reset 要求，把控制协议落实成具体波形。有的方案不需要工作时钟即可恢复，也有的方案需要额外步骤；不要把本例状态顺序直接当作任意工艺的电源规范。

重要约束是：数据在供电变得不可信之前已经隔离；电源切断前状态已保存、时钟已安全停止；供电稳定并完成必要恢复/初始化后才向外宣布 active。唤醒条件必须位于 AON 域，否则“断电模块等待自己产生唤醒”会形成死锁。

对于保持寄存器与复位，不能简单在恢复后对整个域打一遍 reset，否则刚恢复的状态可能被覆盖。生产设计通常分别处理保持与非保持状态，并验证 reset 与 save/restore 的优先级及恢复顺序。

<a id="sequence-lab"></a>
### 4.3 AON 控制器与掉电污染模型

[power_seq.v](lab/Power_Sequence/power_seq.v) 是可综合 AON 状态机。状态对应上述顺序，控制输出均寄存，避免直接用多位状态译码驱动电源/隔离控制。`clk_en` 是送给安全时钟门控结构的使能，不是已经生成的门控时钟；`power_en` 是电源开关控制请求，不是实际电压。

所有请求/ack 都假定已同步到 AON clk。`sleep_req` 是电平请求：ON 时检测进入睡眠；OFF 时为低则唤醒。已经开始的关断序列不被中途撤销的 sleep_req 打断，而是先到 OFF，再响应当前唤醒请求。这样减少中途取消的状态组合，但也可能增加短暂请求的延迟。

协议条件必须区分：

- `idle_ack` 表示可安全保存且没有未完成事务，不只是“当前没有新的 valid”。
- `save_ack` 表示保持副本已捕获，不能只用 save_req 同周期替代。
- `power_good` 表示满足系统定义的供电稳定条件，实际需包含同步/去抖等处理。
- `restore_ack` 与 `init_done` 分别表示保持状态恢复和其余初始化完成。

[tb_power_seq.sv](lab/Power_Sequence/tb_power_seq.sv) 用一个 16 位状态模拟电源岛：运行时递增；保存到 AON shadow；掉电事件主动把岛内状态污染成 X；恢复时从 shadow 取回。隔离后的 observed 值必须为 0，恢复运行后应与累计工作量一致。**这个模型有意使用 X，属于测试平台，不是可综合 retention 单元，更不是 UPF 自动插入模型。**

实际结果：

```text
PASS power sequence cycles_checked=275 sleeps=6 saves=6 restores=7 retained=88
PASS power sequence reset_abort=1
```

六次睡眠使用 1 到 6 周期的应答延迟，检查 275 个时钟采样点；7 次 restore 包括初始上电从初始化的 shadow 恢复一次。测试还在 SAVE 等待阶段异步复位，确认输出回到隔离、停钟、关电的初始状态。复位导致丢弃尚未完成的保存，这是本教学模型的冷复位契约，不是无损休眠。

观察 `lab/Power_Sequence/build/power_seq.vcd` 中的 state_out、iso_en、clk_en、power_en、domain_q、shadow 和 observed。OFF 时 domain_q 为 X、observed 为 0；如果 observed 也变 X，说明隔离没有保护接收端。恢复到 ON 前后对照 shadow 与 expected，而不只看 active 最终是否变 1。

**范围限制：**状态机没有 ack 超时、brownout 紧急处理、power_good 中途跌落的故障恢复，也没有模拟真实工作时钟的停止/启动过程。若某 ack 永远不到，设计会停在对应状态；实际产品应定义超时、错误上报与回退策略。TB 有全局超时，避免回归无限挂起，这不等于 RTL 已实现故障处理。

<a id="upf"></a>
### 4.4 UPF 描述电源意图，不代替功能 RTL 或电源控制协议

UPF（Unified Power Format，统一功耗格式，IEEE 1801）使用 Tcl 风格命令描述电源域、供电网络、电源开关、隔离/保持/电平转换策略以及允许的电源状态。功能 RTL 说明“算什么”，电源意图说明“在什么供电关系下，如何保护与保存”；控制器负责“什么时候发这些控制信号”。三者需要一致。

可以按以下对象理解，而不是背一串命令：

1. **层次范围与电源域**：哪些实例属于可关断域，哪些属于 AON。漏写/写错路径会让策略作用在错误对象上。
2. **供电端口、网络与供电集合**：哪些是主电源、地、保持和隔离电源；谁驱动谁，是否仍然有效。
3. **电源开关**：输入真实电源、输出虚拟电源、控制及开关状态条件。
4. **隔离/保持/LS 策略**：作用方向与范围、钳位值、位置、控制极性和所需供电。
5. **电源状态与合法组合**：运行、睡眠、不同电压 OPP，以及哪些组合/转换禁止。
6. **实现映射与验证**：策略映射到库单元，检查供电连接、控制可达性、边界时序及电源状态下的功能。

概念和策略分层可参考 [Accellera UPF 教程](https://accellera.org/images/resources/videos/Accellera-Next-Generation-Tutorial-2015.pdf) 与 [低功耗/UPF 教程](https://www.accellera.org/images/resources/videos/Low_Power_with_UPF_2013.pdf)。不同 UPF 版本和工具支持范围并不相同，项目中需要固定版本、工具和检查规则。

[intent_example.upf](lab/Power_Sequence/intent_example.upf) 给出一个**未绑定实际层次和工艺库的教学模板**：假想 TOP 包含 u_sw，TOP 常供电，u_sw 可关断；所有输出钳 0，示例状态寄存器保持。关键片段：

```tcl
create_power_domain PD_TOP -include_scope
create_power_domain PD_SW -elements {u_sw}
set_domain_supply_net PD_SW \
    -primary_power_net VDD_SW -primary_ground_net VSS
set_isolation ISO_SW -domain PD_SW -applies_to outputs \
    -clamp_value 0 -isolation_power_net VDD -isolation_ground_net VSS
set_isolation_control ISO_SW -domain PD_SW \
    -isolation_signal iso_en -isolation_sense high -location parent
```

完整文件还列出 switch、retention 和 RUN/SLEEP 电源状态。`u_sw/state_reg`、控制信号路径、所有输出是否都可钳 0、保持元素是否匹配、供电网络跨域可见性及库单元映射，都必须在真实设计中重新绑定和核对。它不是本章 TB 的可加载 power-aware 配置，没有假装仿真器已把电源策略注入设计。

本机现有 OpenROAD 构建查询 `help *upf*` 返回没有匹配命令；本实验因此只使用 Yosys 内置 Tcl 解释器核对模板可解析性。[check_upf_tcl.tcl](lab/Power_Sequence/check_upf_tcl.tcl) 显式将所用命令注册为记录器，运行模板并核对 23 条调用：

```text
PASS Tcl parse only: 23 commands; UPF semantics NOT checked
```

这可以发现 Tcl 括号/续行等解析问题，**不能**证明 UPF 选项合法、层次存在、供电网络连通或隔离正确；记录器不实现任何 UPF 语义。真实接入时仍需支持目标版本的工具完成 load/elaborate、静态低功耗规则检查、电源感知仿真、保持/隔离单元映射与多状态签核。普通 Icarus/Yosys 数字回归无法替代这些步骤。

<a id="dvfs"></a>
## 5. DVFS

<a id="opp"></a>
### 5.1 先确定合法 OPP，再控制切换

DVFS（dynamic voltage and frequency scaling，动态电压频率调节）把工作点从一个电压/频率组合切到另一个。OPP（operating performance point）是经过约束确认的工作点，而不是软件随意拼接的两个数。系统软件通常用 OPP 表组织频率与电压关系，参见 [Linux OPP 文档](https://cdn.kernel.org/doc/html/latest/power/opp.html)。

降低 VDD 会影响路径延迟，因此合法频率受约束：

```text
Tclk >= Tcq + Tcomb(VDD,PVT) + Tsetup + uncertainty
```

还需考虑 hold、clock-gating、存储器最小工作电压、PLL/时钟切换、IR drop 和瞬态电流。满足一张典型工艺角表，不等于满足全部电源状态与温度条件。

在低/高两档均已签核、较高频率需要较高电压的假设下：

```text
升档：先请求高电压 → 等电压稳定 → 再请求高频率 → 等时钟切换完成
降档：先请求低频率 → 等时钟切换完成 → 再请求低电压 → 等电压稳定
```

原因不是某个固定软件习惯，而是必须避免 `高频率 + 尚未达到要求的低电压` 这一危险中间状态。PLL lock、regulator ready 都需要真实的完成条件，不能用“命令已经发出”代替“物理状态已经稳定”。

功率与能量取舍见第 1 节。对有 deadline 的任务，可以在满足时限时降档；也可能先高性能完成再进入深睡更省总能量，称为 race-to-idle 的思路。选择取决于负载、静态功耗、存储瓶颈、转换代价和休眠机会，不能仅从 CV²f 得出“越慢一定越省电”。实际策略还常用滞回避免频繁升降档。

<a id="dvfs-lab"></a>
### 5.2 两档 DVFS 控制器：检查实际状态，而不是只看请求

[dvfs_seq.v](lab/DVFS/dvfs_seq.v) 实现上述顺序。输入请求在 `req_valid && req_ready` 接收，target_high 锁定本次方向；busy 时新请求不能被接收，源端若持续提交须保持 valid/负载直到 ready。`done` 是完成脉冲，`current_high` 只在整个切换完成后更新，不代表转换过程中每一个物理节点已经同时处于该档。

电源与时钟输出是目标请求位 `voltage_req_high/frequency_req_high`；反馈由实际档位 `voltage_high/frequency_high` 与稳定标志共同决定。升频前既要确认 voltage_settled，也要确认 voltage_high 为 1，防止“旧低压档的 settled=1”被误当作升压完成。

本模块有五个状态：

```text
IDLE → UP_V → UP_F → IDLE
IDLE → DOWN_F → DOWN_V → IDLE
```

同档请求直接产生 done，不触发转换。复位假设平台已进入安全低档，本模块不是负责把任意运行中的硬件强制复位到低档的模拟控制器；生产系统需要协调频率与电源复位顺序。

[tb_dvfs.sv](lab/DVFS/tb_dvfs.sv) 用延迟模型更新实际电压/频率档位，并在每拍检查：

- 不允许实际 high frequency 与 low voltage 同时存在。
- 请求高频前电压必须已高且稳定。
- 请求低压前实际频率必须已低。
- done 时反馈必须与 current_high 一致。

实际运行：

```text
PASS DVFS transactions=33 safety_checks=274 up=8 down=8 same_opp=17
```

共 8 次升档、8 次降档、17 次同档请求；不同轮次使用 1–8 的延迟参数，模型在计数结束后更新实际反馈。TB 在请求接收后改变无效总线输入，检查转换方向不受影响。

波形 `lab/DVFS/build/dvfs.vcd` 中先比较 req_high 与 actual_high，再看 done。升档必须先看到 voltage_high 变为 1、稳定后才有 frequency_req_high=1；降档则先看到 frequency_high=0 才允许 voltage_req_high=0。

**本实验没有真的改变供电电压或工作时钟频率。** 模型里的高/低位只表示两档离散状态，不模拟电压爬坡、PLL 波形、无毛刺时钟切换、停钟握手或瞬态时序。控制器也未实现错误超时、升档失败回退或多档策略；异步反馈在进入模块前必须完成 CDC。这些边界明确后，数字实验才不会被误解为模拟电源验证。

<a id="regression"></a>
## 6. 整章运行、验证边界与速查

### 6.1 一键运行与文件

PowerShell：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/09_Low_Power_Design/lab' && bash run_all.sh"
```

脚本使用 `/root/oss-cad-suite/environment`，在 WSL 运行 Icarus、Verilator、Yosys 和 Python；不运行 Windows EDA 工具。入口 [lab/run_all.sh](lab/run_all.sh) 依次运行三组实验、[数值功耗模型](lab/Activity/power_budget.py)、Tcl 模板解析和 [变异测试](lab/check_mutations.py)。工具版本写入 `lab/build/versions.log`，仿真、网表和 VCD 写入各 build 目录，构建产物已由仓库忽略规则排除。

本次计算输出：

```text
MODEL switching=0.768 mW; DVFS power_ratio=0.459375
MODEL fixed_cycles dynamic_energy_ratio=0.765625
MODEL poweroff_break_even=416.667 us (excluding wake deadline)
```

六个变异分别破坏 OFF 隔离、跳过保存、跳过恢复、提前升频、提前降压和移除操作数隔离。每个必须编译成功，再被明确的数值/协议检查拒绝；编译错误、超时或任意非零退出不算检出：

```text
PASS mutation caught: isolation_missing
PASS mutation caught: save_skipped
PASS mutation caught: restore_skipped
PASS mutation caught: frequency_too_early
PASS mutation caught: voltage_too_early
PASS mutation caught: operand_isolation_removed
PASS low-power mutations: 6/6
PASS Chapter 09 digital labs; UPF checked for Tcl parsing only
```

### 6.2 已验证与尚未验证的内容

已验证的是所列位宽/测试场景下的功能保持、观察点活动下降、自动门控网表对比、带 X 污染的关断/恢复协议和两档 DVFS 顺序。可综合模块通过 lint 和 Yosys 检查；唯一有意的 latch 位于 ICG 数字模型。

没有验证的内容包括：全输入/全调度形式证明；真实功耗、毛刺功耗、工艺级 ICG 时序、scan 模式；多 Vt/LS/retention 单元映射；完整 UPF 语义与 power-aware 仿真；IR/EM、浪涌、电源爬坡、PLL 切换、故障恢复和多电源状态的物理签核。本章完成表示总纲中的教学范围已覆盖，不能将教学 PASS 当作芯片 signoff。

### 6.3 面试速查

- **减少 α**：门控时钟、操作数隔离、减少毛刺与无效计算；不能自动消除漏电。
- **减少 C**：更合适的单元/扇出/布线/架构；要重新检查时序与驱动能力。
- **减少 VDD**：动态功耗平方下降，但必须满足性能、库和电源条件。
- **提高 Vt**：通常减少漏电、牺牲速度；与改变 VDD 是两种手段。
- **关断电源**：要付出状态保存、隔离、恢复、开关与唤醒成本，先算空闲盈亏平衡。
- **LS、隔离、CDC**：分别处理电平兼容、掉电数据安全、时钟跨域，互相不能替代。
- **UPF 与控制 FSM**：前者描述电源意图，后者安排动态顺序，还需要工具落实与验证。
- **DVFS**：升档先压后频，降档先频后压；等待实际完成，不只等待命令发出。
- **报告证据**：活动变化不等于 mW，功率比不等于任务能量比，Tcl 可解析不等于 UPF 正确。
