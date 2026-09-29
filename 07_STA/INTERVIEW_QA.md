# STA 面试题库

先自己回答，再看答案。标 ★ 的是高频题。对应知识点见 `README.md`。

---

## 一、基础概念

**1. ★ 什么是 STA？和动态仿真有什么区别？**  
不加激励，把电路拆成时序路径，用库延时计算每条路径是否满足约束。优点是穷举、快、不依赖测试向量；缺点是不查功能、不查异步 CDC、完全依赖约束正确。动态（门级 + SDF）仿真能查功能但覆盖率受向量限制，速度慢。

**2. ★ 解释建立时间和保持时间。**  
setup：时钟沿前数据需稳定的最短时间；hold：时钟沿后数据需保持的最短时间。来源是主从 DFF 中 master latch 需要时间把数据锁定（setup），以及时钟沿后输入传输门要一段时间才完全关断（hold）。

**3. 建立时间、保持时间可以是负数吗？**  
可以。负 hold 表示触发器内部时钟路径比数据路径慢，数据在沿之前一点点变化也不会破坏采样。setup + hold 构成的窗口宽度必须为正。

**4. ★ 什么是亚稳态？怎么解决？**  
违反 setup/hold 时触发器输出停在中间电平或很久才稳定。不能消除，只能降低概率：同步器（两级/三级 DFF）、异步 FIFO、握手。用 MTBF 衡量，`MTBF ∝ e^(Tr/τ)`。

**5. 为什么同步器通常是两级？什么时候用三级？**  
两级给亚稳态留出约一个周期恢复，MTBF 通常已远超产品寿命。高频、先进工艺（τ 相对周期较大）或高可靠性场景用三级。

**6. ★ 时序路径有哪几类？起点和终点是什么？**  
in→reg、reg→reg、reg→out、in→out。起点：寄存器时钟引脚或输入端口；终点：寄存器数据（或复位、门控检查）引脚或输出端口。

**7. 什么是 slack？**  
setup：required − arrival；hold：arrival − required。≥ 0 满足。

**8. WNS 和 TNS 是什么？**  
WNS：最差的负 slack；TNS：所有违例端点负 slack 之和。WNS 看最难修的一条，TNS 看违例规模。

---

## 二、setup / hold 与时钟

**9. ★ 写出 setup 和 hold 的检查公式。**

```
setup: Tlaunch + Tcq + Tcomb_max ≤ T + Tcapture − Tsetup − Tunc
hold : Tlaunch + Tcq + Tcomb_min ≥ Tcapture + Thold + Tunc
```

**10. ★ 为什么 hold 违例比 setup 违例更严重？**  
hold 公式与周期无关，降频救不了；流片后出现 hold 违例一般只能改版。setup 违例可以通过降频让芯片工作。

**11. ★ skew 对 setup 和 hold 各有什么影响？**  
正 skew（capture 时钟晚到）改善 setup、恶化 hold；负 skew 反之。作用永远相反。

**12. 什么是 useful skew？**  
有意调整时钟到达时间，给关键路径的 capture 寄存器晚到的时钟借时间修 setup；代价是该寄存器发出的下一级路径 setup 变紧、本路径 hold 变紧。

**13. ★ skew 和 jitter 的区别？**  
skew 是空间上的：同一时钟沿到达不同寄存器的时间差（时钟树不平衡）。jitter 是时间上的：时钟沿相对理想位置的周期间偏移（PLL、电源噪声）。

**14. clock uncertainty 包含什么？CTS 前后有什么不同？**  
jitter + skew 估计 + 设计余量。CTS 前 skew 未知，要估进去；CTS 后使用 propagated clock，skew 由工具真实计算，uncertainty 只保留 jitter 和余量。

**15. 为什么 hold 的 uncertainty 一般比 setup 小？**  
hold 检查的 launch 与 capture 是同一个时钟沿，该沿的周期抖动对两者影响相同、可以抵消，所以一般不计 jitter，只计 skew 和余量。

**16. 什么是理想时钟和传播时钟？**  
理想时钟：时钟网络延时为 0（或用 `set_clock_latency` 给定值），用于 CTS 前。传播时钟：`set_propagated_clock`，按真实时钟树计算，用于 CTS 后。

**17. source latency 和 network latency 的区别？**  
source：时钟源到设计时钟定义点（片外、PLL）；network：定义点到寄存器时钟引脚（时钟树）。

**18. 半周期路径是什么？**  
上升沿寄存器到下降沿寄存器（或反之），setup 只有半个周期，时钟占空比误差直接影响裕量。

---

## 三、延时计算、corner、OCV

**19. ★ 单元延时怎么算？**  
liberty 中 NLDM 二维查找表，延时和输出 slew 都是 f(输入 slew, 输出负载)，查表插值。先进工艺用 CCS/ECSM。

**20. 为什么要限制 max transition 和 max capacitance？**  
超出库表格范围时延时靠外推，不可信；大 slew 带来更大延时、短路功耗和噪声敏感性；也是可靠性要求（电迁移等）。

