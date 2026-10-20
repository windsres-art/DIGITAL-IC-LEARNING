# 第 04 章：运算单元 —— 从进位依赖到硬件结构

目标：能推导常用算术电路、写出可综合 RTL，说明面积/延迟取舍，并用自检查仿真与工具报告验证判断。面试时不仅说“前缀加法快”，还要说明它解决了哪条依赖、增加了什么代价、结论适用于什么模型。

**本章已覆盖总纲的五个小节：加法器、乘法器、除法器、定点与浮点基础、CORDIC。** 配套 [lab/Adders](lab/Adders/)、[lab/Multipliers](lab/Multipliers/)、[lab/Dividers](lab/Dividers/)、[lab/Fixed_Float](lab/Fixed_Float/) 与 [lab/CORDIC](lab/CORDIC/) 包含 RTL、自检查 TB 和变异测试；加法器另有通用门结构对比，加法器和小位宽组合乘法器有等价证明。第 4 节实现定点格式转换和 binary32 分类器，不是完整浮点运算器；CORDIC 为固定数值格式、四种迭代次数的圆周算法。[INTERVIEW_QA.md](INTERVIEW_QA.md) 包含 84 道面试题。

前置知识：[第 02 章](../02_HDL_Verilog_SystemVerilog/README.md) 的位宽、符号、组合逻辑与 generate；二进制与补码可先按 [第 01 章提纲](../01_Digital_Logic_Fundamentals/) 复习，该章正文尚待编写。结构优化为什么不等于时序收敛，见 [第 07 章 STA](../07_STA/README.md)；综合工具如何改写 RTL，见 [第 08 章](../08_Logic_Synthesis/README.md)。

建议顺序：1.1–1.3 建立进位模型 → 跑加法仿真 → 1.4–1.7 推导其它结构 → 1.8 读综合实验 → 第 2–3 节及乘除法实验 → 第 4 节数值格式与量化实验 → 第 5 节 CORDIC → 面试题。加法器、Booth/Wallace 乘法器、定点转换器和浮点分类器是纯组合；移位相加乘法器、除法器和 CORDIC 是带握手、低有效异步复位的迭代电路。不能从模块名字推断拍数。

## 目录

