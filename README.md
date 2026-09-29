# 数字 IC 设计学习总纲（求职向）

目标岗位：数字 IC 设计（前端为主，兼顾验证、综合、STA、后端的面试常识）。  
本文件是总目录。每个编号文件夹是一章，章内用**一份 `README.md` 总览全部小节**（参考 `07_STA/`），不再细分子文件夹；代码和实验统一放在该章的 `lab/` 下。内容后续逐章填写。

状态标记：✅ 已完成 ｜ 🚧 进行中 ｜ ⬜ 未开始  
优先级：★★★ 面试必考 ｜ ★★ 常考 ｜ ★ 了解即可

---

## 章节文件结构

```
NN_Chapter_Name/
├── README.md          # 本章全部小节的讲解（必须）
├── INTERVIEW_QA.md    # 面试问答与计算题（概念多的章节）
└── lab/               # 代码、testbench、脚本、约束、报告（有代码时）
    └── <实验名>/       # 一个电路或一个实验一个文件夹
```

编写新章节的格式、代码与验证要求见 `CHAPTER_GUIDE.md`。

## 环境约定

- 仿真、综合、STA 均在 **WSL2 Ubuntu** 下运行，工具为 OSS CAD Suite（Icarus、Verilator、Yosys、GTKWave）与 micromamba `orfs` 环境（OpenROAD、OpenSTA、Sky130 PDK）。安装与使用见 `../ascon-aead128-fast/README.md`。
- 工具目前安装在 `/root` 下，需要 `sudo -i` 后再 `source /root/oss-cad-suite/environment`。

---

## 推荐学习路线

| 阶段 | 内容 | 目标 |
|------|------|------|
| 第 1 阶段：基础 | 01 → 02 → 03（常用电路） | 能手撕常见电路、写可综合代码 |
| 第 2 阶段：时序与跨域 | 05 → 06 → 07 → 04 | 讲清 setup/hold、CDC、复位，能算时序题 |
| 第 3 阶段：流程 | 08 → 11 → 09 → 10 → 14 | 了解综合、验证、低功耗、DFT、后端全流程 |
| 第 4 阶段：系统与项目 | 12 → 13 → 16 | 总线协议、体系结构，完成可写进简历的项目 |
| 贯穿全程 | 00、15、17 | 工具、脚本、刷题与面试准备 |

---

## 00_Environment_Tools —— 工具与环境 ★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| Linux 与 WSL 基础 | WSL2 架构、Linux 目录结构、常用命令、权限、环境变量 |
| 仿真：Icarus / Verilator | iverilog/vvp 流程、Verilator lint 与 C++ 仿真、编译选项 |
| 波形：GTKWave | VCD/FST、dump memory、信号分组、保存布局 |
| 开源流程：Yosys / OpenROAD | Yosys 综合、OpenROAD 布局布线、OpenSTA 概览 |
| 商业 EDA 概览 | VCS/Xcelium、Verdi、DC/Genus、PT/Tempus、ICC2/Innovus、Spyglass、Formality/Conformal 各自定位 |
| Git 版本管理 | 基本工作流、分支、`.gitignore`（忽略 build、波形、库文件） |

## 01_Digital_Logic_Fundamentals —— 数字电路基础 ★★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| 数制与编码 | 进制、原码/反码/补码、有符号运算与溢出、BCD、Gray 码、独热码 |
| 布尔代数与卡诺图 | 布尔代数定律、卡诺图化简、最小项/最大项 |
| 组合逻辑 | MUX、译码器、编码器、比较器、用 MUX 实现任意逻辑 |
| 锁存器与触发器 | SR/D 锁存器、主从 DFF、JK/T 触发器、latch 与 FF 的区别 |
| CMOS 电路基础 | CMOS 反相器、与非/或非门结构、传输门、延时与功耗来源 |
| 竞争冒险与毛刺 | 成因与消除 |
| 有限状态机理论 | Moore 与 Mealy、状态编码（二进制/独热/Gray）、状态化简 |

## 02_HDL_Verilog_SystemVerilog —— 硬件描述语言 ★★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| Verilog 语法 | 模块、端口、数据类型（wire/reg）、运算符、位宽与符号扩展 |
| 阻塞与非阻塞赋值 | `=` 与 `<=` 的区别与使用规则、典型错误 |
| 仿真事件调度 | 仿真时间片与事件队列（active/NBA）、竞争条件 |
| 可综合编码风格 | 可综合子集、组合/时序 always 写法、三段式状态机 |
| 参数化与 generate | parameter/localparam、generate、`$clog2` |
| SystemVerilog 设计特性 | logic、always_ff/always_comb、enum、struct、interface、package |
| 常见编码陷阱 | latch 推断、敏感列表不全、多驱动、仿真与综合不一致 |