**21. ★ setup 和 hold 分别在什么 corner 下最坏？**  
setup：慢 corner（SS、低压、高温；存在温度反转时低温也可能更慢）。hold：快 corner（FF、高压、低温）。签核时所有 corner 两种检查都要做。

**22. 什么是温度反转？**  
先进工艺低电压下，温度降低使阈值电压升高的影响超过迁移率提高的影响，低温反而更慢。

**23. ★ 什么是 OCV？怎么在 STA 中建模？**  
同一芯片不同位置的工艺/电压/温度差异。用 derate：setup 检查中 launch 时钟 + 数据路径乘 late 系数（>1），capture 时钟乘 early 系数（<1），hold 反之。演进：flat OCV → AOCV（按深度/距离查表）→ POCV/SOCV（统计 σ）。

**24. ★ 什么是 CRPR / CPPR？**  
launch 和 capture 时钟路径的公共部分，在 OCV 下被同时按慢和快计算，这是不可能出现的悲观。CRPR 把这部分差值加回 slack。

**25. 什么是 MCMM？**  
多 corner 多模式：功能模式、测试模式等 × 各工艺/RC corner，同时分析和优化。

**26. 串扰对时序有什么影响？**  
相邻线反向翻转使受害线变慢（恶化 setup），同向翻转使之变快（恶化 hold）。PT-SI 等工具计算 delta delay 和噪声毛刺。

---

## 四、时序例外与 SDC

**27. ★ 什么是 false path？举例。**  
结构存在但功能上不发生或不需要满足时序的路径：异步时钟间、准静态配置寄存器、互斥选择路径、测试专用路径。滥用会掩盖真实违例。

**28. ★ 多周期路径为什么 setup 设 N、hold 要设 N−1？**  
`-setup N` 把 setup 捕获沿后移 N−1 个周期，hold 检查沿默认跟着后移（setup 沿前一个沿），变得极难满足。`-hold N−1` 把 hold 检查拉回原来的 launch 沿附近。

**29. set_clock_groups 的 asynchronous、logically_exclusive、physically_exclusive 有何区别？**  
三者都不分析组间时序。asynchronous：两个时钟同时存在，SI 仍考虑串扰；logically_exclusive：逻辑上不同时有效（如 MUX 选择），但物理上可能同时存在于不同线上；physically_exclusive：物理上不可能同时存在，连串扰也不算。

**30. ★ set_input_delay 和 set_output_delay 表示什么？-max 和 -min 用于什么？**  
input delay：外部数据相对时钟沿到达端口的时间（外部 Tcq + 外部走线）。output delay：外部要求的时间（外部走线 + 外部 setup）。-max 用于 setup 分析，-min 用于 hold 分析。

**31. 虚拟时钟有什么用？**  
描述片外器件的时钟，作为 IO 约束参考；不与设计内部任何引脚相连，不影响内部时钟树。

**32. create_generated_clock 用在什么场景？**  
分频器、倍频、门控时钟输出、PLL 输出等。工具据此推导其与源时钟的相位关系和延时。

**33. 同一端口对两个时钟做 input delay 需要注意什么？**  
第二条要加 `-add_delay`，否则覆盖前一条。

**34. set_case_analysis 作用？**  
把信号设为常量，工具据此剪掉该模式下不可能出现的路径，例如 `scan_en = 0` 分析功能模式。

**35. 如何在 STA 中处理组合环？**  
工具会自动打断，但位置不可控；应在 SDC 中用 `set_disable_timing` 明确打断，或修改设计。

---

## 五、复位、门控、CDC

**36. ★ 同步复位和异步复位的优缺点？**  
同步：抗毛刺，时序是普通数据路径，但需要时钟、复位脉宽至少一个周期、占用数据路径逻辑。异步：不依赖时钟、响应快，但对毛刺敏感，释放时要满足 recovery/removal，否则亚稳态。

**37. ★ 什么是异步复位同步释放？画电路。**  
两级 DFF，异步复位端接外部复位，第一级 D 接 1，第二级 D 接第一级 Q，第二级 Q 作为本域复位。复位拉起立即生效，释放被同步到时钟沿。代码见 README 10.2。

**38. ★ recovery 和 removal 是什么？**  
异步复位释放相对时钟沿的约束。recovery：释放须在时钟沿前完成的最短时间（类似 setup）；removal：时钟沿后须保持复位的最短时间（类似 hold）。只检查释放，不检查拉起。

**39. 时钟门控为什么要用 ICG？门控检查查什么？**  
直接用 AND 门，en 在 clk 高时变化会产生毛刺或截断脉冲。ICG = latch + AND，latch 在 clk 低时透明，保证 en 只在 clk 低时变化。STA 在门控单元上做 gating setup/hold 检查。

**40. ★ STA 能检查 CDC 吗？**  
不能。异步时钟之间没有确定相位关系，STA 结果没有意义。CDC 正确性靠同步设计 + CDC 工具检查；SDC 中用 clock groups 或 false path 排除，对 Gray 指针可用 `set_max_delay -datapath_only` 限制 bit 间延时差。

**41. 如果忘了声明异步时钟，会怎样？**  
工具在两个时钟所有沿里找最近的一对做检查，产生大量假违例（本 lab 实验 2：5 ns 与 7 ns 时钟被找到只相距 1 ns 的沿，WNS −2.47 ns），综合/布局工具会为这些假违例过度优化。

