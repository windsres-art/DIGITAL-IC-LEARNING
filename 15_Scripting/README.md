# 15 脚本（Tcl / Python / Shell 与 Makefile）—— 面试向

目标：能读写 EDA 工具里的 Tcl 脚本（SDC、综合/STA 脚本、集合查询），能用 Python 解析报告、搭自动化回归，能用 bash 和 Makefile 组织仿真流程。面试里脚本一般不单独考难题，常见形式是：“用 Tcl 找出所有扇出大于 N 的线网”“写个脚本统计时序报告里的违例”“Makefile 里 `$@` `$<` 是什么”“回归怎么判断 PASS/FAIL”。

前置知识：

- 时序报告里各字段的含义：`../07_STA/README.md` 第 14 节
- Yosys 综合流程与 stat 报告：`../08_Logic_Synthesis/README.md`
- 本章实验用第 08 章的 16 bit ALU（`../08_Logic_Synthesis/lab/Yosys_Flow/alu.v`）做综合与 STA 的对象

建议顺序：第 1 节 Tcl（先跑 `tcl_basics.tcl` 把语法规则过一遍，再看 EDA 集合操作）→ 第 2 节 Python（解析第 1 节产出的报告）→ 第 3 节 Shell 与 Makefile（仿真流程 + 回归）→ 速查表和面试题。

配套实验（全部在 WSL 中实际跑通，README 里贴的是真实输出）：

| 实验 | 内容 |
|------|------|
| `lab/Tcl_EDA/` | `tcl_basics.tcl`：Tcl 语法自检（置换、列表、dict、proc、正则、文件）；`synth.tcl`：Yosys Tcl 模式综合 ALU；`alu.sdc`：用 Tcl 写约束；`sta_query.tcl`：OpenSTA 集合查询（单元统计、高扇出线网、端点 slack 直方图、导出 CSV） |
| `lab/Python_Report/` | `parse_sta.py`：解析 OpenSTA 文本报告和 Yosys stat，与 Tcl 导出的 CSV 交叉核对 |
| `lab/Make_Regression/` | 参数化计数器 + 自检查 TB；`Makefile` 组织 lint/编译/仿真；`regress.sh`（bash 串行）与 `regress.py`（Python 并行）回归；可打开一个注入的 corner case bug，看回归能不能抓到 |

---

## 目录