## 03_Common_Circuits —— 常用电路（手撕代码主战场）★★★　✅

已完成：`README.md` 覆盖下表全部 15 节（每节含原理、RTL、真实仿真输出、面试要点）及速查表；`lab/` 下 `FIFO`（同步 FIFO、整理版异步 FIFO 与早期版 `FIFO.v` 对比测试、满空同步延迟实测、深度计算脚本）、`Counter`（可加载可逆模 N、BCD、环形 / Johnson 自启动）、`Shift_LFSR`（通用移位寄存器、并串环回、Fibonacci / Galois LFSR 周期验证）、`Edge_Detect`（同步 / 异步边沿检测、复位值、窄脉冲漏采）、`Clock_Divider`（偶数 / 奇数 50% / 小数分频）、`FSM_Seq`（1101 检测 Moore/Mealy × 重叠/不重叠、移位寄存器检测器、售货机）、`Arbiter`（固定优先级、两种轮询写法、加权轮询）、`Handshake`（打一拍断流 vs 不断流）、`Gray`（二进制↔Gray 逐级 / 对数级、两种 Gray 计数器、非 2 的幂对称截取）、`Enc_Dec_Mux`（参数化优先编码器、译码器、独热编码器、二进制 / 独热 MUX、latch 反例 + Yosys 统计）、`Memory`（单口 RAM 三种写模式、双口冲突旁路、2R1W 寄存器堆、case ROM、SRAM 宏模型 + 包装层）、`Parity_CRC_ECC`（奇偶、串行 / 并行 CRC 三个标准校验值与检错统计、SECDED (13,8)/(39,32)/(72,64)）、`Pipeline_Skid`（skid buffer、3 级流水乘加的全局停顿 vs 逐级握手、ready 组合穿透统计、Yosys 最长路径随级数变化、变异测试）、`Width_Conv`（窄转宽 / 宽转窄带 last/keep 环回、24↔32 / 8↔12 gearbox、变异测试）、`PWM_Debounce`（影子寄存器 PWM 与直接比较对照、按键消抖与"只同步 + 边沿检测"对照），testbench 均自检查并在 WSL 跑通（RTL 前仿真；Enc_Dec_Mux 与 Pipeline_Skid 另用 Yosys 做了结构统计）。

| 小节 | 内容提纲 |
|------|----------|
| FIFO | 同步 FIFO、异步 FIFO（Gray 指针、两级同步、满空判断、偏保守原理）、深度计算 |
| 计数器 | 二进制/BCD/环形/Johnson 计数器、可加载计数器 |
| 移位寄存器与 LFSR | 移位寄存器、串并转换、LFSR 与伪随机数 |
| 边沿检测 | 上升沿/下降沿/双沿检测 |
| 时钟分频 | 偶数分频、奇数分频（50% 占空比）、小数分频 |
| 状态机与序列检测 | 序列检测（重叠/不重叠）、自动售货机等经典题 |
| 仲裁器 | 固定优先级、轮询（Round Robin）、加权轮询 |
| valid/ready 握手 | 握手协议、反压、打拍不断流 |
| Gray 码转换 | 二进制与 Gray 码互转 |
| 编码器、译码器、MUX | 优先编码器、译码器、参数化 MUX、独热 MUX |
| 存储器 | 单口/双口 RAM、ROM、寄存器堆、SRAM 宏的使用 |
| 校验：奇偶、CRC、ECC | 奇偶校验、CRC 串行/并行实现、汉明码 |
| 流水线与 skid buffer | 流水线设计、skid buffer、流水线反压 |
| 位宽转换 | 宽转窄、窄转宽 |
| PWM 与消抖 | PWM 发生器、按键消抖 |

## 04_Arithmetic_Units —— 运算单元 ★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| 加法器 | 行波进位、超前进位（CLA）、进位选择、进位保留（CSA）、并行前缀加法器 |
| 乘法器 | 移位相加、Booth 编码、Wallace 树 |
| 除法器 | 恢复/不恢复余数除法、迭代除法器 |
| 定点与浮点 | 定点数 Q 格式、截位与舍入、IEEE 754 基础 |
| CORDIC | 原理与硬件实现 |

## 05_Clock_Reset_Design —— 时钟与复位 ★★★　✅

已完成：`README.md` 覆盖下表全部小节（每节含面试要点）；`lab/` 下 `Clock_Gating`（AND 门控 vs ICG）、`Glitch_Free_Clock_Mux`（同源/异步无毛刺切换）、`Reset_Sync`（复位同步器、同步/异步复位对比、Yosys → Sky130 单元统计），testbench 均自检查并在 WSL 跑通。

