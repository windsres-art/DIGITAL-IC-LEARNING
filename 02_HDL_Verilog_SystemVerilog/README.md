# 第 02 章：Verilog / SystemVerilog —— 从语句读出硬件

- **从什么问题开始**：Verilog 看起来像程序，为什么行为却不像逐行执行的程序？先把语句对应到导线、选择器和触发器，再看数据如何在时钟沿更新。

- **RTL 是什么**：register-transfer level，即寄存器传输级。用寄存器保存状态，用组合逻辑计算下一份数据。

- **学完要能做什么**：读一小段 RTL，画出大致电路，并手算时钟沿前后的数值。在这个基础上，再掌握语法例外和工具规则。

- **当前进度：总纲全部七节已完成，配套六组实验与面试问答。** 基础 RTL 以 Verilog-2001 风格为主，参数实验用到 Verilog-2005 的 `$clog2`；SV 设计实验使用 `.sv`。自检查 testbench 也使用 `.sv`，便于使用 `$fatal`。

- 使用 `-g2012` 编译不意味着所有设计都必须写成 SystemVerilog。

- **前置知识**：[第 01 章目录](../01_Digital_Logic_Fundamentals/)中的二进制、补码、MUX、DFF（该章正文尚待编写）。至少先知道：组合逻辑输出由当前输入决定，触发器在时钟沿保存数据。时序物理约束另见 [STA](../07_STA/README.md)，复位电路另见 [时钟与复位](../05_Clock_Reset_Design/README.md)。

- **建议顺序**：1.1–1.4 → 跑 Expressions → 1.5–1.8 → 第 2 节 → 跑 Scheduling → 第 3 节 → 第 4–7 节及对应实验 → [面试问答](INTERVIEW_QA.md)。第一次不要同时学习复杂协议；先能手算两级流水线，再读 [常用电路](../03_Common_Circuits/README.md)。

- **仿真**：给电路送输入，观察输出是否符合预期。
- **Lint**：不送测试激励，先从代码中寻找位宽、驱动等可疑写法。
- **综合与结构检查**：把 RTL 转成门和寄存器的连接，检查实际生成了什么电路。先分清这三类检查的用途，再学具体命令。

## 目录

