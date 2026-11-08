# 第 10 章：可测性设计（DFT）—— 让内部故障能被激励、观察和定位

- 假设你已经写好并验证了一个计数器，送去制造后，怎样判断某一颗实物芯片内部有没有坏掉的连线或存储位？芯片外部能接触的引脚很少，内部寄存器却可能很多，光从正常输入等待一个错误出现，测试会很困难。本章介绍的 DFT，就是在设计时为这些内部状态留下方便测试的访问方式。

- 我们先用一个小逻辑门理解“怎样让故障显现”，再把内部寄存器串成扫描链；随后分别学习存储器怎样自测、芯片引脚怎样参与边界扫描。第一次阅读时先跟着数据走一遍，覆盖率、测试时间和时序代价再逐步补上。

- 本章覆盖总纲四个小节，配套三个 WSL 实验：[Scan_ATPG](lab/Scan_ATPG/)、[MBIST](lab/MBIST/)、[JTAG](lab/JTAG/)。它们用教学 RTL 和测试平台演示原理，包含故障注入和自动检查。实验范围是小规模数字模型；工业 ATPG、真实 SRAM 测试及完整 IEEE 1149.1 合规验证需要更多工具和条件，各节末尾会说明差别。

- **前置知识**：[第 02 章 RTL](../02_HDL_Verilog_SystemVerilog/README.md)、[第 05 章时钟/复位](../05_Clock_Reset_Design/README.md)、[第 07 章 STA](../07_STA/README.md)、[第 08 章综合](../08_Logic_Synthesis/README.md)、[第 09 章低功耗](../09_Low_Power_Design/README.md)。建议先手算故障条件，再跑扫描实验；随后理解同步 RAM 读延迟，最后跟踪 TAP 波形。[INTERVIEW_QA.md](INTERVIEW_QA.md) 提供 40 道面试题。

## 目录