1. [Tcl](#1-tcl)
   - 1.1 为什么 EDA 工具都用 Tcl
   - 1.2 一条规则：置换
   - 1.3 列表、数组与 dict、proc、正则、文件
   - 1.4 EDA 里的集合（collection）操作
   - 1.5 实验：Tcl_EDA
   - 1.6 面试要点
2. [Python](#2-python)
   - 2.1 在 IC 流程里用在哪
   - 2.2 解析报告：正则 + 状态机
   - 2.3 实验：Python_Report
   - 2.4 自动化回归
   - 2.5 面试要点
3. [Shell 与 Makefile](#3-shell-与-makefile)
   - 3.1 bash 常用写法
   - 3.2 grep / sed / awk 一行命令
   - 3.3 Makefile 组织仿真流程
   - 3.4 实验：Make_Regression
   - 3.5 面试要点
4. [运行全部实验](#4-运行全部实验)
5. [速查表](#5-速查表)
6. [面试题](#6-面试题)

---

## 1. Tcl

### 1.1 为什么 EDA 工具都用 Tcl

Tcl（Tool Command Language）本来就是为“嵌入到工具里当命令语言”设计的：解释器很小，工具厂商把自己的命令（`read_verilog`、`create_clock`、`report_timing`……）注册成 Tcl 命令，用户就同时拥有了交互命令行和完整的编程能力（变量、循环、过程）。所以：

| 场景 | 例子 |
|------|------|
| 约束 | **SDC 就是 Tcl**：`create_clock -period $PERIOD [get_ports clk]` 里的 `$`、`[]` 都是 Tcl 语法 |
| 综合 | DC/Genus 脚本；Yosys 的 `yosys -c script.tcl` |
| STA | PrimeTime/Tempus/OpenSTA 脚本，报告后处理 |
| 后端 | ICC2/Innovus/OpenROAD 流程脚本 |
| 验证 | Questa/VCS 的 `do` 文件、波形工具脚本 |

面试里 Tcl 考的不是语言本身多深，而是：会不会用集合命令查设计、会不会在 SDC 里写变量和循环、知不知道那几个经典坑。

### 1.2 一条规则：置换

Tcl 的语法几乎只有一条：**解释器先对一行做置换，再按空白切成单词，第一个单词是命令名，其余是参数**。一切都是字符串。

| 写法 | 含义 |
|------|------|
| `$var` | 变量置换 |
| `[cmd ...]` | 命令置换：先执行里面的命令，用结果替换 |
| `"..."` | 分组，**内部照常置换** |
| `{...}` | 分组，**内部不置换**（原样） |
| `\` | 转义单个字符 |
| `;` 或换行 | 命令分隔；`#` 只有出现在命令开头才是注释 |

`lab/Tcl_EDA/tcl_basics.tcl` 第 1 段的真实输出：

```
== 1. 置换：$ 变量、[] 命令、"" 与 {} ==
  ok    expr 半周期                     = 2.0
  ok    "" 内做置换                      = T=4.0
  ok    {} 内不置换                      = T=$period
  ok    expr {$a*$b} 报错              = 1
  ok    expr $a*$b 二次解析              = 7
  ok    整数除法 7/2                     = 3
  ok    浮点除法 7.0/2                   = 3.5
```

**经典坑：`expr` 一定加花括号**。脚本里 `set a 3; set b "2+1"`：

- `expr {$a * $b}`：花括号阻止了 Tcl 的置换，`expr` 自己取变量值，发现 `b` 是字符串 `"2+1"` 不是数，报错。这是**正确**的行为。
- `expr $a*$b`：Tcl 先把它拼成字符串 `3*2+1`，`expr` 再把这个字符串当表达式解析一遍，得到 7。变量内容被当成了代码（和 SQL 注入同理），而且每次都要重新解析，慢。

其它常考的：

- `7/2 = 3`：两边都是整数时是整数除法，算周期、占空比时写 `7.0/2` 或 `double($x)/2`。
- 注释陷阱：`set x 1 # 注释` 会报参数过多，行内注释要写 `;#`。
- `{}` 里的内容是原样传递的，所以 `if {$x > 0} {...}` 的条件和 body 都用花括号，交给命令自己在合适的时候求值。

### 1.3 列表、数组与 dict、proc、正则、文件

#### 列表

列表就是按空白分隔的字符串，带空格的元素用 `{}` 包起来。

```tcl
set cells {dfrtp_1 nand2_1 xor2_1 nand2_1 dfrtp_1 a21oi_1}
llength $cells                       ;# 6
lindex  $cells end                   ;# a21oi_1
lsort -unique $cells                 ;# a21oi_1 dfrtp_1 nand2_1 xor2_1
lsearch -all -glob $cells nand*      ;# 返回下标 {1 3}
lappend cells mux2_1                 ;# 传变量名，不带 $
lsort -dictionary {y[10] y[2] y[1]}  ;# y[1] y[2] y[10]，按数字排，总线位排序必备
```

**“带空格的字符串就是多元素列表”**，这不只是语法题。本机仓库路径是 `DIGITAL IC LEARNING`，脚本里验证：

```
  ok    带空格的路径当列表                    = 3
```

写本章实验时真实遇到过：OpenSTA 的 `read_verilog` 拿到带空格的绝对路径后报 `cannot read file {/mnt/c/.../DIGITAL IC LEARNING/...}`。所以本章所有 `run.sh` 都先 `cd` 到脚本目录，然后用相对路径。

#### 数组（array）与 dict

两者都是“键 → 值”表，做统计最常用：

```tcl
foreach c $cells { incr cnt($c) }             ;# 数组：cnt(nand2_1) = 2
set lib [dict create nand2_1 3.75 dfrtp_1 25.02 ...]
dict get $lib dfrtp_1                         ;# 25.02
dict incr d $key                              ;# dict 版计数
```

区别：数组是一组变量，不能直接当值传给 proc（要 `upvar` 或 `array get`）；dict 是普通值，可以嵌套、可以返回。新脚本优先用 dict。

#### proc

```tcl
proc clk_freq {period {unit ns}} { ... }            ;# {unit ns}：默认参数
proc sum {args} { ... }                             ;# args：可变参数，收成列表
proc add_margin {varname margin} {
    upvar 1 $varname v                              ;# 按引用改调用者的变量
    set v [expr {$v - $margin}]
}
```

- Tcl 默认**传值**；要在 proc 里改外面的变量，用 `upvar`（或传数组名）。
- proc 内部看不到外面的变量，全局变量要 `global x` 或写 `::x`。

脚本里还顺带抓到了一个真实的浮点坑：`3.8 - 0.2` 的结果是 `3.5999999999999996`，直接和 `3.6` 比较是不相等的。第一次运行时自检就报了：

```
  FAIL  upvar 修改外部变量                 = 3.5999999999999996（期望 3.6）
```

改成 `format %.3f` 以后再比较才通过。**比较 slack、面积这类浮点数，要么先格式化，要么比较差值是否小于一个容差**。

#### 字符串与正则

解析报告的主力是 `regexp`：

```tcl
set line "                              1.790   slack (MET)"
regexp {(-?[\d.]+)\s+slack \((\w+)\)} $line -> s st      ;# s=1.790  st=MET
regexp {^(\S+)/(\S+)\s+\((\S+)\)} "_1287_/D (sky130_fd_sc_hd__dfrtp_1)" -> inst pin ref
string map {sky130_fd_sc_hd__ ""} $ref                  ;# dfrtp_1
regsub -all {\[(\d+)\]} {a[3] b[12]} {_\1_}             ;# a_3_ b_12_
```

- 正则一律写在 `{}` 里，否则 `[`、`\`、`$` 会先被 Tcl 置换掉。
- `->` 只是一个普通变量名，习惯用来接“整体匹配”这个不需要的结果。

#### 文件与 catch

```tcl
set fh [open $file r]
while {[gets $fh line] >= 0} { ... }   ;# gets 返回读到的字符数，文件尾返回 -1
close $fh
if {[catch {open /no/such/file r} err]} { puts "出错：$err" }
```

`catch` 让命令出错时不中断脚本，返回 1 并把错误信息放进变量。EDA 脚本里用来包住“可能找不到对象”的查询。

`tcl_basics.tcl` 共 37 项检查，最后输出：

```
PASS tcl_basics (Tcl 8.6.13)
```

### 1.4 EDA 里的集合（collection）操作

#### 集合是什么

`get_cells`、`get_pins`、`get_nets`、`get_ports`、`all_registers` 这类命令返回的不是名字字符串，而是**设计对象的集合**。对象上挂着属性（ref_name、direction、slack……），可以过滤、求关系。

```
all_registers 返回 54 个对象
直接打印第一个：_50e5510da4600000_p_Instance     ← 对象句柄
get_full_name ：_0966_   ref_name：sky130_fd_sc_hd__dfrtp_1
```

**要名字就用 `get_full_name`（OpenSTA）/ `get_object_name`（PT/DC），要属性就用 `get_property` / `get_attribute`。**

#### 常用命令（PrimeTime/DC 与 OpenSTA 对照）

| 用途 | PrimeTime / DC | OpenSTA（本章实验） |
|------|----------------|--------------------|
| 取对象 | `get_cells` `get_pins` `get_nets` `get_ports` `get_clocks` `get_lib_cells` | 同名 |
| 按属性过滤 | `get_cells -filter "ref_name =~ *DFF*"`、`filter_collection` | `get_cells -filter "ref_name =~ *dfrtp*"` |
| 关系查询 | `get_pins -of_objects $cell`、`get_nets -of_objects $pin` | 同名 |
| 层次 | `get_cells -hierarchical` | `get_cells -hierarchical` |
| 名字 / 属性 | `get_object_name`、`get_attribute $obj ref_name` | `get_full_name`、`get_property $obj ref_name` |
| 个数 | `sizeof_collection` | `llength` |
| 遍历 | `foreach_in_collection c $coll {...}` | `foreach c $coll {...}` |
| 集合运算 | `add_to_collection`、`remove_from_collection` | 用 Tcl 列表操作实现 |
| 扇入扇出 | `all_fanin -to`、`all_fanout -from` | 同名 |
| 时序路径对象 | `get_timing_paths -max_paths N` + `get_attribute $p slack` | `find_timing_paths -group_count N` + `get_property $p slack` |
| 报告写文件 | `redirect -file x.rpt {report_timing}` | `report_checks ... > x.rpt` |

面试最常追问的一点：**PT/DC 里集合不是 Tcl 列表**，它是一个句柄。对它用 `llength` 得到的是 1，用 `foreach` 遍历也不对，必须用 `sizeof_collection` 和 `foreach_in_collection`。OpenSTA 的实现把集合返回成 Tcl 列表（实验里 `llength` 直接得到 54），所以列表命令都能用。换工具时这个差别以各自手册为准。

另外 Innovus 有自己的数据库查询命令 `dbGet`（例如 `dbGet top.insts.cell.name`），语法风格与上面不同，用到时查手册。

#### SDC 里的 Tcl

SDC 就是 Tcl 命令的子集，可以用变量和循环（`lab/Tcl_EDA/alu.sdc`）：

```tcl
set PERIOD [expr {[info exists ::env(PERIOD)] ? $::env(PERIOD) : 3.0}]
create_clock -name clk -period $PERIOD [get_ports clk]

# PT/DC 里写 remove_from_collection [all_inputs] [get_ports {clk rst_n}]
set data_in {}
foreach p [all_inputs] {
    if {[get_full_name $p] ni {clk rst_n}} { lappend data_in $p }
}
set_input_delay  -clock clk [expr {$PERIOD * 0.4}] $data_in
```

`ni`（not in）和 `in` 是 Tcl 8.5 起的列表成员运算符。用环境变量控制周期，是扫频、多 corner 脚本的常见做法。注意：交给签核工具的 SDC 最好只含标准 SDC 命令和简单变量，复杂逻辑放在外层脚本里，否则别的工具读不进去。

### 1.5 实验：Tcl_EDA

```bash
cd "/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/15_Scripting/lab/Tcl_EDA"
bash run.sh              # 默认 PERIOD=3.0 ns；PERIOD=4.0 bash run.sh 可放宽
```

流程：`tclsh tcl_basics.tcl` → `yosys -c synth.tcl`（ALU → Sky130 网表）→ `sta -exit sta_query.tcl`。

`synth.tcl` 展示 Yosys 的 Tcl 模式：Yosys 命令前加 `yosys`，其余是普通 Tcl，所以可以用环境变量改参数（`chparam -set W $W alu`）。

`sta_query.tcl` 的真实输出（分段说明）：

**① 按单元类型统计 + 与 Yosys 交叉核对**

```
== 2. 按单元类型统计数量和面积（dict）==
    sky130_fd_sc_hd__a21oi_1       64
    sky130_fd_sc_hd__nor2_1        57
    sky130_fd_sc_hd__dfrtp_1       54
    sky130_fd_sc_hd__nand2_1       53
    sky130_fd_sc_hd__o21ai_0       44
  单元总数 537，总面积 4314.138 um^2
  ok    单元数 = Yosys stat         = 537
  ok    面积 = Yosys stat          = 4314.138
```

面积是在 Tcl 里对每种单元查 `get_property [get_lib_cells */$ref] area` 再乘个数累加的；再用正则从 `reports/synth.stat` 抠出 Yosys 的数字比对。两个工具独立数出来一致，说明网表读对了。排序用了 `lsort -stride 2 -index 1 -integer -decreasing`，把 dict 当成“键 值”对来排。

**② 高扇出线网**

```tcl
foreach n [get_nets *] {
    set loads [get_pins -of_objects $n -filter "direction == input"]
    lappend fo [list [get_full_name $n] [llength $loads]]
}
set fo [lsort -index 1 -integer -decreasing $fo]
```

```
  扇出最大的 5 条线网：
    b_q[1]        54
    clk           54
    rst_n         54
    b_q[2]        52
    b_q[0]        45
```

`clk`、`rst_n` 各 54 = 寄存器个数，符合预期。`b_q[1]` 扇出也是 54：`b` 的每一位都要进加法器和按位逻辑，而 `b[3:0]` 同时还是移位量，要控制 16 位桶形移位器里一整级 MUX，所以扇出比其它位大得多。这条线网在下面的时序分析里会再出现。

**③ 端点 slack 分布**

`find_timing_paths -endpoint_count 1` 对每个端点取最差路径，再用 `get_property $p slack` 取数。寄存器实例名被 Yosys 改成 `_1003_` 这种自动名，脚本顺着“实例 → Q 引脚 → 线网”反查，线网名保留了 RTL 里的寄存器名：

```
  有约束的端点 126 个，最差 5 个：
    _1003_/D       -2.828   Q 端线网 zero
    _1002_/D       -2.687   Q 端线网 y[15]
    _0987_/D       -2.680   Q 端线网 y[0]
    _1001_/D       -2.432   Q 端线网 y[14]
    _1000_/D       -2.180   Q 端线网 y[13]
  slack 分布（每 0.5 ns 一档）：
    [ -3.0,  -2.5)    3  ##
    [ -2.5,  -2.0)    2  #
    [ -2.0,  -1.5)    3  ##
    [ -1.5,  -1.0)    3  ##
    [ -1.0,  -0.5)    4  ##
    [ -0.5,   0.0)    1  #
    [  0.0,   0.5)    1  #
    [  0.5,   1.0)   36  ##################
    [  1.0,   1.5)   18  #########
    [  1.5,   2.0)   55  ############################
  违例端点 16 个
wns -2.83
tns -26.54
```

- 126 个端点 = 54 个寄存器 D 端 + 18 个输出端口 + 54 个 RESET_B（recovery 检查）。
- 3 ns 周期是故意定紧的，16 个违例端点全是输出寄存器 `zero` 和 `y`（17 个里只有 `y[1]` 满足）：它们前面是整个 ALU 组合逻辑（加法器、移位器）。`zero` 最差，因为它还要在 `y_d` 之后再做一次 16 位或非。
- 直方图用 proc + `upvar` 往调用者的数组里计数。最后导出 `reports/endpoint_slack.csv`、写一份 `reports/sta_paths.rpt` 文本报告，交给第 2 节的 Python 用。

### 1.6 面试要点

- **`""` 和 `{}` 的区别**：`""` 内做置换，`{}` 内不做。`expr`、`if` 条件、正则都用 `{}`。
- **`expr` 为什么加花括号**：避免二次解析（变量内容被当代码执行）并且更快。
- **数组与 dict 的区别**：数组是变量集合，不能直接传值；dict 是值，能嵌套、能返回。
- **`upvar` 干什么**：让 proc 按引用修改调用者的变量。
- **集合与列表**：PT/DC 的集合是句柄，用 `sizeof_collection`、`foreach_in_collection`、`get_object_name`；`llength` 结果不对。
- **常考手写题**：“找出所有扇出 > N 的线网”“统计每种单元的个数”“列出所有违例端点及 slack”，就是第 1.5 节的三个片段。

---

## 2. Python

### 2.1 在 IC 流程里用在哪

Tcl 在工具**内部**跑，Python 在工具**外面**把流程串起来、处理结果：

| 用途 | 例子 |
|------|------|
| 报告解析 | 时序、面积、功耗、覆盖率报告 → 表格 / CSV / 趋势图 |
| 自动化回归 | 批量起仿真、并行、超时、判 PASS/FAIL、汇总 |
| 代码生成 | 从寄存器表（Excel/YAML）生成 RTL、C 头文件、文档 |
| 参考模型 | 算法的 golden model，生成激励和期望输出 |
| 验证框架 | cocotb（用 Python 写 testbench） |

Python 的优势在于有成熟的标准库（`re`、`csv`、`json`、`subprocess`、`argparse`），也更适合长期维护。IC 公司的服务器上经常没有 pip 权限，所以本章脚本**只用标准库**。

### 2.2 解析报告：正则 + 状态机

时序报告是定宽文本，一条路径从 `Startpoint:` 开始、到 `slack (...)` 结束。解析方法：**逐行扫描，用预编译正则识别每种行，用一个小状态机记住当前在哪条路径、是否还在数据路径段**（`lab/Python_Report/parse_sta.py`）：

```python
RE_START = re.compile(r"^Startpoint: (\S+)")
RE_STAGE = re.compile(r"^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+[\^v]\s+(\S+)\s+\((\S+)\)")
RE_ARRIVAL = re.compile(r"^\s*(-?\d+\.\d+)\s+data arrival time")
RE_SLACK = re.compile(r"^\s*(-?\d+\.\d+)\s+slack \((MET|VIOLATED)\)")

def parse_sta(text):
    paths, cur, in_data = [], None, False
    for line in text.splitlines():
        if m := RE_START.match(line):
            cur, in_data = TimingPath(start=m[1]), True
            continue
        ...
        elif m := RE_ARRIVAL.match(line):
            if cur.arrival is None:        # arrival 在报告里出现两次，只取第一次
                cur.arrival = float(m[1])
            in_data = False                # 之后是 capture 时钟侧
        elif m := RE_SLACK.match(line):
            cur.slack = float(m[1])
            paths.append(cur)
            cur = None
        elif in_data and (m := RE_STAGE.match(line)):
            cur.stages.append((float(m[1]), m[3], m[4]))
```

要点和常见错误：

- **用 `\s+` 匹配列间空白，不要按列号切字符串**。工具换版本、加 `-digits`、加 `-fields` 后列宽就变了。
- **注意重复出现的行**：OpenSTA 报告在路径末尾写一次 `data arrival time`，在汇总区又写一次负数形式 `-5.505 data arrival time`。只取第一次，否则会被覆盖。
- **区分数据路径和时钟路径**：capture 侧的 `_0966_/CLK` 行只有一个数字，正则本来就匹配不上，再加一个 `in_data` 标志更保险。
- 用 `dataclass` 存每条路径，比到处传元组清楚；`pathlib`、`argparse` 让脚本可以传参复用。
- 解析出来后做**自洽检查**：setup 路径要满足 slack = required − arrival，不满足说明解析错了。

### 2.3 实验：Python_Report

```bash
cd ".../15_Scripting/lab/Python_Report"
bash run.sh            # 报告不存在时会先跑 ../Tcl_EDA/run.sh
```

真实输出：

```
== 1. sta_paths.rpt: 解析出 40 条路径 ==
  group            paths  viol      WNS      TNS(报告内)
  async_default       20     0    1.598         0.000
  clk                 20    16   -2.828       -26.539

  最差 5 条：
  endpoint       slack  arrival  depth  最慢一级
  _1003_        -2.828    5.505     16  1.125 ns @ _0969_/Q (dfrtp_1)
  _1002_        -2.687    5.406     16  1.125 ns @ _0969_/Q (dfrtp_1)
  _0987_        -2.680    5.399     16  1.125 ns @ _0969_/Q (dfrtp_1)
  _1001_        -2.432    5.073     15  1.125 ns @ _0969_/Q (dfrtp_1)
  _1000_        -2.180    4.821     13  1.125 ns @ _0969_/Q (dfrtp_1)

  违例路径最慢一级的单元类型：{'dfrtp_1': 16}
  → 写出 reports/paths.csv

== 2. 与 endpoint_slack.csv 交叉核对 ==
  CSV 端点 126 个，违例 16 个，WNS -2.828，TNS -26.539
  文本报告包含了全部违例端点，两边 TNS 应一致

== 3. synth.stat: 44 种单元，共 537 个 ==
  各行面积之和 4312.8，报告 Chip area 4314.1
  时序单元 54 个，占面积 31.3%
  面积前 3：dfrtp_1 1350，mux2_1 473，a21oi_1 320

PASS parse_sta
```

怎么读：

- **全部 16 条违例路径里最慢的一级都是同一个单元 `_0969_` 的 Q 端（1.125 ns）**。查网表，`_0969_` 的 Q 接的是 `b_q[1]`，正是第 1.5 节 Tcl 找出的扇出 54 的线网：负载大导致 Tcq 很大。所以修时序的第一步不是改 ALU 逻辑，而是给 `b_q[1]` 这类高扇出寄存器插 buffer 树、复制寄存器或换大驱动。这就是“脚本把几十条路径归类，一眼看到共性根因”的价值。
- **depth**（逻辑级数）13～16 级：数的是报告里每个单元输出引脚那一行。
- **交叉核对**：Python 从文本报告算出的 WNS/TNS 和 Tcl 从工具对象取出的 CSV 一致。注意文本报告每组只列了前 20 条；这里违例端点只有 16 个，全部在报告里，TNS 才能对上。违例更多时，文本报告里的 TNS 只是一部分，要用全部端点算。
- **stat 面积差 1.3**：Yosys stat 的每行面积是用 `%g` 打印的（例如 `1.35E+03`），逐行加回去有舍入误差，所以脚本按 1% 相对误差比较，而不是要求完全相等。

### 2.4 自动化回归

回归（regression）= 把一组测试（不同配置 × 不同随机种子）全部跑一遍，汇总结果，失败时给出能复现的命令。`lab/Make_Regression/regress.py` 的结构：

```python
def make(target, timeout, **var):
    cmd = ["make", "-s", "-C", str(HERE), target] + [f"{k}={v}" for k, v in var.items()]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

def run_case(w, seed, opts, timeout):
    try:
        r = make("sim", timeout, W=w, SEED=seed, **opts)
        found = list(RE_RESULT.finditer(r.stdout))
        line = found[-1].group(0) if found else ""
        # 退出码和结果行都要看：TB 中途崩溃时可能根本没有 PASS/FAIL 行
        status = "PASS" if r.returncode == 0 and line.startswith("PASS") else "FAIL"
    except subprocess.TimeoutExpired:
        status, line = "TIMEOUT", ""
    ...

with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    # 1. 编译：每个 W 一次（每个 W 一个 vvp 文件，互不冲突）
    ... pool.map(lambda w: make("compile", ...), args.widths)
    # 2. 仿真：全部组合并行（vvp 已是最新，make 不会重复编译）
    results = list(pool.map(lambda c: run_case(*c, opts, args.timeout), cases))
```

回归脚本的几个关键设计：

| 要点 | 做法 | 为什么 |
|------|------|--------|
| 判定 | 退出码 **和** 结果行都看 | 只 grep PASS：TB 崩溃时可能没有输出；只看退出码：`vvp` 比对失败也返回 0 |
| 结果行格式固定 | TB 最后打印 `PASS/FAIL key=value ...` | 脚本用正则 `(\w+)=(\d+)` 就能收集统计量 |
| 超时 | `subprocess.run(timeout=...)` | 仿真死循环（握手永远等不到）时回归不能卡住 |
| 并行 | `ThreadPoolExecutor` | 任务是等子进程，线程就够，不受 GIL 影响 |
| 先编译后运行 | 编译按配置并行，运行按用例并行 | 多个进程同时写同一个编译产物会互相覆盖 |
| 可复现 | 失败时打印 `make sim W=8 SEED=2 BUG=1 ...` | 随机验证必须能按种子重放 |
| 退出码 | 有失败就 `sys.exit(1)` | CI（Jenkins/GitLab）靠退出码判成败 |
| 覆盖统计 | 汇总关键场景被打到的次数 | PASS 不代表测到了，见第 3.4 节 |

第 3.4 节有运行结果。

### 2.5 面试要点

- **正则**：`re.compile` 预编译；`\s+` 容忍空白；`match` 从行首、`search` 任意位置、`findall` 返回分组、`finditer` 返回 Match 对象；默认贪婪，`.*?` 非贪婪。
- **调用外部工具**：`subprocess.run(cmd_list, capture_output=True, text=True, timeout=...)`，检查 `returncode`。不要用 `shell=True` 拼字符串（路径带空格就出错，还有注入风险）；`os.system` 拿不到输出。
- **并行**：起子进程这种 IO 型任务用线程池；纯 Python 计算型任务用进程池（`ProcessPoolExecutor`）绕开 GIL。
- **浮点比较**：用容差（`abs(a-b) < eps` 或 `math.isclose`），不要 `==`。
- **大文件**：逐行迭代 `for line in f`，不要 `read()` 整个几 GB 的报告进内存。

---

## 3. Shell 与 Makefile

### 3.1 bash 常用写法

以本章 `run.sh`、`regress.sh` 为例：

```bash
#!/usr/bin/env bash
set -euo pipefail          # -e 出错即退；-u 用到未定义变量报错；pipefail 管道中任一段失败即失败
cd "$(dirname "$0")"       # 切到脚本所在目录，之后用相对路径
WIDTHS=${WIDTHS:-"4 8 16"} # 环境变量有就用，没有取默认值
failed=()                  # 数组
failed+=("make sim W=$w SEED=$s")
out=$(make -s sim W="$w" SEED="$s" 2>&1)    # $( ) 捕获输出；2>&1 把 stderr 也并进来
if [[ $? -eq 0 ]]; then ...; fi             # $? 是上一条命令的退出码
pass=$((pass + 1))                          # 算术
printf '  %s\n' "${failed[@]}"              # 遍历数组，每个元素一行
grep -E '^(PASS|FAIL)' <<< "$out"           # here-string：把变量当标准输入
```

要点：

- **`set -e` 什么时候不能用**：`regress.sh` 故意只写 `set -uo pipefail`。回归中单个用例失败是正常结果，不能让整个脚本退出。
- **变量永远加双引号**：`"$path"`。本仓库路径 `DIGITAL IC LEARNING` 带空格，不加引号会被拆成 3 个参数，这和 Tcl 列表那个坑是同一件事。
- **`[[ ]]` 优于 `[ ]`**：不需要给变量加引号防空、支持 `&&` `||` 和 `=~` 正则。
- **退出码约定**：0 成功，非 0 失败。`cmd1 && cmd2` 前者成功才跑后者，`cmd1 || cmd2` 前者失败才跑后者。
- **管道与 tee**：`cmd | tee log` 在没有 `pipefail` 时退出码是 `tee` 的（总是 0），会把失败吞掉。
- **Windows 换行坑**：在 Windows 下编辑的脚本是 CRLF，bash 会报 `$'\r': command not found`，先 `sed -i 's/\r$//' file`。

### 3.2 grep / sed / awk 一行命令

面试常让现场写一行命令处理报告。以下都在本章生成的报告上真实跑过：

```
$ grep -c "slack (VIOLATED)" sta_paths.rpt                # 数违例路径
16
$ awk '/slack \(/{print $1}' sta_paths.rpt | sort -n | head -3      # 最差 3 个 slack
-2.828
-2.687
-2.680
$ awk -F, 'NR>1 && $2<0 {n++; s+=$2} END{printf "viol=%d tns=%.3f\n", n, s}' endpoint_slack.csv
viol=16 tns=-26.539                                          # 用 CSV 算 TNS
$ grep -oE '^\s+sky130_fd_sc_hd__\w+' alu_netlist.v | sed 's/.*sky130_fd_sc_hd__//' \
    | sort | uniq -c | sort -rn | head -3                    # 网表里单元个数排行
     64 a21oi_1
     57 nor2_1
     54 dfrtp_1
```

最后一条的结果和第 1.5 节 OpenSTA 统计的一致。

| 工具 | 擅长 | 常用选项 |
|------|------|----------|
| `grep` | 按行过滤 | `-E` 扩展正则、`-o` 只输出匹配部分、`-c` 计数、`-l` 列文件名、`-v` 反选、`-r` 递归、`-A/-B` 上下文 |
| `sed` | 替换、删行 | `s/a/b/g`、`-i` 原地改、`-n '/re/p'` 打印匹配行、`/re/d` 删行 |
| `awk` | 按列处理、统计 | `-F,` 分隔符、`$1` 第 1 列、`NR` 行号、`END{}` 结尾汇总 |
| `sort` / `uniq` | 排序计数 | `sort -n` 数值、`-r` 逆序、`-k2` 按第 2 列、`-V` 版本号（`W=4` 排在 `W=16` 前）、`uniq -c` 计数 |

### 3.3 Makefile 组织仿真流程

#### 基本结构

```make
目标: 依赖1 依赖2
<TAB>命令
```

make 比较**目标文件与依赖的时间戳**：依赖比目标新（或目标不存在）才执行命令。这就是增量编译：改了 RTL 才重新编译，只换随机种子就直接跑。

本章 `lab/Make_Regression/Makefile` 的核心部分：

```make
W      ?= 8
SEED   ?= 1
BUG    ?= 0
ifeq ($(BUG),1)
  DEFINES := -DINJECT_BUG
  SUFFIX  := _bug
endif

# 编译产物名只含“编译期”参数（W、BUG），运行期参数（SEED 等）放进日志名
SIM_BIN := $(BUILD)/sim_W$(W)$(SUFFIX).vvp
RUN_TAG := W$(W)_S$(SEED)_C$(CORNER)$(SUFFIX)

.PHONY: all compile sim lint regress clean

# | 后面是 order-only 依赖：目录只要存在即可，它的时间戳变化不会触发重编译
$(SIM_BIN): $(RTL) $(TB) | $(BUILD)
	iverilog -g2012 -Wall -P tb_counter.W=$(W) $(DEFINES) -o $@ $^

# 结果判断交给 grep：vvp 本身即使比对失败也返回 0
sim: $(SIM_BIN)
	vvp -n $< +seed=$(SEED) +cycles=$(CYCLES) +corner=$(CORNER) \
	    +vcd=$(BUILD)/$(RUN_TAG).vcd > $(BUILD)/$(RUN_TAG).log
	@grep -E '^(PASS|FAIL)' $(BUILD)/$(RUN_TAG).log
	@grep -q '^PASS' $(BUILD)/$(RUN_TAG).log
```

几个必须会解释的点：

| 语法 | 含义 |
|------|------|
| `$@` / `$<` / `$^` / `$*` | 目标名 / 第一个依赖 / 全部依赖（去重，不含 order-only）/ 模式规则里 `%` 匹配到的部分 |
| `=` | 递归展开，用到时才求值（可能引用后面才定义的变量） |
| `:=` | 立即展开，定义时就求值，一般优先用 |
| `?=` | 没定义过才赋值，用来给默认值；命令行 `make W=16` 会覆盖它 |
| `+=` | 追加 |
| `.PHONY` | 声明伪目标：`sim`、`clean` 不是文件，即使目录里碰巧有同名文件也照样执行 |
| `@` 前缀 | 不回显这条命令 |
| `\|` 之后 | order-only 依赖，只要求存在，不比时间戳 |
| 模式规则 | `%.vvp: %.v` 一条规则适配一类文件 |
| TAB | 命令行必须以 TAB 开头，空格会报 `missing separator` |
| 每行一个 shell | 上一行 `cd dir` 对下一行无效；要么写在同一行 `cd dir && cmd`，要么用 `-C dir` |
| `$$` | 在命令里写 shell 变量要写 `$$var`，单个 `$` 被 make 自己展开 |

常用选项：`make -n`（只打印不执行，调试 Makefile 必备）、`make -j8`（并行执行互不依赖的目标）、`make -B`（强制全部重做）、`make -s`（安静）、`make -C dir`（到别的目录执行）。

#### 真实运行：增量编译

```
$ make clean && make
rm -rf build
mkdir -p build
iverilog -g2012 -Wall -P tb_counter.W=8  -o build/sim_W8.vvp counter.v tb_counter.v
vvp -n build/sim_W8.vvp +seed=1 +cycles=1000 +corner=0 \
    +vcd=build/W8_S1_C0.vcd > build/W8_S1_C0.log
PASS W=8 seed=1 cycles=1000 loads=95 load_en=62 load_en_ones=0 wraps=2
$ make                                   # 再跑一次：RTL 没变，不重新编译
vvp -n build/sim_W8.vvp +seed=1 +cycles=1000 +corner=0 \
    +vcd=build/W8_S1_C0.vcd > build/W8_S1_C0.log
PASS W=8 seed=1 cycles=1000 loads=95 load_en=62 load_en_ones=0 wraps=2
$ touch counter.v && make -n sim W=4 SEED=7    # 改了 RTL，-n 看到会先重新编译
iverilog -g2012 -Wall -P tb_counter.W=4  -o build/sim_W4.vvp counter.v tb_counter.v
vvp -n build/sim_W4.vvp +seed=7 +cycles=1000 +corner=0 \
    +vcd=build/W4_S7_C0.vcd > build/W4_S7_C0.log
grep -E '^(PASS|FAIL)' build/W4_S7_C0.log
grep -q '^PASS' build/W4_S7_C0.log
```

把 `W` 写进 vvp 文件名是关键：如果编译产物只叫 `sim.vvp`，那么从 `W=8` 切到 `W=4` 时 make 看到 `sim.vvp` 比源文件新，就不会重新编译，结果跑的还是 8 位的仿真。**make 只认时间戳，不知道命令行参数变了**，所以影响编译结果的参数要体现在目标文件名里（或者让目标依赖一个记录参数的文件）。

`W` 通过 iverilog 的 `-P tb_counter.W=$(W)` 覆盖 TB 顶层参数，TB 再把它传给 DUT；lint 用 `verilator -GW=$(W)`。

### 3.4 实验：Make_Regression

被测电路 `counter.v` 是一个可加载计数器（load 优先于 en，计满回绕并拉高 `wrap` 一拍）。编译时加 `-DINJECT_BUG` 会打开一个故意埋的 bug：

```verilog
`ifdef INJECT_BUG
            // bug：load 与 en 同时有效且装载值为全 1 时，错误地走了计数分支
            if (load && !(en && (&load_val))) begin
`else
            if (load) begin
`endif
```

TB `tb_counter.v`：每拍随机给 en（70%）、load（10%）、load_val，参考模型用 64 位整数取模实现（故意不照抄 RTL 的写法），在下降沿逐拍比对；`+corner=1` 时装载值有 1/4 概率取全 1 或全 0。最后打印一行 `PASS/FAIL key=value ...`，其中 `load_en_ones` 是“load、en 同时有效且装载值全 1”这个场景被打到的次数，`wraps` 是回绕次数，相当于最朴素的功能覆盖率。

**① 正常 RTL，bash 串行回归**（`bash regress.sh`）：

```
  PASS W=4 seed=1 cycles=1000 loads=95 load_en=62 load_en_ones=5 wraps=42
  ...
  PASS W=8 seed=2 cycles=1000 loads=101 load_en=74 load_en_ones=1 wraps=3
  ...
  PASS W=16 seed=5 cycles=1000 loads=95 load_en=70 load_en_ones=0 wraps=0
total=15 pass=15 fail=0  用时 1 s
```

**② 打开 bug，纯随机**（`python3 regress.py --bug`）：

```
按 W 汇总：
  W=4   pass 0/5   打到 load&en&全1 的种子 5/5   出现过回绕的种子 5/5
  W=8   pass 4/5   打到 load&en&全1 的种子 1/5   出现过回绕的种子 4/5
  W=16  pass 5/5   打到 load&en&全1 的种子 0/5   出现过回绕的种子 0/5

total=15 pass=9 fail=6  墙钟 0.2 s（各用例耗时之和 1.7 s，jobs=12）
复现失败用例：
  make sim W=4 SEED=1 BUG=1 CORNER=0
  ...
  make sim W=8 SEED=2 BUG=1 CORNER=0
```

**③ 打开 bug，加 corner 偏置**（`python3 regress.py --bug --corner`）：

```
  W=4   pass 0/5   打到 load&en&全1 的种子 5/5   出现过回绕的种子 5/5
  W=8   pass 0/5   打到 load&en&全1 的种子 5/5   出现过回绕的种子 5/5
  W=16  pass 0/5   打到 load&en&全1 的种子 5/5   出现过回绕的种子 5/5
total=15 pass=0 fail=15
```

**④ 正常 RTL + corner 偏置，10 个种子**（`python3 regress.py --corner --seeds 10`）：30/30 PASS，并且每个 W 的每个种子都打到了 load&en&全1 场景、都出现过回绕。

结论：

- **PASS 不等于没 bug**。实验 ② 里 W=16 的 5 个种子全部 PASS，但 `load_en_ones=0`、`wraps=0`：触发 bug 的场景和回绕根本没被测到。触发概率大约是 P(load)·P(en)·P(全 1) = 0.1 × 0.7 / 2^W，W=4 时每 1000 拍平均触发约 4 次，W=16 时约 0.001 次。这就是为什么验证要有**功能覆盖率**，并且覆盖率没满之前不能签收。
- **多种子**：W=8 时 5 个种子里只有 seed 2 打中。只跑一个种子，很可能正好错过。
- **corner 偏置**（约束随机里给边界值加权）让全 1、全 0 这类边界值出现的概率从 1/2^W 提高到约 1/8，所有配置都能稳定抓到 bug。这对应第 11 章 SV 约束随机里的 `dist`。
- 失败日志直接给出第一次失配的时刻和数值，配合复现命令和 VCD 就能调试：

```
$ make -s sim W=8 SEED=2 BUG=1
FAIL W=8 seed=2 cycles=1000 errors=16 load_en_ones=1 wraps=3
make: *** [Makefile:46: sim] Error 1

$ cat build/W8_S2_C0_bug.log
  mismatch @5040000: cnt=fa wrap=0, expect cnt=ff wrap=0     ← 应装载 ff，却从 f9 计数到 fa
  mismatch @5050000: cnt=fb wrap=0, expect cnt=00 wrap=1
  mismatch @5060000: cnt=fc wrap=0, expect cnt=01 wrap=0
```

  时间单位是 ps（TB 的 timescale 是 1ns/1ps）。用 GTKWave 打开 `build/W8_S2_C0_bug.vcd`，在 5030 ns 附近看 `load`、`en`、`load_val` 三个信号，就能看到 bug 触发的那一拍。
- **并行**：15 个用例的耗时加起来 1.7 s，12 线程并行后墙钟 0.2 s。本例仿真很短，差别不明显；真实项目里一个用例跑几十分钟、回归上千个用例时，并行（本机线程池或 LSF 之类的集群调度）是必需的。

### 3.5 面试要点

- **`$@ $< $^`** 分别是什么；**`=` 与 `:=`** 的区别；**`.PHONY`** 的作用。
- **make 怎么决定要不要重做**：比较目标和依赖的时间戳；参数变了但文件没变，make 不知道，所以要把参数编进目标文件名。
- **命令前必须是 TAB**；每行命令在独立的 shell 里执行。
- **`set -euo pipefail`** 各自的作用，以及回归脚本为什么不用 `-e`。
- **回归怎么判 PASS/FAIL**：固定格式的结果行 + 退出码；超时；失败给复现命令；有失败返回非 0。
- **为什么要多种子、要覆盖率**：随机测试只保证测到的部分正确，没打到的场景 PASS 也没有意义（实验 ② 的 W=16）。

---

## 4. 运行全部实验

```bash
# WSL，root（工具在 /root 下）
cd "/mnt/c/Users/Administrator/Desktop/workspace/DIGITAL IC LEARNING/15_Scripting/lab"
sed -i 's/\r$//' Tcl_EDA/*.tcl Tcl_EDA/*.sdc Tcl_EDA/*.sh Python_Report/* \
    Make_Regression/*.v Make_Regression/*.sh Make_Regression/*.py Make_Regression/Makefile

bash Tcl_EDA/run.sh                  # Tcl 语法 → Yosys 综合 → OpenSTA 集合查询
bash Python_Report/run.sh            # 解析上一步的报告

source /root/oss-cad-suite/environment
cd Make_Regression
make lint && make                    # 单次仿真
bash regress.sh                      # 串行回归，全部 PASS
python3 regress.py --bug             # 纯随机：部分配置抓不到 bug
python3 regress.py --bug --corner    # corner 偏置：全部抓到
```

| 文件 | 作用 |
|------|------|
| `Tcl_EDA/tcl_basics.tcl` | Tcl 语法自检，37 项 |
| `Tcl_EDA/synth.tcl` | Yosys Tcl 模式综合 `../08_Logic_Synthesis/lab/Yosys_Flow/alu.v` |
| `Tcl_EDA/alu.sdc` | 用 Tcl 变量和循环写的约束 |
| `Tcl_EDA/sta_query.tcl` | OpenSTA 集合查询，产出 `reports/endpoint_slack.csv`、`reports/sta_paths.rpt` |
| `Python_Report/parse_sta.py` | 报告解析 + 交叉核对，产出 `reports/paths.csv` |
| `Make_Regression/counter.v` / `tb_counter.v` | 被测计数器（可注入 bug）与自检查 TB |
| `Make_Regression/Makefile` | lint / compile / sim / regress / clean |
| `Make_Regression/regress.sh` / `regress.py` | 串行 / 并行回归，产出 `build/regress_summary.csv` |

`build/` 下的网表、vvp、VCD、日志都是生成物，不需要提交。

---

## 5. 速查表

```
Tcl
  ""  置换     {}  不置换     []  命令置换     expr 永远加 {}     行内注释 ;#
  列表：llength lindex lrange lappend(变量名) lsort -dictionary/-integer/-stride lsearch -all -glob
  dict：dict create/get/set/incr/exists/for       数组：incr a($k)  array names/size
  proc p {a {b 默认} args} {...}    upvar 1 $name v 按引用    ::x 全局
  regexp {re} $s -> g1 g2    regsub -all {re} $s {\1}    string map/match/trim    format %-8s%6.3f
  open/gets/puts/close    catch {cmd} err    file join/dirname/exists
  浮点比较先 format 或比差值；7/2=3
EDA 集合（PT/DC ↔ OpenSTA）
  get_cells/pins/nets/ports  -filter "ref_name =~ *DFF*"  -of_objects  -hierarchical
  get_object_name ↔ get_full_name    get_attribute ↔ get_property
  sizeof_collection / foreach_in_collection（PT 集合不是列表）↔ llength / foreach
  all_registers all_inputs all_outputs all_fanin -to all_fanout -from
  get_timing_paths ↔ find_timing_paths      redirect -file ↔ report_x > file
Python
  re.compile  \s+ 匹配空白  finditer   状态机逐行解析    dataclass / pathlib / argparse / csv
  subprocess.run([...], capture_output=True, text=True, timeout=T).returncode   不用 shell=True
  IO 型并行 ThreadPoolExecutor，计算型 ProcessPoolExecutor    sys.exit(非 0) 表示失败
bash
  set -euo pipefail   "$var" 永远加引号   ${v:-默认}   $(cmd)   $?   [[ ]]   (( ))   arr+=("x") "${arr[@]}"
  2>&1   | tee   <<< "$s"    CRLF：sed -i 's/\r$//'
  grep -Eocl   sed -n '/re/p' / s///g / -i   awk -F, '{s+=$2} END{print s}'   sort -n -k -V | uniq -c
Makefile
  目标: 依赖 \n<TAB>命令      比时间戳决定是否重做      参数要编进目标文件名
  $@ 目标  $< 第一个依赖  $^ 全部依赖  $* 模式匹配部分    = 延迟  := 立即  ?= 默认  += 追加
  .PHONY   | order-only   @ 不回显   $$ shell 变量   每行一个 shell
  make -n 预览  -j 并行  -B 全部重做  -s 安静  -C 目录   make VAR=x 覆盖 ?=
回归
  固定格式结果行 + 退出码双判定 · 超时 · 多种子 · 失败给复现命令 · 覆盖率没打到的 PASS 不算数
```

---

## 6. 面试题

**Q1. Tcl 里 `"..."` 和 `{...}` 有什么区别？**  
`"..."` 分组并做变量置换和命令置换；`{...}` 分组但内容原样传递。`if`、`while`、`expr` 的条件、proc 的 body、正则表达式都用 `{}`，让命令自己在需要时求值。

**Q2. 为什么 `expr` 要加花括号？**  
不加时 Tcl 先置换出字符串再交给 `expr` 解析一次，变量内容会被当成表达式代码（`b="2+1"` 时 `expr $a*$b` 得到 7 而不是报错），还不能缓存编译结果。加了花括号，`expr` 自己取变量值，既安全又快。

**Q3. 用 Tcl（PT 语法）找出设计里所有扇出大于 32 的线网。**

```tcl
foreach_in_collection n [get_nets -hierarchical *] {
    set fo [sizeof_collection [get_pins -leaf -of_objects $n -filter "direction == in"]]
    if {$fo > 32} { puts "[get_object_name $n] $fo" }
}
```

PT 里也可以直接用线网的扇出属性过滤，属性名以工具手册为准。OpenSTA 版本见 `lab/Tcl_EDA/sta_query.tcl` 第 3 段。

**Q4. PT 里 `llength [get_cells *]` 为什么结果不对？**  
PT/DC 的集合是一个句柄，不是 Tcl 列表，`llength` 得到 1。要用 `sizeof_collection`，遍历用 `foreach_in_collection`，取名字用 `get_object_name`。

**Q5. 列出所有 setup 违例端点及其 slack（PT 语法）。**

```tcl
foreach_in_collection p [get_timing_paths -delay_type max -max_paths 10000 -slack_lesser_than 0] {
    puts "[get_object_name [get_attribute $p endpoint]] [get_attribute $p slack]"
}
```

**Q6. `upvar` 是做什么的？**  
把调用者作用域里的变量关联到 proc 内的局部名，实现按引用修改。Tcl 默认传值。

**Q7. SDC 里能不能写 Tcl 循环？要注意什么？**  
能，SDC 是 Tcl 命令子集，工具都能执行变量、`expr`、`foreach`。但给签核或其它工具的 SDC 最好只保留标准 SDC 命令和简单变量，复杂逻辑放在生成 SDC 的外层脚本里，避免工具之间不兼容。

**Q8. 用一行命令统计时序报告里的违例数和 TNS。**  
`grep -c "slack (VIOLATED)" x.rpt`；TNS 用 `awk '/slack \(VIOLATED\)/{s+=$1} END{print s}' x.rpt`。注意报告只列前 N 条时，这样算出的 TNS 不完整。

**Q9. 用 Python 解析时序报告有哪些坑？**  
列宽会变（要用 `\s+`）；同一字段在报告里出现多次（arrival 出现两次）；要区分数据路径和时钟路径；报告只列前 N 条，统计 TNS 要用全部端点；浮点比较用容差。解析完做自洽检查（slack = required − arrival）。

**Q10. `subprocess.run` 和 `os.system` 的区别？为什么不建议 `shell=True`？**  
`subprocess.run` 能捕获 stdout/stderr、设置超时、拿到退出码；`os.system` 只返回退出状态。`shell=True` 用字符串拼命令，参数里有空格或特殊字符就会被拆错，还有注入风险；传列表更安全。

**Q11. 回归脚本怎么判断一个仿真用例通过？**  
testbench 自检查，最后打印固定格式的结果行；脚本同时检查退出码和结果行（TB 崩溃可能没有结果行，而仿真器比对失败时往往仍返回 0）；加超时防止挂死。全部结束后有失败就返回非 0，给 CI 使用。

**Q12. 随机回归全部 PASS 了，能说明设计没问题吗？**  
不能。要看功能覆盖率，看关键场景有没有被打到。本章实验中 W=16 的 5 个种子都 PASS，但触发 bug 的场景一次都没出现。要多种子、给边界值加权（corner 偏置），并以覆盖率收敛作为签收标准。

**Q13. Makefile 里 `$@`、`$<`、`$^` 分别是什么？`=` 和 `:=` 呢？**  
目标名、第一个依赖、全部依赖。`=` 是递归展开（用到时才求值），`:=` 是立即展开（定义时求值）。`?=` 在未定义时才赋值，适合给默认参数。

**Q14. `.PHONY` 有什么用？**  
声明不对应文件的目标（`clean`、`sim`）。否则目录里一旦有同名文件，make 会认为目标已是最新而不执行。

**Q15. `make W=16` 改了参数，为什么有时仿真跑的还是旧配置？**  
make 只比较文件时间戳，不知道命令行参数变了。如果编译产物名与参数无关，旧产物比源文件新，就不会重编译。解决：把参数编进目标文件名（本章的 `sim_W$(W).vvp`），或让目标依赖一个随参数变化而更新的文件。

**Q16. `set -euo pipefail` 分别是什么？**  
`-e` 任一命令失败就退出；`-u` 使用未定义变量时报错；`-o pipefail` 管道中任一段失败整个管道就失败（否则 `cmd | tee log` 的退出码永远是 tee 的 0）。回归主循环里不能用 `-e`，否则第一个失败用例就会中止整个回归。

**Q17. 脚本里路径带空格要注意什么？**  
bash 变量要加双引号；Tcl 里带空格的字符串会被当成多元素列表，有的工具命令会因此读错文件；Python 用列表传参给 `subprocess`。最稳的做法是先 `cd` 到目录再用相对路径。