| 小节 | 内容提纲 |
|------|----------|
| 时钟产生与 PLL | PLL 基本原理、时钟源、时钟树概念 |
| 门控时钟与 ICG | 门控时钟、ICG 结构、为什么不能用 AND 直接门控 |
| 无毛刺时钟切换 | 同步与异步时钟的无毛刺 MUX |
| 复位策略 | 同步复位与异步复位优缺点 |
| 复位同步与 RDC | 异步复位同步释放、复位树、复位域交叉（RDC） |

## 06_CDC —— 跨时钟域 ★★★　✅

已完成：`README.md` 覆盖下表全部小节（每节含面试要点）；`lab/` 下 `MTBF`（计算脚本）、`Sync_2FF`（两级同步器 + 多 bit 总线偏斜实验）、`Pulse_Sync`（toggle 型脉冲同步）、`Multi_Bit_Sync`（四相握手 vs 两相 MCP），testbench 均自检查并在 WSL 跑通。异步 FIFO 链接到 03 章 `lab/FIFO/`。

| 小节 | 内容提纲 |
|------|----------|
| 亚稳态与 MTBF | 成因、MTBF 公式、同步器级数选择 |
| 单 bit 同步 | 两级同步器、快到慢/慢到快 |
| 脉冲同步 | 脉冲同步器、窄脉冲丢失问题 |
| 多 bit 同步 | 握手同步、MCP 同步、何时用异步 FIFO |
| CDC 检查 | Spyglass/Questa CDC 检查项、约束写法 |

## 07_STA —— 静态时序分析 ★★★　✅

| 文件 | 内容 |
|------|------|
| `README.md` | 建立/保持时间、时序路径、skew/jitter、延时计算、PVT/OCV/CRPR、时序例外、recovery/removal、复位、SDC、PrimeTime/OpenSTA、时序修复 |
| `INTERVIEW_QA.md` | 47 道问答 + 6 道计算题 |
| `lab/` | FIFO → Sky130 网表 → OpenSTA，含收紧时钟、去掉时钟组两个实验 |

## 08_Logic_Synthesis —— 逻辑综合 ★★　✅

已完成：`README.md` 覆盖下表全部小节，末尾 20 道面试题；`lab/` 下 `Yosys_Flow`（16 bit ALU 逐步综合、门级仿真、OpenSTA 时序/功耗、面积 vs 时序驱动映射曲线）、`Opt_Experiments`（边界优化、寄存器合并与 keep、资源共享、FSM 编码、retiming）、`Equivalence`（RTL vs 网表形式等价性检查、注入 bug、check_design），全部在 WSL 跑通。

| 小节 | 内容提纲 |
|------|----------|
| 综合流程 | 翻译、优化、映射；DC/Genus 基本脚本；读报告（面积、时序、功耗） |
| 约束与优化 | 综合约束、`compile_ultra`、retiming、boundary optimization、dont_touch |
| 网表检查与等价性 | 形式等价性检查（Formality/Conformal）、`check_design` |
| Yosys 实验 | 用 Yosys 综合本仓库电路、看网表与单元统计 |

## 09_Low_Power_Design —— 低功耗 ★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| 功耗组成 | 动态功耗（翻转、短路）与静态功耗（漏电）、公式 `P = αCV²f` |
| 门控时钟降功耗 | RTL 级门控、综合自动插 ICG |
| 多阈值与多电压 | 多阈值单元、多电压域、电平转换器 |
| 电源关断与 UPF | 电源关断、隔离单元、保持寄存器、UPF 基础 |
| DVFS | 动态电压频率调节 |

## 10_DFT —— 可测性设计 ★　⬜

| 小节 | 内容提纲 |
|------|----------|
| 故障模型 | 固定型故障（stuck-at）、转换故障、覆盖率 |
| 扫描与 ATPG | 扫描链、扫描触发器、ATPG、scan 对时序的影响 |
| MBIST | 存储器内建自测试、March 算法 |
| JTAG 与边界扫描 | TAP 状态机、边界扫描 |

## 11_Verification —— 验证 ★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| testbench 基础 | 时钟/复位产生、激励、自检查、`$display`/`$monitor`、参考模型对比 |
| SV 验证：OOP、随机、覆盖率 | 类、约束随机、功能覆盖率、mailbox/semaphore |
| SVA 断言 | 立即/并发断言、序列、蕴含、常用协议断言 |
| UVM | 组件结构、phase、sequence/driver/monitor/scoreboard、factory |
| 形式验证 | 属性检查、等价性检查 |
| 门级仿真 | SDF 反标、X 传播 |