1. [Verilog 语法](#s1)（已完成）
2. [阻塞与非阻塞赋值](#s2)（已完成）
3. [仿真事件调度](#s3)（已完成）
4. [可综合编码风格](#s4)（已完成）
5. [参数化与 generate](#s5)（已完成）
6. [SystemVerilog 设计特性](#s6)（已完成）
7. [常见编码陷阱](#s7)（已完成）
8. [运行入口与验证边界](#labs)
9. [面试前速查](#quick)

<a id="s1"></a>
## 1. Verilog 语法

### 1.1 先理解并行，再看模块和端口

- 硬件描述语言（Hardware Description Language，HDL）描述并行电路。模块（module）是电路边界，端口是连接，实例化是放入一份子电路。两个 `assign`、两个 `always` 或两个实例之间，没有“写在上面所以先执行”的保证。

- 可以先想象两块已经接好线的电路：一块算加法，另一块做比较。输入变化时，两块都会响应，不需要等“加法这一行执行完”才轮到比较。HDL 文件的上下排列主要方便人阅读；真正决定依赖关系的是连线。一个 `always` 内部的语句顺序则有意义，我们到第 2 节再展开。

- **MUX（多路选择器）**：根据选择信号，把某一路输入接到输出。
- **DFF（D 触发器）**：在指定时钟沿，把 D 端的数据存到 Q 端。
- 读后面的例子时，先分清两个动作：组合电路负责“算”，触发器负责“记住”。

- 本章的 [expr_datapath.v](lab/Expressions/expr_datapath.v) 是一个参数化组合数据通路：

```verilog
module expr_datapath #(parameter W = 8) (
    input wire [W-1:0] a, b,
    input wire signed [W-1:0] sa, sb,
    output wire [W:0] sum,
    // 其它端口见完整文件
    output wire signed_lt
);
    assign sum = {1'b0, a} + {1'b0, b};
    assign signed_lt = sa < sb;
endmodule
```

- 这是讲解节选，完整可运行源文件以链接为准。`a/b` 与 `sa/sb` 是两组独立输入，不是自动互相转换的别名；TB 给它们相同的位模式，是为了对比不同数值解释。

- 读模块声明，先抓三件事：

  - **方向**：`input/output` 表示数据从哪里进、从哪里出。
  - **位宽**：`[W-1:0]` 从第 W−1 位到第 0 位，共 W 位。
  - **默认配置**：`parameter W=8` 表示默认做成 8 位宽的电路。
- **TB（testbench）**：仿真中给电路送输入、检查输出的测试程序。

```
a,b   ──► 零扩展 ──► 无符号加法 ──► W+1 位 sum
sa,sb ──► 符号扩展 ► 有符号加法 ──► W+1 位 signed_sum
sa,sb ─────────────► 有符号比较 ──► 1 位 signed_lt
sa    ─────────────► 算术右移   ──► W 位 shifted
```

- 推荐命名端口连接 `.a(a)`，不要靠端口位置记忆。实例参数覆盖写 `.W(4)`；参数是在展开（elaboration）时确定的，不是运行中的配置寄存器。

- 漏接端口、拼错信号名可能造成悬空或隐式 1 位线网，因此设计文件使用 `` `default_nettype none``，末尾恢复 `` `default_nettype wire``，避免污染其它源文件。

- 读 `.a(source_data)` 时，点后面的 a 是子模块声明的端口名，括号里的 source_data 是外层接给它的信号名；二者不必同名。模块定义像电路图模板，实例化才是在上层放入一份具体电路。

- `assign` 表示持续维持左右两边的组合关系：右侧输入变化，左侧就重新求值；它不是启动时只赋一次值。

### 1.2 wire、reg 与四态

- **`wire`**：线网类型（net），表示连接及驱动解析结果。Verilog 中的连续赋值 `assign` 和子模块输出通常连接它。
- **`reg`**：过程变量，可在 `always/initial` 中赋值，保存最近一次过程赋值的结果。
- **判断硬件看过程**：`reg` 不等于触发器，`wire` 不等于组合逻辑。实际电路由赋值方式和触发条件决定。

- 先看 `always` 在什么时候执行：

  - **`@*`**：相关输入变化时重新计算，适合组合逻辑。
  - **`posedge clk`**：时钟从 0 变成 1 时执行，适合触发器。
  - **`negedge rst_n`**：复位从 1 变成 0 时也立即执行；后缀 `_n` 提醒我们“低电平有效”。
- 同样声明为 reg，触发条件不同，描述的硬件就不同。

```verilog
reg y;
always @* begin
    y = sel ? a : b;  // 每种输入条件都赋值，描述组合 MUX
end

reg q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) q <= 1'b0;
    else        q <= d;  // 边沿触发，描述带异步复位的触发器
end
```

- 这里是独立语法片段，`a/b/d` 等假定为单 bit 已声明信号。若组合过程有路径没有给 `y` 赋值，它需要保留旧值，可能推断锁存器（latch）；并不是因为声明了 `reg`。

- 锁存器与触发器都能记住数据，区别在于什么时候接收新数据：锁存器在使能有效的整段时间内让输出跟随输入，关闭后保持；触发器只在指定边沿采样。第 7.2 节会用缺少赋值的例子推导这种“打开时跟随、关闭时保持”的行为。

- Verilog 常用的四态（4-state）是 `0/1/x/z`：

  - `x`：未知，可能来自未初始化、驱动冲突或未知输入传播。它不是物理芯片里的“第三个稳定电平”，也不是亚稳态模拟器。
  - `z`：高阻，无有效驱动的含义；片内三态能否实现取决于技术和流程，不应把 `z` 当作普通数据。
  - 未初始化的过程变量通常是 `x`；未驱动的普通 `wire` 通常为 `z`。有多个驱动时线网按规则解析，变量不能因此被当成可任意多写的寄存器。
  - `integer` 是有符号整数类型，适合 TB 计数和循环；数据通路最好显式声明位宽。`real/time` 常用于仿真，不用于本章可综合数据通路。

- 向量与存储器也要分清：

```verilog
reg [7:0] data;        // 一个 8 bit 向量
reg [7:0] mem [0:15];  // 16 个 8 bit 元素；不承诺综合成 SRAM 宏
```

- `data[3]` 是一位，`data[7:4]` 是固定范围切片，`data[base +: 4]` 是起点可变、宽度固定的索引切片。动态选择通常需要 MUX，不是“免费数组访问”。RAM 实现和读写模式见 [第 03 章](../03_Common_Circuits/README.md)。

- 这里 `+:` 的含义是从 base 开始，向编号增大的方向取四位。对上述 `[7:0]` 向量，base=0 时取 `[3:0]`，base=4 时取 `[7:4]`；不是把 base 的数值加上 4，也不是取四个数组元素。

### 1.3 常量与运算符：先判断结果有几位

- 先学会读常量的写法：`位宽'进制数字`。b、d、h 分别代表二进制、十进制、十六进制；十六进制的 a 到 f 代表 10 到 15，每一位对应四个二进制位。因此 `8'b11111111`、`8'd255`、`8'hff` 是同一份八位数据。

- 进制决定怎样把数字写短，signed 则决定怎样解释最高位，两者是不同的问题。

- `8'hff` 是 8 位十六进制无符号数 255；`8'shff` 是同一位模式按 signed 解释的 −1。`8'sd127` 是 +127；`-8'sd1` 是对有符号常量 1 取负，负号是运算符。裸写 `1` 是无显式位宽的十进制有符号常量，不能把它当成 1 bit。

- 工程上尽量给数据通路常量明确位宽。`{W{1'b0}}` 是复制 W 次的全零向量；`{a,b}` 是拼接，高位在左。拼接的每项要能确定宽度，不要写 `{1'b0, 1}`。

- 运算符按用途理解：

  - `+ - * / %`：算术。结果不会自动具有数学上无限精度；一般除法和乘法可能很贵，常数除法可被优化，不能从符号直接断定门数。
  - `& | ^ ~`：按位操作；一元 `&a`、`|a`、`^a` 是归约（reduction），将整个向量压成一位。
  - `&& || !`：逻辑判断，结果一位。例如 `4'b0010 & 4'b0100 = 0000`，但 `4'b0010 && 4'b0100 = 1`，因为两个操作数都非零。
  - `< <= > >= == !=`：比较，结果一位；这里的 `<=` 在表达式里是“小于等于”，在过程赋值位置是非阻塞赋值。
  - `<< >> <<< >>>`：移位；右移是否补符号位要同时看运算符与左操作数的 signed 属性。
  - `cond ? a : b`：条件选择；两分支的位宽和符号也会参与结果类型决定。

- 复杂表达式加括号，不靠记忆优先级。例如用 `(a == b) && valid`；把“比较、与、移位”挤在一行容易把正确的电路意图写成另一个表达式。

- 归约可以直接手算：a=`4'b1011` 时，`&a` 是 `1&0&1&1=0`，`|a` 是 `1|0|1|1=1`，`^a` 是 `1^0^1^1=1`。异或归约等于检查 1 的个数是否为奇数，所以后文用它产生 parity（奇偶校验）位。

### 1.4 位宽：截断、上下文与自决定位宽

- “位宽”就是为一个数准备了多少个二进制位置。纸上计算可以随时在左边多写一位，电路中的一条 8 位总线却只有八根数据线。超出的第九位要么另接一根线保存，要么丢掉；后面的规则都在回答“这一步究竟用了几位”。

- W 位无符号数范围为 `0 .. 2^W−1`；两个最大值相加为 `2^(W+1)−2`，所以完整和需要 W+1 位。只留下低 W 位等价于对 `2^W` 取模。以 8 位为例：255+1=256=`9'h100`，截成 8 位就是 0。

- “取模”在这里就是取除以 `2^W` 后的非负余数：256 除以 256 余 0，257 余 1。这解释了为什么固定宽度的计数器数到最大值后会回到 0，也就是回绕。后文出现没有进制前缀的日志值时，要留意显示格式；例如本节实验日志的 `context_sum=100` 使用十六进制，表示十进制 256。

- 但不能把规则背成“两个 8 位相加一定先按 8 位算”。Verilog 有上下文决定位宽（context-determined）和自决定位宽（self-determined）：

```verilog
wire [8:0] context_sum = x + y;
wire [8:0] concat_sum  = {x + y};   // x、y 均为 8 位
```

- 第一行的赋值上下文使此处加法按 9 位求值；第二行拼接内的加法按自身操作数确定为 8 位，先丢进位，再扩展到 9 位。**括号 `(x+y)` 只是分组，不等于拼接 `{x+y}` 的宽度边界。**

- 本章可复用 RTL 不依赖读者记住这些传播细则，而是直接写：

```verilog
assign sum = {1'b0, a} + {1'b0, b};
assign sum_wrap = sum[W-1:0];
```

- 同理，乘法不能想当然得到双倍位宽；若需完整乘积，要明确结果宽度、操作数扩展和 signed 属性，再用边界向量验证。比较和归约结果是一位；拼接总宽度等于各项宽度之和；移位不会因为移位量大就自动保留所有移出的高位。

- **推导顺序：标注每个操作数的位宽/符号 → 确认上下文与自决定位宽边界 → 扩展后计算 → 检查最终赋值截断。** 仅看左边声明够宽，不保证内层表达式没有先损失信息。

### 1.5 符号：相同 bit，不同整数

- W 位补码范围为 `−2^(W−1) .. 2^(W−1)−1`。本实验用独立整数模型解释输入：当无符号位模式 `i >= 2^(W−1)` 时，有符号值是 `i−2^W`。

- 例如四根线都是 1，位模式就是 `1111`。按 unsigned 解释，它是 8+4+2+1=15；按四位补码解释，最高位权重为 −8，结果是 −8+4+2+1=−1。线上的 bit 没变，变的是解释规则。因此谈“这个数是正还是负”之前，要先确认位宽和 signed 属性。

- 扩展时，无符号补 0，有符号复制最高符号位。例如 `8'hff` 扩展为 `16'h00ff`，signed 的 −1 扩展为 `16'hffff`。但**完整向量切片即使覆盖全部位，也不保留原向量的 signed 属性**：

```verilog
reg signed [7:0] sx;
wire [15:0] signed_ext = sx;       // sx=-1 → ffff
wire [15:0] slice_ext  = sx[7:0];  // sx=-1 → 00ff
```

- 对本章的算术/关系表达式，混用 signed 与 unsigned 往往使运算按 unsigned 处理。`sx=-1`、无符号 `y=1` 时，`sx < y` 为假，因为 8 位的 `ff` 被当成 255。

- 正确修复要先明确数据含义：如果 y 本来是 0..255 的无符号数，直接 `$signed(y)` 会把 128..255 解释成负数。应先扩成共同的 9 位域：

```verilog
$signed({sx[7], sx}) < $signed({1'b0, y})
```

- `$signed` 改变解释类型，不自动增加位宽；拼接本身是 unsigned，因此符号扩展后再强制转换的写法最直观。

- 完整 signed 加法也需要 W+1 位。本 RTL 用两个显式的 signed 扩展操作数产生 `signed_sum`。有符号溢出与无符号进位是两件事：

```verilog
assign overflow = (sa[W-1] == sb[W-1]) &&
                  (signed_sum[W-1] != sa[W-1]);
```

- 为什么看 `[W-1]`？这是**截回 W 位后的符号位**，不是完整 W+1 位和的符号位。4 位例子：7+1=8，截断为 `1000`（−8），同号输入变成异号结果，所以溢出；−1+1=0 虽有无符号进位，但无 signed 溢出。

### 1.6 移位与 X 传播

- `>>` 补零；signed 左操作数的 `>>>` 复制符号位。unsigned 左操作数使用 `>>>` 仍补零。`sx=-1` 时，`sx >> 1` 的 8 位结果为 `7f`，`sx >>> 1` 为 `ff`。signed 的 −3 算术右移一位为 −2，而整数 −3/2 向零截断得到 −1：不能把二者无条件互换。

- 四态值参与比较时：

```verilog
4'b10x1 ==  4'b1001  // x：无法决定是否相等
4'b10x1 === 4'b1001  // 0：把 X/Z 也当成要逐位比较的值
```

- `==` 不保证遇到 X 就一定输出 X：其它已知位已经能证明不等时可以输出 0。`===/!==` 总给确定的 0/1，适合 TB 精确检查；不要把设计中的 X 当成能在普通硬件里检测的稳定状态。

- 为什么自检查用 `if (condition !== 1'b1)`？若用 `if (!condition)`，condition 为 X 时，`if` 不进入真分支，反而可能漏报。

- 条件表达式也有差别。单 bit 条件为 X 时：

```verilog
merged = decision ? 4'b1010 : 4'b1000;  // 10x0：同位相同保留，不同为 X
if (decision) merged = 4'b1010;
else          merged = 4'b1000;        // 1000：if 的未知条件不当成真
```

- 这叫 X 乐观问题的一种表现：仿真给出看似确定的结果，不代表物理选择信号已知。四态仿真帮助发现初始化等问题，但不能模拟模拟电压、亚稳态持续时间或完整的门级 X 行为。

### 1.7 实验：穷举，不能只试 1+1

- 运行方法见[统一入口](#labs)。[tb_expressions.sv](lab/Expressions/tb_expressions.sv) 对 W=2/4/8 分别穷举所有输入对，每对检查完整无符号和、模截断和、完整 signed 和、算术右移、signed 比较、溢出，共六项。参考答案用整数算术和取值范围计算，不照抄 RTL 的溢出位表达式。

- WSL 实测输出节选（2026-10-20；三个配置各运行一次固定语义探针）：

```text
width: context_sum=100 concat_sum=000 signed_ext=ffff slice_ext=00ff
signed: mixed_lt=0 fixed_lt=1 logical_shift=7f arithmetic_shift=ff
PASS expressions W=2 pairs=16 checks=111
PASS expressions W=4 pairs=256 checks=1551
PASS expressions W=8 pairs=65536 checks=393231
PASS Expressions: RTL lint + synthesis structure + 3 simulations
```

- 看波形优先打开 `build/w4/expressions.vcd`，添加 `a/b/sa/sb/sum/sum_wrap/signed_sum/overflow/shifted`，把 signed 信号显示为有符号十进制。

- 检查 7+1 和 −8+(−1) 的溢出、15+1 的无符号回绕。定向语义探针在穷举之后，因此要看 `context_sum/concat_sum` 的差异应跳到结尾。

- 改 W 时，RTL 要求 W≥2；TB 为控制穷举开销限制 2≤W≤8。8 位 65,536 对，16 位则超过 42 亿对，需要定向边界 + 随机/形式方法，不能机械扩展穷举。

### 1.8 面试要点

- 面试官给出“8 位加法为何丢进位”，先确认表达式上下文，不要直接答“加法器不够宽”。给出“负数比较错误”，先看 signed 声明、切片和拼接有没有丢类型，再检查另一操作数。问 `reg` 是否一定综合成寄存器，要从过程触发方式和赋值覆盖回答。

- **一句话：HDL 运算的是有限宽 bit 向量，数值解释、求值宽度和最终截断缺一不可。**

<a id="s2"></a>
## 2. 阻塞与非阻塞赋值

### 2.1 区别在更新时机，不在“是否生成寄存器”

- 无延迟阻塞赋值（blocking assignment）`a = b`：执行到该语句时读取 b，更新 a，再执行本过程的下一条语句。

- 无延迟非阻塞赋值（nonblocking assignment，NBA）`a <= b`：执行到语句时读取 b，安排稍后在 NBA 区域更新 a，本过程立即继续。**不是到下一周期才更新，也不是等到更新时才读 RHS。** RHS 是 right-hand side，LHS 是 left-hand side。

- 组合过程推荐 `=`，因为后面的中间计算应读到刚算出的结果；时序状态推荐 `<=`，因为物理触发器在同一沿采样各自沿前的输入。

- 可以把 `<=` 理解为“先记下这次要写入的值，稍后统一提交”。例如旧 q1=0、d=11，执行 `q1<=d; q2<=q1;` 时，先记下 q1 要写 11、q2 要写旧的 0；两项提交后，q1=11、q2=0。下面的两级流水线就是这个过程。这里“稍后”仍在同一仿真时间片，不是再等一个时钟周期。

### 2.2 两级流水线：用状态方程解释

- 可综合源文件：[pipeline.v](lab/Scheduling/pipeline.v)。默认低有效异步复位，en=0 保持。

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        q1 <= {W{1'b0}};
        q2 <= {W{1'b0}};
    end else if (en) begin
        q1 <= d;
        q2 <= q1;
    end
end
```

- 记 `Q[k]` 是第 k 个有效时钟沿更新后的状态：

```text
en=1：Q1[k] = D[k]，Q2[k] = Q1[k−1]
en=0：Q1[k] = Q1[k−1]，Q2[k] = Q2[k−1]

              上升沿1       上升沿2       上升沿3（停顿）
en               1             1              0
d               11            22             99
沿后 q1         11            22             22
沿后 q2          0            11             11
```

- 这是两级寄存器，数据从第一次被 q1 采入到被 q2 采入相隔一个有效推进间隔；若 en 连续为 1，就是一个时钟周期。讲延迟要先明确从哪个事件开始计数，不能把“两个寄存器”机械等同于“采入以后再等两拍”。

- 时序过程没有 `else q1 <= q1` 也会保持，综合得到带使能寄存器或等价反馈 MUX。组合过程漏赋值则意味着锁存器，两种情况不能混淆。

### 2.3 典型错误与同过程顺序

- 下面的反例仅在 TB 中存在，不作为生产 RTL：

```verilog
else if (en) begin
    bad1 = d;
    bad2 = bad1;
end
```

- 第二行读到的是刚更新的 bad1，因此 `bad2` 同拍获得 d。虽然仍在时钟沿赋值，功能已经不是两级流水线，综合可能合并相同状态。反过来写 `bad2=bad1; bad1=d;` 在单一过程内可能得到移位行为，但依赖语句次序，跨过程读取仍容易竞争，因此状态统一用 NBA。

- 两个 NBA 若在**同一过程、同次执行**中按顺序写同一变量，后执行的赋值生效：

```verilog
q <= 8'h11;
q <= 8'h22;  // 本次最终为 22，不是随机二选一
```

- 这可用于“默认保持、条件覆盖”，也可能隐藏优先级错误；多个 `if` 不是天然互斥。若两个不同 `always` 同时给 q 安排 NBA，则没有这个单过程顺序保证，而且属于应避免的多驱动。

- 阻塞和非阻塞不是在一个模块里不能并存：组合 always 用 `=`、时序 always 用 `<=` 正常。时序过程内使用仅作中间运算、先写后读、不承担跨拍状态的阻塞临时变量可以成立，但基础学习先分开组合计算与寄存器更新。同一状态变量不要混用两种赋值方式。

### 2.4 实验与波形

- [tb_scheduling.sv](lab/Scheduling/tb_scheduling.sv) 用独立的旧状态快照更新参考模型，在下降沿驱动输入，在上升沿后的 `#1` 检查更新结果。32 个周期包括连续输入和每四次一次的停顿；启动与运行中都检查非时钟沿的异步复位。

- **真实输出**：

```text
PASS scheduling cycles=32 blocking_differences=24
PASS Scheduling: RTL lint + 2 register banks + simulation
```

- 24 次是本次固定激励中阻塞反例与正确 q2 不同的次数，不是“所有输入都会不同”。若连续输入相同，错误流水线也可能暂时表现相同，这就是不能只用常量刺激的原因。

- `build/scheduling.vcd` 中观察 `clk/rst_n/en/d/q1/q2/bad2`：15 ns 后 q1=11、q2=0、bad2=11；25 ns 后 q1=22、q2=11、bad2=22。en=0 时 q1/q2 都保持。

- Yosys 检查默认 W=8 的正确设计包含两个 `$adffe` 向量寄存器单元（每个 8 位），不是只有两个 1 bit DFF；未做技术映射和时序签核。

- **一句话：时序 NBA 让每级读旧状态、统一更新；组合阻塞赋值让下一语句读到本次计算的新值。**

<a id="s3"></a>
## 3. 仿真事件调度

### 3.1 为什么在同一个时间戳能看到不同值

- 仿真器是离散事件模拟器（discrete-event simulator）。一个仿真时间片（time slot）内部可以执行多轮零时间事件。没有推进物理时间，不代表所有信号已经稳定。

- 例如到了 15 ns，时钟先出现上升沿，触发器过程读输入并安排更新，寄存器更新后又使后面的组合逻辑重新计算。这些事情在仿真器里需要有先后安排，但时间标签都可以仍然是 15 ns。“事件区”就是仿真器整理这些待办事项的规则。先沿着下面的箭头看一次，不必一开始就背完整区域名称。

- 对本章 module RTL/TB，先掌握以下简化模型；它不是完整 SystemVerilog 区域表：

```text
当前时间 t
  Active：执行被触发的过程、无延迟阻塞赋值、计算 NBA 的 RHS、$display
     ↓ 当前活跃事件处理后
  Inactive：module 中 #0 挂起的过程继续
     ↓ 前面待处理的相关事件排空后
  NBA：应用非阻塞更新
     └── 信号变化可触发更多 Active / 后续迭代，仍可能在同一个 t
  Postponed：$strobe / $monitor 等观察本时间片最终值
     ↓ 当前时间片稳定后
  下一个有事件的时间
```

- 同一区域内不同过程的先后通常不应依赖。NBA 更新触发组合逻辑后，组合输出还要再求值，因此图不是“每层永远只过一次”。

- SystemVerilog 的 assertion、clocking block、program 等还涉及 Preponed、Observed、Reactive 等区域；完整验证调度留待第 11 章，不能把上图用于推断所有 SV 验证构造。

### 3.2 逐步推导 15 ns 的流水线

- 上升沿前 q1=q2=0，d=11、en=1 已在 10 ns 下降沿稳定：

1. 15 ns 时钟变为 1，DUT 和观察进程被触发。
2. DUT 执行 `q1<=d`，记下“给 q1 写 11”；执行 `q2<=q1`，此时 q1 仍是 0，记下“给 q2 写 0”。
3. 观察进程的 `$display` 看到旧 q1/q2。两进程谁先执行都不影响这个结论，因为 DUT 尚未在 Active 改状态。
4. 观察进程 `#0` 后在 Inactive 继续，此时仍早于这些 NBA 更新，仍读到旧值。
5. NBA 更新 q1=11、q2=0；相关组合逻辑若存在会被触发。
6. `$strobe` 在时间片末打印最终值，时间戳仍为 15 ns。

- 真实日志：

```text
ACTIVE t=15000 d=11 q1=0 q2=0
INACTIVE t=15000 q1=0 q2=0
POSTPONED t=15000 q1=11 q2=0
ACTIVE t=25000 d=22 q1=11 q2=0
INACTIVE t=25000 q1=11 q2=0
POSTPONED t=25000 q1=22 q2=11
```

- TB 声明 `` `timescale 1ns/1ps``：`#1` 是 1 ns，精度为 1 ps；本次 `%t` 默认显示单位为 ps，因此 15000 对应 15 ns。这不是 15000 ns，也不是 NBA 增加了时间。

- VCD 主要记录时间戳与信号变化，并不完整表达 Active/Inactive/NBA 区域。同一时间戳内的旧值/新值关系，应结合日志和语言规则理解，不能只凭波形显示器最后画出的电平断定执行次序。

### 3.3 竞争条件：不是“偶尔才有”的物理问题

- 竞争（race）是当合法执行顺序不唯一时，结果依赖于该顺序。典型 TB 错误：

```verilog
always @(posedge clk) d = next_d;   // TB：与 DUT 同一沿写
always @(posedge clk) q <= d;      // DUT：同一 Active 区域读
```

- 若 TB 先运行，DUT 采到新 d；反之采到旧 d。某个仿真器连续一百次得到同一结果，也不能证明不存在竞争。不要靠交换文件顺序或“本机一直能过”解决。

- 本章做法是下降沿驱动、下一上升沿采样；时钟周期 10 ns，输入留了 5 ns 仿真间隔。采样后 `#1` 再核对输出，明确避开 NBA 尚未更新的窗口。

- 这里 `#1` 是**零延迟 RTL TB 的观察方法**，不是真实芯片的 clk-to-Q，也不是适用于任意周期、门级延时的通用方案。更系统的同步采样可以用 clocking block 等验证机制，后续再讲。

- `#0` 不是“等待所有信号稳定”：它到 Inactive，仍在当前 NBA 前。不断加 `#0` 也不是可靠的跨进程同步协议。`<=` 同样不能消灭所有 race：多个写者、同沿 TB 驱动、错误的采样区域仍可造成问题。

- 本实验没有把某次不确定的竞争输出包装成固定答案：测试的是无竞争 RTL 的确定语义。阻塞反例故意放在同一过程，使流水线退化可稳定复现。

### 3.4 延迟、时间单位与仿真/硬件边界

- 理解以下三种写法即可，不要放进本章设计 RTL：

```verilog
#5 q = d;   // 等 5 个时间单位，然后读取 d 并阻塞赋值
q = #5 d;   // 现在读 d，过程挂起，5 个单位后写 q
q <= #5 d;  // 现在读 d，安排 5 个单位后的 NBA 更新，过程继续
```

- 无论 `#5` 是否被某综合器忽略，都不能把它当成通用可综合延时电路。需要延迟几个周期，用寄存器/计数器表达，并受时钟驱动；需要物理传播延时，用库、STA 和后端实现分析。

- `initial` 在 TB 中生成时钟、复位、激励、dump 和结束条件是正常的；本仓库 ASIC 设计逻辑不靠 `initial` 上电初始化。部分 FPGA 流程支持初始化，不代表可以无条件迁移到 ASIC。

### 3.5 追问与速记

- “为什么波形 q 已经更新，`$display` 却还是旧值？”——日志调用发生在更新前，波形显示的是时间片内更新后的状态。

- “NBA 是并行执行所有语句吗？”——过程内语句仍顺序执行，只是 RHS 当场采样、LHS 延后更新；不能据此给多写者建立确定次序。

- “把 `#1` 加到 RTL 能修 timing 吗？”——不能；仿真调度与 setup/hold 是两个层次。前者决定模型怎样求值，后者约束物理电路能否正确采样。

- **一句话：先定位驱动与采样属于哪个事件区域，再判断读的是旧值还是新值；时间戳相同并不意味着观察时机相同。**

<a id="s4"></a>
## 4. 可综合编码风格

### 4.1 从“仿真会运行”到“工具能建立电路”

- 综合（synthesis）需要把行为转换为有限的组合逻辑与存储元件。能被仿真器执行，不等于能综合；能综合，也不等于面积、时序和功能符合需求。

- 比较两种“重复十次”：

```verilog
// 概念片段：这是同一轮组合计算的 10 项 XOR，不是等 10 个时钟。
always @* begin
    parity = 1'b0;
    for (i=0; i<10; i=i+1) parity = parity ^ data[i];
end
```

- 循环边界为编译时常量，工具可以展开成固定组合电路。若希望每拍处理一个 bit、十拍得到结果，需要计数器、状态机和寄存器。运行时无界的 `while` 不会自动变成“循环 CPU”；带 `#delay` 的计算也不会自动变成指定纳秒的硬件。

- 常用可综合构造包括 `assign`、组合/边沿 always、完整的 if/case、固定边界循环、固定宽度运算、静态数组和组合函数。函数（function）常用于复用组合计算；**函数调用本身不保证共享同一个加法器，也不自动产生流水级**。资源是否共享要看并发使用关系与综合优化。

- `$display`、文件读写、测试激励、`fork/join` 等主要用于验证；本章设计不以 `initial`、`force`、仿真延迟表达 ASIC 功能。`$clog2` 等常量计算是另一回事：在展开时算常数，不在硬件里放一个“求对数器”。具体子集仍以目标综合前端为准。

### 4.2 三条可落地的规则

- **组合：完整赋值；时序：单一写者；状态：明确复位与保持。**

- 组合 always 开头给输出/下一状态默认值，再按条件覆盖。若输出之间有依赖，先算中间结果，后赋最终输出；不要把先读后写误认为会自动重新运行。

```verilog
always @* begin
    result = default_value;
    if (enable) result = input_value;
end
```

- 这描述 MUX。若默认写 `result=result`，不是消除 latch，而是明确要求保留旧值。在时序过程里省略不更新分支则正常；第 2 节的 en 就是触发器保持。

- if/else-if 通常描述优先级；两个独立 if 同时成立时后执行赋值覆盖先执行赋值。普通 case 若匹配项互斥，功能上是互斥选择，但面积与逻辑深度还取决于工具优化，不能看一个 `case` 就保证“无优先级、单级门”。

### 4.3 三段式 FSM：一段存状态，一段算转移，一段译码输出

- 有限状态机（finite state machine，FSM）用一个状态寄存器记住“目前做到哪一步”。本例有空闲 IDLE、处理中 WORK、等待对方取结果 RESP 三种状态。所谓“下一状态”，只是根据当前状态和输入算出的去向；真正走到那里，要等下一个时钟沿。三段式把“记位置、决定去哪、告诉外界当前在做什么”分开写。

- [request_fsm.v](lab/FSM_Style/request_fsm.v) 描述一个请求/处理/响应控制器，不重复第 03 章的序列检测算法：

```text
                req                 finish
       ┌────────────────► WORK ────────────────► RESP
       │                  busy=1                valid=1
      IDLE ◄─────────────────────────────────────┘
    accept=1                    ack

IDLE 无 req、WORK 无 finish、RESP 无 ack：各自停留。
```

- **接口契约**：`accept` 表示当前周期能接收，`accept && req` 在上升沿接受请求；WORK 期间 req 被忽略；`finish` 只在 WORK 有意义；响应 valid 必须保持到 ack。外部信号假定已在同一时钟域同步，不负责 CDC。

- 状态寄存器使用 NBA，下一状态组合逻辑写全分支：

```verilog
always @(posedge clk or negedge rst_n)
    if (!rst_n) state <= IDLE;
    else state <= next_state;

always @* begin
    next_state = state;
    case (state)
        IDLE: if (req)    next_state = WORK;
        WORK: if (finish) next_state = RESP;
        RESP: if (ack)    next_state = IDLE;
        default: next_state = IDLE;
    endcase
end
```

- 第三段先给 `accept/busy/valid` 全部赋 0，再根据 **当前 state** 译码，其中 RESP 输出 valid=1。Moore 输出只依赖状态；如果使用 `next_state` 译码，输出可能随输入在本拍提前变化，时序含义会变。

- 这里“三段”指过程分工，不是三拍延迟，也不意味着输出是寄存器。文献里也有把第三段写成时序输出的风格；必须读代码判断，不要只记名字。要输出无组合译码毛刺的信号，可以增加寄存器，但必须重新定义/验证延迟。

- 一段式 FSM 把状态和输出更新放同一个时序过程，代码可能短但保持/清除容易遗漏；两段式把输出和转移合在组合过程；三段式更容易分开读控制转移与输出。没有“段数越多硬件越好”的结论：综合只关心最终行为。

### 4.4 用周期推导协议，而非只看状态名字

- 复位后 IDLE：假设沿 A 前 req=finish=ack=1，沿 A 后只能进入 WORK，不会在一个沿跨越到 RESP 或 IDLE。沿 B 前 finish 仍为 1，沿 B 后进入 RESP；即使 B 沿 ack=1，本实现也是到了下一个 RESP 状态中的沿才能确认响应。

- 若 RESP 时 ack 和 req 同时为 1，本沿只退休旧响应并进入 IDLE，**不同时接受新请求**，因此吞吐有空隙。这是明确的简单协议选择，不是编码 bug。若要求连续吞吐，需要额外的转移和数据通路设计，见 [valid/ready 与流水线](../03_Common_Circuits/README.md)。

- `default: next_state=IDLE` 表达 RTL 非法状态恢复意图，但不能直接宣称能抗单粒子翻转：综合可能重新编码或优化不可达状态，安全状态机需要故障模型、约束和实现后验证。本实验没有故障注入。

### 4.5 实验与面试要点

- [tb_request_fsm.sv](lab/FSM_Style/tb_request_fsm.sv) 用独立的事务阶段建模，检查提前 finish/ack、工作期间重复 req、响应保持、10 笔完成事务和运行中复位中止：

```text
PASS FSM steps=72 accepted=11 responded=10 retired=10 response_holds=20
PASS FSM_Style: lint + no latch + simulation
```

- 第 11 个请求被复位中止，故接收数比退休数多 1，这是测试预期。Yosys 在 `proc; opt` 后检查没有 `$dlatch`；这是结构检查，不是性能报告。

- 打开 `lab/FSM_Style/build/fsm.vcd`，看 `state/next_state/req/finish/ack/accept/busy/valid`：输入改变后 next_state 可以先变，但 state 要等上升沿。

- valid 在 RESP 期间跨两次无 ack 的沿保持。复位中止时无需等时钟，state 返回 IDLE。

- 常见追问：“三段式为什么还会有 latch？”——因为组合部分仍可能缺赋值；“写 default 能保证安全恢复吗？”——只证明 RTL 意图，不能替代综合后的故障验证；“组合循环执行要几拍？”——不是软件循环，拍数必须由状态和寄存器定义。

- **速记：先画状态转移与握手时刻，再选编码风格；段数不是延迟，也不是质量证明。**

<a id="s5"></a>
## 5. 参数化与 generate

### 5.1 配置、展开、运行分清楚

- 假设要做两份相同功能的加法器，一份 8 位、一份 16 位。没必要复制代码再逐处改数字，可以用参数描述位宽，在建立每个实例时选定数值。这样得到的是两块宽度固定的电路；运行时给输入换一个数，不会让导线数量跟着变化。

- `parameter` 是模块配置，实例化时可用 `#(.W(8))` 覆盖；`localparam` 是内部派生常量，不能作为普通实例参数覆盖。优先命名参数覆盖，不用容易破坏层次封装的 `defparam`。

```
源文件 + 参数值 → 展开出具体实例/位宽 → 仿真或综合
                       ↑
             generate 在这里决定结构
```

- 例如 `PIPE=0` 代表构建旁路电路，`PIPE=1` 代表构建寄存器电路，两种电路不是运行时切换。如果需要芯片运行中可切换延迟，必须真的实现两条路径、MUX 和切换协议。

- generate-if 的条件必须在展开时确定；generate-for 用 `genvar` 生成实例或声明。过程 for 则在过程求值时执行语义，综合固定边界的过程循环仍可展开成组合逻辑，但不能在其中实例化模块。前者复制结构，后者描述算法；都不自动增加周期。

### 5.2 `$clog2`：最少编码位数与合法取值不是一回事

- N 个对象的索引要编码 `0..N−1`，数学上最少需要 `ceil(log2(N))` 位。N=3 需要 2 位，但编码 3 仍是非法；N=8 的 3 位编码则都合法。

- 这个公式可以从“w 位能表示 2^w 种组合”推出来：找最小的 w，使 2^w≥N，得到 w≥log2(N)，再向上取整。`ceil` 就是向上取整，`$clog2` 帮我们做这项常量计算。N=3 时，一位只有两种组合不够，两位有四种组合，于是多出一个不用的编码。

- N=1 时 `$clog2(1)=0`。写 `wire [$clog2(N)-1:0] sel` 会得到 `[-1:0]`；这在语言里可能被接受为一个反向范围，**不是你想要的“零位向量”**。本实验使用：

```verilog
localparam SW = (N<=1) ? 1 : $clog2(N);
```

- 端口宽度也使用同一表达式，保留至少 1 位。N=1 的 sel=1 被明确判为非法并输出 0；不是因为只有一个通道就忽略 sel。

- 地址宽度与计数宽度不同：深度 D=8，地址 0..7 需要 3 位，占用量 0..8 需要 `$clog2(D+1)=4` 位。D=3 时二者恰好都是 2 位，不能据此推导普遍相同。非 2 的幂环形计数器必须在 D−1 显式回绕，天然截断只实现模 `2^W`。

### 5.3 实验电路：N 通道数据银行，选择之前可选寄存

- [param_mux.v](lab/Generate/param_mux.v) 参数 W 为每通道位宽，N 为通道数，PIPE 为 0/1。输入打平为 N×W 位，第 g 个通道是 `din[g*W +: W]`。每通道提供奇偶归约输出，再选择一路数据：

```text
通道0 ─► [PIPE=1 时寄存] ─┬─► parity[0]
通道1 ─► [PIPE=1 时寄存] ─┼─► 多路选择 ─► dout
 ...                     │       ▲
通道N−1 ─────────────────┘      sel（当前值）
```

- **关键结构**：

```verilog
for (g=0; g<N; g=g+1) begin : g_lane
    if (PIPE) begin : g_reg
        reg [W-1:0] q;
        always @(posedge clk or negedge rst_n)
            if (!rst_n) q <= {W{1'b0}};
            else q <= din[g*W +: W];
        assign lanes[g*W +: W] = q;
    end else begin : g_bypass
        assign lanes[g*W +: W] = din[g*W +: W];
    end
    assign parity[g] = ^lanes[g*W +: W];
end
```

- 每轮展开有独立层次，例如 `g_lane[2].g_reg.q`；不是三路共享同一个 q。命名 generate 块让波形、约束和报错路径稳定，不依赖工具自动生成的 `genblk` 名字。

- **寄存的是各通道数据，不是 sel，也不是 MUX 输出。** PIPE=1 时，在两个时钟沿之间改 sel 会立即选到另一份已保存的数据；如果规格要“采入 din 与 sel 后下拍得到对应输出”，就需要一起寄存选择或把寄存器放到 MUX 后。两种结构的寄存器数、关键路径和接口延迟不同。

- 选择逻辑先默认 0，再遍历合法索引比较后覆盖。这样 N=3、sel=3 时有定义行为，且不会由于非法选择推断 latch；没有用 `lanes[sel*W +: W]` 把越界后果留给工具。

### 5.4 参数契约及非法配置

- 合法条件为 W≥1、N≥1、PIPE∈{0,1}。本例在非法 generate 分支实例化一个刻意不存在的 `PARAMETER_ERROR_W_N_PIPE` 模块，使所用工具在展开/层次检查时报错。脚本不仅检查退出失败，还确认出现该诊断名，避免把任意语法错误冒充“参数检查成功”。

- 这是这个教学项目的静态防错方式。实际项目也常在验证侧使用 elaboration 检查或 `initial $fatal`，配合构建脚本限制参数；不同综合器对断言/系统任务的处理不同，需要验证。不要把设计逻辑初始化混入参数验证，更不要在非法参数下声称生成了有效硬件。

### 5.5 12 组配置与结构检查

- [tb_param_mux.sv](lab/Generate/tb_param_mux.sv) 覆盖 W∈{1,8}、N∈{1,3,8}、PIPE∈{0,1}，共 12 组。每组 24 个数据周期，分别在采样前后检查，再在一个周期内遍历全部选择编码；参考模型用独立数组保存通道，用逐 bit 异或检查 parity。

- 真实输出节选：

```text
PASS generate W=1 N=1 PIPE=0 checks=51 invalid_selects=25
PASS generate W=8 N=3 PIPE=1 checks=53 invalid_selects=13
PASS generate W=8 N=8 PIPE=1 checks=57 invalid_selects=0
PASS rejected invalid W=0 at elaboration
PASS rejected invalid N=0 at elaboration
PASS rejected invalid PIPE=2 at elaboration
PASS Generate: 12 configurations + 3 invalid parameters
```

- 非法选择次数是采样检查次数，不是独立事务数。N=3 有一个非法编码，N=8 没有；N=1 为防零宽度保留了额外的非法编码。

- 每组均 lint 和 Yosys 检查无 latch；PIPE=0 不含 `$adff`，PIPE=1 含 N 个 W 位 `$adff` 向量寄存器。本实验寄存器无使能，所以与 Scheduling 的 `$adffe` 类型不同。

- 旁路配置保留统一 clk/rst_n 端口，因此脚本仅在 PIPE=0 时豁免 `UNUSEDSIGNAL`，不把这两个不用的输入伪装成实际时钟逻辑。

- 波形位于各配置 `build/w*_n*_p*/generate.vcd`。对比 W=8、N=3、PIPE=0/1，观察下降沿改变 din 后 dout 的即时变化与保持；结尾的 sel 遍历可看到 PIPE=1 下选择依然是组合行为。

- **速记：参数决定硬件数量；位宽正确不等于值域合法；每个参数都要测最小值和非 2 的幂边界。**

<a id="s6"></a>
## 6. SystemVerilog 设计特性

### 6.1 目的：把设计意图交给类型和过程检查

- SystemVerilog（SV）不只是验证语言，也为 RTL 提供更明确的类型和过程语义。它不能替你定义协议、位宽和复位，但能让部分错误更早暴露。本节用一个单槽 ALU 响应通道贯穿所有特性；复杂验证类、随机约束、UVM 不在本章范围。

- ALU 是 arithmetic logic unit，即算术逻辑单元，负责加法、异或等运算。“单槽响应通道”表示它只用一份寄存器保存一个待取走的结果。

- 本节可以分三步读：先看 enum/struct 如何描述一笔请求，再看 package/interface 如何共享类型和连接，最后看 always_comb/always_ff 如何计算并保存结果。

- `logic` 是四态数据类型，常用于单驱动信号；它不表示“综合成组合逻辑”。`logic q` 可被 always_ff 写成寄存器；`wire logic` 明确是线网加四态元素类型。需要多驱动解析或 inout 时仍应选择适合的 net 类型，不能机械地把所有 wire 换成变量 logic。

- `bit` 是二态类型，TB 的参考模型可以使用，但未初始化/X 的诊断可能因此消失。类型、端口的 net/variable 属性、实际驱动源是不同概念，面试回答不要只说“logic=wire+reg，随便用”。

### 6.2 always_comb 与 always_ff 的额外约束

- `always_comb` 表达组合计算意图，自动建立敏感集合、在仿真启动时执行一次，并对写者等施加约束；其敏感推导也涵盖所调用函数读取的相关量。它不支持拿延时/事件等待表达组合计算，所写变量不应再由其它过程写。

- 但它不是自动修错器：遗漏输出赋值依旧是缺陷，工具可能报 latch；先读后写顺序仍重要：

```systemverilog
// 不推荐：c 先读 b；不要期待写 b 自动让此过程再次运行一遍。
always_comb begin
    c = b;
    b = a;
end
```

- 稳妥写成先 `b=a` 再 `c=b`，或直接表达两个输出。它不是依赖方程求解器；写入变量相关的隐式敏感规则也不能拿来当隐式迭代。

- `always_ff @(posedge clk or negedge rst_n)` 表达触发器意图：一个事件控制中可包含时钟与异步复位边沿，状态使用 NBA，由该过程独占写入。工具可检查不合规用法，但不能保证检查覆盖所有错误，更不会保证时钟/复位的物理质量。

- `always_latch` 用于有意的锁存器；本章正确设计不需要它。

### 6.3 enum 与 packed struct：18 位请求不是“松散的三个整数”

- [alu_pkg.sv](lab/SV_Design/alu_pkg.sv) 定义共享协议：

```systemverilog
typedef enum logic [1:0] {
    OP_ADD=2'd0, OP_XOR=2'd1, OP_AND=2'd2, OP_BAD=2'd3
} op_t;
typedef struct packed {
    op_t op;
    logic [7:0] a;
    logic [7:0] b;
} request_t;
```

- enum 给值命名并保留明确的 2 位底层表示，比无类型魔数容易审查。用强制类型转换 `op_t'(value)` 可以构造枚举值，但转换不等于运行时合法性检查；本例把编码 3 明确当错误操作码处理，而不是假设“有 enum 就不会收到坏请求”。

- packed struct 连续打包成一个向量，总宽度为 2+8+8=18 位。先声明的 op 位于高位，因此布局是 `op[17:16]、a[15:8]、b[7:0]`。响应为 `error` 与 9 位 `result`，共 10 位。整包可赋 `'0`，也可用 `req.a` 访问字段。

- 不带 packed 的 struct 是成员集合，不要据此假定一个可随意位选的连续向量；声明在类型右侧的数组维度是 unpacked 维度。例如 `request_t queue[0:3]` 是四个请求元素，而不是把结构本身变成一份 72 位 packed 数据。打包顺序是位布局，不自动定义总线字节序。

- 本例协议固定操作数 8 位，避免不同端点各自参数化而产生不兼容类型。若改宽度，应统一修改共享类型/常量并重新编译所有端点；不能只给一个实例传 W、期待 package 里的固定类型跟着变。

### 6.4 package 与 interface 各自解决什么问题

- package 存放共享类型、参数、函数等声明，不实例化硬件。本例使用 `alu_pkg::request_t` 指明类型来源，在模块内部 `import alu_pkg::*` 后可以写短名。包必须先编译；import 不会替代编译包文件，也不是文本粘贴的 `` `include``。公共接口可用显式作用域，避免多个包里同名类型冲突。

- [alu_link.sv](lab/SV_Design/alu_link.sv) 把请求、响应与 valid/ready 信号放入一个 interface 实例。`modport device` 从设备视角规定方向：

```systemverilog
modport device(input req_valid, req, rsp_ready,
               output req_ready, rsp_valid, rsp);
```

- `input` 表示接入该 modport 的设备读取它，不是说整个 interface 的某一边天然是输入。host 视角相反。modport 能帮助检查方向，但不会自动生成仲裁器、保证握手、插入寄存器或解决 CDC。

- **结构关系**：

```text
普通端口 → alu_top 内部的 alu_link 实例
                      ↓ .device modport
                 alu_device → alu_core
共享类型来自 alu_pkg（不是一块实例化的电路）
```

- [alu_top.sv](lab/SV_Design/alu_top.sv) 保留普通顶层端口便于连接和完整 lint，内部实例化 interface；[alu_device.sv](lab/SV_Design/alu_device.sv) 通过 modport 接收它，再把信号连接到 [alu_core.sv](lab/SV_Design/alu_core.sv)。分层是为了看清类型、连接和行为的职责，不是要求每个小 ALU 都拆成这么多文件。

### 6.5 用 always_comb 算结果，用 always_ff 保存响应

- 先认识接口上的 valid 和 ready：发送方用 valid=1 表示“我有一份有效数据”，接收方用 ready=1 表示“我现在能收”。两者在同一个上升沿都为 1，才算交接了一笔。若发送方已有数据而接收方暂时不能收，发送方必须把它留住。

- 这种让上游等待的情况叫反压（backpressure）。下面的寄存器更新条件就是围绕这个交接规则写的。

- 组合部分先将 `calculated='0`，再用 case 实现 ADD/XOR/AND；默认置 error=1，因此编码 3 的结果为 0、error 为 1。加法先补位，255+1 得到 9 位 256，不因换成 SV 就自动免于位宽问题。

- 响应寄存器的更新条件：

```systemverilog
assign req_ready = !rsp_valid || rsp_ready;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rsp_valid <= 1'b0;
        rsp <= '0;
    end else if (req_ready) begin
        rsp_valid <= req_valid;
        if (req_valid) rsp <= calculated;
    end
end
```

- 空槽可以接收；满槽且下游不 ready 时，valid 和整份响应保持；旧响应本拍被消费时允许新请求替换。旧响应消费但没有新请求时，valid 清零，数据位可以保留旧值，因为 valid=0 表示其内容不应被使用。

- 这是一个响应槽，连续 ready 且连续请求时稳态可每拍接收一笔；不是两个独立队列。ready 有从下游到上游的组合路径，其系统级代价见 [第 03 章流水线/握手](../03_Common_Circuits/README.md)，本节专注语言如何表达状态与类型。

### 6.6 实验、工具边界与读波形

- [tb_sv_design.sv](lab/SV_Design/tb_sv_design.sv) 给 120 个周期的确定性激励，源端在反压期间保持请求，末尾停止产生新请求并排空。参考模型检查每次 valid/ready、响应结果、请求/响应守恒，覆盖全部操作码、停顿和同拍替换：

```text
PASS SV sends=67 receives=67 stalls=41 replacements=60 ops=17,17,17,16
PASS SV_Design: package + enum + struct + interface/modport + always_comb/ff
```

- 41 表示满槽被反压的周期；60 是同时消费旧响应并接收新请求的周期。操作码 3 的 16 笔是预期的错误响应，不是测试失败。

- 看 `lab/SV_Design/build/sv_design.vcd` 的 `req_valid/req_ready/req.op/req.a/req.b/rsp_valid/rsp_ready/rsp`。

- 在 rsp_valid=1 且 rsp_ready=0 的整段停顿里，rsp 的两个字段都必须保持；恢复 ready 后可以连续替换。

- 本实验使用 Verilator 的 `--binary --timing --trace` 实际编译和运行，完整顶层 lint 无告警。

- 所装版本的生成 Makefile 不能在含空格路径中构建，所以脚本把同一组源文件复制到 WSL `/tmp/ch02-sv.*` 编译，再将可执行文件放回 `build/` 运行并保留波形/日志；临时目录自动清理。没有在 Windows 安装工具。

- **这套 SV 实验验证二态功能，不验证 X/Z 传播。** Verilator 官方说明其主要采用二态模拟，且敏感列表遗漏的处理与标准事件仿真存在差异，因此本章四态/敏感列表反例另用 Icarus。[工具语义边界](https://verilator.org/guide/latest/languages.html)

- 未用 Yosys 为这套 package/interface 层次做综合验证，也没有声称所有 SV 语法都能被任意综合器支持。设计采用通常可综合的组合/触发器与静态类型构造，但迁移到目标综合前端时仍需单独检查；class、动态数组、mailbox 等验证功能不能因此混入设计。

- **速记：类型让意图可检查，interface 让连接集中，always_ff/comb 让过程用途明确；它们不替代协议和时序设计。**

<a id="s7"></a>
## 7. 常见编码陷阱

### 7.1 如何使用错误样例

- [bad_examples.v](lab/Pitfalls/bad_examples.v) 全部是有意的反例，含 latch、多驱动和组合环，**不作为可复用 RTL，也不宣称满足正确代码规范**。脚本的 PASS 表示预期问题确实被检测到；它必须同时确认退出状态/诊断内容或行为差异，不是把错误日志吞掉。

- 调试顺序可以是：检查编译/展开 → lint 看结构意图 → 自检查仿真找功能 → 综合结构检查 → 需要时做等价/门级/时序验证。每种工具有盲区，不能用某一个 PASS 代替全部环节。

### 7.2 不完整赋值：从缺 else 推导到锁存器

```verilog
always @* if (en) q=d;
```

- en=1 时透明跟随 d；en=0 时语句不写 q，必须记住上次的值，所以是 latch。实验先令 en=1、d=1，再令 en=0、d=0，q 仍为 1；Yosys 实际推断一个 `$dlatch`。

- 若规格是组合门控，写全 `q = en ? d : 1'b0`；若规格是带使能触发器，就加时钟并在边沿过程用 NBA。不能为了消告警随意补零而改变“保持”的规格。

- case 漏 default、循环只在某些路径给输出赋值、部分位赋值也可能产生相同问题。组合默认写 `q=q` 只是把存储需求写得更显式。

### 7.3 敏感列表遗漏：前仿真与综合电路不同

```verilog
always @(a) y = a & b;
```

- 仿真只在 a 变化时算 y；a=1 保持、b 从 0 变 1 时 y 留在 0。但综合按逻辑依赖构建 AND，b 变化会影响硬件输出。

- 脚本对这个模块跑 Yosys，生成并改名为 `synthesized_sensitivity`，与原 RTL 同时放入 Icarus，在同一组激励下对比。结果不是手写一个“假网表”：

```text
sensitivity: RTL=0 synthesized=1; latch held=1
```

- 修复为 `always @*` 或 `always_comb`。综合输出是工具生成的逻辑级 Verilog，无工艺映射、无 SDF；本实验只证明敏感列表导致功能模型不一致，不是门级时序签核。

### 7.4 多驱动和组合环：不是靠修改赋值运算符修复

```verilog
always @(posedge clk_a) q<=a;
always @(posedge clk_b) q<=b;
```

- 这不能综合为“自动选择最近一次时钟的双时钟触发器”。实验在 Yosys `proc` 后运行 `check -assert`，实际拒绝两个寄存器输出同时驱动 q 的结构。正确架构是明确定义一个状态拥有者，必要时先完成 CDC/仲裁，再由单一时钟域更新。不能把 `<=` 换成 `=` 就算修好。

- `assign y=~y` 是组合反馈，本例用 Verilator lint 捕获 `UNOPTFLAT`，不运行这个反馈电路去等待它“收敛”。部分组合环在仿真中表现为 X、无限零时间迭代或偶然稳定，均不能用来推导真实振荡频率。正常反馈应跨过明确存储元件；振荡器属于专门电路，不是普通同步 RTL 环。

### 7.5 case、casez、casex：通配符会把坏输入藏起来

- 普通 case 对 0/1/X/Z 精确匹配；casez 把 Z/`?` 当通配，casex 进一步把 X 当通配。关键是：**通配不仅可能出现在分支常量，也可能来自选择表达式本身的 X/Z**。

- 反例分支按顺序写 `2'b1?` 优先于 `2'b01`；已知输入 11/10 授予高位、01 授予低位。现在注入未知或悬空选择：

```text
sel=x1 exact=00 casex=10 casez=00
sel=z1 exact=00 casex=10 casez=10
```

- 普通 case 回到默认 00；casex 把 x1 当成能匹配 1?，错误地给出确定授权；casez 虽不吞 X，却仍会吞输入里的 Z。不能把“换成 casez”当作全部修复。

- 对纯二态优先编码，casez 可以清晰表达模式，但必须保证/检查控制输入没有未知与高阻，且匹配优先级符合规格。不要随意用 casex 掩盖初始化问题。

- `unique case` 表达互斥及相关覆盖意图，`priority case` 表达优先/覆盖意图；它们不是默认赋值或非法输入处理的替代品。带 default 会改变未匹配时的检查条件，工具还可能利用这些承诺优化；如果假设不成立，仿真警告与实际硬件结果可能偏离。

- 避免把 `full_case/parallel_case` 指示当作消告警技巧，具体验证支持需检查工具设置。

### 7.6 还有哪些“跑通了”仍不可靠

- 无尺寸常量、signed/unsigned 混合、切片丢符号：见第 1 节。时钟沿上驱动与采样竞争：见第 3 节。隐式线网把拼写错误变成 1 bit：见第 1.1 节。这些问题应有针对性的边界输入，而不是只做正常路径仿真。

- 给非法状态赋 `x` 有时会让综合利用 don't-care 优化，但在 RTL 仿真里又传播未知，可能掩盖规格未定义区域；本章正确设计为非法选择/操作码给确定默认行为。使用 don't-care 需要明确可达性假设和等价验证，不是“面积免费优化”。

- “前仿真能过，综合后不一致”的排查方向包括：敏感列表、初始化/延迟被忽略、多写者、case 优化假设、位宽工具扩展。不要先怀疑综合器“把正常代码随便改坏”。进一步流程见 [第 08 章](../08_Logic_Synthesis/README.md)。

### 7.7 实验结果与检查范围

- 运行 `lab/Pitfalls/run_sim.sh`，真实输出：

```text
PASS detected latch: exactly one $dlatch
PASS rejected multiple conflicting drivers
PASS detected combinational loop (UNOPTFLAT)
PASS pitfalls expected_counterexamples=6
PASS Pitfalls: structural diagnostics + RTL/netlist mismatch + four-state cases
```

- 前三项是结构检查；六个自检查覆盖初始化基线、a 触发、只改 b、x1、z1 和 latch 重新透明。

- `build/pitfalls.vcd` 可观察 stale/synthesized/held/sel/exact/wild_x/wild_z，重点在 4 ns 的 RTL/网表分歧与 5/6 ns 的 X/Z 注入。

- 这些最小反例不穷举所有 lint 告警，也没有证明所有写法的跨工具一致性。其价值是每个结论都有可重复的触发条件、诊断和修复方向。

- **速记：先确认代码要实现的硬件，再用独立的行为与结构检查交叉验证；检测到预期错误也是实验成功。**

<a id="labs"></a>
## 8. 运行入口与验证边界

- Windows PowerShell 中一键运行整章（路径含空格，保留引号）：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/02_HDL_Verilog_SystemVerilog/lab' && bash run_all.sh"
```

- 单独运行时将目录改为 `lab/Expressions`、`lab/Scheduling`、`lab/FSM_Style`、`lab/Generate`、`lab/SV_Design` 或 `lab/Pitfalls`，执行 `bash run_sim.sh` 即可。

- 脚本内部加载 `/root/oss-cad-suite/environment`，所有 EDA 执行都在 WSL 中。若 Windows 编辑器改变了换行，在相应实验目录执行 `sed -i 's/\r$//' run_sim.sh`；脚本源文件使用 LF。

- Expressions、Scheduling、FSM_Style、Generate 做 RTL lint、Yosys 结构检查、Icarus/vvp 自检查仿真。Icarus 使用 `-g2012 -gstrict-expr-width`。

- 后者避免默认模式对无尺寸表达式的扩展行为影响教学，依据 [Icarus 官方说明](https://steveicarus.github.io/iverilog/usage/icarus_verilog_quirks.html)。定向位宽探针使用显式尺寸，避免靠工具扩展“碰巧算对”。

- 正确设计 lint 通过；Generate 的旁路配置单独豁免未使用端口类告警，原因见第 5.5 节。TB 包含刻意的截断、X、阻塞时序反例，不声称它们也通过严格 RTL lint。Yosys `check -assert` 检查结构，额外断言无 `$dlatch`。

- Scheduling 与 Generate 还检查预期的寄存器数量。

- SV_Design 使用 Verilator 完整顶层 lint 和二态自检查仿真，没有 Yosys 综合。仿真编译仅豁免 `TIMESCALEMOD`（设计模块不含延迟，TB 指定时间单位），没有因此关闭 RTL lint。

- Pitfalls 检查指定的预期错误，并用 Icarus 比较 RTL/生成网表和四态行为。**这些检查不等于整章形式证明或 STA；Pitfalls 的逻辑级网表对比也不是带 SDF 的门级时序仿真。**

- 自检查不符合预期会以带 `FAIL` 的 `$fatal(1,...)` 或非零脚本退出报告；正常打印 `PASS` 并 `$finish`。所有 TB 均有超时保护和 VCD。持久输出写各自 `build/`，已被仓库 `.gitignore` 忽略；SV 构建临时目录由脚本清理，不需要提交仿真可执行文件和波形。

- **验证范围**：

  - Expressions：三种位宽，共 65,808 对输入及固定四态探针。
  - Scheduling：32 个周期。
  - FSM_Style：72 步事务阶段检查。
  - Generate：12 组配置与 3 个非法参数。
  - SV_Design：120 个激励周期及排空。
  - Pitfalls：结构诊断与 6 次定向行为检查。

- 这些检查没有穷举全部时序激励、参数或语言语法。波形可在 WSL 中用 GTKWave 打开，脚本不自动启动 GUI。

- 本次 WSL 工具：Verilator `5.051 devel`、Yosys `0.68+182`（2026-10-20 实测）；不同版本的日志措辞和中间单元类型可能变化，更新脚本时应核对检查语义，不能直接删除失败的断言。

<a id="quick"></a>
## 9. 面试前速查

- **reg 是过程变量，不是寄存器类型承诺；电路由过程决定。**
- **先扩展再运算；左边够宽不保证内层没有截断。**
- **切片/拼接可能丢 signed；`$signed` 改解释，不补位。**
- **无符号进位 ≠ signed 溢出；signed 同号加法看截断后符号是否翻转。**
- **时序 `<=` 当场读 RHS，NBA 更新 LHS；不是下一拍才更新。**
- **同一过程后执行 NBA 可覆盖前一次；跨过程不靠书写顺序。**
- **`#0` 不等于 NBA 之后；`$display` 与 `$strobe` 观察区域不同。**
- **四态仿真不是亚稳态仿真；通过一组测试不代表结构与时序都正确。**
- **三段式是过程分工，不是三拍；看当前状态还是下一状态会改变输出时机。**
- **generate 选结构，普通输入选运行行为；`$clog2` 位宽不负责排除非法编码。**
- **SV 类型、interface 与过程关键字帮助检查意图，不自动保证协议或可移植综合。**
- **casex 可吞掉控制信号的 X；缺敏感信号可能让 RTL 与综合电路行为不同。**

- 巩固：[INTERVIEW_QA.md](INTERVIEW_QA.md) 共 44 道概念题、找错题和计算题，覆盖全部七节。
