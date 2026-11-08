// =============================================================================
// RV32I 经典五级流水线：IF → ID → EX → MEM → WB
//   参数：
//     FWD = 1  EX 级前递（EX/MEM、MEM/WB → EX），只有 load-use 停 1 拍
//     FWD = 0  不前递：消费者在 ID 等到生产者进入 WB（寄存器堆写穿透）为止
//     BP  = 0  总预测不跳（取 PC+4）
//     BP  = 1  静态 BTFN：IF 级预译码，jal 和向后的分支预测跳，向前的分支预测不跳
//     BP  = 2  动态：BTB（全 PC 标签 + 目标）+ 2 bit 饱和计数器，EX 级更新
//   冒险处理：
//     数据冒险  前递 + load-use 停顿（ID 和 IF 保持，EX 插气泡）
//     控制冒险  分支 / 跳转在 EX 级解析，预测错则冲掉 IF/ID、ID/EX 两条（罚 2 拍）
//     结构冒险  哈佛结构 + 2R1W 寄存器堆 + WB 写穿透，不存在
//   优先级：EX 级改向（冲刷）> ID 级停顿。被冲掉的指令不能再让流水线停。
//   ecall / 异常（非法指令、非对齐访存）在 EX 级杀掉所有更年轻的指令并停止取指，
//   自己继续走到 WB 才"退休"——这样它后面的 store 永远到不了 MEM，停机点是精确的。
//   两个存储器仍是组合读（与单周期核相同的 testbench 存储模型）；同步读 SRAM 的安排见 README。
// =============================================================================
module rv32i_pipe #(
    parameter [31:0] RESET_PC = 32'h0000_0000,
    parameter        FWD      = 1,
    parameter        BP       = 0,
    parameter        BTB_BITS = 6               // BP = 2 时 BTB / BHT 共 2^BTB_BITS 项
)(
    input             clk,
    input             rst_n,
    output     [31:0] imem_addr,
    input      [31:0] imem_rdata,
    output     [31:0] dmem_addr,
    output            dmem_re,
    output     [3:0]  dmem_wstrb,
    output     [31:0] dmem_wdata,
    input      [31:0] dmem_rdata,
    output reg        halted,
    output reg        trap,
    // 提交接口（WB 级）
    output            commit_valid,
    output     [31:0] commit_pc,
    output     [31:0] commit_insn,
    output            commit_rd_we,
    output     [4:0]  commit_rd,
    output     [31:0] commit_rd_wdata,
    output     [3:0]  commit_wstrb,
    output     [31:0] commit_st_addr,
    output     [31:0] commit_st_data,
    // 性能计数用的事件脉冲
    output            perf_stall,               // 本拍 ID 级停顿（数据冒险）
    output            perf_redirect             // 本拍 EX 级改向（预测错）
);
    // =========================================================================
    // 级间寄存器声明
    // 两个阶段的前缀表示级间寄存器：if_id_* / id_ex_* / ex_mem_* / mem_wb_*。
    // 例如 id_ex_imm 在 ID 末尾采样，下一拍由 EX 使用；本拍 ID 的组合结果叫 id_imm。
    // 本级信号用 if_* / id_* / ex_* / mem_* / wb_*；if_pc 是取指 PC 寄存器。
    // =========================================================================
    // IF/ID：保存 IF 的输出，供 ID 使用
    reg        if_id_valid;
    reg [31:0] if_id_pc, if_id_instr, if_id_pred_next;
    // ID/EX：保存 ID 的输出，供 EX 使用
    reg        id_ex_valid;
    reg [31:0] id_ex_pc, id_ex_instr, id_ex_rs1_val, id_ex_rs2_val, id_ex_imm, id_ex_pred_next;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg [3:0]  id_ex_alu_op;
    reg [2:0]  id_ex_funct3;
    reg [1:0]  id_ex_wb_sel;
    reg        id_ex_alu_a_pc, id_ex_alu_a_zero, id_ex_alu_b_imm, id_ex_reg_we, id_ex_mem_re, id_ex_mem_we;
    reg        id_ex_is_branch, id_ex_is_jal, id_ex_is_jalr, id_ex_is_system, id_ex_illegal;
    // EX/MEM：保存 EX 的输出，供 MEM 使用
    reg        ex_mem_valid;
    reg [31:0] ex_mem_pc, ex_mem_instr, ex_mem_result, ex_mem_rs2_val;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_reg_we, ex_mem_mem_re, ex_mem_mem_we, ex_mem_is_system, ex_mem_exc;
    // MEM/WB：保存 MEM 的输出，供 WB 使用
    reg        mem_wb_valid;
    reg [31:0] mem_wb_pc, mem_wb_instr, mem_wb_wdata, mem_wb_st_addr, mem_wb_st_data;
    reg [4:0]  mem_wb_rd;
    reg [3:0]  mem_wb_wstrb;
    reg        mem_wb_reg_we, mem_wb_is_system, mem_wb_exc;

    reg        fetch_stop;                      // ecall / 异常进入 EX 后停止取指

    wire        ex_taken;                       // EX 级分支解析结果（BTB 更新也要用）
    wire [31:0] ex_target;

    // =========================================================================
    // IF：取指 + 预测下一条 PC
    // =========================================================================
    reg  [31:0] if_pc;
    wire [31:0] if_instr    = imem_rdata;
    wire [31:0] if_pc_plus4 = if_pc + 32'd4;
    wire [31:0] if_pred_next;
    assign imem_addr = if_pc;

    generate
        if (BP == 1) begin : g_btfn
            // 组合读的指令存储器让 IF 级就能看到指令，于是可以"预译码"：
            // 只认 opcode 和立即数，算出 jal / 分支的目标，不需要任何表
            // IF 预测与 EX 执行属于不同指令，这里的预测加法不能直接复用 EX 的 ALU。
            wire        if_jal = (if_instr[6:0] == 7'b1101111);
            wire        if_br  = (if_instr[6:0] == 7'b1100011);
            wire [31:0] if_imm_j = {{11{if_instr[31]}}, if_instr[31], if_instr[19:12], if_instr[20],
                                   if_instr[30:21], 1'b0};
            wire [31:0] if_imm_b = {{19{if_instr[31]}}, if_instr[31], if_instr[7], if_instr[30:25],
                                   if_instr[11:8], 1'b0};
            assign if_pred_next = if_jal                ? if_pc + if_imm_j :
                                  (if_br & if_instr[31]) ? if_pc + if_imm_b : // 向后（偏移为负）预测跳
                                                          if_pc_plus4;
        end else if (BP == 2) begin : g_btb
            localparam N  = 1 << BTB_BITS;
            localparam TW = 30 - BTB_BITS;
            reg [N-1:0]  v;
            reg [TW-1:0] tag  [0:N-1];
            reg [31:0]   tgt  [0:N-1];
            reg [1:0]    cnt  [0:N-1];
            reg          jmp  [0:N-1];         // 无条件跳转（jal）：命中就跳，不看计数器

            wire [BTB_BITS-1:0] if_idx = if_pc[BTB_BITS+1:2];
            wire if_hit = v[if_idx] && (tag[if_idx] == if_pc[31:BTB_BITS+2]);
            assign if_pred_next = (if_hit && (jmp[if_idx] || cnt[if_idx][1])) ? tgt[if_idx] : if_pc_plus4;

            // EX 级更新：分支和 jal 都在这里解析。EX 里永远是正确路径上的指令，表不会被污染
            wire [BTB_BITS-1:0] ex_idx = id_ex_pc[BTB_BITS+1:2];
            wire ex_hit   = v[ex_idx] && (tag[ex_idx] == id_ex_pc[31:BTB_BITS+2]);
            wire ex_upd   = id_ex_valid & (id_ex_is_branch | id_ex_is_jal);
            // 只有有效位需要复位：v = 0 的项，其标签、目标、计数器都不会被使用
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    v <= {N{1'b0}};
                end else if (ex_upd) begin
                    if (ex_taken) begin
                        v[ex_idx]   <= 1'b1;
                        tag[ex_idx] <= id_ex_pc[31:BTB_BITS+2];
                        tgt[ex_idx] <= ex_target;
                        jmp[ex_idx] <= id_ex_is_jal;
                        // 新分配的项从"弱跳"开始；已有的项饱和加 1
                        cnt[ex_idx] <= !ex_hit ? 2'b10 : (cnt[ex_idx] == 2'b11) ? 2'b11 : cnt[ex_idx] + 2'b01;
                    end else if (ex_hit) begin
                        cnt[ex_idx] <= (cnt[ex_idx] == 2'b00) ? 2'b00 : cnt[ex_idx] - 2'b01;
                    end
                end
            end
        end else begin : g_nt
            assign if_pred_next = if_pc_plus4;
        end
    endgenerate

    // =========================================================================
    // ID：译码、读寄存器、冒险检测
    // =========================================================================
    wire [4:0]  id_rd, id_rs1, id_rs2;
    wire [2:0]  id_funct3;
    wire [31:0] id_imm;
    wire [3:0]  id_alu_op;
    wire [1:0]  id_wb_sel;
    wire        id_alu_a_pc, id_alu_a_zero, id_alu_b_imm, id_reg_we, id_mem_re, id_mem_we;
    wire        id_is_branch, id_is_jal, id_is_jalr, id_is_system, id_uses_rs1, id_uses_rs2, id_illegal;

    rv32i_decode u_dec (
        .instr(if_id_instr), .rd(id_rd), .rs1(id_rs1), .rs2(id_rs2), .funct3(id_funct3), .imm(id_imm),
        .alu_op(id_alu_op), .alu_a_pc(id_alu_a_pc), .alu_a_zero(id_alu_a_zero), .alu_b_imm(id_alu_b_imm),
        .reg_we(id_reg_we), .mem_re(id_mem_re), .mem_we(id_mem_we), .wb_sel(id_wb_sel),
        .is_branch(id_is_branch), .is_jal(id_is_jal), .is_jalr(id_is_jalr), .is_system(id_is_system),
        .uses_rs1(id_uses_rs1), .uses_rs2(id_uses_rs2), .illegal(id_illegal));

    wire [31:0] id_rs1_val, id_rs2_val;
    wire        wb_we = mem_wb_valid & mem_wb_reg_we & ~mem_wb_exc;
    rv32i_regfile #(.BYPASS(1)) u_rf (
        .clk(clk), .we(wb_we), .waddr(mem_wb_rd), .wdata(mem_wb_wdata),
        .raddr1(id_rs1), .rdata1(id_rs1_val), .raddr2(id_rs2), .rdata2(id_rs2_val));

    // ID 指令需要读 r，而更老的有效指令将写 r、尚未写回。只比较编号，不比较数据。
    function dep(input [4:0] r, input use_r, input v, input we, input [4:0] rd);
        dep = use_r && v && we && (rd != 5'd0) && (rd == r);
    endfunction

    wire dep_ex  = dep(id_rs1, id_uses_rs1, id_ex_valid, id_ex_reg_we, id_ex_rd) |
                   dep(id_rs2, id_uses_rs2, id_ex_valid, id_ex_reg_we, id_ex_rd);
    wire dep_mem = dep(id_rs1, id_uses_rs1, ex_mem_valid, ex_mem_reg_we, ex_mem_rd) |
                   dep(id_rs2, id_uses_rs2, ex_mem_valid, ex_mem_reg_we, ex_mem_rd);

    // 有前递：只有"EX 里是 load、ID 要用它的结果"必须停（数据要到 MEM 末尾才有）
    // 无前递：生产者还在 EX 或 MEM 就得等，进入 WB 后靠寄存器堆写穿透拿到
    wire load_use  = dep_ex & id_ex_mem_re;
    wire hazard    = (FWD != 0) ? load_use : (dep_ex | dep_mem);

    // =========================================================================
    // EX：前递、ALU、分支解析
    // =========================================================================
    reg  [31:0] ex_a_fwd, ex_b_fwd;             // 前递后的 rs1 / rs2
    always @* begin
        ex_a_fwd = id_ex_rs1_val;
        ex_b_fwd = id_ex_rs2_val;
        if (FWD != 0) begin
            // 先判 MEM/WB 再判 EX/MEM：后者写在后面，优先级更高（取最新的值）
            if (mem_wb_valid && mem_wb_reg_we && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs1) ex_a_fwd = mem_wb_wdata;
            if (ex_mem_valid && ex_mem_reg_we && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs1) ex_a_fwd = ex_mem_result;
            if (mem_wb_valid && mem_wb_reg_we && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs2) ex_b_fwd = mem_wb_wdata;
            if (ex_mem_valid && ex_mem_reg_we && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs2) ex_b_fwd = ex_mem_result;
        end
    end

    // jal / branch 选择本条 PC + imm；jalr 选择前递后的 rs1 + imm。
    wire [31:0] alu_a = id_ex_alu_a_zero ? 32'd0 : id_ex_alu_a_pc ? id_ex_pc : ex_a_fwd;
    wire [31:0] alu_b = id_ex_alu_b_imm  ? id_ex_imm : ex_b_fwd;
    wire [31:0] alu_y;
    rv32i_alu u_alu (.a(alu_a), .b(alu_b), .op(id_ex_alu_op), .y(alu_y));

    // branch 的比较仍使用两个前递操作数，与 ALU 的目标地址计算并行。
    wire br_cond;
    rv32i_branch u_br (.a(ex_a_fwd), .b(ex_b_fwd), .funct3(id_ex_funct3), .taken(br_cond));

    wire [31:0] ex_pc_plus4 = id_ex_pc + 32'd4;
    assign      ex_taken   = id_ex_is_jal | id_ex_is_jalr | (id_ex_is_branch & br_cond);
    // 实际跳转目标统一取 ALU；PC+4 独立用于顺序执行和 jal / jalr 的链接值。
    assign      ex_target  = id_ex_is_jalr ? {alu_y[31:1], 1'b0} : alu_y;
    wire [31:0] ex_next    = ex_taken ? ex_target : ex_pc_plus4;

    // 预测错 = 预测的下一条 PC 与实际不符。非控制指令的预测值就是 PC+4，自然不会改向
    wire redirect = id_ex_valid & (ex_next != id_ex_pred_next);

    // 非对齐访存在 EX 就能判断（地址已经算出来）
    wire [3:0]  unused_strb;
    wire [31:0] unused_wd, unused_ld;
    wire        ex_misalign;
    rv32i_lsu u_lsu_chk (
        .addr_lo(alu_y[1:0]), .funct3(id_ex_funct3), .st_data(32'd0), .ld_word(32'd0),
        .wstrb(unused_strb), .wdata(unused_wd), .ld_data(unused_ld), .misalign(ex_misalign));
    wire ex_exc  = id_ex_illegal | ((id_ex_mem_re | id_ex_mem_we) & ex_misalign);
    wire ex_kill = id_ex_valid & (id_ex_is_system | ex_exc);   // 杀掉所有更年轻的指令

    // =========================================================================
    // MEM：访存
    // =========================================================================
    wire [3:0]  mem_strb;
    wire [31:0] mem_wdata_bus, mem_ld_data;
    wire        mem_misalign_unused;
    rv32i_lsu u_lsu (
        .addr_lo(ex_mem_result[1:0]), .funct3(ex_mem_funct3), .st_data(ex_mem_rs2_val), .ld_word(dmem_rdata),
        .wstrb(mem_strb), .wdata(mem_wdata_bus), .ld_data(mem_ld_data), .misalign(mem_misalign_unused));

    wire mem_go = ex_mem_valid & ~ex_mem_exc;
    assign dmem_addr  = {ex_mem_result[31:2], 2'b00};
    assign dmem_re    = mem_go & ex_mem_mem_re;
    assign dmem_wstrb = (mem_go & ex_mem_mem_we) ? mem_strb : 4'b0000;
    assign dmem_wdata = mem_wdata_bus;

    // =========================================================================
    // 流水线控制：先汇总事件，再生成每组寄存器在下一个沿的动作
    // =========================================================================
    // 事件：redirect 纠正预测；ex_kill 终止年轻指令；fetch_stop 记住停止取指的状态。
    // 冲刷优先于数据停顿：已取消的 ID 指令不再等待，也不计一次 stall。
    wire flush_young = redirect | ex_kill;
    wire stall       = if_id_valid & hazard & ~flush_young;

    // 动作：clear 只清 valid（气泡）；hold 保留 valid 和全部数据；其余情况接收上游。
    // PC：纠正 > 保持 > 采用预测；ex_kill 屏蔽纠正，使异常 / 程序结束优先。
    wire pc_redirect = redirect & ~ex_kill;
    wire pc_hold     = stall | fetch_stop | ex_kill;
    // IF/ID：清空 > 保持 > 接收 IF。stall 留住当前 ID 指令。
    wire if_id_clear = flush_young | fetch_stop;
    wire if_id_hold  = stall;
    // ID/EX：清空 > 接收 ID，没有保持分支。stall 时插气泡，原 EX 指令继续进 MEM。
    // 显式列出 fetch_stop：停止取指期间两级都无效，不靠 IF/ID 的无效位间接表达。
    wire id_ex_clear = flush_young | fetch_stop | stall | ~if_id_valid;
    // EX/MEM、MEM/WB：当前存储器无等待，每拍接收上游，包括随 valid 传来的气泡。

    assign perf_stall    = stall;
    assign perf_redirect = pc_redirect;

    // ---------------- PC ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_pc <= RESET_PC;
        end else if (pc_redirect) begin
            if_pc <= ex_next;
        end else if (pc_hold) begin
            if_pc <= if_pc;                    // 保持
        end else begin
            if_pc <= if_pred_next;            // 接收预测的下一地址
        end
    end

    // 停止取指状态：ex_kill 当拍就阻止 PC 前进；沿后由 fetch_stop 持续阻止。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_stop <= 1'b0;
        end else if (ex_kill) begin
            fetch_stop <= 1'b1;
        end else begin
            fetch_stop <= fetch_stop;          // 保持，直到复位
        end
    end

    // 四组级间寄存器的复位 / 清空只清 valid：无效槽位的数据不参与副作用，不必逐位清零。
    // ---------------- IF/ID ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_id_valid <= 1'b0;
        end else if (if_id_clear) begin
            if_id_valid <= 1'b0;               // 清空：阻止年轻指令进入 ID
        end else if (if_id_hold) begin
            if_id_valid     <= if_id_valid;    // 保持：整组保留，等待中的指令不能丢
            if_id_pc        <= if_id_pc;
            if_id_instr     <= if_id_instr;
            if_id_pred_next <= if_id_pred_next;
        end else begin                        // 接收 IF
            if_id_valid     <= 1'b1;
            if_id_pc        <= if_pc;
            if_id_instr     <= if_instr;
            if_id_pred_next <= if_pred_next;
        end
    end

    // ---------------- ID/EX ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_ex_valid <= 1'b0;
        end else if (id_ex_clear) begin
            id_ex_valid <= 1'b0;               // 插气泡，不是保持原 EX 指令
        end else begin                        // 接收有效的 ID 指令
            id_ex_valid      <= 1'b1;
            id_ex_pc         <= if_id_pc;
            id_ex_instr      <= if_id_instr;
            id_ex_pred_next  <= if_id_pred_next;
            id_ex_rs1        <= id_rs1;
            id_ex_rs2        <= id_rs2;
            id_ex_rd         <= id_rd;
            id_ex_rs1_val    <= id_rs1_val;
            id_ex_rs2_val    <= id_rs2_val;
            id_ex_imm        <= id_imm;
            id_ex_alu_op     <= id_alu_op;
            id_ex_funct3     <= id_funct3;
            id_ex_wb_sel     <= id_wb_sel;
            id_ex_alu_a_pc   <= id_alu_a_pc;
            id_ex_alu_a_zero <= id_alu_a_zero;
            id_ex_alu_b_imm  <= id_alu_b_imm;
            id_ex_reg_we     <= id_reg_we;
            id_ex_mem_re     <= id_mem_re;
            id_ex_mem_we     <= id_mem_we;
            id_ex_is_branch  <= id_is_branch;
            id_ex_is_jal     <= id_is_jal;
            id_ex_is_jalr    <= id_is_jalr;
            id_ex_is_system  <= id_is_system;
            id_ex_illegal    <= id_illegal;
        end
    end

    // ---------------- EX/MEM：始终接收沿前的 EX，前端停顿 / 冲刷不冻结它 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem_valid <= 1'b0;
        end else begin
            ex_mem_valid     <= id_ex_valid;
            ex_mem_pc        <= id_ex_pc;
            ex_mem_instr     <= id_ex_instr;
            // jal / jalr 的"结果"是链接值 PC+4；其它指令是 ALU 结果（load / store 是地址）
            ex_mem_result    <= (id_ex_wb_sel == 2'd2) ? ex_pc_plus4 : alu_y;
            ex_mem_rs2_val   <= ex_b_fwd;                  // store 数据也要用前递后的值
            ex_mem_rd        <= id_ex_rd;
            ex_mem_funct3    <= id_ex_funct3;
            ex_mem_reg_we    <= id_ex_reg_we;
            ex_mem_mem_re    <= id_ex_mem_re;
            ex_mem_mem_we    <= id_ex_mem_we;
            ex_mem_is_system <= id_ex_is_system;
            ex_mem_exc       <= ex_exc;
        end
    end

    // ---------------- MEM/WB：始终接收沿前的 MEM，老指令继续完成 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb_valid <= 1'b0;
        end else begin
            mem_wb_valid     <= ex_mem_valid;
            mem_wb_pc        <= ex_mem_pc;
            mem_wb_instr     <= ex_mem_instr;
            mem_wb_wdata     <= ex_mem_mem_re ? mem_ld_data : ex_mem_result;
            mem_wb_rd        <= ex_mem_rd;
            mem_wb_reg_we    <= ex_mem_reg_we;
            mem_wb_wstrb     <= dmem_wstrb;
            mem_wb_st_addr   <= dmem_addr;
            mem_wb_st_data   <= dmem_wdata;
            mem_wb_is_system <= ex_mem_is_system;
            mem_wb_exc       <= ex_mem_exc;
        end
    end

    // ---------------- WB：退休与停机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            halted <= 1'b0;
            trap   <= 1'b0;
        end else if (mem_wb_valid && !halted) begin
            if (mem_wb_exc) begin
                halted <= 1'b1;
                trap   <= 1'b1;
            end else if (mem_wb_is_system) begin
                halted <= 1'b1;
            end
        end
    end

    assign commit_valid    = mem_wb_valid & ~mem_wb_exc & ~halted;
    assign commit_pc       = mem_wb_pc;
    assign commit_insn     = mem_wb_instr;
    assign commit_rd_we    = mem_wb_reg_we & (mem_wb_rd != 5'd0);
    assign commit_rd       = commit_rd_we ? mem_wb_rd : 5'd0;
    assign commit_rd_wdata = commit_rd_we ? mem_wb_wdata : 32'd0;
    assign commit_wstrb    = mem_wb_wstrb;
    assign commit_st_addr  = mem_wb_st_addr;
    assign commit_st_data  = mem_wb_st_data;

    wire unused_ok = &{1'b0, unused_strb, unused_wd, unused_ld, mem_misalign_unused};
endmodule