1. [加法器](#adders)（已完成）
   - [1.1 接口、位宽与加减法](#contract)
   - [1.2 全加器与产生/传播](#pg)
   - [1.3 行波进位 RCA](#rca)
   - [1.4 分组超前进位 CLA](#cla)
   - [1.5 进位选择 CSLA](#cselect)
   - [1.6 进位保留 CSA](#csa)
   - [1.7 并行前缀加法器](#prefix)
   - [1.8 运行、验证与结构对比](#lab)
   - [1.9 选择方法与面试速查](#review)
2. [乘法器](#multipliers)（已完成）
   - [2.1 规格与部分积](#mul-contract)
   - [2.2 迭代移位相加](#mul-shift)
   - [2.3 Radix-4 Booth 编码](#mul-booth)
   - [2.4 Wallace 风格压缩树](#mul-wallace)
   - [2.5 仿真、形式检查与变异](#mul-lab)
   - [2.6 结构选择与追问](#mul-review)
3. [除法器](#dividers)（已完成）
   - [3.1 数学与接口契约](#div-contract)
   - [3.2 恢复余数算法](#div-restoring)
   - [3.3 不恢复余数算法](#div-nonrestoring)
   - [3.4 RTL 与握手时序](#div-rtl)
   - [3.5 WSL 实验与错误注入](#div-lab)
   - [3.6 结构扩展与面试速查](#div-review)
4. [定点与浮点](#fixed-float)（已完成基础范围）
   - [4.1 Q 格式与动态范围](#fixed-format)
   - [4.2 运算缩放与保护位](#fixed-scale)
   - [4.3 截位、舍入与饱和](#fixed-round)
   - [4.4 定点转换器 RTL](#fixed-rtl)
   - [4.5 IEEE 754 binary32 编码](#float-format)
   - [4.6 浮点运算流程与异常](#float-arithmetic)
   - [4.7 WSL 实验与验证边界](#fixed-float-lab)
   - [4.8 格式选择与面试速查](#fixed-float-review)
5. [CORDIC](#cordic)（已完成）
   - [5.1 从旋转矩阵到移位加法](#cordic-principle)
   - [5.2 两种模式与增益](#cordic-modes)
   - [5.3 收敛范围与象限处理](#cordic-range)
   - [5.4 接口、格式与 RTL](#cordic-rtl)
   - [5.5 WSL 数值与协议验证](#cordic-lab)
   - [5.6 误差、结构选择与面试速查](#cordic-review)

<a id="adders"></a>
## 1. 加法器

<a id="contract"></a>
### 1.1 先定义输出含义：位向量、进位与溢出

加法不仅用于 ALU，还用于地址生成、计数、比较、乘法部分积累加。这里先处理两个 W 位操作数和一位 cin：

```text
{cout, sum[W−1:0]} = a + b + cin
```

当 a、b 按无符号数解释时，最大值是 `2*(2^W−1)+1=2^(W+1)−1`，因此 W+1 位恰好完整。`sum` 是模 `2^W` 结果；cout 是超出低 W 位的无符号进位。本章四种两操作数加法器端口一致，便于在同一 TB 中比较。

**signed 与 unsigned 的低 W 位加法电路相同，区别是如何解释数值及判断溢出。** 若需要更宽的 signed 和，要先做符号扩展；不能把 `{cout,sum}` 直接当作 W+1 位 signed 结果。

8 位例题：

- 无符号 `255+1=256`：cout=1、sum=0。
- 有符号 `127+1=128` 超出范围：sum=`8'h80`，解释为 −128；此时无符号 cout=0，仍发生 signed 溢出。
- 有符号 `−1+1=0`：同一位模式 ff+01 产生 cout=1，但 signed 没有溢出。

加法的 signed 溢出可以看“同号输入、异号输出”：

```text
V = NOT(a[W−1] XOR b[W−1]) AND (sum[W−1] XOR a[W−1])
  = c[W−1] XOR c[W]
```

第二种形式比较进入符号位和离开符号位的进位。第一种便于只访问输入/结果的包装层；第二种便于已有内部进位的实现。不要把 V 和 cout 混用。

减法可复用同一加法器：

```text
a − b = a + NOT(b) + 1             （模 2^W）
b_effective = b XOR {W{sub}}
cin = sub
```

sub=0 加，sub=1 减。对无符号减法，采用这种二补码实现时 cout=1 表示无借位，borrow 通常取 `~cout`；ISA 对标志位的命名/极性需单独确认。减法的 signed 溢出条件为“a、b 异号且结果与 a 异号”。本章没有额外实现 ALU 标志寄存器。

扩展方向：若规格要求饱和而非回绕，8 位 signed `100+60` 应钳到 127，而普通截断结果是 −96。饱和需要溢出检测与输出选择，不能靠把 `+` 换成另一种进位结构自动得到。

<a id="pg"></a>
### 1.2 全加器：把“等前一位”写成公式

第 i 位全加器（full adder）接收 `a_i、b_i、c_i`，输出 `s_i、c_(i+1)`。三个 bit 相加可能得到 0、1、2、3，最低位是奇偶，最高位在至少两个输入为 1 时成立：

```text
s_i     = a_i XOR b_i XOR c_i
c_(i+1) = (a_i AND b_i) OR (a_i AND c_i) OR (b_i AND c_i)
```

定义产生（generate）与传播（propagate）：

```text
g_i = a_i AND b_i
p_i = a_i XOR b_i
c_(i+1) = g_i OR (p_i AND c_i)
s_i = p_i XOR c_i
```

直觉是：a=b=1 时不管输入进位是什么都产生进位；a、b 恰好一个为 1 时把输入进位传下去；a=b=0 时杀掉进位。本文始终使用 XOR 定义 p。有些教材用 OR 定义进位传播，也能构造正确的 carry 方程，但不能把该 p 不加区分地代入 `s=p XOR c`。

位级公式很短，慢的原因是跨位依赖：

```text
cin=c0 → bit0 → c1 → bit1 → c2 → ... → bit(W−1) → cout
            ↓s0          ↓s1                  ↓s(W−1)
```

以下几种结构，就是以不同方式处理这条依赖；逻辑等价不意味着拓扑相同。

<a id="rca"></a>
### 1.3 行波进位加法器（Ripple-Carry Adder，RCA）

#### 原理与 RTL

[adder_rca.v](lab/Adders/adder_rca.v) 逐位连接全加器：

```verilog
assign p = a ^ b;
assign g = a & b;
assign c[0] = cin;
for (i=0; i<W; i=i+1) begin : g_bit
    assign c[i+1] = g[i] | (p[i] & c[i]);
    assign sum[i] = p[i] ^ c[i];
end
```

此处是 generate 内的关键片段，完整模块见链接。c 使用 W+1 位，保证既有输入 c0 又有输出 cW。每一位的 c 只有一个驱动，没有组合反馈。

4 位例题：a=1111、b=0000、cin=1，所有位 `p=1、g=0`，因此 c0=1 会沿链传到 c4，sum=0000、cout=1。这类长传播向量比只试 `1+1` 更能检验跨位连接。

面积随 W 近似线性；在逐级进位延迟模型里，最坏 carry 路径也随 W 线性增长。如果设每级 carry 延时为 `t_c`，可粗略写 `T≈W*t_c`，还需按输出端点加入初始 p/g 和末级 sum 的延迟。这是估算模型，不是本章测出的纳秒数。

#### 实验、错误与扩展

统一实验同时比对 RCA 与其它结构。本机通用门展开后，W=8/32/64 的 RCA 最长拓扑路径分别是 17/65/129 层；这与显式的 AND→OR 进位链增长相符，不能拿“每层一纳秒”换算频率。

常见错误：`c` 少开一位，最高位 cout 丢失；循环边界少处理最高位；把 `c[i+1]` 错写成 `c[i]`，产生自反馈。TB 有每一种传播长度的向量，形式检查则覆盖所选参数下所有二态输入。

RCA 适合先建立正确基线；短位宽、宽松时序下可能已经足够。FPGA 还有专用 carry chain，手写前缀网络不一定优于工具对 `+` 的映射；本章实验是通用门逻辑，不提供 FPGA 性能结论。

**面试一句话：RCA 结构简单、规模线性，但进位依赖逐位串行；“代码并行 assign”不代表电路路径没有串行依赖。**

<a id="cla"></a>
### 1.4 超前进位加法器（Carry-Lookahead Adder，CLA）

#### 展开 carry，而不是仅把代码换成 p/g 名字

把上一位进位递推代入下一位，在布尔表达式中展开：

```text
c1 = g0 | p0*c0
c2 = g1 | p1*g0 | p1*p0*c0
c3 = g2 | p2*g1 | p2*p1*g0 | p2*p1*p0*c0
c4 = g3 | p3*g2 | p3*p2*g1 | p3*p2*p1*g0 | p3*p2*p1*p0*c0
```

这里 `*` 表示 AND，`|` 表示 OR，不是数值乘加。所有 p/g 可以由输入同时产生；每个 carry 直接由本组的输入 carry 与 p/g 得到，避免组内逐位等待。

定义四位组：

```text
P_(3:0) = p3*p2*p1*p0
G_(3:0) = g3 | p3*g2 | p3*p2*g1 | p3*p2*p1*g0
c4 = G_(3:0) | P_(3:0)*c0
```

不能据此说任意 W 位 CLA 都只要“两层门”：门的输入数有限，大扇入 AND/OR 要分解，扇出和布线也增加。把 64 位所有项直接展开，表达式规模与连接代价都很高。

#### 本实现是“组内超前、组间行波”

[adder_cla.v](lab/Adders/adder_cla.v) 默认 B=4。对每一组的第 i 位进位，将每一个“某位产生 + 以上全部传播”的项单独生成，再 OR 起来：

```verilog
assign terms[j] = g[BASE+j] & (&p[BASE+i:BASE+j+1]);
assign c[BASE+i+1] =
    (|terms) | ((&p[BASE+i:BASE]) & c[BASE]);
```

j=i 时单独处理为 `terms[j]=g[BASE+j]`，避免空切片。所有内部 carry 都只依赖本组入口 `c[BASE]`，不是前一位 c。若仍写 `c[i+1]=g[i]|p[i]&c[i]`，本质就是 RCA，不能因模块名叫 CLA 就变快。

组间入口来自上一组输出，因此 B 固定时还有约 W/B 组的串行依赖。可以在组的 P/G 上继续做第二级超前或前缀树；本代码没有暗含这一级。

参数化处理尾组：`NB=ceil(W/B)`，`K=min(B,W−BASE)`。例如 W=17、B=4 的分组为 4+4+4+4+1；W=17、B=7 为 7+7+3，不能偷偷补入未定义数据。B=1 时公式退化为逐位进位，实验专门验证这一边界。

#### 例题与实际结果

4 位 a=1011（11）、b=0101（5）、cin=0：p=1110、g=0001。最低位产生 g0=1，以上 p1=p2=p3=1，故 `G_(3:0)=1`、c4=1，结果为 `1_0000`（16）。不是只有 cin 才能启动一条传播链，内部 g 同样可以。

WSL 中 W=32、B=4 的通用门优化前结构为 304 个 cell、22 层；经本实验默认 ABC 通用门映射后变成 175 个 cell、65 层。说明工具会重新分解与共享逻辑，**不能把源码 CLA 的理论优势直接当成综合结果**。完整比较见 1.8。

**面试一句话：CLA 展开进位依赖；分组 CLA 必须说清组间如何连，不能一概宣称整条路径是 O(log W)。**

<a id="cselect"></a>
### 1.5 进位选择加法器（Carry-Select Adder，CSLA）

#### 用重复计算换等待时间

当高位组不知道低位 carry 时，可以同时预计算两种答案：

```text
                 ┌─ RCA(cin=0) ── {cout0,sum0} ─┐
高位组 a,b ──────┤                              MUX ─► {cout,sum}
                 └─ RCA(cin=1) ── {cout1,sum1} ─┘
                                               ▲
                                    低位组真实 carry
```

低位组用实际 cin 正常计算；后续组只等真实 carry 选择结果，不再从头计算该组的全加器链。

[adder_cselect.v](lab/Adders/adder_cselect.v) 用两份 [adder_rca.v](lab/Adders/adder_rca.v) 得到 r0、r1，关键是 **sum 与 cout 必须一起选**：

```verilog
assign {c[k+1],sum[BASE +: K]} = c[k] ? r1 : r0;
```

不能选了 sum 却总把 r0 的 cout 传给下一组；那会在跨组进位时出错。最后不足 B 位的组同样使用 K 计算，避免宽度越界。

例如一组输入 15+0：cin=0 时得到 `0_1111`，cin=1 时得到 `1_0000`。两份都算好后，真实 carry=1 应同时选择和 0 与进位 1。

#### 代价与分组选择

额外计算单元增大面积与潜在翻转功耗；是否真的耗电更多要看活动、优化和门控，不能只凭实例数给瓦数。均匀 B 位分组的粗略路径模型是：

```text
T ≈ B*t_carry + (ceil(W/B)−1)*t_mux + 其它端点延迟
```

在假设两类单级延迟都为 1、忽略端点和布线的玩具模型中，W=64：B=4 得到 4+15=19，B=8 得到 8+7=15。连续近似 `B+W/B` 的最小值在 `B≈sqrt(W)`；这不是工艺无关的最佳分组结论。

变体包括低位小组、高位逐渐加大的非均匀分组，让预计算时间与 carry 到达时间匹配；也可用递增器从 cin=0 结果生成 cin=1 结果以省资源。本实验实现的是均匀分组的双 RCA，不声称包含这些优化。

WSL 中 W=32、B=4，优化前为 266 个通用 cell、16 层；RCA 是 160 个、65 层，展示了此结构的数量/层数取舍。映射后数值会变，见 1.8。

**面试一句话：CSLA 预计算两种 carry 假设，再用 MUX 选择；它与下节 CSA 不是同一种电路，缩写要讲全。**

<a id="csa"></a>
### 1.6 进位保留加法器（Carry-Save Adder，CSA）

#### 解决多操作数累加，不急着输出一个二进制数

三个 W 位数 a、b、d 相加，若串联两次普通加法，每一步都要做横向进位传播。CSA 换了一种中间表示：每个位独立压缩三个输入 bit，产生同权重 sum 和高一权重 carry。

```text
第 i 列：a_i + b_i + d_i = s_i + 2*m_i
s_i = a_i XOR b_i XOR d_i
m_i = (a_i&b_i) | (a_i&d_i) | (b_i&d_i)

所有列同时计算：a+b+d = saved_sum + saved_carry
saved_carry = {m, 1'b0}   // 已经按权重左移一位
```

[csa3.v](lab/Adders/csa3.v) 直接实现这两行：

```verilog
assign saved_sum = a ^ b ^ d;
assign saved_carry = {(a&b)|(a&d)|(b&d),1'b0};
```

各列的 m 不依赖邻列 carry，压缩层没有横向 carry chain。它不是没有进位，而是把进位保存到第二行留待以后处理；模块没有寄存器，“保留”是数值表示方式。

#### 位宽、数例与最后一级 CPA

saved_sum 为 W 位，saved_carry 为 W+1 位，因为最高列产生的 carry 必须保留。完整三数和使用 W+2 位是统一安全选择；W≥2 时最坏值 `3*(2^W−1)` 也确实需要 W+2 位，W=1 则这个统一接口多留一位。

4 位例题：a=7、b=5、d=3：

```text
  a = 0111
  b = 0101
  d = 0011
sum = 0001
  m = 0111 → carry = 01110
1 + 14 = 15
```

若对 saved_carry 再左移一次，就把权重算成 4 倍；若 carry 只保留 W 位，就在最高位丢失信息。变异测试专门注入了“未左移、权重错误”来验证 TB 能抓到。

要得到普通二进制结果，仍需一次进位传播加法（Carry-Propagate Adder，CPA）。[adder_three.v](lab/Adders/adder_three.v) 用 CSA 后接 W+1 位前缀加法器：

```text
a,b,d → CSA → {saved_sum, saved_carry 两行}
               ↓ 零扩展对齐
          前缀 CPA → W+2 位 total
```

WSL 实测 W=8、三个输入均为 255：

```text
max3 W=8 saved_sum=ff saved_carry=1fe total=2fd
```

即 255+510=765；total=`0x2fd`。注意这两行不是两个独立结果，而是一份数的冗余表示。

#### 扩展到压缩树

多行输入可反复做 3→2 压缩，直到剩两行再 CPA；这正是后续 Wallace/Dadda 乘法部分积压缩的基础。不能把每个 CSA 的两行立刻又通过 CPA 合成一行，再声称获得了树形压缩的延迟优势。

加法实验实现一个 3→2 层和一个完整三操作数求和器；多层压缩树见第 2.4 节。通用门展开后，CSA 核在 W=8/32/64 都是 3 层，cell 数随位宽增长；**完整三数和仍包含最终 CPA，其层数不再是常数**。

**面试一句话：CSA 快在暂缓全宽进位传播，输出两行；普通二进制结果仍需最后一次 CPA。**

<a id="prefix"></a>
### 1.7 并行前缀加法器：把区间进位函数组成树

#### 从区间函数推导结合运算

一个 bit 或一段连续 bit，都可以用 `(G,P)` 表示进位关系：

```text
c_out = G | P*c_in
```

设高位段为 H，紧邻的低位段为 L。低位输出进入高位：

```text
c_out = G_H | P_H*(G_L | P_L*c_in)
      = (G_H | P_H*G_L) | (P_H*P_L)*c_in
```

因此定义有序合并：

```text
(G_H,P_H) ○ (G_L,P_L) = (G_H | P_H*G_L, P_H*P_L)
```

连续三个区间不论先合并哪两个，最终均为
`G_H | P_H*G_M | P_H*P_M*G_L` 与 `P_H*P_M*P_L`，所以运算满足结合律，可以树形重组；但通常不满足交换律，高低位顺序不能颠倒。

“前缀”是为每个 i 求覆盖 `i:0` 的 G/P，进而同时得到所有 carry：

```text
c_(i+1) = G_(i:0) | P_(i:0)*cin
s_i = p_i XOR c_i
```

最后的 sum 用原始单 bit p_i，不是区间 P_(i:0)。把两者混用是常见错误。

#### 本实现：Kogge–Stone 风格的逐级距离倍增

[adder_prefix.v](lab/Adders/adder_prefix.v) 先存单 bit P/G，随后按距离 1、2、4……合并：

```text
8 位示例（s 是合并级编号）：
初始   每个节点覆盖 1 位
s=0   合并距离 1，覆盖最多 2 位
s=1   合并距离 2，覆盖最多 4 位
s=2   合并距离 4，覆盖最多 8 位
最终   节点 i 覆盖 i:0
```

关键 RTL：

```verilog
assign g[s+1][i] = g[s][i] | (p[s][i] & g[s][i-(1<<s)]);
assign p[s+1][i] = p[s][i] & p[s][i-(1<<s)];
```

i 小于合并距离时直接传递原节点，没有负下标。W=1 时 LEVELS=0，直接使用 bit P/G；W=17 时 LEVELS=5，不需要强行补到 32 位。每一级读取上一层数组，不允许在同一层从低到高反复覆盖，否则可能重新串成进位链。

对 W 为 2 的幂的全前缀网络，合并节点数为
`Σ(W−2^s)=W*log2(W)−W+1`。W=8 时为 17 个，W=32 时为 129 个。合并级数为 log2(W)，但一个合并节点不是单个物理门，且还有 P/G 生成、cin 合入和最终 XOR。

Kogge–Stone 的代价是较多节点和连线；Brent–Kung 通常用更多合并级换较少节点/布线；稀疏前缀可以只算部分进位，再在局部使用 RCA 或选择结构。本次只实现这里的全前缀版本，未给其它拓扑贴上未验证的性能数字。

#### 实验与物理局限

通用门展开后 W=32 的前缀为 547 个 cell、12 层，RCA 为 160 个、65 层。层数减少但逻辑数量增加，这才是具体可检查的架构取舍。

本实现最后把 cin 送往各位 carry 合入逻辑，因此还有 cin 扇出问题；理论前缀树内部的扇出性质不等于整个模块所有信号都低扇出。布线电容、拥塞、驱动和输入到达时间都会影响真实延迟，必须经过目标库映射与 STA 才能比较实际频率。

**面试一句话：前缀结构利用进位区间合并的结合律并行求 carry，以节点和连线换逻辑深度；结合律不允许交换高低位顺序。**

<a id="lab"></a>
### 1.8 运行、验证与综合结构对比

#### 一键入口

在 Windows PowerShell 执行，所有工具实际在 WSL root 环境运行：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab/Adders' && bash run_sim.sh"
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab/Adders' && bash run_experiments.sh"
```

两个脚本都会 `source /root/oss-cad-suite/environment`。脚本是 LF；若编辑器改为 CRLF，在 WSL 实验目录用 `sed -i 's/\r$//' run_sim.sh run_experiments.sh` 修正。所有生成文件位于 `build/`，仓库已忽略该目录。

源文件职责：

- 六个设计模块：四种两操作数加法器、`csa3.v` 压缩核、`adder_three.v` 完整三数求和器。
- [tb_adders.sv](lab/Adders/tb_adders.sv)：自检查仿真，独立使用显式宽度的数值加法计算期望值，同时检查 CSA 两行重组和最终 total。
- [adder_miter.v](lab/Adders/adder_miter.v)：把各实现与数学规格连接为组合等价比较器。
- [compare_structure.py](lab/Adders/compare_structure.py)：生成 18 个通用门结构报告和机器可读汇总。
- [check_mutations.py](lab/Adders/check_mutations.py)：仅修改 build 内副本，注入错误并检查仿真确实失败。

#### 仿真覆盖

参数契约 W≥1，CLA/CSLA 的 B≥1；TB 为控制运行规模限制 W≤64。回归配置为 `(W,B)=(1,4)、(3,4)、(5,4)、(8,4)、(17,4)、(32,4)、(17,1)、(17,7)`，覆盖最小位宽、B 大于 W、非 2 的幂、非整组尾部和 B=1 退化。

每组先测全零、最大值、不同长度的 carry 传播，再用固定种子的 xorshift 生成 2048 个三操作数向量。W≤5 时穷举 a、b、cin；W≤3 时额外穷举 a、b、d。随机测试不依赖仿真器内置随机算法，但仍不是形式证明的替代品。

2026-10-20 WSL 实测输出节选：

```text
PASS adders W=1 B=4 vectors=2071 exhaustive2=8 exhaustive3=8
PASS adders W=3 B=4 vectors=2701 exhaustive2=128 exhaustive3=512
PASS adders W=5 B=4 vectors=4115 exhaustive2=2048 exhaustive3=0
PASS adders W=8 B=4 vectors=2076 exhaustive2=0 exhaustive3=0
PASS adders W=17 B=4 vectors=2103 exhaustive2=0 exhaustive3=0
PASS adders W=32 B=4 vectors=2148 exhaustive2=0 exhaustive3=0
PASS adders W=17 B=1 vectors=2103 exhaustive2=0 exhaustive3=0
PASS adders W=17 B=7 vectors=2103 exhaustive2=0 exhaustive3=0
```

合计 19,420 次输入向量检查。每次都检查全部实现，不是把每种加法器算成一笔独立向量。失败使用 `!==` 捕获未知/错误结果，打印 FAIL 和输入，再 `$fatal(1,...)` 让脚本非零退出；成功打印 PASS 并 `$finish`，另有超时保护。

波形按配置保存在 `build/w*_b*/adders.vcd`。推荐先看 W=8/B=4：

1. `a/b/cin` 与 `rca/cla/cselect/prefix`：四个 W+1 位结果应一致。
2. `u_rca.c` 与 `u_cla.c`：看 carry 数值是否跨越组边界。
3. `d/saved_sum/saved_carry/total`：看三数求和的两行表示与完整结果。

**TB 的 `#1` 只是等待组合逻辑稳定后检查，不是 1 ns 的电路延迟。** 零延迟 RTL 波形不能测出 RCA 比前缀慢多少；也不要把所有内部进位在同一时间戳变化理解成没有物理传播时间。

#### Lint 与组合形式检查

8 组配置的六个设计模块均执行 `verilator --lint-only -Wall`，本次没有告警豁免。Yosys 展开、扁平化后 `check -assert` 检查结构，断言没有 `$dlatch`，再对 miter 的 ok 证明恒为 1：

```text
sat -verify -timeout 60 -set-def-inputs -prove ok 1 -show-inputs
```

每组都实际成功，例如：

```text
PASS formal W=32 B=4 all binary inputs
PASS formal W=17 B=7 all binary inputs
PASS Adders: 8 configurations, RTL lint + simulation + combinational proof
```

这证明**这八组已展开配置**对所有二态 a/b/d/cin 满足组合算术规格，不是只覆盖随机向量；没有证明任意参数值、X/Z 传播、物理时序或综合网表后等价。W=64 只进入下面的结构实验，不属于本次形式/仿真回归配置。

#### 通用门实验：看结构，不给未经测量的频率

结构脚本对 W=8/32/64 的六个 top 共 18 个设计，采用同一流程：

```text
read → hierarchy → proc → flatten → opt → techmap → opt
  → before.json + ltp
  → abc -g simple → clean
  → after.json + ltp
```

cell 数来自 JSON 中的实际单元数；depth 来自 Yosys `ltp` 的最长拓扑路径。该命令只在模块内部计算路径，所以先 flatten；它不是按 Liberty 延时做 STA。[Yosys ltp 说明](https://yosyshq.readthedocs.io/projects/yosys/en/v0.55/cmd/ltp.html)

真实 W=32 输出：

```text
W=32 adder_rca      before cells= 160 depth= 65 | abc cells= 160 depth= 65
W=32 adder_cla      before cells= 304 depth= 22 | abc cells= 175 depth= 65
W=32 adder_cselect  before cells= 266 depth= 16 | abc cells= 214 depth= 47
W=32 adder_prefix   before cells= 547 depth= 12 | abc cells= 250 depth= 34
W=32 csa3           before cells= 224 depth=  3 | abc cells= 192 depth=  3
W=32 adder_three    before cells= 674 depth= 14 | abc cells= 578 depth= 49
```

这些数如何解释：

- `before` 也已经过通用门展开与局部优化，并非原封不动的 RTL 实例数量；它更接近代码表达的拓扑。
- ABC 后 CLA cell 数减少，但路径增加；本次默认通用门映射没有保证保留超前结构，也没有真实时序预算驱动的最优性承诺。
- 前缀在这个 W=32 映射结果中仍有更短拓扑路径，但不能因此宣称“真实芯片快 65/34 倍”。
- CSA 核只输出两行，不能拿它的 3 层直接和两操作数 CPA 或完整三数求和器比较完成同一任务的速度。`adder_three` 才包含最终 CPA。
- 不同门的延迟/面积不同；通用 cell 数不是 μm²，逻辑层数不是 ns。也没有统计动态活动和功耗。

全部报告在 `build/structure/<top>_w<width>/synth.log`，汇总在 `build/structure/summary.json`。若要做真实 PPA 比较，应使用相同工艺库、输入驱动/到达时间、输出负载、综合目标和后端条件，再跑 STA/面积/功耗分析；本次未进行这些实验。

#### 变异测试：验证检查器能发现错误

脚本依次在副本中注入 CLA 丢 cin、前缀 P 合并把 AND 写成 OR、CSA carry 没有按权重左移三种错误。要求变异代码能编译，且仿真因算术不匹配失败；语法错误或超时不能冒充成功抓 bug。

```text
PASS mutation caught: cla_drop_cin
PASS mutation caught: prefix_wrong_propagate
PASS mutation caught: csa_wrong_weight
PASS mutations: 3/3 arithmetic errors detected
```

这不是全量故障覆盖率，也不是穷举全部单点错误；它证明最关键的三个推导点有可触发的测试检查。正确源文件没有被修改。

<a id="review"></a>
### 1.9 选择方法与面试速查

先问操作数数量、输出格式、位宽、频率/面积目标，再讨论架构：

- 两个操作数、短位宽或宽松时序：先用 `+` 或 RCA 基线，查看实际综合结果。
- 需要缩短 carry 路径：考虑分组 CLA、进位选择、前缀或混合结构，检查分组、扇出、布线和映射。
- 三个及更多操作数：优先考虑暂保两行表示的压缩结构，再在末尾做一次 CPA。
- 要每拍吞吐而组合路径过长：考虑流水线，但先定义延迟、valid/ready、停顿及复位协议。流水化和换进位结构是两个层次。

不要默认手写门级式 RTL 一定胜过 `+`；综合器可能根据库和约束选择其它实现，也可能破坏你想保留的层次。需要保留结构时要有可解释的约束策略和实现后检查，而不是盲目加 keep/dont_touch。

**面试速查：**

- **无符号 carry ≠ signed overflow；低 W 位算术相同，解释不同。**
- **RCA 串行传 carry；CLA 展开 carry 方程；CSLA 预算两个 carry 假设。**
- **CSA 输出两行，不是普通 sum/cout；carry 行的左移只能算一次。**
- **前缀利用区间合并的结合律，高低位次序不可交换。**
- **组内超前不等于整条路径对数级；必须说明组间结构。**
- **功能等价、通用门拓扑和真实 PPA 是三种证据，不能互相冒充。**

更多拓扑图和门级实现可参阅作者课程 [CMOS VLSI Design：Adders](https://pages.hmc.edu/harris/cmosvlsi/4e/lect/lect17.pdf)；本章数值结果均来自本地实验，而非课件性能数据。

<a id="multipliers"></a>
## 2. 乘法器

<a id="mul-contract"></a>
### 2.1 先说清规格：符号、结果位宽、延迟与吞吐

乘法器常用于 DSP、地址计算和处理器乘法指令。面试通常从“移位相加如何做”追问到部分积压缩、Booth 的负数处理、流水线和资源取舍。本节用三份实现分开讲清算法层次：

- [mul_shift.v](lab/Multipliers/mul_shift.v)：可选两个操作数都 unsigned 或都 signed，W 拍迭代，带请求/响应握手。
- [mul_booth.v](lab/Multipliers/mul_booth.v)：signed×signed 的组合 radix-4 Booth 重编码，随后用加法链累加。
- [mul_wallace.v](lab/Multipliers/mul_wallace.v)：unsigned×unsigned 的组合 AND 部分积，加 Wallace 风格行压缩树与最终 CPA。

后三个关键词不能混为一谈：**Booth 决定产生哪些部分积，压缩树决定怎样累加，迭代/流水决定何时复用或寄存硬件。** Booth 可以与压缩树组合，但本例有意拆开，以便分别调试；不把串联累加版本称作“Booth-Wallace 高速乘法器”。

W 位无符号数相乘最大为 `(2^W−1)^2 < 2^(2W)`，完整积需最多 2W 位。两个 W 位补码数的完整 signed 积也可用 2W 位表示；最小负数乘自身是 `2^(2W−2)`，仍在 2W 位 signed 范围内。只有截成较窄结果时才需要额外判断溢出、舍入或饱和。

相同输入 bit，signed/unsigned 的完整积并不相同。例如 8 位 a=80、b=ff：

```text
unsigned：128 × 255 = 32640 = 16'h7f80
signed： −128 × (−1) = 128 = 16'h0080
```

两者低 8 位同为 80，但高位不同；不能因低半积相同就复用未经处理的无符号高半积。

#### 从二进制展开得到部分积

无符号 `b=Σ b_i*2^i`，所以：

```text
a*b = Σ ((b_i ? a : 0) << i)
```

每一行是部分积（partial product）。4 位 a=1011（11）、b=1101（13）：

```text
  00001011   ← bit0=1
  00000000   ← bit1=0
  00101100   ← bit2=1
+ 01011000   ← bit3=1
----------
  10001111   = 143
```

移位前应先扩宽到 2W，不能在 W 位临时量里左移后再扩宽，已经移出的高位无法恢复。对于 signed b，最高位带负权，不能直接把所有 W 行都当非负 AND 部分积；本节分别用幅值转换和 Booth 处理符号。

<a id="mul-shift"></a>
### 2.2 迭代移位相加：复用一个累加数据通路

#### 每拍做什么

令 A、B 是输入幅值，初始 `acc=0、multiplicand=A、multiplier=B`。每个计算沿：

```text
若 multiplier[0]=1：acc_next = acc + multiplicand
否则：               acc_next = acc
multiplicand <<= 1
multiplier   >>= 1
```

经过 k 步后，acc 是已处理的低 k 位部分积之和，multiplicand 为 `A<<k`，multiplier 为 `B>>k`。因此在需要的精度范围内，保持
`acc + multiplicand*multiplier = A*B`；W 步后 multiplier=0，acc 就是积。

4 位 11×13 的逐步数值：

```text
步骤    旧 multiplier    旧 multiplicand    新 acc
  0          13                11             11
  1           6                22             11
  2           3                44             55
  3           1                88            143
```

RTL 的关键不是写一个 for 循环，而是寄存这三份状态，在每个时钟沿推进一次：

```verilog
wire [2*W-1:0] next_acc =
    acc + (multiplier[0] ? multiplicand : {(2*W){1'b0}});
```

最后一个计算沿必须将 **next_acc** 写入 product。若用旧 acc，就漏掉最高位乘数对应的最后一行；变异测试会稳定抓到这个错误。

#### signed 的幅值处理与最小负数

接收请求时，若 signed_mode=1，则负数输入转成 W 位无符号幅值，保存最终符号 `a_sign XOR b_sign`。计算幅值积后，再在 2W 位域中按需要取二补码。

W=8 的 −128 不能变成 8 位 signed 的 +128，但可表示为 8 位 **unsigned 幅值** 80。代码的 abs_a/abs_b 和 multiplier 都是 unsigned；它们随后零扩展到 2W 位，因此不会因“abs(min) 在 signed 域溢出”而损坏结果。

```verilog
negative <= signed_mode && (a[W-1] ^ b[W-1]);
multiplicand <= {{W{1'b0}}, abs_a};
```

不可以忘记 signed_mode 条件，否则 unsigned 输入最高位为 1 时也会被当成负数。输入与 signed_mode 都在握手时捕获，busy 期间改变外部端口不能影响已接收事务。

#### 接口时序：W 拍延迟不等于每 W 拍收一笔

本实现用 `req_valid && req_ready` 接收，用 `rsp_valid && rsp_ready` 消费响应：

```verilog
assign req_ready = !busy && !rsp_valid;
```

busy 期间不接新请求；计算结束后 busy 清零、rsp_valid 置位；响应被反压时 product 与 rsp_valid 保持。这里刻意采用简单的单请求结构，不支持响应退休的同一沿接受下一笔。

以 W=4、下游一直 ready 为例：

```text
时钟沿       E0    E1    E2    E3    E4    E5    E6
动作         接收  步0   步1   步2   步3   消费  下一笔接收
沿后 busy     1     1     1     1     0     0     1
沿后 valid    0     0     0     0     1     0     0
```

接受到响应有效的延迟为 W 周期；无反压时最小启动间隔（initiation interval）为 W+2 周期。E4 前 valid 还是 0，不能声称 E4 已消费结果；E5 前 ready 仍被旧 valid 挡住，也不能声称 E5 已接新请求。

复位采用 `negedge rst_n` 异步拉低，清除 busy/valid/product 和内部状态，未完成事务被取消。复位同步释放的系统接法见 [第 05 章](../05_Clock_Reset_Design/README.md)，本实验释放时刻避开采样沿。

**一句话：迭代乘法靠跨拍状态复用硬件；除了算式，还必须明确结果何时有效、何时能接下一笔。**

<a id="mul-booth"></a>
### 2.3 Radix-4 Modified Booth：把两位乘数变成一个有符号数字

#### 从连续的 1 到带符号重编码

连续一串二进制 1 可以用边界差表示，例如 `00111100=01000000−00000100`。Booth 利用类似思想，把乘数表示为少量正负倍数之和。radix-2 关注相邻位转变；本例实现更常用的 radix-4 修改 Booth，每次处理两位，并额外看前一位。

在乘数最低位右侧补 `b_−1=0`，第 j 个重编码数字：

```text
d_j = b_(2j−1) + b_(2j) − 2*b_(2j+1)
b   = Σ d_j * 4^j
```

这会产生 −2、−1、0、+1、+2 五种值，因此部分积只需要 0、±a、±2a。三位窗口按 **高、中、低** 顺序读取：

```text
000 / 111 →  0
001 / 010 → +a
011       → +2a
100       → −2a
101 / 110 → −a
```

这些是重叠窗口：j=0 看 `(b1,b0,0)`，j=1 看 `(b3,b2,b1)`，不能每三位分成互不重叠的组。对应权重是 `2^(2j)`，不是 `2^j`。

4 位 signed b=1001（−7）：低窗口 010→+1，高窗口 100→−2，故 `b=1+(−2)*4=−7`。若 a=−8，部分积为 −8 与 +64，总和 56。这也说明负部分积不意味着最终结果为负。

#### 奇数位宽和符号扩展

代码取 `GROUPS=ceil(W/2)`，PAD 为补到偶数位所需的 0 或 1 位：

```verilog
wire [2*GROUPS:0] b_ext = {{PAD{b[W-1]}},b,1'b0};
wire signed [2*W-1:0] a_ext = {{W{a[W-1]}},a};
```

W=3 时最高位要补 **符号位**，不是补 0。比如 −4 的 3 位表示是 100，补为 1100 后才能按 signed Booth 正确重编码；补为 0100 就把它变成 +4。

先把 a 符号扩展到运算域，再产生负倍数：

```verilog
3'b100: partial = -(a_ext <<< 1);
3'b101,3'b110: partial = -a_ext;
```

不要先在 W 位里取负再扩展：W=8 的 −128 若先做 W 位取负仍得到 80，随后符号扩展仍为负；而本例需要能得到 +128，必要时还要得到 +256。

本实现所有 partial/acc 为 2W 位 signed，移位和累加按模 `2^(2W)` 运算。某些中间位模式可回绕，但最终完整 signed 积保证可表示；不要把“每一步都无中间溢出”当成正确性的前提。W=1 的可达窗口只取 0 或 −a，不需要构造 ±2a；该边界也实际测试。

#### 这个 Booth 实现的能力边界

[mul_booth.v](lab/Multipliers/mul_booth.v) 的 case 是重编码器，for 循环中的：

```verilog
acc = acc + (partial <<< (2*i));
```

是**组合加法链**，不是多拍执行，也不是 Wallace 树。它让读者先检查重编码、符号、位宽；综合器可以重写逻辑，但本章没有依赖优化器自动帮它变成理想压缩树。

若将它推广为 unsigned，不能仅把输入端口的 signed 关键字删掉：原公式把最高位视为负权。常见做法是给 unsigned 乘数补一个最高 0 位后按扩展宽度重编码，并相应调整组数/被乘数扩展；本节 unsigned 路径由另外两份 RTL 实现，没有声称此 Booth 模块支持 unsigned。

输入包含 X/Z 时 case 的默认分支为 0，因此可能产生 X 乐观行为。功能测试和形式证明针对二态输入，不能把它当作未知值诊断设计。

**一句话：Booth 减少部分积行数，但符号扩展、重叠窗口和累加结构必须分别正确。**

<a id="mul-wallace"></a>
### 2.4 Wallace 风格压缩树：多行一起变少，而非依次做完整加法

#### 生成行、压缩到两行、最后传播进位

[mul_wallace.v](lab/Multipliers/mul_wallace.v) 先生成 W 行、每行 2W 位的 unsigned 部分积：

```verilog
assign rows[i*(2*W) +: 2*W] =
    ({{W{1'b0}},a} & {(2*W){b[i]}}) << i;
```

这里已经在移位前扩为 2W。随后 [csa_reduce.v](lab/Multipliers/csa_reduce.v) 每层把独立的三行变成两行：

```text
sum_row   = x XOR y XOR z
carry_row = ((x&y) | (x&z) | (y&z)) << 1
```

各列原理见 1.6。本层产生的 carry 直接作为下一层输入，不在本层继续串行传播。

```text
W=8 的行数变化：
8 行 → 6 行 → 4 行 → 3 行 → 2 行 → 最终 CPA → product
       层1    层2    层3    层4
```

若有 R 行，`floor(R/3)` 组各产生两行，剩余 R mod 3 行直接透传：

```text
R_next = 2*floor(R/3) + (R mod 3)
```

R=1 直接输出，R=2 才执行一次完整的 `row0+row1`。递归模块参数不断变小，在**展开阶段**生成有限的硬件层次，不是芯片运行时递归调用函数。

#### 这是什么树，不是什么树

本例是 Wallace 风格的逐层全行 3→2 压缩，便于参数化和理解；没有针对每列有效 bit 的高度做最小化，也没有实现 Dadda 调度或手工半加器优化。零位会在综合时被简化，但不能据此宣称取得最少门数。

压缩层数随操作数行数近似对数增长，不代表电路只有这几层门：还包括 AND 部分积、每层压缩的门结构、最终 CPA、扇出与布线。W=12 的行数变化为 `12→8→6→4→3→2`，有五个压缩层。

本树每行使用 PW=2W 位，carry 左移时保持 PW 位，数学上是模 `2^PW` 的压缩。对于本模块产生的非负 unsigned 部分积，完整总和本就小于 `2^PW`；因此最终乘积不丢有效最高位。若把通用树拿去累加任意多行数据，必须先根据总和上界选择 PW，不能照搬乘法器的位宽保证。

#### 与 Booth、流水线的关系

要组合 Booth+Wallace，应先生成各个重编码部分积，并正确处理符号扩展/负部分积校正，再把全部行压缩，最终 CPA。不是把已累加完成的 Booth 输出接进一棵空树；本节没有实现这个组合版本。

可以在压缩层之间插入流水寄存器，提高单级时序余量并争取每拍接收；代价是新增延迟、面积、时钟功耗以及 valid/ready 对齐逻辑。本节的 Booth 和 Wallace 模块均无时钟，未实现流水或反压，不能把组合仿真 #1 当作一级寄存器。

**一句话：Wallace 的关键是并行压缩部分积行，直到两行才做 CPA；它与 Booth 是可以组合的不同优化层次。**

<a id="mul-lab"></a>
### 2.5 WSL 实验：算术、接口、覆盖和错误注入

#### 运行入口

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab/Multipliers' && bash run_sim.sh"
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab/Multipliers' && bash run_experiments.sh"
```

当前已完成的加法与乘法全部回归，也可执行：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab' && bash run_all.sh"
```

脚本加载 `/root/oss-cad-suite/environment`，产物写 `build/`。RTL 参数要求 W≥1；TB 为确保整数参考模型与穷举规模受控，限定 W≤12。回归取 1/3/4/8/12 五种位宽。

#### 组合测试：不要把不同符号规格的输出直接比较

[tb_mul_comb.sv](lab/Multipliers/tb_mul_comb.sv) 为 Wallace 用无符号整数参考，为 Booth 用独立的补码数值解释再相乘。W≤4 穷举所有输入对，每种位宽另加 1024 个固定种子向量，以及 0、−1、最小负数、最大正数等定向组合。每个向量同时检查两种不同的产品规格。

实际结果：

```text
PASS comb W=1 vectors=1035 booth_codes=2
PASS comb W=3 vectors=1095 booth_codes=6
PASS comb W=4 vectors=1287 booth_codes=8
PASS comb W=8 vectors=1031 booth_codes=8
PASS comb W=12 vectors=1031 booth_codes=8
min_times_min W=8 bits=80 signed_product=4000
```

共 5,479 个组合向量。最后一行是实测 `−128×−128=16384`，16 位结果 4000。

覆盖也要尊重可达性：W=1 只有两种 Booth 窗口；W=3 最低窗口含补 0、最高窗口含重复符号位，因此总共只有六种可达窗口，不能要求八种全覆盖。W≥4 的这些测试配置实际覆盖了全部八种窗口。这里的统计由 TB 的整数模型计算，不是宣称使用了商业 covergroup 覆盖流程。

#### 迭代测试：不能只等一个完成信号再看乘积

[tb_mul_shift.sv](lab/Multipliers/tb_mul_shift.sv) 对每种 signed_mode 做穷举/定向/固定种子测试，并检查：

- 接收后 busy 拉起；每个计算沿都检查不能提前出结果，恰好 W 周期后 valid 有效。
- busy 期间故意注入 req_valid 和 a/b/signed_mode 变化，确认没有非法重接收或输入污染。这部分是对抗性刺激，会撤回未接受请求，不作为遵守“valid 保持到握手”约定的源端 BFM；正常流量另由末尾八笔连续事务验证。
- 每笔定向/随机事务将响应反压三周期，检查 product/valid 保持、req_ready 被阻挡。
- 运算中异步复位取消事务，随后 W+2 个周期没有迟到响应，并能再次正确计算。
- 连续请求、下游始终 ready 的八笔流量，逐次核对接收间隔为 W+2，且收发守恒。

真实输出：

```text
PASS iterative W=1 transactions=153 latency=1 hold_checks=435 reset_aborts=1 stream=8 interval=3
PASS iterative W=3 transactions=273 latency=3 hold_checks=795 reset_aborts=1 stream=8 interval=5
PASS iterative W=4 transactions=657 latency=4 hold_checks=1947 reset_aborts=1 stream=8 interval=6
PASS iterative W=8 transactions=145 latency=8 hold_checks=411 reset_aborts=1 stream=8 interval=10
PASS iterative W=12 transactions=145 latency=12 hold_checks=411 reset_aborts=1 stream=8 interval=14
```

共 1,373 笔完整事务，另有每种位宽一次复位中止，共 5 笔。latency/interval 的单位是时钟周期，不能当作纳秒或最高频率。TB 的 10 ns 时钟只定义仿真节奏，不代表通过了 100 MHz STA。

波形在 `build/w*/mul_comb.vcd` 和 `mul_shift.vcd`。组合先看 a/b 与两种 product，务必选择正确的有符号显示方式；迭代看 req_valid/req_ready、busy、count、multiplier、multiplicand、acc、rsp_valid/rsp_ready/product。特别看最后一拍 acc 的新值与 product，以及反压时的保持。

#### Lint、结构检查和形式证明边界

五种位宽的三个设计 top 均通过 Verilator `-Wall` lint，无告警豁免；Yosys 展开/扁平化后检查结构，并断言没有 `$dlatch` 或 `$mul`，确认设计没有意外 latch，也没有用 RTL `*` 偷代替手写数据通路。参考模型中的 `*` 仅存在于 TB/miter，不属于这项设计检查。

[mul_miter.v](lab/Multipliers/mul_miter.v) 对 W=1/3/4 的两个组合乘法器证明全部二态输入都等价于各自的乘法规格，实际输出：

```text
PASS formal combinational multipliers W=1
PASS formal combinational multipliers W=3
PASS formal combinational multipliers W=4
PASS Multipliers: 5 widths; combinational + iterative; 3 small-width proofs
```

没有对 8/12 位组合乘法器或迭代时序协议做形式证明；它们通过所列仿真。结构检查不是目标库映射，未比较物理面积、延时、功耗，也未做带 SDF 的门级仿真。

#### 变异检查

[check_mutations.py](lab/Multipliers/check_mutations.py) 只改变 build 中的源副本；要求编译成功且因算术不匹配失败，不把编译错误、超时或任意非零退出算成“抓到 bug”：

```text
PASS mutation caught: last_bit_lost
PASS mutation caught: unsigned_gets_negated
PASS mutation caught: booth_no_sign_extend
PASS mutation caught: booth_odd_padding
PASS mutation caught: wallace_carry_weight
PASS multiplier mutations: 5/5
```

分别对应最后一位贡献遗漏、unsigned 被错误取负、被乘数漏符号扩展、奇数位宽补位错误、CSA carry 权重错误。它们验证关键检查点有效，不代表所有可能错误都被穷举。

<a id="mul-review"></a>
### 2.6 结构选择与常见追问

若面积/并发需求不高、允许多周期延迟，迭代结构容易复用资源；若需要高吞吐，可以考虑组合树加流水。但“有乘法符号”并不意味着必须手写结构：实际项目也常让工具把 `*` 映射到标准单元或 FPGA DSP，是否值得手写要用约束和实现报告判断。

有符号 unsigned 混乘还要另定规格，本章 signed_mode 表示两个操作数都按同一类型解释，不支持“一边 signed 一边 unsigned”的独立模式。高半积、MAC、截断乘法和舍入也需要额外规则，不能随意丢位后沿用完整乘法的正确性结论。

**面试速查：**

- **完整 W×W 积通常保留 2W 位；先扩展再移位/取负。**
- **最小负数的幅值可以存在 W 位 unsigned 中，不能存在同宽 signed 正数中。**
- **Booth 三位重叠窗口每次前进两位；奇数位宽的高端补符号。**
- **Booth 只减少行数；串联累加仍可能很深。**
- **Wallace 风格压缩树每层并行 3→2，最后才做 CPA。**
- **延迟、启动间隔和反压保持分别验证；本迭代版本为 W 与 W+2。**
- **本节已实现迭代和组合电路；流水、Booth+Wallace 融合及 PPA 是后续扩展，未冒充已验证结果。**

需要进一步看部分积点阵和数据通路图，可参阅作者课程 [CMOS VLSI Design：Datapath Functional Units](https://pages.hmc.edu/harris/cmosvlsi/4e/lect/lect18.pdf)；本节回归数字来自本地源代码与日志。

<a id="dividers"></a>
## 3. 除法器

除法出现在整数 ALU、地址换算、比例计算中。长除法每一步都依赖前一步余数，天然适合复用一个加减器进行多拍迭代。面试重点不是背“移位再减”，而是解释商位如何产生、为什么余数范围受限、有符号结果如何还原，以及什么时候才算一次请求完成。

<a id="div-contract"></a>
### 3.1 先定义数学与接口契约

本节 [div_iter.v](lab/Dividers/div_iter.v) 的参数 `W>=1`，`NONRESTORE=0/1` 选择恢复/不恢复余数算法。输入 a、b 和输出 quotient、remainder 都是 W 位位向量，`signed_mode` 决定两个输入同时按 unsigned 或 signed 解释。混合符号除法不在接口范围内。

对非异常输入：

```text
A = Q × B + R
unsigned：0 <= R < B
signed：Q 向零截断，|R| < |B|，非零 R 与 A 同号
```

因此 `−13 / 3 = −4`、余数 `−1`；`13 / −3 = −4`、余数 `1`；`−13 / −3 = 4`、余数 `−1`。余数跟被除数走，不能照抄商的符号，也不能把向零截断混同于向负无穷取整。

实现先对幅值做无符号除法，再恢复符号。8 位 `8'h80` 表示 −128，它的幅值 128 可放入 **8 位 unsigned**，不能放入 8 位 signed 正数；本实现的幅值寄存器均为 unsigned。

**本实验明确选择以下异常规则，这是模块契约，不表示所有处理器都必须如此：**

- `b==0`：`div_zero=1`，商全 1，余数原始 a，`overflow=0`。
- signed 最小负数除以 −1：`overflow=1`，商保持最小负数位模式，余数 0，`div_zero=0`。例如 8 位 `−128 / −1` 的数学结果 128 无法表示，输出 `8'h80`。
- 其余请求两个标志为 0。标志与结果一同有效，在反压期间保持。
- 所有请求，包括异常请求，都在接收后 **W 个计算时钟沿**产生响应；没有提前退出。异常结果不要求满足正常除法恒等式。

`req_valid && req_ready` 在上升沿接收输入。`rsp_valid && rsp_ready` 在上升沿消费响应。发送者必须在请求未被接收时保持 valid 和负载，接收者可以反压；模块只容纳一笔未完成事务。复位为低有效异步 `rst_n`，丢弃正在计算或尚未消费的结果，复位期间 `req_ready=0`。系统层如何安全释放异步复位参见 [第 05 章](../05_Clock_Reset_Design/README.md)。

<a id="div-restoring"></a>
### 3.2 恢复余数除法：试减失败就保留试减前的值

恢复余数（restoring division）是二进制长除法。令 D 为正的除数幅值，初始 R=0，从被除数最高位开始，每步取一位 x：

```text
S = 2R + x
T = S − D
若 T >= 0：本位商=1，下一轮 R=T
若 T <  0：本位商=0，下一轮 R=S
```

为什么每步只需减一次？假设上一轮 `0<=R<D`，则 `0<=S<=2D−1`。减一次 D 就足以把非负结果放回 `[0,D)`；减后为负则 S 本来就在这个区间。这同时给出了每轮的**不变量（invariant）**和可直接写入 TB 的检查条件。

教材中的“恢复”可以理解成试减后再加回 D；硬件无需真的串联一个加法器做恢复，而可用 mux 选择保存的 S。本实现正是：

```verilog
wire signed [W+1:0] r_next =
    (NONRESTORE == 0 && trial[W+1]) ? shifted : trial;
```

商/被除数共用 `q_work`：初值为被除数幅值，最高位逐拍送入余数，整体左移，最低位填入新商位。W 轮之后初始被除数位全部移出，寄存器只剩商。

<a id="div-nonrestoring"></a>
### 3.3 不恢复余数除法：允许负部分余数，下一步补偿

不恢复余数（non-restoring division）让试减失败的负数留下来，下一轮根据**旧部分余数**符号选加或减：

```text
旧 R >= 0：T = 2R + x − D
旧 R <  0：T = 2R + x + D
下一轮 R=T，本位商 = (T>=0)
W 轮结束后：若 R<0，执行 R=R+D
```

推导补偿项：若上一轮试减得到负值 `R=S−D`，恢复算法会保存 `S=R+D`。下一轮正常试减应为 `2(R+D)+x−D = 2R+x+D`，因此负部分余数的下一轮应加 D。**选择加减看旧 R，决定新商位看新 T**，两者不能混用。

对 D>0，不变量变为 `−D<=R<D`。旧 R 非负时，`2R+x−D` 位于 `[−D,D−1]`；旧 R 为负时，`2R+x+D` 仍在同一区间。末轮若为负，只需加回一次 D，恢复到通常的非负幅值余数；不需要重新计算商。

下面来自 W=4、unsigned `13/3` 的实际运行（Q 是还混有未处理被除数位的 q_work，只有末轮才是完整商）：

```text
TRACE step=1 restoring_R=1 nonrestoring_R=-2 Q=10
TRACE step=2 restoring_R=0 nonrestoring_R=0 Q=5
TRACE step=3 restoring_R=0 nonrestoring_R=-3 Q=10
TRACE step=4 restoring_R=1 nonrestoring_R=-2 Q=4
```

最后不恢复算法的 R=−2，加回 3 得 1，与恢复算法一致，`13=4×3+1`。如果只检查“整除”的用例，很容易漏掉最后一次校正；本实验也统计真正执行了该校正的正常事务。

<a id="div-rtl"></a>
### 3.4 RTL：符号保护位、最终 next 值与接口时序

两种算法共享状态和接口，通过常量参数选择数据通路，综合时常量分支会被化简：

```text
输入 → 捕获幅值/符号/异常
                ↓
        q_work 最高位 ──→ 部分余数左移 → 加/减 D → 部分余数寄存器
                ↑                         │
                └──── 左移并填入新商位 ─────┘
                   W 轮后 → 校正余数/恢复符号 → 输出寄存器
```

`partial` 使用 W+2 位 signed，`divisor` 使用 W 位 unsigned。即使最终余数小于 D，移位后的中间值也可能接近 ±2D，所以不能把中间值塞进仅 W 位，也不能把最高位简单视为 unsigned 借位。先零扩展除数、明确 signed，再在足够宽的域内判断符号：

```verilog
wire signed [W+1:0] shifted = {partial[W:0], q_work[W-1]};
wire signed [W+1:0] d_ext = $signed({2'b00, divisor});
wire signed [W+1:0] trial =
    (NONRESTORE != 0 && partial[W+1]) ? shifted + d_ext : shifted - d_ext;
wire [W-1:0] q_next =
    (q_work << 1) | {{(W-1){1'b0}}, !trial[W+1]};
```

末轮必须输出 `q_next` 和由 `r_next` 校正得到的 `r_mag`。在时序 always 内写 `q_work <= q_next` 后，右侧 q_work 仍是旧值，拿它输出会少算最后一位。`r_mag` 的校正使用低 W 位模加法，正常输入校正后的真实值已证明处于 `[0,D)`，因此低 W 位足够；除零走明确的输出旁路，不依赖这一证明。

最小负数除以 −1 时，幅值商为 `2^(W−1)`，恢复符号后保留该位模式，溢出标志另行报告；没有悄悄饱和到最大正数。原始 a、符号和异常判断都在请求接收时锁存，之后总线改变不应影响结果。

计数器宽度是 `max(1,clog2(W))`，终止值为 W−1。这样 W=1 不产生零位宽寄存器，W=3/12 等非二次幂也能正确结束。参数 W 任意正整数可展开，但本节的工具验证范围只是 1/3/4/8/12，不能据此声称所有参数已形式证明。

无反压时，以接收沿 E0 为基准：

```text
沿：      E0     E1 ... EW      E(W+1)       E(W+2)
行为：    接收   计算   结果生成  响应被消费     可接收下一笔
busy：    1      1      0
rsp_valid：0            1       0
```

结果在 EW 沿之后变为有效，接收端最早在下一沿消费。实现不允许消费旧响应与接收新请求发生在同一个沿，因此最小**启动间隔（initiation interval）为 W+2**，不能称为每 W 拍一笔。`rsp_ready=0` 时，valid、商、余数和两个异常标志保持；无空闲状态自动重算。

<a id="div-lab"></a>
### 3.5 在 WSL 运行，验证哪些性质

文件入口：

- [div_iter.v](lab/Dividers/div_iter.v)：两种算法的参数化可综合实现。
- [tb_div_iter.sv](lab/Dividers/tb_div_iter.sv)：同时驱动两个实例，用独立的整数 `/`、`%` 参考模型检查结果；先处理异常再使用参考运算。
- [run_sim.sh](lab/Dividers/run_sim.sh)：五个位宽 × 两种算法的 Verilator lint、Yosys 结构检查及 Icarus 仿真。
- [check_mutations.py](lab/Dividers/check_mutations.py) 和 [run_experiments.sh](lab/Dividers/run_experiments.sh)：注入五种错误并检查测试是否拒绝。

在 PowerShell 中执行（EDA 全部在 WSL）：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab/Dividers' && bash run_sim.sh && bash run_experiments.sh"
```

WSL 内可直接在该目录运行两个脚本；脚本加载 `/root/oss-cad-suite/environment`。整章当前完成范围运行 [lab/run_all.sh](lab/run_all.sh)。

实际输出：

```text
PASS dividers W=1 transactions=16 algorithms=2 latency=1 hold_cycles=16 corrections=2 reset_aborts=2 interval=3
PASS dividers W=3 transactions=136 algorithms=2 latency=3 hold_cycles=256 corrections=68 reset_aborts=2 interval=5
PASS dividers W=4 transactions=520 algorithms=2 latency=4 hold_cycles=1024 corrections=303 reset_aborts=2 interval=6
PASS dividers W=8 transactions=1082 algorithms=2 latency=8 hold_cycles=2148 corrections=714 reset_aborts=2 interval=10
PASS dividers W=12 transactions=1082 algorithms=2 latency=12 hold_cycles=2148 corrections=718 reset_aborts=2 interval=14
```

合计 **2,836 笔输入事务，每笔同时检查两种算法，共 5,672 组商/余数结果**。W=1/3/4 穷举全部输入组合及两种符号模式；W=8/12 每种符号模式使用 25 个边界组合和 512 个固定种子的 xorshift 随机输入。每个位宽再运行 8 笔连续无反压事务检查 W+2 间隔。TB 的整数参考仅面向这里的 W<=12，扩大位宽需同步扩展参考模型，避免 32 位 integer 溢出。

正常向量每笔保持响应两拍，共 5,592 个反压保持周期；每个位宽分别在计算中和响应等待中复位，合计 10 次中止（两个算法同时中止），检查异步清空与无幽灵响应。逐拍验证两种部分余数不变量；除零不适用该不变量，改查异常结果。改变无效输入总线验证输入锁存。固定 W 延迟包括除零和溢出用例。

`lint` 是静态代码检查，不需要测试激励；本实验 `verilator --lint-only -Wall` 没有警告豁免。它有助于发现位宽、符号、未使用信号等问题，但不能代替功能仿真。Yosys 经过 `proc; opt; check -assert`，再断言无 `$dlatch/$div/$mod`，确认没有意外锁存器或把 RTL 运算隐藏为内建除法单元；这不是功能等价证明，也不是实际工艺面积/时序报告。

五个变异分别删除恢复选择、删除末轮余数校正、误用商符号作为余数符号、使用旧商输出，以及破坏除零余数。每个变异必须编译成功，并因 `division mismatch` 或 `partial invariant` 自检查失败才算抓到；编译错误和超时不算有效检出。

本节变异测试的实际结尾：

```text
PASS mutation caught: missing_restore
PASS mutation caught: missing_final_correction
PASS mutation caught: wrong_remainder_sign
PASS mutation caught: stale_final_quotient
PASS mutation caught: wrong_divzero_remainder
PASS Dividers mutations: 5/5
```

波形路径为 `lab/Dividers/build/w4/dividers.vcd`。在 WSL 中可自行运行：

```bash
gtkwave build/w4/dividers.vcd
```

先看 req_valid/ready 与 rsp_valid/ready，再展开 `impl[0].dut` 和 `impl[1].dut`，观察 q_work、partial、trial、r_next、count。把 partial/trial 显示为 signed 十进制；观察 unsigned 13/3 的四轮与末轮校正。验证响应阻塞时输出稳定，复位下降沿立刻清除 busy/valid。VCD、工具日志与变异副本均在忽略的 build 目录中。

**验证边界：**本节没有时序形式证明，没有工艺映射、STA、PPA 或门级仿真。随机和小位宽穷举不能证明任意宽度与所有时序；TB 也不是覆盖所有合法请求调度的协议形式验证环境。

<a id="div-review"></a>
### 3.6 结构扩展与面试速查

恢复算法保存非负部分余数，适合先从长除法理解；不恢复算法允许负部分余数并在下一轮补偿，需要加减选择和末轮校正。二者都每轮产生一位商，当前实现都是 W 拍。恢复版使用 mux 避免“减后再加”的串联路径，所以不能仅凭名称断言不恢复版一定更快；本版本末轮还包含校正及符号恢复组合逻辑，真实关键路径需综合与 STA 判断。

若要求更高吞吐，可将多轮展开并流水化，但会复制算术硬件，还需随流水携带除数、符号、异常与 valid，反压不能只暂停最后一级。若只缩短平均延迟，可考虑前导零检测、`A<B`、除数为 1 等提前结束路径，此时需要改写固定延迟契约和测试。

除以 unsigned 的 `2^k` 可拆为右移和低位取余；signed 负数不能直接套算术右移，因为算术右移通常对应向负无穷取整，例如 `−13 >>> 2` 得 −4，而向零截断的 `−13/4` 应为 −3。需要对负且存在被丢弃位的结果进行校正，并相应构造余数。常数除法、倒数乘法和高基数选商是进一步优化方向，当前实验未实现。

面试前至少能独立回答：

- **恢复版：试减失败选择移位前一轮余数得到的 S，商位 0；不恢复版：保留负值，下一步加 D。**
- **选加减看旧符号，产生商位看新符号，末轮负余数还要加 D。**
- **signed 商向零截断，余数与被除数同号；异常行为要写成规格。**
- **幅值是 unsigned；移位加减需要保护位；最终输出要用 next 值。**
- **W 拍计算、W+2 最小启动间隔和反压等待是三个不同的时间概念。**
- **功能测试、lint、结构检查各自提供不同证据，不能由它们宣称物理性能已达标。**

<a id="fixed-float"></a>
## 4. 定点与浮点

前面处理的是整数位向量；在滤波、控制、音频和机器学习计算中，同样的加法器、乘法器还要表示小数。关键是**位串本身不携带小数点，解释规则属于接口规格**。本节先说明定点数如何缩放和控制误差，再用浮点编码解释动态范围、精度和特殊值。

<a id="fixed-format"></a>
### 4.1 Q 格式：硬件存整数，数值由比例解释

用 `(W,F)` 明确表示 signed 定点格式：W 是含符号位的总位宽，F 是小数位数，二进制补码整数 X 代表：

```text
x = X × 2^(−F)
分辨率 Δ = 2^(−F)
范围 = [−2^(W−1−F), 2^(W−1−F) − 2^(−F)]
```

推导很直接：W 位补码整数范围为 `−2^(W−1)` 到 `2^(W−1)−1`，所有值乘上同一个比例 `2^(−F)`。例如 `(8,4)` 的分辨率为 1/16，范围为 `[−8,7.9375]`；`8'h18` 的整数值 24 代表 1.5，`8'he8` 的整数值 −24 代表 −1.5。

“Qm.n”存在是否把符号位计入 m 的不同习惯。若 m 不含符号位，`Q3.4` 的总宽是 `1+3+4=8`；若计入符号位，同一格式会写成 Q4.4。因此接口应直接写“signed、W=8、F=4、饱和/回绕规则”，不要仅写一个 Q 名称让上下游猜测。

unsigned 也可使用同样比例，但范围变为 `[0,(2^W−1)×2^(−F)]`。本实验转换器只实现 signed；不通过修改输入标签假装支持 unsigned。

当 W 固定，增加 F 会缩小可表示范围、提高小数分辨率；减少 F 则相反。例如 `(8,7)` 的范围 `[−1,127/128]`，**不能表示 +1**。输入信号是否可能达到或超过 +1，直接决定格式选择与溢出策略。

<a id="fixed-scale"></a>
### 4.2 加乘除中的小数点与保护位

**加减必须先对齐比例。** 若 a 的 F=4、b 的 F=2，把 b 的整数编码左移 2 位，才可在 F=4 的域内相加。左移前要先符号扩展并预留空间；直接把两个原始编码相加，会把不同单位的量混在一起。同宽同 F 的两个 signed 数相加，完整结果通常增加一位，F 不变。

**乘法的小数位相加。** 因为：

```text
(A × 2^(−Fa)) × (B × 2^(−Fb)) = (A×B) × 2^(−Fa−Fb)
```

完整积保留 Wa+Wb 位，F=Fa+Fb。例：两个 `(8,4)` 数 1.5 与 −0.75 的编码是 24 和 −12，16 位完整积为 −288，F=8，数值为 −1.125。若输出仍是 `(8,4)`，应把 −288 按比例缩成 −18；该例恰好精确，不需要舍入。不能直接截取乘积低 8 位当作原 Q 格式结果。

MAC（multiply-accumulate，乘加累加）通常先在宽域累加，最后再舍入一次。同格式 K 项相加，保守增加 `ceil(log2(K))` 位整数保护位，F 不变；例如 16 项 16 位完整积可用 20 位累加器覆盖最坏范围。若每项提前量化，量化误差可能逐项累积；若信号范围已知，可进一步推导更紧位宽，而不是无条件套保守值。

**除法要为目标小数精度预缩放。** 对编码 A/B，目标 Fq 位小数需要：

```text
Q ≈ (A/B) × 2^(Fb−Fa+Fq)
```

当指数非负，可先在足够宽的域把分子左移，再做整数除法。例：`1.5/0.5`，A=24、B=8、Fa=Fb=4、Fq=4，应算 `(24<<4)/8=48`，对应 3.0。直接算 `24/8=3` 后解释成 Fq=4 会得到 0.1875。指数为负时涉及进一步缩放和丢位，不能在不分析舍入的情况下先截分子。第 3 节除法器没有自动处理这些定点比例。

格式转换的通用整数目标是 `T=X×2^(Fo−Fi)`：Fo>Fi 时左移补零；Fo<Fi 时右移并舍入。**补更多小数位不会创造新信息，缩少小数位才会引入量化误差。**

<a id="fixed-round"></a>
### 4.3 截位、四种舍入与饱和：三件事分别定义

将目标的最小步长记为 Δ，设转换前的理想目标编码是 t。下列模式选择邻近整数编码：

- 向负无穷取整（floor）：取不大于 t 的最大整数。
- 向零截断（toward zero）：丢掉数值的小数部分。
- 最近偶数舍入（round to nearest, ties to even，RNE）：取最近整数，恰好居中时取偶数。
- 向正无穷取整（ceil）：取不小于 t 的最小整数。

**补码直接算术右移相当于 floor，不是对所有符号都向零截断。** 例如编码 −26 右移 2 位为 −7，因为 `−26=4×(−7)+2`；向零截断 `−26/4` 应是 −6。这里低两位 `10` 表示相对 floor 基数的非负余量 2，不能再把它当负的尾数。

对右移 k 位的数，写成 `X=q×2^k+r`，其中 q=floor、`0<=r<2^k`。四种模式均可写成 q 加 0 或 1：

```text
floor：      不加
toward zero：X<0 且 r!=0 时加 1
RNE：        r>2^(k−1)，或 r==2^(k−1) 且 q 为奇数时加 1
ceil：       r!=0 时加 1
```

RNE 对负数也成立：`−26/4=−6.5`，floor 基数 −7 为奇数，加 1 得 −6；`−22/4=−5.5`，floor 基数 −6 已为偶数，不加。正数 `22/4=5.5` 得 6，`26/4=6.5` 也得 6。“半入”会把所有正的恰好半点向上推；取偶数避免该规则固定偏向同一侧，但不能保证任意有限输入集合的平均误差一定为零。

无溢出时，RNE 满足 `|量化后−原值|<=Δ/2`；floor 的误差在 `(-Δ,0]`，ceil 在 `[0,Δ)`，toward zero 的误差朝零方向且绝对值小于 Δ。这些是单次转换的绝对误差界，不是整个滤波链路的误差或信噪比结论。

**舍入决定保留哪个邻点，饱和决定超出范围时怎么办。** 输出 Ow 位时，舍入后的编码合法范围为 `L=−2^(Ow−1)` 至 `H=2^(Ow−1)−1`。饱和（saturation）把低于 L 的结果钳到 L，高于 H 的结果钳到 H；回绕（wrap-around）则只保留低位，可能把很大的正值变成负值。二者都能设计，但必须事先约定。

以 `(8,4)→(4,2)` 为例，输入 1.875 的编码 X=30，理想目标编码是 7.5；RNE 应先取 8，再发现超过 H=7，输出 7，即 1.75，并报告溢出。**先截成 4 位再判断溢出，会把编码 8 误解释成 −8。** 饱和后不能继续使用“误差不超过半个 LSB”的一般保证。

本实验 `overflow` 精确定义为“**舍入后的无限范围整数编码**超出输出范围”，`inexact` 表示最终数值与输入数值不相等，包括饱和造成的误差。因此原值略超最大可表示数、却向下舍入到最大值时，overflow 可以是 0，而 inexact 是 1；这不是原始数值越界检测器，也不是 IEEE 浮点异常标志。

<a id="fixed-rtl"></a>
### 4.4 可综合定点格式转换器

[fixed_quantize.v](lab/Fixed_Float/fixed_quantize.v) 是组合模块，参数为输入/输出总宽 `IW/OW`、小数位数 `IF/OF`，满足 `IW,OW>=1`、`0<=IF<IW`、`0<=OF<OW`。这里 IF 是参数名，不是小写 Verilog 关键字 `if`。模式编码为 `0=floor, 1=toward zero, 2=RNE, 3=ceil`。没有时钟、握手或复位；上游寄存器和下游时序约束由集成者负责。

核心数据通路：

```text
signed X → 符号扩宽 → 比例移动 → floor 基数 + 舍入增量
                           └→ 丢位/半点检测      ↓
                                    宽域上下限比较 → 饱和/取低位 → Y
```

内部宽度 `EW=IW+OW+2` 是方便理解的保守选择，足够承载最大合法左移和舍入进位，不是最小面积的位宽设计。左右缩放用 generate 分开，IF=OF 和左移路径没有丢位；右移路径仅当 `IF>OF` 时才引用低位，避免出现负下标或零宽切片。

```verilog
wire signed [EW-1:0] extended = {{(EW-IW){x[IW-1]}}, x};
// 右移分支：
assign base = extended >>> SHIFT;
// 舍入：
2'd1: increment = x[IW-1] && lost;
2'd2: increment = above_half || (tie && base[0]);
// 在宽域比较之后，才保存 OW 位：
if (rounded > MAXIMUM) begin
    y = MAXIMUM[OW-1:0];
    overflow = 1'b1;
end
```

SHIFT=1 时，丢弃部分只有 0 或 1，最多恰好半点，不可能“大于半点”，因此单独生成 `above_half=0`。这也避免了工具对常量比较的警告和 `tail[-1:0]` 之类无效切片。EW 位的上下限明确声明为 signed；漏掉 signed 会让负数比较改变含义。

常见错误包括：unsigned 信号上使用 `>>>` 后期待符号填充；在原 IW 位内先左移再扩宽；最近舍入一律加半个单位而不处理 tie；饱和比较之前先截成 OW 位；只用丢弃的小数位生成 inexact，漏掉“原来是整数但被饱和”的数值损失。下面的变异测试覆盖后面几类典型错误。

<a id="float-format"></a>
### 4.5 IEEE 754 binary32：指数移动小数点

定点在整个范围使用相同步长；浮点用符号、指数和有效数表示值，能覆盖更宽动态范围，但间隔随指数改变。binary32 的布局是：

```text
31            30               23 22                         0
+---------------+----------------+----------------------------+
| sign s : 1 bit| exponent E : 8 | fraction f : 23 bits       |
+---------------+----------------+----------------------------+
```

把 f 看作 0 到 `2^23−1` 的整数：

- `1<=E<=254`：正规数（normal），值为 `(-1)^s × (1+f/2^23) × 2^(E−127)`。
- `E=0, f!=0`：次正规数（subnormal），值为 `(-1)^s × (f/2^23) × 2^(−126)`。
- `E=0, f=0`：带符号的零。
- `E=255, f=0`：带符号的无穷大。
- `E=255, f!=0`：NaN（not a number）。

正规数有隐含的首位 1，因而有 24 位有效精度；次正规数首位为 0，指数固定为 −126。编码规则可核对 [Oracle Numerical Computation Guide：Single Format](https://docs.oracle.com/cd/E37069_01/html/E39019/z4000ac019178.html)。

自己推一遍 1.5：二进制为 `1.1×2^0`，s=0，E=127，fraction 只有最高位为 1，得到 `32'h3fc00000`。−1.5 只改变符号位，得到 `bfc00000`。**浮点负数不是把整个正数位串取补码。**

几个边界可直接由公式得到：

```text
00000001：最小正次正规数，2^(−149)
007fffff：最大正次正规数，(2^23−1)×2^(−149)
00800000：最小正正规数，2^(−126)
7f7fffff：最大有限正数，(2−2^(−23))×2^127
7f800000 / ff800000：+∞ / −∞
00000000 / 80000000：+0 / −0
```

最小正规数与最大次正规数之间仍相差 `2^(−149)`。这就是渐进下溢（gradual underflow）留下的过渡区域；若把所有次正规数强制当成零，会改变小数值运算语义。越靠近零，次正规数可用的相对有效精度越少，不能继续保证正规数的相对误差界。

在 `[2^e,2^(e+1))` 的正正规数区间，相邻间隔为 `2^(e−23)`，称为该区间的一个 ULP（unit in the last place）。例如 1 附近向上的间隔是 `2^−23`；到 `2^24` 处向上的间隔已是 2，因此 `2^24+1` 恰好居中，RNE 会回到 `2^24`。增加动态范围并不意味着每个整数或十进制小数都能精确表示。

0.1 的 binary32 位模式为 `3dcccccd`。本地脚本把该值转为精确有理数，与 1/10 相减，得到误差 `1/671088640`。这是编码量化产生的误差，不是显示十进制时才产生的问题。

NaN 分安静 NaN（quiet NaN，qNaN）和信号 NaN（signaling NaN，sNaN）。本实验采用 fraction 最高位 `f[22]=1` 表示 qNaN、为 0 且其余 payload 非零表示 sNaN 的约定，见 [Berkeley HardFloat 的 NaN 编码说明](https://www.jhauser.us/arithmetic/HardFloat-1/doc/HardFloat-Verilog.html)。NaN 不能仅匹配一个固定常量；`7fc00000` 只是其中一个编码。sign 不用于判断 NaN 类别。

[fp32_classify.v](lab/Fixed_Float/fp32_classify.v) 对原始 32 位编码做组合分类，输出 sign 和六位 one-hot kind：bit0=zero、bit1=subnormal、bit2=normal、bit3=infinity、bit4=qNaN、bit5=sNaN。它不修改 payload，不把 sNaN 静默转换成 qNaN，也不产生运算异常。不要先用宿主语言浮点加载再分类 sNaN，否则某些浮点路径可能已经把它安静化。

<a id="float-arithmetic"></a>
### 4.6 浮点加乘的硬件流程、舍入和异常

以有限数浮点加法为例，典型思路为：

```text
解码/特殊值判断
    → 比较有效指数，较小操作数右移对阶
    → 按符号加减有效数
    → 规格化（处理进位或抵消后的前导零）
    → 根据保留位与丢弃位舍入
    → 必要时再次调整指数
    → 编码结果与异常状态
```

次正规输入的有效指数与隐含位不同，不能直接把 exponent 字段作普通整数相减。异号相减可能产生大量前导零，通常需要前导零检测和左移；同号相加可能多出一位，需右移并增加指数。舍入也可能再次产生进位。流水级如何切分是实现选择，本节未实现此完整数据通路。

浮点乘法则对符号异或、有效指数相加并处理偏置、有效数相乘，然后规格化和舍入。binary32 的两个正常有效数各 24 位，完整有效数积需要 48 位；“输出只有 23 位 fraction”不表示可直接省略所有低位，因为它们影响舍入。融合乘加 FMA（fused multiply-add）对精确的乘加整体最后舍入一次，与先舍入乘法结果再加法可能不同。

硬件常用保护位 G（guard）、舍入位 R（round）和粘滞位 S（sticky）保存丢位信息：G 是保留位之后第一位，R 是再后一位，S 是更低所有位的 OR。对规范化后的正幅值进行 RNE，增量判断可写成：

```text
increment = G && (R || S || retained_LSB)
```

`G=1,R=S=0` 为恰好半点，只在保留末位为奇数时进位。S 不是“最后一位”，也不能在多次移位时丢掉此前已经丢失的非零信息。GRS 是舍入决策的摘要，不表示只要保留三个附加位就能忽略对阶、抵消和规格化的正确性。有关精确舍入与保护位的背景见 [Goldberg：Floating-Point Arithmetic](https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html)。

浮点环境还要规定舍入方向和异常。除常见的最近偶数、向零、向正/负无穷外，还有“最近、半点远离零”的规则；不能说标准只存在四种规则。常见五类异常为 invalid、divide-by-zero、overflow、underflow、inexact。underflow 不能仅依据输出是 subnormal 就置位；在通常的默认异常处理下，还涉及 tiny 与 inexact，并需明确在舍入前还是舍入后检测 tiny。参考 [SoftFloat 的舍入、下溢检测与异常接口](https://www.jhauser.us/arithmetic/SoftFloat-3/doc/SoftFloat.html)。

用具体例子区分这些概念：

- `0/0`、`∞−∞` 属于 invalid 的典型情况；非零有限数除以零是 divide-by-zero，默认得到有符号无穷大。这不同于第 3 节整数除法的自定义返回规则。
- overflow 的返回值取决于符号和舍入方向，不能一律写成无穷大；inexact 表示精确结果无法被本次输出准确表示。
- 恰好可表示的次正规结果不应仅因“很小”就被断定触发 underflow。分类器只能看到编码，无法知道产生该编码的运算是否精确。
- 普通数值比较下 +0 与 −0 相等，但它们的符号在除法等操作中有意义；NaN 与任何数（包括自己）的相等比较为假。不同比较指令对 NaN 的异常行为需按接口规定，不能从分类结果直接推断。

舍入还会破坏实数加法的结合律。本实验显式将每步存回 binary32：

```text
a=−2^24，b=2^24，c=1
(a+b)+c = 1
a+(b+c) = 0
```

第二条路径中 b+c 在半点按偶数舍入成 b，再与 a 抵消。编译器重排、不同中间精度以及 FMA 融合都可能影响位级结果；若要求可重复，需要一起规定这些条件。

<a id="fixed-float-lab"></a>
### 4.7 WSL 实验：精确参考、分类边界与变异测试

新增 [lab/Fixed_Float](lab/Fixed_Float/) 包含两个组合 RTL、两个自检查 TB、[精确向量与数值例题脚本](lab/Fixed_Float/generate_vectors.py)、[仿真入口](lab/Fixed_Float/run_sim.sh) 和 [变异检查](lab/Fixed_Float/check_mutations.py)。

在 PowerShell 中运行：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab/Fixed_Float' && bash run_sim.sh && bash run_experiments.sh"
```

定点参考使用 Python `Fraction` 表示精确输入值，分别调用 floor、trunc、精确分数的 round-to-even、ceil，再在整数域限幅，生成期望值和两个标志；不使用宿主 float 近似值作为定点 golden model。TB 用 `$fscanf` 读向量，逐项比较输出，失败用 `$fatal` 退出，并输出 VCD。

实际仿真输出：

```text
PASS fixed IW=1 OW=1 IF=0 OF=0 vectors=8
PASS fixed IW=4 OW=3 IF=2 OF=1 vectors=64
PASS fixed IW=8 OW=4 IF=4 OF=2 vectors=1024
PASS fixed IW=8 OW=4 IF=4 OF=0 vectors=1024
PASS fixed IW=8 OW=4 IF=2 OF=2 vectors=1024
PASS fixed IW=8 OW=12 IF=0 OF=4 vectors=1024
PASS fixed IW=8 OW=4 IF=0 OF=3 vectors=1024
PASS fixed IW=16 OW=8 IF=12 OF=4 vectors=16928
PASS fp32 classification vectors=4610
```

定点合计 **22,120 个向量**。前七组穷举所有输入编码和四种模式；最后一组包含端点、零附近连续值和 4,096 个固定种子随机输入，每个都检查四种模式。参数覆盖 W=1、只丢一位、丢多位、同 F 缩窄、扩宽左移以及左移后饱和。这里的 TB 用 integer 读参考值，仅验证列出的参数，并非任意宽度测试框架。

浮点分类的 **4,610 个位模式**来自先确定类别再构造编码：覆盖正负零/无穷、次正规边界、所有 254 个正规 exponent 的五种 fraction，以及两种 NaN 的固定/随机 payload。直接比对原始位模式类别，不经宿主浮点转换，因而保留 sNaN。没有穷举全部 `2^32` 编码。

数值例题脚本也实际输出：

```text
EXAMPLE fixed raw=-26 value=-13/8 outputs=[-7, -6, -6, -6]
EXAMPLE fixed raw=-22 value=-11/8 outputs=[-6, -5, -6, -5]
EXAMPLE fixed raw=22 value=11/8 outputs=[5, 5, 6, 6]
EXAMPLE fixed raw=26 value=13/8 outputs=[6, 6, 6, 7]
EXAMPLE fixed raw=30 value=15/8 outputs=[7, 7, 7, 7]
EXAMPLE binary32 0.1 bits=3dcccccd exact_error=1/671088640
EXAMPLE binary32 nonassociative left=1.0 right=0.0
PASS binary32 numeric examples: encoding, error, tie, nonassociation, subnormal gap
```

outputs 按 floor/toward-zero/RNE/ceil 排列，表示 `(4,2)` 的整数编码，读成实际数值还需除以 4。raw=30 的四种输出恰好相同，但 RNE/ceil 发生舍入后溢出，floor/toward-zero 没有；TB 同时检查标志，不能只看最终 y 相同就认为模式等价。

Verilator `--lint-only -Wall` 和 Yosys `check -assert`、无 `$dlatch` 结构检查均通过。变异测试将半点处理改成无条件加一、删除负数向零校正、把正饱和改成回绕、遗漏饱和导致的 inexact、将次正规错分成零、交换 qNaN/sNaN；必须成功编译且被数值检查拒绝，编译失败或超时不算检出。

本节变异测试的实际结尾：

```text
PASS mutation caught: tie_always_up
PASS mutation caught: negative_zero_rounding
PASS mutation caught: positive_wrap
PASS mutation caught: missing_saturation_inexact
PASS mutation caught: subnormal_as_zero
PASS mutation caught: quiet_signaling_swapped
PASS Fixed_Float mutations: 6/6
```

波形分别为 `build/8_4_4_2/fixed.vcd` 和 `build/fp32.vcd`。在 WSL 中可自行执行：

```bash
gtkwave build/8_4_4_2/fixed.vcd
gtkwave build/fp32.vcd
```

定点波形把 x/y/base/rounded 显示成 signed 十进制，观察 x=−26、−22、30 时不同 mode 的结果和标志，尤其是 rounded=8 后 y 饱和为 7。浮点波形将 bits 显示成十六进制，观察 007fffff→00800000 的类别边界、7f800001 的 sNaN 与 7fc00000 的 qNaN。两者都是组合电路，TB 的 `#1` 是留出仿真稳定时间，不是硬件“一拍延迟”。

**验证边界：**本节没有实现或验证完整浮点加法器、乘法器、格式转换器、异常状态寄存器或 FMA。Python 的 binary32 示例仅验证列出的数值现象，不是完整 IEEE 舍入/异常参考模型，也未接入 SoftFloat 回归。RTL 仅验证定点转换与位模式分类，没有形式证明、工艺库 STA 或 PPA；下一步若实现 FPU，应引入独立的完整参考模型及专门的舍入、特殊值、取消抵消和下溢用例。

<a id="fixed-float-review"></a>
### 4.8 格式选择与面试速查

范围可预测、可统一缩放的通路通常适合定点：算术主体可复用整数电路，代价是必须提前分配范围和误差预算。动态范围变化很大时，浮点省去许多显式缩放工作，但引入对阶、规格化、舍入和特殊值逻辑。不能只看“都是 32 位”就认为面积或精度相同，也不能未经综合就给出倍数性能结论。

面试时优先说清以下条件：

- **Q 格式要报 signed、总宽 W、小数位 F；先用范围公式检查输入能否表示。**
- **加法对齐 F，乘法的 F 相加，除法按目标 F 预缩放；先扩宽再移位。**
- **补码直接丢低位是 floor；向零和最近偶数需要额外判断。**
- **先舍入再饱和；饱和/回绕、overflow/inexact 都属于独立规格。**
- **浮点正规数有隐含 1，次正规数没有；ULP 随指数改变。**
- **分类不能推断运算异常；NaN 不止一种编码，subnormal 不等于必然 underflow。**
- **最终位模式受舍入、求值顺序和中间精度影响；分类器通过不代表 FPU 通过。**

<a id="cordic"></a>
## 5. CORDIC

CORDIC（coordinate rotation digital computer，坐标旋转数字计算）把一个较大的旋转分解成一系列方向可选的小旋转。精心选择角度后，每一步只需移位、加减和查常量表，可以求 sin/cos、向量角度和模长。本节实现**圆周 CORDIC**；不是调用综合器的三角函数，也不是用仿真 real 变量实现硬件。

<a id="cordic-principle"></a>
### 5.1 从旋转矩阵推导移位加法

二维向量逆时针旋转 θ 的精确公式为：

```text
x' = x cosθ − y sinθ = cosθ × (x − y tanθ)
y' = y cosθ + x sinθ = cosθ × (y + x tanθ)
```

选择第 i 次微旋转角 `αi=atan(2^−i)`，方向 `di∈{−1,+1}`。先把共同的 cosαi 因子省略，得到：

```text
x(i+1) = x(i) − di × y(i) × 2^(−i)
y(i+1) = y(i) + di × x(i) × 2^(−i)
z(i+1) = z(i) − di × αi
```

乘 `2^−i` 在定点补码中可用算术右移，乘 ±1 可用选择加减，因此每轮可以复用两个坐标加减器和一个角度加减器。x、y 两个更新都必须使用**同一轮的旧坐标**；先更新 x 再把新 x 用于更新 y，会改变旋转矩阵。

前几轮角度是约 45°、26.565°、14.036°、7.125°，随后接近每轮减半，但并不等于严格的 `45°/2^i`。本实验把弧度乘 `2^20` 后取整，ROM 的前四项实际为：

```text
i=0：823550
i=1：486170
i=2：256879
i=3：130396
```

常量表由 [generate_vectors.py](lab/CORDIC/generate_vectors.py) 生成到 [cordic_tables.vh](lab/CORDIC/cordic_tables.vh)，仿真前重新计算并检查文件一致性。硬件中是常量 case，不运行 atan；Python 是离线生成工具。

<a id="cordic-modes"></a>
### 5.2 旋转、向量两种模式，以及不能忽略的增益

**旋转模式（rotation mode）**让剩余角 z 接近零：

```text
z>=0：di=+1；z<0：di=−1
```

若初始向量是 `(1,0)`、初始 z 是 θ，理想末态方向就是 θ，但长度被放大。由省略的 cos 因子可知第 i 轮长度乘上：

```text
gi = 1/cosαi = sqrt(1+2^(−2i))
GN = ∏(i=0..N−1) gi
KN = 1/GN
```

随着 N 增大，G 趋近约 1.646760258，K 趋近约 0.607252935。不同资料可能把 G 或 K 中任意一个叫“CORDIC gain”，所以应先声明定义。本节 G>1 是放大倍数，K<1 是补偿系数。

求 sin/cos 时最便宜的补偿是在初始化装入 `(KN,0)`，而非 `(1,0)`；经过 N 轮后输出约为 `(cosθ,sinθ)`。8 轮和 20 轮的 G 并不完全相同，因此常量按实际迭代次数生成：

```text
ITER=8 ：G=1.646743506597，round(K×2^20)=636757
ITER=12：G=1.646760192685，round(K×2^20)=636751
ITER=16：G=1.646760257865，round(K×2^20)=636751
ITER=20：G=1.646760258120，round(K×2^20)=636751
```

后面三组补偿编码相同，是量化到 20 位小数后的结果，不表示真实 G 完全相同。中途跳过迭代或遇到 z=0 就提前结束，也会改变已累积的增益，不能继续无条件使用 KN。

**向量模式（vectoring mode）**让 y 接近零：

```text
y>=0：di=−1；y<0：di=+1
```

在右半平面，正 y 需要顺时针转，负 y 需要逆时针转。用同一条 z 更新式、初始 z=0，最终 z 约为原向量的角度，x 约为 `GN×sqrt(x_in²+y_in²)`，y 是残余量。

本实验向量输出 x **保留增益**，接口名称与文档把它解释为 scaled_r；若需要真实模长 r，应在外部乘 KN。数值参考直接用 `GN×hypot(x,y)` 检查硬件 x；除以 GN 即可还原模长，误差也相应缩小。硬件可选常数乘法、移位加法近似或与后续比例合并来补偿，但本模块没有加入该后处理。rotation 的预补偿已经实现，不能据此声称 vectoring 输出也已补偿。

<a id="cordic-range"></a>
### 5.3 收敛范围不是任意角度：先处理象限

微旋转总角度幅度的上限是 `Σatan(2^−i)`，无限轮约 1.7433 rad，即 99.88°。有限轮还会更小；因此未经处理，不能让 z=170° 也期待剩余角归零。本实验把旋转模式归约到更保守的 `[-π/2,π/2]`：

```text
θ > +π/2：初始 x=−KN，z=θ−π
θ < −π/2：初始 x=−KN，z=θ+π
其它：     初始 x=+KN，z=θ
初始 y 均为 0
```

例如 135° 先用负 x 轴作为初始方向，再旋转 −45°。180° 翻转只是符号变化，不需要乘法，也不改变增益。θ 和 π 都是定点近似，边界附近应按实际编码解释。

向量模式要处理 atan2 的四象限，不能仅用 `atan(y/x)`。若 `x_in<0`，先把输入向量取反，使它落入右半平面；同时按原始 y 的符号预置 z：

```text
x_in<0 且 y_in>=0：初始 (x,y)=(-x_in,-y_in)，z=+π
x_in<0 且 y_in< 0：初始 (x,y)=(-x_in,-y_in)，z=−π
x_in>=0：          保留 (x,y)，z=0
```

负 x 轴、y=0 按 +π 分支处理。本接口只有补码零，没有 IEEE 的 −0。有限迭代和量化可能使输出角度略越过 ±π，角度比较使用模 `2π` 的最短距离；若下游要求严格的标准区间，应再做角度归一化。零向量的方向没有数学定义，必须明确给出接口规则，不能把迭代过程产生的任意角度当成有效 atan2。

商业 IP 同样会把粗旋转与幅度补偿作为明确配置项，可对照 [AMD CORDIC Product Guide](https://www.amd.com/content/dam/xilinx/support/documents/ip_documentation/cordic/v6_0/pg105-cordic.pdf)；这里的迭代周期与接口是本地实现，不能套用该 IP 的延迟数字。

<a id="cordic-rtl"></a>
### 5.4 本实验接口、数值格式与 RTL

[cordic_iter.v](lab/CORDIC/cordic_iter.v) 支持参数 `ITER=8/12/16/20`，其它值不属于接口范围。x、y、角度统一使用 signed `(24,20)`，范围 `[-8,8−2^−20]`；角度单位为**弧度**。本版本故意固定格式，让角度表、阈值、误差预算与接口一致；更改位宽/小数位不是只改一个参数就完成，需要同时重新生成常量和验证。

输入与输出契约：

- `mode=0`：求 sin/cos，只使用 angle_in，忽略 x_in/y_in。合法角度编码为 `[-3294199,+3294199]`，对应量化的 ±π。输出 x_out≈cosθ、y_out≈sinθ，angle_out 是剩余角。
- `mode=1`：求向量角度与带增益模长，只使用 x_in/y_in，忽略 angle_in。合法坐标各自在 `[-1048576,+1048576]`，即 `[-1,+1]`；输出 x_out≈G×模长，y_out≈0，angle_out≈atan2。
- 有效向量 `(0,0)` 返回三项零，并置 `zero_vector=1`；这表示方向未定义，不表示测得角度为零。其他有效输入该标志为 0。
- 使用的输入超出上述范围时，`range_error=1`，输出三项零。没有内部饱和或通用溢出输出；范围外结果不能当作数值计算结果使用。
- 零向量与范围错误也等待 ITER 个计算沿，不提前返回。输入只在 `req_valid && req_ready` 上升沿捕获。

为什么需要保护位？向量输入最大模长为 √2，迭代后约为 `1.6468×√2≈2.329`，如果只提供 `[-1,1)` 的坐标格式就会溢出。本实验整个坐标寄存器范围到 ±8，给增益和量化留下空间；合法输入取反也不会碰到 24 位最小负数。非法输入可能在内部回绕，但最终被错误标志与零结果隔离，不对其内部数值作保证。

核心 RTL：

```verilog
wire signed [23:0] x_shift = x >>> step;
wire signed [23:0] y_shift = y >>> step;
wire positive = vector_mode ? y[23] : !z[23];
wire signed [23:0] x_next = positive ? x-y_shift : x+y_shift;
wire signed [23:0] y_next = positive ? y+x_shift : y-x_shift;
wire signed [23:0] z_next = positive ? z-alpha : z+alpha;
```

正负判据不同，但两个模式共享三条加减数据通路。x、y、z 和移位结果都明确声明 signed；若改成逻辑右移，负坐标会被补零，四象限用例会严重失真。坐标右移采用 floor，没有每轮 RNE；最终 x/y/z 也不再舍入或饱和，因此微小误差是设计的一部分。

时序 always 同时执行 `x<=x_next; y<=y_next; z<=z_next`，最后一轮直接把 next 值写入输出寄存器。否则会少算最后一轮。只有 angle ROM 和常量，设计逻辑没有 initial、real、乘法、除法或三角函数调用。

握手风格与本章乘除法器一致：E0 接收，E1 到 EITER 计算，EITER 之后响应有效；无反压时 E(ITER+1) 消费、E(ITER+2) 才能接收下一笔。**计算延迟为 ITER，最小启动间隔为 ITER+2**。结果和两个标志在反压期间保持，低有效异步复位会取消正在计算或等待消费的响应，复位期间不接收请求。

<a id="cordic-lab"></a>
### 5.5 WSL 实验：独立数学参考和协议检查

运行：

```powershell
wsl -u root -e bash -lc "cd '/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/04_Arithmetic_Units/lab/CORDIC' && bash run_sim.sh && bash run_experiments.sh"
```

[run_sim.sh](lab/CORDIC/run_sim.sh) 先核对常量表，再对四种 ITER 执行 Verilator `--lint-only -Wall`、Yosys 结构检查和 Icarus 自检查仿真。Yosys 断言没有 `$dlatch/$mul/$div`。这说明本版本没有乘除算子与意外锁存器，不是门级时序或功耗结论。

参考值使用 Python `sin/cos/hypot/atan2`，输入先量化，再对**实际输入编码**计算数学结果；没有把 RTL 递推抄一遍当成唯一 golden model。每组 1,557 个参考向量包含：

- 721 点全圆等间隔角度扫描、五处角度边界各 ±1 LSB 和本点、256 个固定种子随机角度。
- 七种坐标值的 49 个笛卡尔积，覆盖四象限、坐标轴、零及 1 LSB 小向量。
- 512 个固定种子随机向量，以及额外范围错误输入。边界扫描本身也包含越过 ±π 的错误用例。

TB 每笔检查精确的 ITER 延迟、错误/零标志及数值容差，保持响应两拍，改变无效请求总线验证输入锁存。另加每组 8 笔无反压连续事务检查启动间隔，再分别在计算和响应等待阶段复位。

实际协议结果：

```text
PASS CORDIC ITER=8 transactions=1565 latency=8 interval=10 hold_cycles=3114 reset_aborts=2
PASS CORDIC ITER=12 transactions=1565 latency=12 interval=14 hold_cycles=3114 reset_aborts=2
PASS CORDIC ITER=16 transactions=1565 latency=16 interval=18 hold_cycles=3114 reset_aborts=2
PASS CORDIC ITER=20 transactions=1565 latency=20 interval=22 hold_cycles=3114 reset_aborts=2
```

合计 **6,260 笔完成事务、12,456 个反压保持周期、8 次复位中止**。所有生成输入都实际进入 RTL，不是只检查 Python 模型。

由于 CORDIC 是近似算法，不能要求结果逐位等于数学函数取整。检查器采用以下公开的工程验收容差，S=2^20、N=ITER、ρ=输入模长：

```text
q = 8(N+1)/S              // 量化累积预算
t = 4 × 2^(−N)           // 有限迭代残角预算
旋转：x、y、残角容差 = q+t
向量：x、y 容差 = q+t×max(1,Gρ)
向量：角度容差 = min(π, q/max(ρ,1/S)+t)
```

向量残余 y 约为 `Gρ×sin(残角)`，因此坐标与角度不能共用不考虑幅度的容差。相位对坐标误差的敏感程度约与 1/ρ 成比例，所以小向量的角度容差会放大；达到 π 时，该检查对相位几乎不提供精度约束。范围错误与零向量要求精确零输出，不使用宽容差放行。

这些是测试采用的保守预算，**没有推导成任意合法输入的严格误差证明**。另外记录实测最大误差，避免只报 PASS 而隐藏实际精度：

```text
ERROR ITER=8 rotation_xy=0.00754651 vector_scaled_r=6.4808e-05 phase_rho_ge_0.125=0.00779423 tiny_phase=0.164679
ERROR ITER=12 rotation_xy=0.000485966 vector_scaled_r=9.87362e-06 phase_rho_ge_0.125=0.000486298 tiny_phase=0.172003
ERROR ITER=16 rotation_xy=3.29586e-05 vector_scaled_r=1.36883e-05 phase_rho_ge_0.125=3.21963e-05 tiny_phase=0.172461
ERROR ITER=20 rotation_xy=8.04189e-06 vector_scaled_r=1.7503e-05 phase_rho_ge_0.125=1.6716e-05 tiny_phase=0.17249
```

rotation_xy 是 sin/cos 分量的最大绝对误差；vector_scaled_r 是带 G 增益模长的绝对误差；phase 与 tiny_phase 的单位为弧度，分别统计 ρ≥0.125 与更小的非零向量。它们是这组扫描/随机输入上的结果，不是全输入空间的最坏误差界。尤其小幅度相位约 0.17 rad 的误差不能宣传成“20 位角度精度”。

两个具体波形例子（所有整数输出除以 S 才是实际数值）：

```text
EXAMPLE ITER=20 sincos(0) x=1048578 y=2 residual=0
EXAMPLE ITER=20 vector(1,1) scaled_r=2442001 residual_y=-3 angle=823552
```

cos(0) 得到 1+2 LSB，而非严格的 1；sin(0) 也不是精确零。向量 (1,1) 输出 x 约为 G√2，角度约为 π/4；真实模长需再乘 K。零输入有单独的标志规则，其他坐标轴没有额外“强制精确”旁路。

查看波形：

```bash
gtkwave build/n20/cordic.vcd
```

先看请求接收、响应阻塞与复位，再把 x/y/z、x_next/y_next/z_next、alpha 显示为 signed 十进制，step 显示为整数。观察旋转时 z 趋近零，向量时 y 趋近零；在 135° 或左半平面输入处检查接收沿的粗旋转初始化。不要把定点原始编码直接当角度“度数”。

[check_mutations.py](lab/CORDIC/check_mutations.py) 注入六类缺陷：遗漏旋转增益预补偿、粗旋转符号错误、向量方向颠倒、逻辑右移、输出分量接错和遗漏零向量标志。每个变异必须编译成功，并被数值或标志自检查拒绝才算检出。运行日志保存在忽略的 build 目录，不能把“语法错误”或超时当作测试抓到了算法错误。

本次实际变异与整章回归结尾：

```text
PASS mutation caught: missing_rotation_gain
PASS mutation caught: wrong_coarse_rotation
PASS mutation caught: wrong_vector_direction
PASS mutation caught: logical_shift
PASS mutation caught: wrong_output_component
PASS mutation caught: missing_zero_flag
PASS CORDIC mutations: 6/6
PASS Chapter 04: Adders + Multipliers + Dividers + Fixed_Float + CORDIC
```

<a id="cordic-review"></a>
### 5.6 为什么迭代更多不一定更准，以及结构选择

误差有多个来源：剩余角没有完全归零；atan 表量化；K 量化；每轮坐标算术右移截位；π 和 π/2 的边界常量量化。增加 ITER 主要降低第一项，并不自动减少其余项。实测从 12 到 20 轮，一般幅度角度误差继续下降，但 scaled_r 最大误差有所增加，正好说明截位误差可能累积。

接近零的向量尤其敏感：如果 x/y 只有几个 LSB，右移很快把很多信息变为 0 或 −1；再多迭代也无法恢复输入没有提供的方向分辨率。工程上可约定最小有效幅度、报告相位不可信，或把向量先按二的幂规格化，再恢复模长比例。本实验没有实现这个前置规格化，不能用宽松 tiny_phase 容差掩盖这一限制。

若需要更高数值精度，可扩大内部坐标/角度的小数位，最后只舍入一次；同时需要重新评估表长度、补偿常量和保护位。对于严格的 sin(0)=0、cos(0)=1 等需求，可加坐标轴特殊值处理，但要明确数值契约、延迟以及反压行为。

迭代结构复用加减器，节省算术单元，但每轮的移位量随 step 变化，可能综合出可变移位选择网络，不能把“移位”全部当成免费连线。展开流水结构每级 i 固定，移位可成为固定布线，代价是复制加减器和寄存器；若每级支持流水传递，稳定后可做到每拍接收一笔。实际面积/频率还受复用、复位、反压和布线影响，本节未做 PPA 对比。

本章不扩展到双曲或线性 CORDIC。它们会改变迭代公式、角度表、增益和收敛条件，双曲情形还涉及特定迭代重复，不能仅把 atan 替换成另一个函数就声称通用。圆周版本已足以训练移位加法、定点量化和带握手迭代数据通路的设计方法。

面试速查：

- **tanαi=2^−i 才把乘法变成移位；省去 cosαi 必然引入 G 增益。**
- **rotation 看 z 的符号，vectoring 看 y 的符号；两路坐标同时用旧值更新。**
- **sin/cos 可预装 K；向量模长是否补偿要看输出契约，不能默认已经补偿。**
- **先做象限归约，区分 atan 与 atan2；零向量方向无定义。**
- **保护位承载幅度增益，小数位决定量化；多迭代不是无限精度。**
- **本实验 ITER 拍计算、ITER+2 最小启动间隔；数值精度与协议正确性分别验证。**

至此可从 [lab/run_all.sh](lab/run_all.sh) 一次回归全章五组实验。章节完成指总纲中的教学内容及上述实验均已覆盖，不表示实现了完整 FPU、所有 CORDIC 变体或工艺签核。
