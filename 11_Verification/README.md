# 第 11 章：验证——从自检查 testbench 到形式证明

本章目标：能从规格写出验证计划，搭建不会“假 PASS”的 testbench，解释 SV 验证特性、SVA、UVM、形式验证与门级仿真各自解决的问题，并用真实实验说明它们的边界。

前置知识：[Verilog/SystemVerilog](../02_HDL_Verilog_SystemVerilog/README.md)、[常用电路与握手](../03_Common_Circuits/README.md)、[时钟与复位](../05_Clock_Reset_Design/README.md)。门级部分建议结合[综合](../08_Logic_Synthesis/README.md)和 [STA](../07_STA/README.md)阅读。

建议顺序：第 1 节建立规格与记分板 → 第 2、3 节学习随机与属性 → 第 4 节理解 UVM 如何组织这些部件 → 第 5、6 节比较证明与门级验证。最后完成 [40 道面试问答](INTERVIEW_QA.md)。

本章有五组 WSL 实验，统一入口为 [lab/run_all.sh](lab/run_all.sh)。UVM 部分讲标准架构与工程流程，**没有把非 UVM 的 SV 实验宣称为 UVM 回归**；未运行 UVM 类库或商业模拟器。

## 目录

1. [Testbench 基础：规格、激励、自检查与调度](#testbench)
2. [SV 验证：OOP、约束随机、覆盖率与进程通信](#sv)
3. [SVA：立即断言、并发断言与协议属性](#sva)
4. [UVM：组件、phase、sequence 与 factory](#uvm)
5. [形式验证：属性证明、可达性与等价检查](#formal)
6. [门级仿真：综合网表、SDF 与 X 传播](#gls)
7. [整章回归、故障注入与学习边界](#regression)

<a id="testbench"></a>
## 1. Testbench 基础：先确定什么叫正确

### 1.1 验证不是“把波形跑出来”

设计验证（design verification）检查实现是否符合规格。波形是定位问题的证据，不能代替通过条件。自检查环境至少包含激励、观测、参考模型、比较器、完成条件和超时保护。

```
规格 → 验证计划 → 激励生成 → driver → DUT → monitor → scoreboard
                     │                          │          ↑
                     └──── 被接受的输入事务 ── 参考模型 ────┘
                                                │
                                         覆盖率与错误报告
```

参考模型应尽量按规格建模。例如验证一个带反压的算术单元，模型只需要按输入事务计算结果并排队，不必照抄 DUT 的寄存器使能条件。照抄同一错误会让实现与模型“错得一致”。

一次测试通过应同时满足：数据与协议无错误、计划要求的场景已发生、在途事务已经排空或按复位规则取消、没有超时。只在固定时间调用 `$finish`，可能让尚未返回的响应永远逃过比较。

### 1.2 本章 DUT 的规格

[elastic_alu.v](lab/Handshake/elastic_alu.v) 是一个 W 位、单槽、按序响应的运算通道，W≥1：

- `in_valid && in_ready` 的上升沿接受请求；op=0 做模 \(2^W\) 加法，op=1 做逐位异或。
- `out_valid && out_ready` 的上升沿消费旧响应。
- 输出槽为空或者旧响应将在本拍被消费时，允许接收新请求。
- `out_valid && !out_ready` 时必须保持 valid 与 result。
- 低有效异步复位清空槽，已经接受但尚未输出的事务被取消；不是复位后继续返回。
- 不支持多笔乱序返回、ID、错误响应或 CDC。

关键控制只有：

```verilog
assign in_ready = !out_valid || out_ready;
// 时序块内，rst_n 有效时：
else if (in_ready) begin
  out_valid <= in_valid;
  if (in_valid) result <= op ? (a^b) : (a+b);
end
```

当本拍同时输入输出握手时，消费者得到旧 result，寄存器在 NBA 区写入新 result。连续无反压时启动间隔为一拍；这不表示一个刚在上升沿接受的请求能在同一上升沿被消费。

例：W=8，255+1 得到 0；5 xor 3 得到 6。运算宽度、溢出是否保留都属于规格，不能由 testbench 随意选择。

### 1.3 验证计划要能落到检查点

本例把计划分成以下可执行目标：

1. 加法截断与异或结果：事务参考模型比较。
2. 输出背压：逐拍检查 valid/result 保持。
3. 吞吐：允许同拍出队与入队，确认出现过这种情况。
4. 复位：在输出待取时拉低 reset，检查立即清空，记分板取消一笔。
5. 参数边界：W=1、8、13，包含最小位宽与非整字节位宽。
6. 完成性：接收计数 = 输出计数 + 取消计数，队列排空。
7. 场景覆盖：输入握手/输出握手的 00、01、10、11 四种组合全部出现。

这些目标是基础计划，不包含所有数据组合。即使四个握手 bin 全满，也不能说整个设计已达到“100% 验证”。

### 1.4 时钟、复位与避免竞争

Testbench 用 `always #5 clk=~clk` 产生 10 ns 时钟；这类 `initial`、延迟与动态数据结构属于验证代码，不放进可综合 DUT。

本章 driver 在下降沿改变输入，monitor 在上升沿读取旧输出。DUT 同样在上升沿执行非阻塞赋值，其新值在 NBA 更新，因此 monitor 看到的正是本拍握手的数据。任务里上升沿后的 `#1` 用于等待更新和组织下一步，不是靠任意延迟去修复协议。

```
       下降沿                    上升沿                  下降沿
driver 设置 a/b/valid/ready ──── 保持 ────────────────── 下一组
monitor                         采样本拍握手与旧结果
DUT                             计算 → NBA 更新寄存器
```

常见错误：在上升沿用阻塞赋值驱动 DUT 输入，同时 DUT 也在这个沿读取，执行顺序可能决定结果。工业 SV 环境可用 clocking block 明确驱动/采样偏移，再通过 virtual interface 交给类访问；不能笼统地认为换成 `program` 或全部用 `<=` 就消除了所有竞争。

reset 在下降沿附近断言/释放只是本实验安排；真实芯片的异步复位同步释放与 recovery/removal 要另外设计和检查，见第 05、07 章。

### 1.5 参考队列与四态比较

[tb_channel.sv](lab/Handshake/tb_channel.sv) 用数组与 head/tail 表示期望队列。一个上升沿先检查并移除旧响应，再加入新请求的期望值，防止把同拍新请求误认为旧响应。

复位时执行“取消剩余期望事务”，并累加 cancelled。只清队列而不记录取消，会把真实丢包与合法 reset flush 混在一起。

结果比较使用 `!==`。`==`/`!=` 遇到 X 可能返回 X，而 `if(X)` 不执行 true 分支，导致错误分支没有触发。控制信号也显式检查是否为确定的 0/1。四态检查在 Icarus 执行；不要依赖二态仿真发现未初始化问题。

`$display` 在执行时打印当前值，适合错误现场与事务摘要；`$monitor` 在参数变化时于时间片末输出，容易产生大量日志；`$strobe` 适合观察当前时间片更新后的值。打印任务都不等于自动比较。错误使用 `$fatal(1,...)`，成功在检查完成后 `$finish`，并另设 watchdog。

### 1.6 实际运行

在本章 lab 下运行 `bash Handshake/run_sim.sh`。使用固定 xorshift 状态生成随机流，输入源背压时保持事务不变。保存种子、版本和代码才能复现；“同一个种子”不保证不同生成器或不同代码得到相同序列。

三个宽度各跑种子 1、17、2026；实际节选：

```text
PASS channel W=1 seed=1 accepted=200 received=199 cancelled=1 stalls=64 transfer_bins=4/4
PASS channel W=8 seed=17 accepted=173 received=172 cancelled=1 stalls=56 transfer_bins=4/4
PASS channel W=13 seed=2026 accepted=196 received=195 cancelled=1 stalls=81 transfer_bins=4/4
```

九次运行共接受 1,707 笔、输出 1,698 笔、复位取消 9 笔。每个宽度下相同种子的控制序列相同，因此这些不是九种独立随机控制分布。脚本也对三个宽度做 Verilator lint 和 Yosys 结构/无 latch 检查。

波形 `lab/Handshake/build/channel.vcd` 保留最后一次运行；观察 valid/ready、result、head/tail、held。最关键的是 out_ready=0 时旧响应不动，以及同时握手时队列仍只有至多一笔在途事务。

**速查：先定义接受/完成/取消，再写模型；波形、计数和覆盖率都应服务于规格。**

<a id="sv"></a>
## 2. SV 验证：对象、随机与覆盖率

### 2.1 为什么需要类和分层

纯模块 TB 可以验证小电路，但协议事务越来越复杂时，激励、时序与结果检查混在一个大 `initial` 中难以复用。面向对象（OOP）把事务和策略封装成类，driver 保留对时序的控制，monitor 负责观测，scoreboard 按规格比较。

[tb_objects.sv](lab/SV_Objects/tb_objects.sv) 定义 `transaction`，含 rand op/a/b、合法范围约束和 `predict()`；`corner_transaction` 继承它并把操作数进一步限制到 0 或 15。父类句柄可以引用子类对象，virtual 方法允许以后按动态类型覆盖行为；本实验的子类只增加约束，没有覆盖预测函数。

必须区分“句柄”和“对象”。`tr2=tr1` 只复制句柄，两者指向同一对象。生产者把对象放进 mailbox 后若继续改它，消费者可能看到被改写的事务。此处每笔都 `new`，发布后不再修改。复杂环境常用 clone/copy，还要考虑嵌套对象是否需要深拷贝。

### 2.2 约束随机不是随机数取模

核心片段为：

```systemverilog
rand bit [7:0] a,b;
constraint legal { a inside {[0:15]}; b inside {[0:15]}; }
// corner_transaction 中进一步要求 a、b 属于 {0,15}
```

调用 `randomize()` 是求解满足约束的赋值；必须检查返回值，否则约束冲突后旧字段仍可能被拿去驱动。`rand` 不表示均匀覆盖所有联合场景；约束关系、求解次序和工具实现都会影响分布。`dist` 可做偏置，`solve ... before` 会影响相关变量的分布，不能随意把它当成改变合法解集合。

类约束与 inline constraint 通常共同生效，并非 inline 自动覆盖类约束。例：类要求 a≤15，测试要求 a=31，会导致无解。应调试约束或明确关闭相应约束，不能忽略失败。

本实验先发送八笔定向事务覆盖所有交叉格，再发 64 笔约束随机事务，其中 32 笔使用边界子类。随机测试用于探索，定向测试用于关闭已知缺口，二者配合。

### 2.3 Mailbox、semaphore 与并发

`mailbox #(transaction)` 是类型化事务队列。容量为 2 时，生产者在队列满时 `put` 阻塞；消费者在队列空时 `get` 阻塞。它能同时传递对象和提供同步，适合 generator→driver。

`semaphore` 是资源钥匙，不承载事务。`get(1)` 获得独占权，`put(1)` 归还。本例用一把钥匙包住整个驱动任务，但只有一个消费者，所以验证了 API 的获取/释放，**没有验证多个 driver 竞争公平性**。

`fork...join` 等待两个分支都结束。`join_any` 只等一个结束，剩下的进程仍可能运行；必须有明确的停止与回收策略。`join_none` 不代表整个测试可以立即结束。错误使用这些构造，常见结果是测试提前退出或永久等待。

### 2.4 功能覆盖率与代码覆盖率

功能覆盖率（functional coverage）回答“规格要求的场景是否发生”；代码覆盖率回答“实现的语句、分支、翻转等是否被执行”。覆盖率高不代表结果正确，scoreboard 与断言仍不可少。

本例 covergroup 对三个布尔维度采样：

- op：加法或异或；
- a 是否为 0；
- b 是否为 0。

cross 有 \(2×2×2=8\) 个组合格。采样发生在响应被真正消费时，不是对象生成时，避免“生成了但没有送到 DUT”也算完成场景。另用整数计数数组逐格检查，防止仅凭一个汇总百分数宣布闭环。

对于一个均匀独立、概率为 p 的场景，N 次后一次都没遇到的概率是 \((1-p)^N\)。若 p=1/8，32 次仍未命中这个指定格的概率约为 1.39%；这是单格，不是“全部八格覆盖不足”的概率。实际约束随机不一定满足独立均匀前提，不能套公式保证覆盖。

`ignore_bins` 应对应有规格依据的无关场景，不能用于隐藏难以覆盖的有效场景；`illegal_bins` 不能代替完整协议断言。覆盖率闭环要追查：缺激励、监视器采错、约束排除、规格不可达，还是 RTL 真有 bug。

### 2.5 实测与边界

运行 `bash SV_Objects/run_sim.sh`。本机使用 Verilator 5.051 devel、`--timing --assert --trace --coverage-user`，三个种子均得到：

```text
PASS SV objects produced=72 consumed=72 cross_bins=8/8 coverage=100.0
```

总共 216 笔，每笔检查两拍反压和最终消费。`objects.vcd` 可观察整个 drive task 的节奏。100.0 只针对上述三个 coverpoint 与其 cross；没有输出完整代码覆盖率报告，也没有声称覆盖全部 8 位操作数。

GNU Make 不支持这里带空格的构建路径，脚本把编译源复制到 WSL `/tmp/ch11_objects.*`，编译后把程序放回本实验 build，退出清理临时目录。工具支持随版本变化，当前特性以本机实测为准，见 [Verilator 语言说明](https://verilator.org/guide/latest/languages.html)及[覆盖率说明](https://verilator.org/guide/latest/simulating.html)。

**速查：对象描述事务，driver 描述时间，覆盖率描述场景；三者不能相互替代。**

<a id="sva"></a>
## 3. SVA：把时间关系写成可执行规格

### 3.1 立即断言与并发断言

立即断言在过程执行到它时检查表达式，适合检查 `randomize()` 成功、函数结果或当前条件。本章对象实验用了这种方式，并通过 `--assert` 开启执行。

并发断言以采样时钟为基准表达多周期关系。主要层次是：sequence 描述事件序列，property 描述序列之间的要求，assert/assume/cover 指定检查、环境约束或可达性目标。

并发断言通常在 Preponed 区采样信号、在 Observed 区求值；它不是在 DUT 的 NBA 更新之后重新采样。理解这一点比背语法重要：在某个沿接受请求，其寄存响应在该沿 NBA 之后出现，而并发属性应在下一个采样沿看到它。

### 3.2 蕴含与延迟

`A |-> B` 的后件从前件匹配结束的同一个采样拍开始；`A |=> B` 从下一拍开始。当前件本身跨多拍时，必须从“结束拍”推导，不能总是从第一次出现 A 的拍开始数。

序列中的 `##1` 是一个采样周期，不是 1 ns；`##[1:3]` 描述一到三拍的范围。重复运算用于描述连续或非连续事件，工具支持需逐项确认。本章实际执行的属性只使用单拍前件和 `|=>`、`$past`、`$stable`，没有把未运行的复杂序列当成已验证功能。

### 3.3 输出保持属性

[channel_properties.sv](lab/SVA/channel_properties.sv) 的实际属性：

```systemverilog
assert property (@(posedge clk) disable iff(!rst_n)
  out_valid && !out_ready |=> out_valid && $stable(result))
  else $fatal(1,"FAIL SVA hold_response");
```

若第 n 拍输出有效且不能被接收，则第 n+1 拍仍必须有效、数据不变。第 n+1 拍 ready 即使已经为 1，也仍应看到原数据，直到该拍完成握手后才能更新。只在“前后两拍 ready 都为 0”时检查，会漏掉释放反压的边界。

若复位中止事务，`disable iff(!rst_n)` 取消相关检查尝试。它具有异步禁用语义，不能简单理解为一个同步采样的前件。真实复位边沿与仿真调度仍需明确。

### 3.4 数据正确、清空和组合关系

本章另外检查：

1. 输入握手之后下一采样拍 out_valid=1，result 等于上一拍输入运算结果。
2. `in_ready && !in_valid` 后下一拍 out_valid=0。
3. 每拍 `in_ready == (!out_valid || out_ready)`。

捕获属性使用 `$past(a/b/op)`，否则可能用下一笔输入去检查上一笔响应。首拍直接使用 `$past` 可能没有有效历史；本例 `$past` 在由前件启动的下一拍后件中使用，且复位禁用。更一般的属性应显式建立 past-valid 条件。

数据槽只占一拍寄存延迟，属性能直接描述它；多周期乱序模块需要保存 tag/事务身份，不能简单套“上一拍输入等于当前输出”。

### 3.5 真空通过、活性与属性归属

如果从未出现 `out_valid && !out_ready`，保持属性可以一直通过但没有真正检查后件，这叫真空通过（vacuous pass）。配套 TB 计数 launches/stalls/clears，并要求都非零；另有同拍收发 cover property。计数是非真空的基础防护，不是全部属性质量的证明。

安全性（safety）是“不发生坏事”，例如背压时数据不变。活性（liveness）是“好事最终发生”，例如请求最终完成。环境可以永远拉低 ready，因此不能无条件要求输出最终被消费；需要合理的公平性或有界响应假设。

源端 valid/data 保持是上游责任，输出保持是本 DUT 责任。本 SVA 测试为了探索槽位逻辑允许输入每拍变化，没有把源协议保证当作已经验证；第 1 节的常规 driver 则遵守保持要求。形式环境中也不能把 DUT 应保证的结论误写成 assume。

### 3.6 运行与调试

`bash SVA/run_sim.sh` 使用 Verilator 开启断言，实际结果：

```text
PASS SVA launches=27 stalls=8 clears=13
```

读 `sva.vcd` 时按采样沿标记前件与后件。失败先检查规格与采样点，再检查设计；不要为了让断言通过把 `|=>` 随意改成 `|->`。本章变异测试把加法改成减法，要求捕获属性真正报错，以防忘记启用断言而出现假 PASS。

**速查：属性必须有清楚的采样时钟、复位语义、前后件拍数和责任边界。**

<a id="uvm"></a>
## 4. UVM：把验证部件组织成可复用环境

### 4.1 UVM 解决什么问题

通用验证方法学（Universal Verification Methodology）是建立在 SystemVerilog 上的标准化类库与组织方式，适合多 IP、复杂协议和团队复用。它提供组件层次、phase、事务通信、factory、配置和报告机制；它不会自动生成正确参考模型或验证计划。

```
test
 └─ env
     ├─ active agent
     │   ├─ sequencer ← sequence 产生 sequence_item
     │   ├─ driver ── virtual interface ── DUT
     │   └─ monitor ── analysis port ──┬─ scoreboard
     │                                └─ coverage subscriber
     └─ 其他 agent / predictor / reference model
```

`uvm_component` 适用于具有父子层次、参与 phase 的长寿命部件；`uvm_object` 适用于事务、sequence、配置等数据或策略对象。Sequence 是对象，通常不固定在组件拓扑里。

主动 agent 包含 sequencer/driver/monitor，能驱动总线；被动 agent 通常只监视，用于已有主设备或系统级集成。Monitor 必须从接口的实际握手重建事务，不能仅转发 sequence “计划发送”的数据。

### 4.2 用本章通道理解完整事务路径

一笔 a=255、b=1、op=0 的事务在典型 UVM 环境中经历：

1. Sequence 创建 item，在请求仲裁后随机化/填充字段并发送给 sequencer。
2. Driver 用 `get_next_item` 获得 item，通过 virtual interface 设置引脚，等待输入握手。
3. Driver 在约定的请求完成点调用 `item_done`，释放 sequencer 的等待。
4. 输入 monitor 观测实际输入握手，发出独立事务；predictor 算出期望值 0。
5. 输出 monitor 在输出握手时观测 result；scoreboard 比较并移除期望项。
6. 在途队列排空且覆盖目标满足后，test 才允许结束。

**`item_done` 不自动等于 DUT 响应完成。** 如果 driver 在请求接受后就调用它，sequence 可以继续送下一笔，而 scoreboard 仍有待处理响应。协议中响应对象如何返回、是否使用 transaction ID，都需要环境约定。

对于乱序接口，FIFO 比较不够，需按 ID/tag 匹配，检查重复、未知 ID、丢失和超时。同一个 ID 内是否必须保序还取决于协议。不能把本章单槽队列模型直接用于多 outstanding 的 AXI 环境。

### 4.3 Phase 与结束控制

常见 phase 的分工：

- build：创建组件、取得配置；通常自顶向下建立层次。
- connect：连接 TLM 端口、export 和实现端。
- end_of_elaboration / start_of_simulation：检查拓扑、配置与准备状态。
- run：耗时任务，产生时钟交互、驱动与监视；不同组件的任务并发运行。
- extract / check / report：汇总结果、检查剩余事务和覆盖目标、报告状态。

Phase 的执行顺序和并发关系由框架管理，不是按源码文件排列。`build_phase` 是 function，不能在里面等待时钟；driver 的耗时行为应在 task phase。

Objection 用于告诉 phase 还有工作。测试开始提高 objection，完成激励并排空响应后降低；漏降会挂住，过早降低会截断 monitor/scoreboard。不能靠“再等 100 ns”替代所有事务已完成的条件。Drain time 可以辅助处理尾部活动，但不是正确完成协议的替代品。

### 4.4 Factory 与配置为什么重要

直接 `new` 固定了实际类型；通过 factory 的 `type_id::create` 创建，测试可以用 type override 或 instance override 替换实现，而不改原 env 代码。

例：普通 transaction 替换为边界事务，或者普通 driver 替换为增加随机间隔的 driver。替换类型必须兼容，override 要在目标创建之前设置；实例路径错误、目标没有注册、或原代码绕过 factory，都可能使替换失效。打印实际类型和拓扑比“宏写了就认为生效”可靠。

Factory 解决“创建什么类型”，`uvm_config_db` 解决“给组件什么配置”。virtual interface 句柄、active/passive 模式、超时等常通过配置传递。`get` 失败应明确报错；大范围通配路径可能让配置误作用到其他实例。

### 4.5 TLM、对象所有权与 reset

Analysis port 用于广播观测事务；订阅者的 `write` 是 function，不能阻塞等待。如果 scoreboard 需要耗时处理，可先进入分析 FIFO，再由任务取出处理。多个订阅者收到的可能是同一对象句柄，因此 monitor 应新建对象或按约定 clone，订阅者不应随意修改共享对象。

Reset 策略要贯穿 driver、monitor、scoreboard、coverage：正在发送的 item 是取消、重试还是完成报错？旧响应是否丢弃？本章规定 reset flush，因此 UVM 迁移时要通过 reset 事件或带 epoch 的事务统一清空策略，不能只复位 DUT 引脚。

常见工程问题：driver 等不到 `item_done` 相关协议推进；monitor 在 valid=1 但 ready=0 时重复采样；test 停止过早；scoreboard 接到同一可变对象多次；config_db 路径错误；factory override 设置太晚。它们都是环境 bug，而不是“换 UVM 就不会出现”。

### 4.6 本章实验与 UVM 的映射边界

对象实验的 generator 类似 sequence 的激励职责；mailbox 类似简化事务通道；drive task 类似 driver；predict() 和消费检查类似 reference model/scoreboard。它没有 sequencer 仲裁、UVM phase、factory、config_db、analysis port 或独立 monitor，因此**不是 mini-UVM 实现，也不能作为 UVM API 测试证据**。

本节以 [Accellera UVM 1.2 User's Guide](https://www.accellera.org/images/downloads/standards/uvm/uvm_users_guide_1.2.pdf) 的常见架构术语为教学参考，不宣称覆盖后续 IEEE 1800.2 的所有 API 差异。真实工程须固定类库版本和模拟器兼容配置。

**速查：UVM 标准化组织与复用；正确性仍依赖规格、monitor、参考模型、属性和结束条件。**

<a id="formal"></a>
## 5. 形式验证：证明的是模型中的命题

### 5.1 仿真、属性检查与等价检查

仿真观察选定输入序列；形式属性检查在模型与假设下探索所有允许行为。等价检查比较两个表示的行为是否对应，例如 RTL 与综合网表。两份实现都把加法写错但完全一致，等价检查仍可能通过，所以等价不等于符合外部规格。

有界模型检查（BMC）把前 k 步状态关系展开给求解器。若发现违反属性，给出反例；k 步内未找到，不自动证明无限时间成立。

归纳证明通常需要：初始可达区间满足属性；假设前若干步满足归纳条件，推出下一步也满足。归纳步可能遇到从未可达的状态，需要辅助不变量。增加深度不一定解决问题，结果 UNKNOWN 也不等于发现真实反例。

### 5.2 本章属性模型

[formal_channel.sv](lab/Formal/formal_channel.sv) 使用 W=4 的 DUT，输入标记 `anyseq`，每个离散时步可任意选择。只要求第一拍复位；后续输入、背压和采样到的复位均可任意变化，不假定 ready 最终为 1。

参考状态 occupied/reference_data 从事务入队、出队建立，检查：

- out_valid 与占用状态一致；
- 有效时数据等于已接受事务的期望；
- ready 组合关系；
- 非复位期间，前一拍背压的响应保持。

这里没有假设上游保持数据，也没有检查这种环境义务；DUT 只在握手时读取输入，所以更宽松输入空间仍能用于验证输出槽。模型不是物理异步边沿仿真。

异步复位 RTL 经 `async2sync` 转换为适合求解的离散模型。属性在 rst_n=1 时比较参考占用，避免把“刚被异步清空的 DUT”与“尚未在时钟沿更新的参考占用”直接比较。这是对模型采样语义的处理，不是屏蔽正常工作时的错误。亚稳态、恢复/移除时间和两次采样间的短脉冲不在证明范围。

### 5.3 Assume、assert、cover 各自回答什么

`assume` 规定合法环境，`assert` 要求实现满足规格，`cover` 要求存在一条可达轨迹。过强 assume 可以让错误路径消失，甚至使整个状态空间无解；必须审查假设，并设置有意义的 cover。

本章两个 cover 分别寻找输出背压与同拍收发。它们成功说明这些场景在约束下可达；并不表示所有状态都可达，也不表示安全属性已经证明。覆盖轨迹与反例都可生成 VCD，用 GTKWave 按周期检查。

[channel.sby](lab/Formal/channel.sby) 分开运行 prove 和 cover，深度参数为 12，求解器为 Z3。**本实验 prove 得到归纳 PASS，不只是“12 拍未发现问题”。** 证明范围仍只有固定 W=4 的模型，不能推广成所有参数的数学证明。

### 5.4 RTL 与综合网表等价

[run_sim.sh](lab/Formal/run_sim.sh) 保存规范化 RTL 为 gold，再综合另一份为 gate，建立对应点，运行 `equiv_simple` 与 `equiv_induct -seq 4`，最后 `equiv_status -assert` 要求全部证明成功。对应实验 W=8。

时序等价要明确初始状态与状态映射；本例共享同一寄存器来源并检查相应状态行为，不是“两个完全独立、任意初始状态的芯片始终输出相同”。异步单元也经过离散化处理，未证明模拟电气行为。

真实低功耗、扫描插入、retiming 或编码变换需要适当的匹配、模式与黑盒策略。黑盒过多可能让证明变弱；未证明点必须解释，不能只挑已证明点数量报告成功。

### 5.5 实际结果与追问

运行 `bash Formal/run_sim.sh`，日志包含：

```text
DONE (PASS, rc=0)
DONE (PASS, rc=0)
PASS formal W=4 safety induction + 2 covers; RTL/netlist equivalence W=8
```

两条 DONE 分别对应 prove 与 cover。完整日志在 build/prove.log、cover.log、equivalence.log；cover 轨迹在对应任务的 engine 目录。另把加法改成减法，形式检查会产生 `Assert failed` 和反例，而不是编译失败。

本章不证明“每个请求最终被消费”，因为环境可以永久背压；也没有等价性变异实验、全参数证明或多时钟模型。参见 [SBY 文档](https://yosyshq.readthedocs.io/projects/sby/en/stable/)。

**速查：PASS 必须附模型、假设、参数与证明方法；BMC 深度不是无限时间保证。**

<a id="gls"></a>
## 6. 门级仿真：功能、延迟与 X 是三件事

### 6.1 门级仿真在流程中的位置

门级仿真（gate-level simulation, GLS）使用综合网表或布局布线后的网表。零延迟 GLS 检查网表连接、复位、测试模式和功能启动；带延迟 GLS 加入单元与连线时序，帮助检查动态时序行为。

STA 不需要功能激励，适合系统检查被约束路径；GLS 只覆盖被激励到的动态行为。GLS PASS 不能替代 STA；STA 也不检查软件启动和所有功能序列。

本章将三个实验分开，避免混淆：

1. Yosys 生成通用门级网表，复用事务 testbench 做零延迟仿真。
2. 一个手写缓冲单元加手写 SDF，验证延迟反标确实生效。
3. Icarus 四态探针，展示 X 乐观与比较陷阱。

第 2 个实验不是第 1 个网表的布线后 SDF，也不是工艺库时序签核。

### 6.2 零延迟综合网表

[GLS/run_sim.sh](lab/GLS/run_sim.sh) 对默认 W=8 综合并 `write_verilog`，再用 Icarus 编译生成的网表与同一个 scoreboard。综合网表已经固化宽度，不再接受原 RTL 的 parameter override；TB 用 `NETLIST` 宏选择无参数实例。

实际输出：

```text
PASS channel W=8 seed=2026 accepted=196 received=195 cancelled=1 stalls=81 transfer_bins=4/4
```

这个结果验证了该激励下的网表功能，并与等价检查互补。网表是通用逻辑映射，没有 Sky130 等工艺库单元、时钟树和真实互连延迟。

### 6.3 SDF 反标到底做什么

标准延迟格式（Standard Delay Format）存储延迟与时序检查数据。反标需要网表层次、实例名、单元类型、端口和 timing arc 匹配，并统一时间单位。SDF 的 min:typ:max 不是自动等价于完整工艺 corner；需由生成流程定义它们的含义。

[delay_cell.v](lab/GLS/delay_cell.v) 有默认 1 ns 的 specify 路径；[delay.sdf](lab/GLS/delay.sdf) 将输入 A→输出 Y 的上升/下降延迟写成 `(2:3:4)` ns，`-Ttyp` 选择 3 ns：

```verilog
specify
  (A=>Y)=(1,1);
endspecify
```

Testbench 调用 `$sdf_annotate`，编译启用 `-gspecify`。输入翻转 2 ns 后要求输出仍为旧值，3.1 ns 后要求已更新；上升下降各检查一次：

```text
PASS SDF typ=3ns rise/fall measured between 2ns and 3.1ns
```

这是一个时间窗口检查，没有测到无限精度的“正好 3 ns”。删除反标后默认 1 ns 会导致过早改变，测试必须失败，因此不会仅凭“日志没报错”推断反标成功。

若实际工程出现 SDF warning，应检查未匹配实例、被优化层次、条件 arc、单元模型、timescale、corner 和路径类型，不能盲目忽略。

### 6.4 Timing check 与工具边界

标准单元模型可能含 `$setuphold`、`$recrem` 等检查，并通过 notifier 影响输出。违例后的 X 行为取决于单元模型与模拟器，不是所有逻辑违例都会自动产生 X。

当前 Icarus 的 timing-check 支持存在限制，不能把本例 IOPATH 成功等同于 setup/hold 检查已执行，见 [Icarus SDF 跟踪说明](https://github.com/steveicarus/iverilog/issues/943)。本章没有用它宣称完成时序违例检测，也没有验证脉冲过滤、条件 arc、互连延迟或全 corner。

### 6.5 X 乐观、X 悲观与未初始化状态

[tb_x.sv](lab/GLS/tb_x.sv) 将 sel 置 X，比较两个写法：

- `if(sel) y=1; else y=0;`：sel 不为确定真，走 else，输出 0，可能掩盖未知控制，这称为 X 乐观的一种表现。
- `sel ? 1'b1 : 1'b0`：两分支不一致，合并得到 X，保留不确定性。

`if(result != expected)` 可能在比较结果为 X 时漏报；本章验证 `!==` 能明确发现差异：

```text
PASS X probe: if masks X, ternary merges X, !== detects mismatch
```

X 悲观则可能把真实电路中有关联的未知信号当作彼此独立，从而传播出过多 X。遇到 X 应追查第一源头：未复位寄存器、未初始化 RAM、非法控制、总线冲突或时序 notifier。把所有寄存器强制初始化为 0 可能掩盖真正的启动错误。

二态随机初始化可帮助探索不同初态，但不等价于四态 X 传播；四态仿真也不能模拟亚稳态的模拟电压过程。商业 xprop 模式有其语义和限制，不能仅凭 RTL 的 if 示例推断某工具模式行为。

### 6.6 实验观察与速查

运行 `bash GLS/run_sim.sh`。build/channel.vcd 是网表事务轨迹；delay.vcd 检查 A/Y 的延迟窗口；x.vcd 检查 sel、optimistic、merged。

**速查：零延迟网表看功能，SDF 看已支持的延迟语义，四态仿真看未知传播；三者都不能代替 STA 和物理签核。**

<a id="regression"></a>
## 7. 整章回归、故障注入与学习边界

### 7.1 一键运行与产物

在 PowerShell 中执行：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/11_Verification/lab' && bash run_all.sh"
```

脚本加载 `/root/oss-cad-suite/environment`。Icarus 承担四态与 SDF 仿真，Verilator 承担类/随机/covergroup/SVA，Yosys 与 SBY/Z3 承担结构、综合与形式检查。全部 EDA 在 WSL 运行。

每组 build 存放编译日志、运行日志、VCD 或证明结果；根 build 存放变异检查，可将整章输出重定向为 build/regression.log。生成物受仓库忽略规则保护。普通仿真的 VCD 保留该脚本最后一次运行，不是所有种子的合集。

### 7.2 用错误验证检查器

[check_mutations.py](lab/check_mutations.py) 在隔离目录运行七种错误：

1. 加法改减法：scoreboard 必须检出。
2. 背压时仍更新槽：保持检查必须检出。
3. 输出 valid 永远为 0：完成性/场景检查必须失败。
4. 复位后 valid=1：异步复位检查必须失败。
5. 加法改减法：独立要求 SVA 捕获属性失败。
6. 加法改减法：独立要求形式属性给出反例。
7. 删除 SDF 反标：延迟窗口检查必须失败。

编译错误和超时不计为成功检出。变异覆盖的是这些选定错误，不是测试质量的完整证明；等价变异、没被激活的变异和错误的 checker 仍需要人工分析。

实际整章回归末尾：

```text
PASS mutation caught: wrong_add
PASS mutation caught: overwrite_stall
PASS mutation caught: drop_valid
PASS mutation caught: bad_reset
PASS mutation caught: sva_capture
PASS mutation caught: formal_capture
PASS mutation caught: missing_sdf
PASS verification mutations: 7/7
PASS Chapter 11: Handshake + SV_Objects + SVA + Formal + GLS
```

### 7.3 如何把实验发展成工程验证计划

扩展 DUT 前先同步扩展规格：若加入 ID，就检查匹配与顺序；若加入多拍运算，就定义延迟/吞吐范围；若加入错误响应，就定义取消、重试与完成规则；若加入多时钟或低功耗，就增加 CDC/RDC 与电源状态专用验证。

回归失败应保留：代码版本、工具版本、种子、参数、首个失败时间、相关事务和最短复现。先区分 DUT bug、参考模型 bug、环境竞态和规格歧义，修复后添加能锁住该错误的回归，而不是只增加随机运行时长。

本章覆盖全部六个总纲主题，并实际验证五组教学实验；UVM 仅为架构讲解。未执行 UVM 类库、商业仿真器、完整代码覆盖率闭环、乱序/多时钟形式证明、真实工艺库带 SDF 全芯片 GLS、timing-check 签核或任意参数证明。
