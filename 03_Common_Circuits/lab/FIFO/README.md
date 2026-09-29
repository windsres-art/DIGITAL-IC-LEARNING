# 异步 FIFO 学习笔记

> 本文件是早期的详细笔记（调试过程、波形讲解），要点已并入章 README `../../README.md` 第 1 节。
> 章 README 另有同步 FIFO `fifo_sync.v`、整理版异步 FIFO `fifo_async.v`（Gray 指针寄存输出）、自检查 testbench 与深度计算。

基于本目录示例（`FIFO.v` / `FIFO_TB.v`）与调试、波形讨论整理。  
仿真环境见仓库 `ascon-aead128-fast/README.md`：**WSL2 + OSS CAD Suite**，不要在 Windows 本机跑。

---

## 1. 结构（Cummings 五块）

| 模块 | 作用 |
|------|------|
| `RAM` | 双口存储：写时钟写、读时钟读 |
| `write_full` | 写指针（二进制）+ Gray + `full` |
| `read_empty` | 读指针（二进制）+ Gray + `empty` |
| `synchronization` ×2 | 两拍同步：对侧 Gray 指针跨进本侧时钟域 |

- 深度：`DEPTH = 2^FIFO_addr_size`
- 指针位宽：`FIFO_addr_size + 1`（多 1 bit 区分满/空）
- RAM 地址：指针**低位**  
  `w_addr = w_pointer_bin[FIFO_addr_size-1:0]`  
  → 指针是「带圈数的计数器」，地址是环形缓冲落点

---

## 2. 本示例修过的关键 bug

1. **两路同步器 din/时钟接反**  
   正确：读 Gray → 写时钟；写 Gray → 读时钟（必须真正跨域）。
2. **RAM 的 `else` 清零 `mem`** → 不写就擦数据；应只在 `w_en && !full` 时写。
3. **复位循环用 `FIFO_data_size`** → 应按 `DEPTH` 清存储。
4. **同步器/读指针复位宽度少 1 bit** → 应为 `FIFO_addr_size+1`。

---

## 3. 为何用 Gray + 多 1 bit 指针

- **Gray**：相邻值只翻 1 bit，跨时钟采样不会采到「半新旧」乱码。
- **多 1 bit**：地址相同可能是「空」或「满」；用多出的圈数位区分。
  - 空：完整指针（Gray）相等  
  - 满：等价于写比读多绕一整圈（Gray 空间用「高 2 位取反再比」表达）

```verilog
// full（写侧）
full = (w_pointer_gray ==
        {~r_pointer_gray_sync[MSB:MSB-1], r_pointer_gray_sync[其余]});

// empty（读侧）
empty = (r_pointer_gray == w_pointer_gray_sync);
```

---

## 4. 亚稳态与「打两拍」

**产生**：异步信号相对本地时钟可能踩 setup/hold → 第一级 DFF 可能卡在中间电平或很晚才落下。

**两拍同步器**：

```
din ──► [DFF1] ──► [DFF2] ──► dout（给逻辑用）
        可能亚稳     几乎总是干净 0/1
```

- 作用：把亚稳态关在第一级，用约 1 个目的时钟周期做恢复。
- **不是**消灭亚稳态，也**不是**把源域每个中间值都记下来。
- **MTBF**（Mean Time Between Failures）：这类失效平均隔多久才发生一次；级数↑、目的时钟不太快 → MTBF↑。
- 级数选取：控制/Gray 指针跨域默认 **2**；很高频/很严 MTBF 才考虑 3。
- 多 bit 普通总线不能整组打两拍当同步（各位恢复不一致会出非法码）→ 用 Gray / 握手 / FIFO。

---

## 5. 为何 full/empty「偏保守」（核心）

打两拍 → 本侧看到的对侧指针是**旧快照**。

| 你在哪侧 | 对侧其实已经… | 真实情况 | 你按旧指针会… |
|----------|----------------|----------|----------------|
| 读侧 | 多写了 | 其实有更多数据 | 更容易判 `empty` → **偏空** |
| 写侧 | 多读了 | 其实有更多空位 | 更容易判 `full` → **偏满** |

本质（两边对称）：

> **对侧走得比你看见的更远 → 真相往往更好（更有货/更有空）→ 你按旧快照决策就更保守。**

- 代价：吞吐略损（虚空/虚满多等几拍）
- 收益：不读穿、不写穿；**正确性优先**
- 危险的是反过来的「乐观」估计（full/empty 来晚了）

写快读慢时：写 Gray 在读域采样偏稀，`w_pointer_gray_sync` 常**跳步**（如只见到 `011`→`110`），中间 Gray 被跳过——正常现象。  
读更快时：原理不变，虚满在写侧往往更显眼；sync 对写指针可能跟得更密。

---

## 6. Verilog 小句法

```verilog
w_pointer_bin <= {(FIFO_addr_size+1){1'b0}};  // 复制运算符：N 位全 0
w_pointer_bin <= 0;                           // 等价，更常见
```

---

## 7. 仿真与看波形

```bash
# WSL 内；工具若在 /root，需 sudo 或挪到 /opt 后再 source
source /opt/oss-cad-suite/environment   # 或 /root/...（root 权限）
cd ".../DIGITAL IC LEARNING/03_Common_Circuits/lab/FIFO"
bash run_sim.sh
# 或: iverilog -g2012 -o fifo_sim FIFO.v FIFO_TB.v && vvp fifo_sim
gtkwave fifo_async.vcd &
```

**Icarus 默认 `$dumpvars` 不录 memory**：要对 `mem[0]`…逐元素 `$dumpvars`（TB 已加）。

### 推荐波形顺序（上→下）

1. `clk_w` / `clk_r` / `rst_*`  
2. 写：`w_en` `data_in` `full` `w_addr` `w_pointer_bin` `w_pointer_gray`  
3. 存储：`mem[0..3]`（Decimal）  
4. 跨域：`r_pointer_gray` → `r_pointer_gray_sync`；`w_pointer_gray` → `w_pointer_gray_sync`  
5. 读：`r_en` `empty` `r_addr` `r_pointer_bin` `data_out`  

主线：**写沿改 mem → Gray 跨域晚约 2 个目的时钟 → 读沿改 data_out**。

### 时间轴抓手（当前 TB：写 50 ns / 读 100 ns）

- 复位后：`empty=1`，指针/`mem` 清 0  
- ~450 ns 起写 → 满后看 `full`  
- 盯 `*_gray_sync` 比本域 Gray 滞后、可能跳步  
- ~900 ns 起读 → `data_out` 先进先出（同步读，有效值在下一拍）

---

## 8. WSL 相关（本机）

- 形式：**WSL2** = Windows 上的轻量 Linux 虚拟机（真 Linux 内核）
- 文件两套盘：Linux `/`（如 `/root`、`/home`）与 Windows `C:` → `/mnt/c/...`
- 工程可放 `/mnt/c/...` 方便 Cursor 编辑；大工具宜装 `/opt` 或 `~/`，避免仅 root 可读

---

## 9. 一句话总览

异步 FIFO = 双口 RAM + 两端带额外 bit 的指针 + Gray 跨域 + 两拍同步；  
同步延迟使对侧进度看起来偏旧，从而 **empty/full 偏保守**，用少量吞吐换正确性。