## 12_Bus_Interfaces —— 总线与接口 ★★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| APB | 信号、读写时序、状态机、APB 从机实现 |
| AHB | 流水传输、burst、HREADY、仲裁 |
| AXI4 与 AXI-Stream | 五通道、握手规则、burst 类型、outstanding、乱序、AXI-Stream |
| UART | 帧格式、波特率、过采样、收发器实现 |
| SPI | 四种模式（CPOL/CPHA）、主从实现 |
| I2C | 起止条件、应答、开漏、仲裁 |

## 13_Computer_Architecture_SoC —— 体系结构与 SoC ★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| RISC-V 指令集 | RV32I 指令格式、寄存器、寻址 |
| 流水线与冒险 | 五级流水线、数据/控制/结构冒险、前递、分支预测 |
| Cache | 映射方式、替换策略、写策略、命中率计算 |
| 存储层次与 DDR | SRAM/DRAM、DDR 基本概念 |
| 中断与 DMA | 中断控制器、DMA 原理 |
| SoC 集成 | 总线互联、地址映射、IP 集成 |

## 14_Physical_Design_Backend —— 后端物理设计（面试常识）★　✅

已完成：`README.md` 覆盖下表全部小节（每节含公式、数值例子、真实报告解读和面试题）；`lab/PnR_Flow` 用第 08 章的 16 bit ALU 在 Sky130 上跑完整后端流程：OpenROAD 布图/PDN → 布局 → CTS → 布线 → OpenRCX 三 corner 抽取 → OpenSTA 三 corner 签核 → 时序 ECO → PDNSim IR drop/EM → Magic GDS + DRC（0 错误）→ Netgen LVS（匹配）→ 布线后门级仿真（PASS），另有利用率、天线、电源条间距、关掉优化、签核周期、DRC 修补、供电点间距 7 组对比实验，全部在 WSL 跑通。只在 tt corner 收敛（ss 需约 10 ns）；未做 SI 分析和带 SDF 的门级仿真。

| 小节 | 内容提纲 |
|------|----------|
| 布图与电源规划 | 布图规划、宏单元摆放、电源网络 |
| 布局 | 标准单元布局、拥塞、时序驱动布局 |
| 时钟树综合 | 目标、skew/latency、useful skew |
| 布线 | 全局布线与详细布线、串扰 |
| 寄生参数抽取 | RC 抽取、SPEF |
| 物理验证 | DRC、LVS、天线效应 |
| IR drop 与电迁移 | 电压降、电迁移 |
| 签核与 ECO | 签核标准、时序 ECO、功能 ECO |

## 15_Scripting —— 脚本 ★★　✅

已完成：`README.md` 覆盖下表全部小节，末尾 17 道面试题；`lab/` 下 `Tcl_EDA`（Tcl 语法自检、Yosys Tcl 模式综合 ALU、用 Tcl 写 SDC、OpenSTA 集合查询：单元统计、高扇出线网、端点 slack 直方图）、`Python_Report`（解析 OpenSTA 报告与 Yosys stat，与 Tcl 导出结果交叉核对）、`Make_Regression`（参数化计数器 + Makefile + bash 串行 / Python 并行回归，注入 corner case bug 演示多种子与 corner 偏置），全部在 WSL 跑通。

| 小节 | 内容提纲 |
|------|----------|
| Tcl | 变量、列表、过程、EDA 工具中的集合操作 |
| Python | 文本/报告处理、正则、自动化回归 |
| Shell 与 Makefile | bash 常用写法、Makefile 组织仿真流程 |

## 16_Projects —— 项目（写进简历）★★★

项目体量大，开始做时再在本文件夹下建项目文件夹。

| 项目 | 内容提纲 | 状态 |
|------|----------|------|
| Ascon AEAD128 | 现有工程 `../ascon-aead128-fast`：RTL → Yosys 综合 → OpenROAD P&R → STA | 🚧 |
| UART 控制器 | 带 FIFO 的 UART + APB 接口，完整验证 | ⬜ |
| RISC-V 核 | RV32I 五级流水 CPU | ⬜ |
| AXI DMA | AXI 主机 DMA 控制器 | ⬜ |

## 17_Interview_Prep —— 面试准备 ★★★　⬜

| 小节 | 内容提纲 |
|------|----------|
| 手撕代码 | 题目汇总（分频、FIFO、序列检测、仲裁、边沿检测、同步器……），链接到各章 lab |
| 笔试 | 数字电路、Verilog 找错、时序计算 |
| 概念问答 | 各章问答汇总（STA 部分见 `../07_STA/INTERVIEW_QA.md`） |
| 简历与项目讲述 | 项目描述、STAR 讲法、可能被追问的细节 |
| 面经 | 各公司面经整理 |