1. [故障模型与覆盖率](#faults)
   - [1.1 制造缺陷、逻辑故障与功能验证](#fault-purpose)
   - [1.2 Stuck-at 的激活与传播](#stuck-at)
   - [1.3 转换故障与双向量测试](#transition)
   - [1.4 穷举故障模拟与覆盖率分母](#coverage)
2. [扫描与 ATPG](#scan-atpg)
   - [2.1 扫描触发器与 load/capture/unload](#scan-principle)
   - [2.2 测试时间与 ATPG 流程](#atpg-flow)
   - [2.3 扫描对时序、时钟和功耗的影响](#scan-timing)
   - [2.4 RTL 实验与波形](#scan-lab)
3. [MBIST 与 March 算法](#mbist)
   - [3.1 为什么存储器需要专门测试](#memory-faults)
   - [3.2 March C− 的顺序与复杂度](#march)
   - [3.3 同步读接口与诊断状态](#mbist-rtl)
   - [3.4 注入故障与实际输出](#mbist-lab)
4. [JTAG 与边界扫描](#jtag)
   - [4.1 TAP 引脚与 16 状态机](#tap)
   - [4.2 IR、DR、BYPASS 与边界寄存器](#boundary)
   - [4.3 教学 RTL 与边沿约定](#tap-rtl)
   - [4.4 状态、指令和边界功能验证](#tap-lab)
5. [整章运行与面试速查](#regression)

<a id="faults"></a>
## 1. 故障模型与覆盖率

<a id="fault-purpose"></a>
### 1.1 验证“设计正确”与测试“芯片制造正确”是两件事

- 功能验证针对设计规范：相同输入下，RTL 是否产生要求的行为。制造测试针对实际器件：晶圆制造、封装等过程中产生的缺陷，是否让这颗芯片偏离正确实现。正确的 RTL 并不意味着每颗制成的芯片都正确。

- 物理缺陷可能是开路、短路、电阻异常或晶体管参数偏移；直接枚举全部物理缺陷代价很大，因此测试使用抽象故障模型（fault model），例如某根线固定为 0、一次转换过慢。**缺陷不是故障模型本身，检测到模型中的全部故障也不等于覆盖全部物理缺陷。**

- DFT（design for testability，可测性设计）通过增加可控性（controllability）和可观察性（observability）降低测试难度：

  - **可控性**：能否把内部某点设成想要的值。例如寄存器平常要计数很久才到目标状态，测试时若能直接装入该状态，就更容易控制。
  - **可观察性**：内部出错后，能否在外部读出差别。若能直接读回寄存器，就更容易观察。
  - **扫描链的作用**：增加一条内部状态访问通路，把上面两个动作都变得容易。

```text
外部输入 → 很长的时序序列 → 才能到达某内部状态
                          ↓ 加 scan / test point
              能直接设置并读出关键内部状态
```

- 扫描、MBIST、边界扫描分别处理不同问题：扫描让内部逻辑状态容易访问；MBIST 面向存储阵列；边界扫描侧重芯片 I/O 与板级互连。它们经常协同使用，但不能相互替代。

<a id="stuck-at"></a>
### 1.2 单固定型故障：激活，再传播到可观察点

- 固定型故障（stuck-at fault）将某个故障点强制为 0（SA0）或 1（SA1），不受其正常驱动逻辑影响。常见单故障模型假定一次只存在一个故障；同时出现多个缺陷可能互相掩蔽，不属于单故障覆盖结论。

- **激活故障**：检测 SA0 时，让好电路在故障点取 1；检测 SA1 时，让好电路取 0。这样好、坏电路才有差异。
- **传播差异**：让差异到达输出或可捕获寄存器。经过 AND 时，其余输入通常设为 1；经过 OR 时设为 0，避免差异被遮住。
- **复杂电路的限制**：重汇聚和输入约束可能使旁路输入无法独立设置，需要一起求解。

- 先用 y=a AND b 想一遍：怀疑 a 固定为 0，就把正常输入设为 a=1。若同时 b=0，好电路和坏电路的 y 都是 0，仍然看不出故障；把 b 设为 1，好电路 y=1，坏电路 y=0，才有可检测的差异。前一步叫激活，后一步叫传播。

- 重汇聚则是某信号分成几条支路后又在后面相遇，支路之间有关联，因此复杂电路不能总像这个例子一样独立设值。

- 本实验使用一个刻意保留冗余支路的小网络：

```text
p = a & b
q = ~a & c
dead = a & ~a
y = p | q | dead
```

- 无故障时 dead 永远为 0，整体相当于 `a ? b : c`。手算：

  - p/SA0：设 a=1、b=1，使 p=1；此时 q=0、dead=0，差异能到 y。c 可以任意。
  - q/SA0：设 a=0、c=1，使 q=1，同时 p=0；b 可以任意。
  - p/SA1：让 p=0 且 q=0，例如 abc=000，好电路 y=0，故障电路 y=1。
  - dead/SA0：好电路该点本来恒为 0，任何输入都无法激活差异，因此不可检测。

- 故障点还要明确是扇出源干线（stem）还是某条分支（branch）。对 a 的 stem 注入会影响它所有使用点；只对某条分支注入是不同的故障集合。本实验列出七个点 `a,b,c,p,q,dead,y`，每点 SA0/SA1，共 14 个，未额外枚举所有分支。

- 该故障集合属于**手工定义的教学网络**。真实综合可能把 dead 删除，故障折叠也会合并等价故障；不能把这里的 14 个点当作综合后网表的故障数。

- 故障折叠是减少重复分析：有些故障在所有测试下表现相同，可以用一个代表来分析，而不必逐个重复搜索。因此报告中的“故障数”还要问清楚是折叠前还是折叠后；这不表示芯片里的物理缺陷被工具消除了。

<a id="transition"></a>
### 1.3 转换故障需要“旧值、转换、及时捕获”

- 转换故障（transition fault）把某节点的 0→1 或 1→0 转换视为过慢，分别称 slow-to-rise、slow-to-fall。逻辑上的 stuck-at 测试只要求某稳态值可区分；转换测试还要在限定时间内观察到新值。

- 可以把它理解成“最终能变对，但没有及时变对”。例如正常节点应在采样前从 0 变成 1，故障节点却在采样之后才变成 1；如果等很久才检查，两边都已经是 1，就会漏掉问题。因此这类测试既要安排前后两个值，还要安排什么时候看结果。

- 双向量思路：

```text
V1 初始化：故障点先为 0
V2 发起：  正常电路应转为 1
捕获：     在目标时间窗口采样，过慢故障可能仍表现为 0
```

- 下降故障对应 1→0。只有 V2、没有受控的 V1，不足以保证真的激活了目标转换。节点转换故障与路径延迟故障也不同：前者针对某故障点的慢转换，后者针对选定路径的总延迟。

- 扫描中的常见发起方式：

  - Launch-on-capture（LOC，也常称 broadside）：装入扫描状态后切到功能模式，功能脉冲发起转换，下一捕获脉冲观察。
  - Launch-on-shift（LOS）：利用最后一个移位脉冲发起转换，再切换 scan enable，进行捕获；对 scan enable 的及时切换有额外要求。

- 移位阶段可以较慢，但 at-speed 测试的发起/捕获间隔必须对应目标要求，不能把低速扫描移位时钟当成已完成高速转换测试。工业 ATPG 还使用更丰富的故障与约束模型，可对照 [Synopsys TestMAX ATPG](https://www.synopsys.com/implementation-and-signoff/test-automation/testmax-atpg.html)。

- at-speed 可以理解为“按目标工作速度检查能否及时到达”。若要求两次功能采样间隔为 2 ns，测试也要在规定的发起/捕获窗口内检查；用 100 ns 慢慢移入状态，只是在准备输入。准备输入的速度与检验转换的速度，要分开看。

- 本实验 Python 仅对输出 y 的两向量组合做抽象分析：枚举 8×8=64 对输入，其中 16 对激活输出上升、16 对激活下降，并把“过慢时捕获旧值”作为逻辑模型。**没有门延迟、实际发起/捕获时钟或 SDF，所以这不是 at-speed RTL/门级转换故障测试。**

<a id="coverage"></a>
### 1.4 穷举故障模拟与覆盖率：先说分母

- 一组测试输入常叫测试向量（test pattern）。例如 abc=110，就是同时给三个输入指定一组值。ATPG 是 automatic test pattern generation，即自动测试向量生成，任务是替我们寻找这样的输入。

- 故障字典则像一张对应清单：每种故障可以被哪些输入发现。先有这张清单，才容易理解下面“选少量向量覆盖更多故障”的做法。

- [atpg.py](lab/Scan_ATPG/atpg.py) 对全部 8 个输入和 14 个单故障计算好/坏输出，生成故障字典，再贪心选择每次覆盖最多尚未覆盖故障的输入。该方法是小规模穷举加集合覆盖启发式，不是 PODEM、FAN、SAT ATPG 或工业顺序 ATPG。

- 这里的“贪心”只是一个选择办法：先挑当前能发现最多故障的向量，把这些故障从待覆盖清单划掉，再挑下一组。它容易实现，但不保证最后的向量数量最少。初学时先理解这个过程即可，后面列出的工业搜索算法名称不需要在本节展开。

- 实际输出：

```text
PASS exhaustive fault simulation: patterns=8 faults=14 detectable=13 undetectable=1
ATPG greedy patterns=010,110,001,100
COVERAGE raw=13/14=92.857143%; testable=13/13=100%
PASS output transition abstraction: pairs=64 slow_rise_detecting=16 slow_fall_detecting=16
NOTE transition abstraction has no physical delay or at-speed clock model
PASS fault RTL oracle vectors=120
```

- 四个选中向量覆盖全部 13 个可检测故障；脚本没有证明贪心集合一定最小。`fault_dictionary.txt` 逐故障列出检测输入，dead/SA0 对应空集合。

- 本章明确定义两种统计：

```text
raw coverage = detected / all modeled faults = 13/14
testable coverage = detected / proven detectable faults = 13/13
```

- 工业报告中 fault coverage、test coverage、ATPG effectiveness 等术语与分类细节可能不同，需核对工具定义。不能仅为了让数字变大，把所有未检测故障从分母删除：

  - **不可检测/冗余**需要证明，或符合明确的约束分类；本例已穷举全部输入，因此 dead/SA0 的结论成立。
  - **ATPG aborted**可能只是搜索资源耗尽，不是不可检测证明。
  - **未建模、被排除、受约束、X 掩蔽**应分别解释，不应混成同一类。
  - 故障折叠前后的分母不同，比较报告时必须一致。

- [fault_cone.v](lab/Scan_ATPG/fault_cone.v) 用显式 mux 注入同样的故障点，TB 比较 8 个无故障和 112 个带故障情形，共 120 个结果。注入 mux 是测试模型，不是生产 DFT 插入单元。注入函数把故障选择/使能/值显式作为参数传入，避免依赖隐藏外部变量的仿真敏感性。

<a id="scan-atpg"></a>
## 2. 扫描与 ATPG

<a id="scan-principle"></a>
### 2.1 扫描触发器把状态访问变成串行通路

- 扫描触发器可直观理解为 D 端带选择的触发器：

```text
functional_d ─┐
              mux(scan_en) → DFF → Q → 下一个扫描单元
scan_in ──────┘
```

- scan_en=0 时执行正常捕获，scan_en=1 时从串行链移入。全扫描设计使内部寄存器成为组合逻辑的伪输入/伪输出，显著降低“先跑很长功能序列才能设置内部状态”的难度。部分扫描则需保留更多时序搜索问题。

- “伪输入/伪输出”不表示额外增加了同样多的芯片引脚。它表示：测试时可以先通过串行链设置这些寄存器，把它们当作后面组合逻辑的输入；计算后又能读出捕获寄存器，把它们当作可观察的输出。串行移位比较慢，但换来了少量外部引脚访问大量内部状态的能力。

- 一次基本测试：

1. **Load/shift**：打开扫描，将目标状态装入寄存器。
2. **Capture**：退出扫描，施加规定的输入和捕获时钟，保存组合逻辑响应。
3. **Unload/shift**：再次扫描，将响应移出并与期望值比较。

- [scan_bank.v](lab/Scan_ATPG/scan_bank.v) 采用 q[0] 接近 scan_in、q[W−1] 接 scan_out，更新为：

```verilog
assign scan_out = q[W-1];
always @(posedge clk or negedge rst_n)
    if (!rst_n) q <= 0;
    else if (scan_en) q <= (q << 1) | {{(W-1){1'b0}}, scan_in};
    else q <= functional_d;
```

- 按本方向装入目标字要先发最高位，移出时也先观察最高位，并在移位上升沿**之前**采样当前 scan_out。例如 W=4 装入 1011，依次发送 1、0、1、1；最后 q=1011。若在已经移位后才采样，响应会错位一位。

- 若初始 q=0000，这四个移位沿之后依次得到 0001、0010、0101、1011。每次都是旧内容向高位移动一格，新 bit 从最低位进入。装好后切回功能模式，寄存器就能接收电路算出的响应；再切回扫描模式，把响应按同样的链逐位读出去。

- 扫描保持的是链内状态访问能力，并不自动解决 SRAM、黑盒、模拟块和不受控时钟造成的 X。未扫描寄存器、异步复位和测试模式约束仍然影响 ATPG。

<a id="atpg-flow"></a>
### 2.2 测试时间与工业 ATPG 流程

- 假设一条链有 1000 个触发器，每打一拍，所有数据只前进一格，因此装入一整份状态需要 1000 个移位周期。读出旧结果时链同样在移位，入口也可以同时送下一份测试数据；这就是下面“装入/移出重叠”能节省时间的原因。

- 若有 N 个扫描 FF、M 条近似等长链，最长链约为 `L=ceil(N/M)`。每个向量移位时间主要由 L 决定；增加链数会增加引脚/通道、布线和压缩结构需求。

- P 个向量、每次捕获 C 个周期，粗略估计：

```text
不重叠装入/移出：cycles ≈ P(2L+C)
用移出上一响应同时装入下一向量：cycles ≈ (P+1)L+PC
```

- 第二式包含最初装入与最后移出，忽略测试控制额外开销。例：L=1000、P=500、C=1、shift clock=10 MHz，若把捕获周期也用该频率粗算，重叠约 50.15 ms，不重叠约 100.05 ms。真实 at-speed 捕获有不同时间尺度，需分别计算。

- 用 P=2 理解为何是 P+1 次移位最直观：先用 L 拍装第一组；捕获后，用 L 拍一边读第一组响应、一边装第二组；第二次捕获后，再用 L 拍读最后响应。合计 3L+2C。推广到 P 组，中间 P−1 次都可重叠，再加开头和结尾，共 P+1 次完整移位。

- 一个实际 DFT/ATPG 流程通常包括：

```text
定义测试模式、时钟、复位与可控信号
 → DFT 规则检查
 → 扫描单元替换、链连接/重排
 → 检查链完整性和功能等价
 → 定义故障模型、约束、X 处理
 → ATPG 生成向量与故障模拟
 → 看未检测/中止/排除故障分类
 → 导出测试程序并做仿真、时序与 ATE 对接
```

- ATPG（automatic test pattern generation）负责寻找能激活并传播故障的激励；故障模拟（fault simulation）负责判断某组向量检测哪些故障。二者不是同一个动作。

- 本章用故障模拟结果指导贪心选择，但没有自动修改生产网表插 scan，也没有把小电路的向量接成真实扫描 ATPG 测试协议；扫描链与组合故障模型是两个独立教学实验。

- 大设计还可能使用扫描压缩：解压器把少量外部通道扩展成内部扫描数据，压缩器汇总响应，以降低数据量和测试时间。未知 X 会污染响应压缩，需要 X 约束/屏蔽等策略，不能把 X 随意当 0。逻辑 BIST 的伪随机激励和 MISR 签名也存在难测故障与别名。

- “m 位签名碰撞约 2^−m”依赖特定随机性假设，不是任何测试的绝对保证。相关工业工具功能见 [Siemens Tessent ScanPro](https://www.siemens.com/en-us/products/ic/tessent/test/scanpro/)。

- BIST 是 built-in self-test，即芯片自己产生测试并检查结果。MISR 是 multiple-input signature register（多输入签名寄存器），把多路、多拍响应压缩成较短的最终值，这个值叫签名。

- 压缩会丢掉部分信息，因此两份不同响应可能得到相同签名，这叫混叠或别名；签名相同不能无条件推出每个原始响应都相同。

<a id="scan-timing"></a>
### 2.3 Scan 对时序、时钟和功耗的影响

- 扫描 mux 可能增加功能 D 路径延迟与负载；扫描 FF 与普通 FF 的 setup/hold、面积、功耗也可能不同。功能模式和测试模式都要分析，不能只检查正常工作时钟。

- 移位路径通常很短，hold 是重要风险。若捕获时钟比发起时钟晚到 `Tskew>0`，粗略 hold 条件为：

- hold（保持时间）要求采样沿之后，输入还要保持旧值一小段时间。扫描链中相邻触发器之间常常只有很短的连线，新数据可能来得太快；如果两个触发器收到时钟的时间还有偏差，就更容易把本该下一拍到的数据过早送来。因而扫描时序不仅要防“太慢”，也要防“太快”。

```text
Tcq_min + Tdata_min >= Thold + Tskew
```

- 还应加入相应不确定度。**降低移位频率通常不能修复同沿 hold 违例**，因为该约束与周期长短不同。可通过链重排、延迟单元、锁存器或正确的时钟组织处理，不能只把测试时钟调慢。

- 跨时钟域或跨时钟边沿连接扫描链时，应按规则分组，并根据实际波形使用 lockup latch 等结构管理偏斜。它不是通用 CDC 同步器，也不是“跨域链一定加一个 latch 就安全”。扫描链重排还能优化布局布线，但需同步更新链信息和测试向量映射。

- 这里的偏斜（skew）是同一个预定时钟事件到达两个触发器的时间差。Lockup latch 是插在适当位置的保持锁存器，利用时钟相位让新扫描数据暂时留住，给接收端增加保持裕量；具体在哪个相位打开，必须根据两边的时钟关系选择。

- 测试时还需保证：

  - scan enable、test mode、异步 reset/set 可控，在 shift/capture 窗口满足要求。
  - 门控时钟在需要移位时可被测试控制打开；高速捕获的时钟脉冲由合适的测试时钟/OCC 机制产生。
  - 多电源域在测试状态下供电、隔离、保持和链连通性合法；不能扫描一个已经断电的中间链段。
  - 移位与捕获翻转可能高于正常工作活动，引发功耗、IR drop 或捕获失败；测试功耗是向量与时钟调度的约束。

- 本章没有使用目标库的 scan FF、lockup latch 或 on-chip clock controller，也没有做 scan STA、功耗和物理链重排；这些是从教学 RTL 走向实现时必须补足的工作。

- OCC 就是 on-chip clock controller（片上时钟控制器），在测试模式下按要求组织发起和捕获脉冲。ICG 是第 09 章的集成门控单元，负责安全地放行或阻断时钟。一个负责测试脉冲安排，一个负责门控，不能只看到都有“时钟”就认为职责相同。

<a id="scan-lab"></a>
### 2.4 扫描实验输出与波形

- 运行 [Scan_ATPG/run_sim.sh](lab/Scan_ATPG/run_sim.sh)，除前面的故障报告外，还得到：

```text
PASS scan W=1 load_capture_unload=32
PASS scan W=4 load_capture_unload=32
PASS scan W=9 load_capture_unload=32
```

- 三个位宽共 96 组 load/capture/unload 流程；W=1 检查边界，W=9 检查非整字节链。TB 装入编码、功能捕获其按位反值、再移出比较并检查链已被零填满；每轮都检查实际值，不只打印状态。

- 在 WSL 可查看：

```bash
cd lab/Scan_ATPG
gtkwave build/scan.vcd
gtkwave build/fault.vcd
```

- scan.vcd 是最后一次 W=9 的波形。按 scan_en 分辨 shift/capture，检查 q 的移动方向与 scan_out 采样点；fault.vcd 中观察故障点、故障值和 y 的对应变化。更换测试宽度会覆盖同名 VCD，但各位宽日志独立保存。

<a id="mbist"></a>
## 3. MBIST 与 March 算法

<a id="memory-faults"></a>
### 3.1 存储阵列不是靠普通扫描就能高效测完

- MBIST（memory built-in self-test，存储器内建自测试）把地址、数据背景、读写序列和比较逻辑放到片上，直接通过存储器接口执行测试。SRAM 宏内部位单元通常不是普通扫描 FF，阵列规模大、故障类型与普通组合逻辑不同，因此需要专门方法。

- SRAM 是静态随机存取存储器，通常以已经设计好的存储宏接入芯片；宏可以理解成带固定接口的一整块存储电路。FF 是 flip-flop，即触发器。这里强调它们的区别，是因为不能假定 SRAM 中的每个存储 bit 都像普通触发器一样接进扫描链。

- 可以先把 MBIST 看成一个自动读写检查员：走到某地址，写入已知数据，再读回来比较，然后换下一个地址。“数据背景”就是安排写入的位模式，例如一整个字全为 0、全为 1，或者 0101 交替。使用不同地址顺序和位模式，是为了让不同故障显现出来，而不只是检查一次读写能否成功。

- 常见抽象包括：

  - 单元 stuck-at：某位始终为 0/1。
  - 转换故障：某位写入 0→1 或 1→0 失败。
  - 地址译码故障：地址不可访问、多个地址访问同一单元，或一次访问影响多个单元。
  - 耦合故障：一个 aggressor 单元的状态/转换影响另一个 victim 单元。
  - 读扰、保持、动态故障等：需要相应操作、等待时间和电压/频率条件才能暴露。

- 不能由“跑了一个 March 算法”推出这些类别全部覆盖。特别是字组织存储器，只有全 0/全 1 背景无法充分区分同一字内所有位之间的耦合；通常还需补充 checkerboard、walking 等背景或专门的 word-oriented 测试序列。

- 字是一次接口访问的一组 bit，例如 W=8 时一次读写八位。耦合故障中的 aggressor 是施加影响的一位，victim 是受影响的一位；它们不一定处在不同地址。

- Checkerboard 用交错的 0/1 制造相邻位差异，walking-1 则让唯一的 1 逐位移动，例如 0001→0010→0100→1000。它们提供不同的位间关系，具体覆盖能力还要结合操作序列分析。

<a id="march"></a>
### 3.2 March C−：在同一地址做完操作，再移动地址

- March 的意思可以联系到“按次序行进”：测试从一个地址走到下一个地址，有时从低到高，有时从高到低。先不必记算法名字，把每个括号当成当前地址上的操作清单。比如 `(r0,w1)` 就是“先读，确认原值是 0，再写成 1”。

- 本实验使用下面的 March C− 顺序，↑ 表示地址递增，↓ 表示递减；r0/r1 表示读并比较预期，w0/w1 表示写入全 0/全 1：

```text
M0：↑(w0)
M1：↑(r0,w1)
M2：↑(r1,w0)
M3：↓(r0,w1)
M4：↓(r1,w0)
M5：↑(r0)
```

- 最初写和最后读本可选择任一遍历方向，本实现固定递增。**括号内操作在同一个地址连续完成，再转到下一个地址**，不是先对全部地址读完，再统一写。该区别正是许多地址/耦合故障检测机制的一部分。March 背景与长度可核对 [Microchip March Test Background](https://onlinedocs.microchip.com/oxy/GUID-1BC922B5-0BDE-4D42-AC92-68359BB22BEC-en-US-1/GUID-81A68B22-3BC9-479D-A63A-DAD6B44A852F.html)。

- 对 N 个字，本例操作数为：

```text
N + 2N + 2N + 2N + 2N + N = 10N
```

- 这包括 5N 次读和 5N 次写。它是**字接口操作数**，不是声称本实验实现了逐 bit March 的全部覆盖结论，也不一定等于 10N 时钟周期。

- 深度 N=4 的 M1 为：

```text
addr0:r0,w1 → addr1:r0,w1 → addr2:r0,w1 → addr3:r0,w1
```

- M3 则从 addr3 到 addr0。假设 addr3 错误地别名到 addr0：M0 都写 0 后，M1 在 addr0 写 1，再走到 addr3 时读到 1 而预期 0，即可报错。本实验明确注入这个地址别名模型，不声称穷尽所有译码缺陷。

- 改变遍历方向的意义是交换先后关系：递增时低地址先改写、高地址后检查；递减时相反。如果某一地址的写入会错误地影响另一地址，不同方向能让影响发生在不同的读回窗口内。这里先理解“为什么顺序有用”，不要把它扩大成对所有耦合故障的覆盖证明。

- MBIST 通常是破坏性的：测试覆盖原始内容。本例完成后内存为 0。运行时测试需要先解决业务访问仲裁、内容备份/恢复或选择可破坏的窗口，不能直接让 CPU 与 BIST 同时争用存储器。

<a id="mbist-rtl"></a>
### 3.3 控制器必须匹配同步读延迟

- [march_c_minus.v](lab/MBIST/march_c_minus.v) 参数为 DEPTH、W，地址宽度默认 `max(1,ceil(log2(DEPTH)))`；DEPTH≥1。它支持非二次幂深度，最后地址按 DEPTH−1 判断，不靠计数器自然溢出来结束。

- 存储器接口契约是：mem_en 为 1 时在上升沿接收请求；mem_we=1 为写，mem_we=0 为读；读数据在该沿后更新，控制器下一拍检查。没有 ready、重试或可变延迟：

```text
READ_REQ：发出同步读请求
      ↓ 下一个状态
CHECK：读取上拍更新的 mem_rdata，比较并记录错误
      ↓
WRITE：如当前 March 元素有写操作，则写新背景，再移动地址
```

- 如果在发出同步读请求的同一时序 always 中立刻比较 mem_rdata，看到的通常是旧响应，会错配地址。真实 SRAM 可能有不同读延迟、读写碰撞语义或时钟要求，必须修改控制协议，而不是只换个 memory 模块名。

- 本设计每个读多一个 CHECK 周期，因此数据操作与检查占 `5N+2×5N=15N` 个时钟工作周期，再加启动/完成控制开销。测试时间估算不能把 10N 内存操作直接当作完整控制器延迟。

- 接口行为：

  - start 在空闲上升沿启动一次测试；busy 时忽略 start。调用者使用脉冲请求，不能持续为 1 后意外再次启动。
  - done 为完成脉冲；fail 是本轮 sticky 标志，发现错误后继续完成全序列。
  - first_fail_addr/phase 仅记录第一个失败，后续失败不覆盖；下一次测试或复位清除。
  - 低有效异步复位中止本轮并停发请求；测试已改写的存储内容不会自动恢复。

- sticky 可以读成“置位后保持”：即使后续读写都正确，fail 也不会自动回到 0，否则先前发现的错误可能被掩盖。它只在本接口约定的新一轮启动或复位时清除。

- 本例比较器使用硬件二态意义的 `!=`，不是完整 X 检测器；TB 的正常首遍写入建立已知数据，故障模型也产生确定的 0/1。若要研究未知读数据，需要另加仿真检查，不能假定硬件 fail 自动检测任意 X。

<a id="mbist-lab"></a>
### 3.4 故障注入、操作序列检查与实际输出

- [tb_march.sv](lab/MBIST/tb_march.sv) 的同步 memory 模型注入：

```text
fault=0：无故障
fault=1：地址 DEPTH/2 的 bit0 固定为 0
fault=2：同一 bit 固定为 1
fault=3：同一 bit 的 0→1 写入转换被阻止
fault=4：逻辑最后地址映射到物理地址 0
```

- 固定值故障在写入模型中钳住目标位，首轮 w0 后开始读比较；这是本实验的具体建模方式。DEPTH=1 没有两个不同地址，跳过地址别名场景。

- TB 不只检查最终 fail，还按独立的操作编号展开 M0–M5，逐请求比较读写方向、地址次序和写入背景；检查恰好 10×DEPTH 次操作、错误地址/阶段以及诊断信息保持。DUT 出错后仍然执行完整 March，因此每种故障都有完整操作数检查。

- 以 DEPTH=7 为例：

```text
PASS March DEPTH=7 fault=0 operations=70 fail=0 first_addr=0 first_phase=0
PASS March DEPTH=7 fault=1 operations=70 fail=1 first_addr=3 first_phase=2
PASS March DEPTH=7 fault=2 operations=70 fail=1 first_addr=3 first_phase=1
PASS March DEPTH=7 fault=3 operations=70 fail=1 first_addr=3 first_phase=2
PASS March DEPTH=7 fault=4 operations=70 fail=1 first_addr=6 first_phase=1
PASS MBIST DEPTH=7 runs=5 reset_aborts=1
```

- DEPTH=1、4、7 共完成 14 次测试：3 次无故障、11 次故障注入，共 590 次完整运行的内存操作，另有三次中途复位。SA0 与 0→1 失败都在 M2 的 r1 暴露；SA1 在 M1 的 r0 暴露；地址别名在 M1 的最后地址暴露。

- fail=0 时 first_fail_* 的初值不代表真实故障记录，使用者必须先检查 fail。

- 查看 `lab/MBIST/build/d7/march.vcd`，重点对照 state、phase、mem_en/we/addr、mem_rdata、fail 与 first_fail_*。

- memory 数组通过 generate 中的 memory_view/word_value 别名进入 VCD，避免只 dump 数组名却看不到每个字。

- **覆盖边界：**这是全 0/全 1 字背景的 March C− 教学实现，未穷举所有地址/位故障，没有测试 1→0 转换故障、全体耦合故障、保持时间、读扰或真实 SRAM at-speed 条件。也没有实现 BIRA/BISR、冗余行列修复、ECC 联动或多端口存储测试。

- BIRA 是内建冗余分析，决定用哪些备用行或列替换坏位置；BISR 是内建自修复，将修复方案落实到访问映射。ECC 是纠错码，通过额外校验位检测或纠正规定范围内的数据错误。它们分别涉及修复资源分配、修复执行和数据纠错，不能由 MBIST 的 fail 信号自动得到这些能力。

<a id="jtag"></a>
## 4. JTAG 与边界扫描

<a id="tap"></a>
### 4.1 TAP 引脚和 16 状态机

- 前面主要检查芯片内部，这里把注意力转到芯片引脚之间的连接。两颗芯片焊在板上后，某根连线是否断了，未必能直接用探针接触。边界扫描在芯片靠近输入输出的位置加入可控制、可读取的单元，让一端送测试值、另一端读回，再通过串行接口把观察结果取出来。

- JTAG 通常指 IEEE 1149.1 测试访问与边界扫描体系。TAP（test access port）使用 TCK、TMS、TDI、TDO；可选 TRST 提供异步测试复位。本实验使用低有效 trst_n。TCK 是测试时钟，不能默认与芯片功能时钟同域。

- 四根主要信号按职责记：

  - **TCK**：测试时钟，决定何时推进一步。
  - **TMS**：控制 TAP 状态机往哪走。
  - **TDI**：把测试 bit 送进来。
  - **TDO**：把测试 bit 送出去。

- TAP 状态机决定当前是在装指令、搬数据，还是让装入值生效。先分清动作，再读 16 个状态名。

- TMS 控制状态转移，TDI/TDO 在相应 shift 状态搬运数据。状态分为两条扫描路径：

```text
Test-Logic-Reset ↔ Run-Test/Idle
                      │
                  Select-DR-Scan ──→ Select-IR-Scan ──→ Reset
                      │                  │
                   Capture-DR         Capture-IR
                      │                  │
                    Shift-DR           Shift-IR
                      │                  │
                    Exit1-DR           Exit1-IR
                    /     \            /     \
                Pause-DR Update-DR Pause-IR Update-IR
                   │                  │
                 Exit2-DR           Exit2-IR
                 /      \           /      \
              Shift   Update     Shift    Update
```

- 上图表示结构，具体分支由 TMS 决定，不能替代完整状态表。精确的全部 32 条转移可读 [tap_demo.v](lab/JTAG/tap_demo.v) 的 case，以及独立的 [状态图路径生成器](lab/JTAG/generate_walk.py)。TI 文档也给出状态图与控制时序背景：[JTAG Interface](https://www.ti.com.cn/cn/lit/pdf/spma075)。

- 连续至少五个 TCK 上升沿保持 TMS=1，可从任意正常 TAP 状态回到 Test-Logic-Reset；这与可选的 TRST 物理引脚是两种复位路径。Pause 状态不移位，退出 Pause 后可以继续 Shift 或直接 Update。

- 从 Run-Test/Idle 出发，手走一次 DR 访问：

1. **进入移位路径**：TMS 依次为 1、0、0，三个上升沿后依次进入 Select-DR-Scan、Capture-DR、Shift-DR。
2. **搬运数据**：TMS=0 时留在 Shift-DR，每个移位沿搬一位。
3. **送最后一位**：该移位沿令 TMS=1，送入最后一位的同时进入 Exit1-DR。
4. **提交结果**：继续令 TMS=1，进入 Update-DR；本实现在该状态的下降沿提交更新。
5. **返回空闲**：令 TMS=0，回到 Idle。

- **分清控制与数据**：TMS 决定走哪条路，TDI 才是沿途搬运的数据。

- Capture、Shift、Update 的区别：

  - Capture 把当前被观察的并行状态装进移位寄存器。
  - Shift 串行移入新位、移出旧位。
  - Update 把已移入的测试控制值提交到保持寄存器，避免输出随每个移位位元变化。

<a id="boundary"></a>
### 4.2 IR 选择路径，DR 不一定是一条固定长度链

- IR（instruction register，指令寄存器）决定当前 DR（data register，数据寄存器）路径及其作用。

- IR 可以理解成“当前要做哪一种测试”的选择寄存器，DR 是该测试要搬运的数据寄存器。通常先走 IR 路径装入指令，再走 DR 路径搬数据。例如选 BYPASS 时只经过一位，选边界寄存器时则经过多个边界单元，所以不能认为每次扫描的数据长度都一样。常见指令如下：

  - **BYPASS**：选一位旁路寄存器，让不参与测试的芯片只贡献一位串行延迟；不是零延迟连线。
  - **SAMPLE/PRELOAD**：采样边界状态，或预装稍后使用的边界输出值，功能核心通常仍控制输出。
  - **EXTEST**：使用边界更新寄存器控制外部引脚、采样输入，以检查板级互连。
  - **IDCODE**：若设备实现该寄存器，可读器件标识；不能假设所有教学 TAP 都有。

- 边界单元通常包含 capture/shift 通路与 update 保持通路：

```text
功能输出 ───────────────┐
                       mux(EXTEST) → pad
边界 update 寄存器 ────┘
          ↑ Update
边界 capture/shift 寄存器 ← pad/功能状态
          ↔ TDI / TDO 串行通路
```

- 如果直接用 shift 寄存器驱动测试 pad，装入一个新向量的过程中引脚可能每拍改变；update 寄存器使最终提交前输出保持稳定。

- 板级测试可让器件 A 的边界输出驱动连接，再由器件 B 采样输入，配合不同向量检查互连开路/短路等模型。实际测试还需 BSDL 描述、引脚/输出使能、安全值、电气条件和测试仪连接；不能从一个 TAP 的内部回环 PASS 推出 PCB 连通性已经测试过。

- BSDL 是 boundary-scan description language（边界扫描描述语言），告诉测试工具这颗器件有哪些边界单元、对应哪些引脚、指令如何编码等。PCB 是承载芯片及其互连的印制电路板；ATE 是自动测试设备，负责实际施加测试并采集结果。

- TAP 提供访问方式，这些描述和设备才能把访问落实到具体器件与板级连接。

- 边界扫描与芯片内部扫描都能串行访问状态，但对象和协议不同；JTAG TAP 可以作为某些内部测试网络的访问入口，却不是“所有内部 FF 自动串成 JTAG 链”。

<a id="tap-rtl"></a>
### 4.3 教学实现的具体契约与边沿

- 本实验 [tap_demo.v](lab/JTAG/tap_demo.v) 有完整 16 状态 TAP，但故意只实现一个小的固定边界：

- 这里 pad 表示芯片与外部连接的引脚接口，core 表示内部功能逻辑。`core_out` 是功能电路想输出的值，`pad_out` 是当前真正送往外部的值。平常两者相连；进入 EXTEST 后，选择器改用边界 update 寄存器里的测试值驱动输出。沿着这两个数据来源读代码即可。

```text
IR 宽度：2 bit
00 = EXTEST
01 = SAMPLE/PRELOAD
11 = BYPASS
10 = 保留编码，按 BYPASS 处理

边界 DR：8 bit = {pad_in[3:0], pad_out[3:0]}
Update 时，仅低 4 bit 用于驱动输出 pad
BYPASS DR：1 bit，Capture 时清 0
```

- IR Capture 装入 `01`；串行顺序为 LSB first，TDI 从高位移入。该惯例与前面 scan_bank 的移位方向不同，必须分别按接口定义驱动，不能见到“扫描”二字就套同一顺序。Capture-IR 的低位约定可对照 [OpenOCD 的 TAP 说明](https://openocd.org/files/thesis.pdf)。

- 本实现时序：

  - TMS/TDI 在 TCK 上升沿参与状态与移位操作。
  - 进入 Capture 状态后，在执行该状态的上升沿捕获数据；TB 要留完整的 Capture 步骤。
  - IR active 和边界 update 在相应 Update 状态的下降沿提交。
  - TDO 在下降沿更新，测试驱动端在下一上升沿之前/上升沿采样稳定值。
  - tdo_oe 只在 Shift-IR/Shift-DR 为 1；实际 pad 的三态驱动由外部集成。

- 这种设计区分了 IR 移位值与当前生效指令：装新指令时旧指令仍保持，直到 Update-IR 才切换。EXTEST 时 pad_out 来自 boundary_update；其他指令下来自 core_out。复位默认 BYPASS，并释放输出回到核心控制。

- 本模块是教学子集：没有 IDCODE、BSDL、双向 pad 的输出使能单元、模拟电气模型或完整 1149.1 一致性检查。固定 4 位输入/4 位输出和 2 位 IR 是本实验格式，不是所有器件的 JTAG 长度。

- 若通过 JTAG 控制功能时钟域内状态，还需要额外 CDC/握手，不能直接拿 TCK 更新的控制值驱动任意功能寄存器。

<a id="tap-lab"></a>
### 4.4 先覆盖状态图，再验证指令含义

- [generate_walk.py](lab/JTAG/generate_walk.py) 对独立定义的 TAP 图做最短路径连接，生成 97 步 TMS 序列，覆盖全部 16 状态的两种 TMS 出边。TB 每步比较 state_debug，并用位图确认 32 条边都实际经过；这比仅在纸上列出状态机更具体，但仍不是全时序形式证明。

- 之后进行功能测试：

1. TMS 五拍复位后，加载 SAMPLE/PRELOAD，检查 Capture-IR 串行读出 01。
2. 核心输出 5、pad 输入 A，边界 Capture 应读出 A5；移入 3C 并 Update，功能 pad 仍为 5。
3. 切到 EXTEST，输出应立即采用预装值 C。
4. 再读边界得到 AC，移入 06，在 Update 后输出变为 6；移位期间保持旧输出不变。
5. 两次边界传输均中途 Pause 三拍再恢复，检查数据没有额外移位。
6. 检查 10/11 两个编码的单 bit BYPASS 延迟，以及离开 Shift 后 tdo_oe 关闭。
7. 从 EXTEST 复位，确认核心重新控制输出，并单独检查异步 TRST。

- 实际输出：

```text
REFERENCE TAP walk steps=97 states=16 edges=32
PASS TAP walk_steps=97 states=16 edges=32 IR_capture=01 boundary_transactions=2 bypass_opcodes=2 pause_resume=2 reset_paths=2
```

- 上述 Pause 数据保持测试针对 DR；IR Pause 路径已覆盖状态转移，但未穷举所有中断/恢复位置的数据组合。状态边覆盖不等于全部指令数据行为覆盖。

- 打开 `lab/JTAG/build/tap.vcd`，观察 state_debug、instruction_debug、ir_shift、boundary_shift、boundary_update、tdo/tdo_oe 和 pad_out。

- 最重要的检查是：Shift 期间 update 值不变，Update 后才提交；TDO 在下降沿更新，不能用错误边沿驱动/采样而“碰巧得到正确数据”。

<a id="regression"></a>
## 5. 整章运行与面试速查

### 5.1 一键回归

- 在 PowerShell 运行：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/10_DFT/lab' && bash run_all.sh"
```

- [run_all.sh](lab/run_all.sh) 加载 `/root/oss-cad-suite/environment`，依次运行三组实验与 [变异检查](lab/check_mutations.py)。EDA 工具全部在 WSL 中执行；各实验包含 Verilator lint，自检查 Icarus 仿真。

- scan_bank、March 控制器和 TAP 另经 Yosys 无 latch/结构检查。故障注入锥主要用来对照模拟，未把其人为注入结构作为生产电路进行面积分析。

- RTL 和脚本在 lab 子目录，build 内为向量、故障字典、日志、仿真程序和 VCD。它们受仓库忽略规则保护，不应作为源码提交。仿真超时与任意数值不匹配均通过 `$fatal` 返回失败，而不是只打印 FAIL 后继续成功退出。

- 七个变异分别破坏逻辑函数、扫描方向、MBIST 比较、March 地址方向、IR Capture 值、边界 update 隔离、TAP Pause 转移。实际回归：

```text
PASS mutation caught: wrong_logic
PASS mutation caught: scan_direction
PASS mutation caught: mbist_no_compare
PASS mutation caught: mbist_wrong_direction
PASS mutation caught: ir_capture_wrong
PASS mutation caught: boundary_no_update_latch
PASS mutation caught: tap_pause_edge
PASS DFT mutations: 7/7
PASS Chapter 10: Scan_ATPG + MBIST + JTAG
```

- 每个变异先要求编译成功，再要求被对应功能/协议断言检出；编译失败与超时不算抓到了缺陷。它证明测试对这些错误有敏感性，不是测试本身完全正确的数学证明。

### 5.2 总体边界与面试速查

- 已验证：明确故障集合的小规模穷举、扫描串行功能、字级 March 顺序/诊断/复位、TAP 全状态边与部分指令数据场景。

- 未验证：工业 scan insertion/压缩、完整 at-speed ATPG、真实 SRAM 故障族覆盖、ATE 程序、BSDL/1149.1 合规、电气接口、scan STA/PPA、测试功耗/IR drop、全调度形式证明。

- 面试速查：

  - **Stuck-at 要激活和传播，转换故障还要受控旧值与及时捕获。**
  - **覆盖率先声明故障模型、故障点和分母；aborted 不等于不可检测。**
  - **Scan 把内部状态变得可控/可观察，shift/capture/unload 的时钟与使能必须明确。**
  - **降低扫描频率不能自动修复 hold；跨时钟链、reset、ICG 和功耗都要检查。**
  - **March 括号内先在同一地址做完，10N 是操作数，不必然是控制器拍数。**
  - **全 0/全 1 字背景不代表所有位间耦合都已覆盖；MBIST 也不自动修复坏存储器。**
  - **TAP 状态机负责访问协议，IR 选择 DR；BYPASS 是一位延迟，Update 保持引脚稳定。**
  - **教学 PASS 是在给定模型和场景下成立，不能替代生产测试签核。**