---

## 六、修复与流程

**42. ★ setup 违例怎么修？**  
upsize、换 LVT、插 buffer 降负载、逻辑重构、缩短走线、useful skew、流水线/retiming、多周期路径（功能允许时）、降频。

**43. ★ hold 违例怎么修？**  
数据路径插 buffer/delay cell、换 HVT/小驱动单元、调整时钟。修 hold 时不能破坏 setup，一般先修 setup 再修 hold，在多个 corner 下验证。

**44. 为什么通常先修 setup 再修 hold？**  
setup 修复（加速）会让 hold 变差，hold 修复（插延时）一般只加少量延时；按这个顺序迭代次数少。而且 hold 在 CTS 前意义不大（时钟未定），通常 CTS 后才正式修。

**45. 签核 STA 的输入有哪些？**  
门级网表、各 corner 的库（.db/.lib）、SPEF 寄生参数、SDC 约束（各模式）、OCV/POCV 数据、（可选）SI 所需的耦合电容信息。

**46. check_timing 主要检查什么？**  
未约束端点、没有时钟的寄存器、组合环、多时钟驱动的寄存器、IO 未设 delay、生成时钟源找不到等约束完整性问题。

**47. PrimeTime 读入流程？**  
设置 `link_path` → `read_verilog` → `link_design` → `read_parasitics` → `read_sdc` → `update_timing` → `check_timing` / `report_timing` / `report_constraint`。

---

## 七、计算题

**C1. ★ 求最高频率**  
Tcq = 0.3，Tcomb_max = 2.5，Tsetup = 0.2，Tskew（capture − launch）= +0.1，Tunc = 0.1（单位 ns）。

```
T ≥ 0.3 + 2.5 + 0.2 + 0.1 − 0.1 = 3.0 ns  →  Fmax ≈ 333 MHz
```

**C2. ★ 判断 hold**  
Tcq_min = 0.25，Tcomb_min = 0.05，Thold = 0.15，Tskew = +0.2，Tunc_hold = 0.05。

```
AT = 0.25 + 0.05 = 0.30
RT = 0.15 + 0.05 + 0.2 = 0.40
slack = 0.30 − 0.40 = −0.10  → 违例，需在数据路径插 ≥ 0.10 ns 延时
```

注意正 skew 让 hold 更难。

**C3. 两级组合逻辑，哪条限制频率**  
FF1 → 逻辑 A（1.8 ns）→ FF2 → 逻辑 B（2.6 ns）→ FF3。Tcq = 0.2，Tsetup = 0.1，skew 可调。  
不调 skew：T ≥ 0.2 + 2.6 + 0.1 = 2.9 ns。  
useful skew：第二级是瓶颈，要给它借时间。FF2 是第二级的 **launch** 寄存器，让 FF2 的时钟**早到** δ：  
- 对 FF2→FF3：launch 早 δ，等效正 skew +δ，`T ≥ 2.9 − δ`  
- 对 FF1→FF2：capture 早 δ，等效负 skew −δ，`T ≥ 2.1 + δ`  

令两式相等：δ = 0.4，T = 2.5 ns（Fmax 从 345 MHz 提到 400 MHz）。之后还要检查两级的 hold。

**C4. 多周期路径**  
T = 2 ns，某路径组合延时 3.2 ns，Tcq + Tsetup = 0.3，数据每 2 个周期更新一次。  
单周期不满足（3.5 > 2）。设 `set_multicycle_path 2 -setup`，允许 4 ns，slack = 4 − 3.5 = +0.5；同时 `set_multicycle_path 1 -hold`，hold 仍在 launch 沿检查。

**C5. IO 预算**  
时钟 10 ns，外部器件 Tcq = 1.5，板上走线 1.0，本芯片内部 in→reg 组合 5 ns，Tsetup = 0.3。  
`set_input_delay -max 2.5`；内部 required = 10 − 0.3 = 9.7，arrival = 2.5 + 5 = 7.5，slack = +2.2。

**C6. 读报告找问题**  
某路径中，一个 DFF 的 Tcq 为 2.7 ns（正常约 0.3–0.5），Q 端负载 0.4 pF、slew 3.4 ns。问题是什么？  
扇出过大（本 lab 读指针驱动整个 RAM 读 MUX）。修法：插 buffer 树或复制寄存器（register duplication），换大驱动 DFF。

---

## 八、开放题（说思路）

- **给你一份有几千条违例的报告，你怎么开始？** 先 `check_timing` 确认约束完整，按 path group 看 WNS/TNS，看是否集中在少数起点/终点（约束错误、高扇出、跨时钟未声明），先排除假违例再修真违例。
- **综合后时序很好，布局后大量违例，可能原因？** 线延时估计过乐观（wire load 不准）、拥塞绕线、高扇出网没修、时钟树 skew 超预期、IO 位置导致长走线。
- **时序和功耗怎么平衡？** 关键路径用 LVT，非关键路径换 HVT 降漏电；多 Vt 优化、门控时钟、避免过度 upsize。
