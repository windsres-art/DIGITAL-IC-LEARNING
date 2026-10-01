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
    // =========================================================================
    // IF/ID
    reg        d_valid;
    reg [31:0] d_pc, d_instr, d_pred_next;
    // ID/EX
    reg        x_valid;
    reg [31:0] x_pc, x_instr, x_rs1_val, x_rs2_val, x_imm, x_pred_next;
    reg [4:0]  x_rs1, x_rs2, x_rd;
    reg [3:0]  x_alu_op;
    reg [2:0]  x_funct3;
    reg [1:0]  x_wb_sel;
    reg        x_alu_a_pc, x_alu_a_zero, x_alu_b_imm, x_reg_we, x_mem_re, x_mem_we;
    reg        x_is_branch, x_is_jal, x_is_jalr, x_is_system, x_illegal;
    // EX/MEM
    reg        m_valid;
    reg [31:0] m_pc, m_instr, m_result, m_rs2_val;
    reg [4:0]  m_rd;
    reg [2:0]  m_funct3;
    reg        m_reg_we, m_mem_re, m_mem_we, m_is_system, m_exc;
    // MEM/WB
    reg        w_valid;
    reg [31:0] w_pc, w_instr, w_wdata, w_st_addr, w_st_data;
    reg [4:0]  w_rd;
    reg [3:0]  w_wstrb;
    reg        w_reg_we, w_is_system, w_exc;

    reg        fetch_stop;                      // ecall / 异常进入 EX 后停止取指

    wire        ex_taken;                       // EX 级分支解析结果（BTB 更新也要用）
    wire [31:0] ex_target;

    // =========================================================================
    // IF：取指 + 预测下一条 PC
    // =========================================================================
    reg  [31:0] f_pc;
    wire [31:0] f_instr    = imem_rdata;
    wire [31:0] f_pc_plus4 = f_pc + 32'd4;
    wire [31:0] f_pred_next;
    assign imem_addr = f_pc;

    generate
        if (BP == 1) begin : g_btfn
            // 组合读的指令存储器让 IF 级就能看到指令，于是可以"预译码"：
            // 只认 opcode 和立即数，算出 jal / 分支的目标，不需要任何表
            wire        f_jal = (f_instr[6:0] == 7'b1101111);
            wire        f_br  = (f_instr[6:0] == 7'b1100011);
            wire [31:0] f_imm_j = {{11{f_instr[31]}}, f_instr[31], f_instr[19:12], f_instr[20],
                                   f_instr[30:21], 1'b0};
            wire [31:0] f_imm_b = {{19{f_instr[31]}}, f_instr[31], f_instr[7], f_instr[30:25],
                                   f_instr[11:8], 1'b0};
            assign f_pred_next = f_jal               ? f_pc + f_imm_j :
                                 (f_br & f_instr[31]) ? f_pc + f_imm_b :   // 向后（偏移为负）预测跳
                                                        f_pc_plus4;
        end else if (BP == 2) begin : g_btb
            localparam N  = 1 << BTB_BITS;
            localparam TW = 30 - BTB_BITS;
            reg [N-1:0]  v;
            reg [TW-1:0] tag  [0:N-1];
            reg [31:0]   tgt  [0:N-1];
            reg [1:0]    cnt  [0:N-1];
            reg          jmp  [0:N-1];         // 无条件跳转（jal）：命中就跳，不看计数器

            wire [BTB_BITS-1:0] fi = f_pc[BTB_BITS+1:2];
            wire f_hit = v[fi] && (tag[fi] == f_pc[31:BTB_BITS+2]);
            assign f_pred_next = (f_hit && (jmp[fi] || cnt[fi][1])) ? tgt[fi] : f_pc_plus4;

            // EX 级更新：分支和 jal 都在这里解析。EX 里永远是正确路径上的指令，表不会被污染
            wire [BTB_BITS-1:0] xi = x_pc[BTB_BITS+1:2];
            wire x_hit   = v[xi] && (tag[xi] == x_pc[31:BTB_BITS+2]);
            wire x_upd   = x_valid & (x_is_branch | x_is_jal);
            // 只有有效位需要复位：v = 0 的项，其标签、目标、计数器都不会被使用
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    v <= {N{1'b0}};
                end else if (x_upd) begin
                    if (ex_taken) begin
                        v[xi]   <= 1'b1;
                        tag[xi] <= x_pc[31:BTB_BITS+2];
                        tgt[xi] <= ex_target;
                        jmp[xi] <= x_is_jal;
                        // 新分配的项从"弱跳"开始；已有的项饱和加 1
                        cnt[xi] <= !x_hit ? 2'b10 : (cnt[xi] == 2'b11) ? 2'b11 : cnt[xi] + 2'b01;
                    end else if (x_hit) begin
                        cnt[xi] <= (cnt[xi] == 2'b00) ? 2'b00 : cnt[xi] - 2'b01;
                    end
                end
            end
        end else begin : g_nt
            assign f_pred_next = f_pc_plus4;
        end
    endgenerate

    // =========================================================================
    // ID：译码、读寄存器、冒险检测
    // =========================================================================
    wire [4:0]  d_rd, d_rs1, d_rs2;
    wire [2:0]  d_funct3;
    wire [31:0] d_imm;
    wire [3:0]  d_alu_op;
    wire [1:0]  d_wb_sel;
    wire        d_alu_a_pc, d_alu_a_zero, d_alu_b_imm, d_reg_we, d_mem_re, d_mem_we;
    wire        d_is_branch, d_is_jal, d_is_jalr, d_is_system, d_uses_rs1, d_uses_rs2, d_illegal;

    rv32i_decode u_dec (
        .instr(d_instr), .rd(d_rd), .rs1(d_rs1), .rs2(d_rs2), .funct3(d_funct3), .imm(d_imm),
        .alu_op(d_alu_op), .alu_a_pc(d_alu_a_pc), .alu_a_zero(d_alu_a_zero), .alu_b_imm(d_alu_b_imm),
        .reg_we(d_reg_we), .mem_re(d_mem_re), .mem_we(d_mem_we), .wb_sel(d_wb_sel),
        .is_branch(d_is_branch), .is_jal(d_is_jal), .is_jalr(d_is_jalr), .is_system(d_is_system),
        .uses_rs1(d_uses_rs1), .uses_rs2(d_uses_rs2), .illegal(d_illegal));

    wire [31:0] d_rs1_val, d_rs2_val;
    wire        wb_we = w_valid & w_reg_we & ~w_exc;
    rv32i_regfile #(.BYPASS(1)) u_rf (
        .clk(clk), .we(wb_we), .waddr(w_rd), .wdata(w_wdata),
        .raddr1(d_rs1), .rdata1(d_rs1_val), .raddr2(d_rs2), .rdata2(d_rs2_val));

    // ID 里的指令要读 r，而 r 正被更老的某级指令写
    function dep(input [4:0] r, input use_r, input v, input we, input [4:0] rd);
        dep = use_r && v && we && (rd != 5'd0) && (rd == r);
    endfunction

    wire dep_x = dep(d_rs1, d_uses_rs1, x_valid, x_reg_we, x_rd) |
                 dep(d_rs2, d_uses_rs2, x_valid, x_reg_we, x_rd);
    wire dep_m = dep(d_rs1, d_uses_rs1, m_valid, m_reg_we, m_rd) |
                 dep(d_rs2, d_uses_rs2, m_valid, m_reg_we, m_rd);

    // 有前递：只有"EX 里是 load、ID 要用它的结果"必须停（数据要到 MEM 末尾才有）
    // 无前递：生产者还在 EX 或 MEM 就得等，进入 WB 后靠寄存器堆写穿透拿到
    wire load_use  = dep_x & x_mem_re;
    wire hazard    = (FWD != 0) ? load_use : (dep_x | dep_m);

    // =========================================================================
    // EX：前递、ALU、分支解析
    // =========================================================================
    reg  [31:0] ex_a_fwd, ex_b_fwd;             // 前递后的 rs1 / rs2
    always @* begin
        ex_a_fwd = x_rs1_val;
        ex_b_fwd = x_rs2_val;
        if (FWD != 0) begin
            // 先判 MEM/WB 再判 EX/MEM：后者写在后面，优先级更高（取最新的值）
            if (w_valid && w_reg_we && w_rd != 5'd0 && w_rd == x_rs1) ex_a_fwd = w_wdata;
            if (m_valid && m_reg_we && m_rd != 5'd0 && m_rd == x_rs1) ex_a_fwd = m_result;
            if (w_valid && w_reg_we && w_rd != 5'd0 && w_rd == x_rs2) ex_b_fwd = w_wdata;
            if (m_valid && m_reg_we && m_rd != 5'd0 && m_rd == x_rs2) ex_b_fwd = m_result;
        end
    end

    wire [31:0] alu_a = x_alu_a_zero ? 32'd0 : x_alu_a_pc ? x_pc : ex_a_fwd;
    wire [31:0] alu_b = x_alu_b_imm  ? x_imm : ex_b_fwd;
    wire [31:0] alu_y;
    rv32i_alu u_alu (.a(alu_a), .b(alu_b), .op(x_alu_op), .y(alu_y));

    wire br_cond;
    rv32i_branch u_br (.a(ex_a_fwd), .b(ex_b_fwd), .funct3(x_funct3), .taken(br_cond));

    wire [31:0] x_pc_plus4 = x_pc + 32'd4;
    assign      ex_taken   = x_is_jal | x_is_jalr | (x_is_branch & br_cond);
    assign      ex_target  = x_is_jalr ? {alu_y[31:1], 1'b0} : x_pc + x_imm;
    wire [31:0] ex_next    = ex_taken ? ex_target : x_pc_plus4;

    // 预测错 = 预测的下一条 PC 与实际不符。非控制指令的预测值就是 PC+4，自然不会改向
    wire redirect = x_valid & (ex_next != x_pred_next);

    // 非对齐访存在 EX 就能判断（地址已经算出来）
    wire [3:0]  unused_strb;
    wire [31:0] unused_wd, unused_ld;
    wire        ex_misalign;
    rv32i_lsu u_lsu_chk (
        .addr_lo(alu_y[1:0]), .funct3(x_funct3), .st_data(32'd0), .ld_word(32'd0),
        .wstrb(unused_strb), .wdata(unused_wd), .ld_data(unused_ld), .misalign(ex_misalign));
    wire ex_exc  = x_illegal | ((x_mem_re | x_mem_we) & ex_misalign);
    wire ex_kill = x_valid & (x_is_system | ex_exc);   // 杀掉所有更年轻的指令

    // =========================================================================
    // MEM：访存
    // =========================================================================
    wire [3:0]  m_strb;
    wire [31:0] m_wdata_bus, m_ld_data;
    wire        m_misalign_unused;
    rv32i_lsu u_lsu (
        .addr_lo(m_result[1:0]), .funct3(m_funct3), .st_data(m_rs2_val), .ld_word(dmem_rdata),
        .wstrb(m_strb), .wdata(m_wdata_bus), .ld_data(m_ld_data), .misalign(m_misalign_unused));

    wire m_go = m_valid & ~m_exc;
    assign dmem_addr  = {m_result[31:2], 2'b00};
    assign dmem_re    = m_go & m_mem_re;
    assign dmem_wstrb = (m_go & m_mem_we) ? m_strb : 4'b0000;
    assign dmem_wdata = m_wdata_bus;

    // =========================================================================
    // 流水线控制
    // =========================================================================
    wire flush_young = redirect | ex_kill;            // 冲掉 IF/ID、ID/EX 里的指令
    wire stall       = d_valid & hazard & ~flush_young;

    assign perf_stall    = stall;
    assign perf_redirect = redirect & ~ex_kill;

    // ---------------- PC ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       f_pc <= RESET_PC;
        else if (redirect & ~ex_kill)     f_pc <= ex_next;
        else if (stall | fetch_stop | ex_kill) f_pc <= f_pc;
        else                              f_pc <= f_pred_next;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       fetch_stop <= 1'b0;
        else if (ex_kill) fetch_stop <= 1'b1;
    end

    // ---------------- IF/ID ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_valid <= 1'b0;
        end else if (flush_young | fetch_stop) begin
            d_valid <= 1'b0;
        end else if (!stall) begin
            d_valid     <= 1'b1;
            d_pc        <= f_pc;
            d_instr     <= f_instr;
            d_pred_next <= f_pred_next;
        end
    end

    // ---------------- ID/EX ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_valid <= 1'b0;
        end else if (flush_young | stall | !d_valid) begin
            x_valid <= 1'b0;                          // 插气泡
        end else begin
            x_valid      <= 1'b1;
            x_pc         <= d_pc;
            x_instr      <= d_instr;
            x_pred_next  <= d_pred_next;
            x_rs1        <= d_rs1;
            x_rs2        <= d_rs2;
            x_rd         <= d_rd;
            x_rs1_val    <= d_rs1_val;
            x_rs2_val    <= d_rs2_val;
            x_imm        <= d_imm;
            x_alu_op     <= d_alu_op;
            x_funct3     <= d_funct3;
            x_wb_sel     <= d_wb_sel;
            x_alu_a_pc   <= d_alu_a_pc;
            x_alu_a_zero <= d_alu_a_zero;
            x_alu_b_imm  <= d_alu_b_imm;
            x_reg_we     <= d_reg_we;
            x_mem_re     <= d_mem_re;
            x_mem_we     <= d_mem_we;
            x_is_branch  <= d_is_branch;
            x_is_jal     <= d_is_jal;
            x_is_jalr    <= d_is_jalr;
            x_is_system  <= d_is_system;
            x_illegal    <= d_illegal;
        end
    end

    // ---------------- EX/MEM ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
        end else begin
            m_valid     <= x_valid;
            m_pc        <= x_pc;
            m_instr     <= x_instr;
            // jal / jalr 的"结果"是链接值 PC+4；其它指令是 ALU 结果（load / store 是地址）
            m_result    <= (x_wb_sel == 2'd2) ? x_pc_plus4 : alu_y;
            m_rs2_val   <= ex_b_fwd;                  // store 数据也要用前递后的值
            m_rd        <= x_rd;
            m_funct3    <= x_funct3;
            m_reg_we    <= x_reg_we;
            m_mem_re    <= x_mem_re;
            m_mem_we    <= x_mem_we;
            m_is_system <= x_is_system;
            m_exc       <= ex_exc;
        end
    end

    // ---------------- MEM/WB ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_valid <= 1'b0;
        end else begin
            w_valid     <= m_valid;
            w_pc        <= m_pc;
            w_instr     <= m_instr;
            w_wdata     <= m_mem_re ? m_ld_data : m_result;
            w_rd        <= m_rd;
            w_reg_we    <= m_reg_we;
            w_wstrb     <= dmem_wstrb;
            w_st_addr   <= dmem_addr;
            w_st_data   <= dmem_wdata;
            w_is_system <= m_is_system;
            w_exc       <= m_exc;
        end
    end

    // ---------------- WB：退休与停机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            halted <= 1'b0;
            trap   <= 1'b0;
        end else if (w_valid && !halted) begin
            if (w_exc) begin
                halted <= 1'b1;
                trap   <= 1'b1;
            end else if (w_is_system) begin
                halted <= 1'b1;
            end
        end
    end

    assign commit_valid    = w_valid & ~w_exc & ~halted;
    assign commit_pc       = w_pc;
    assign commit_insn     = w_instr;
    assign commit_rd_we    = w_reg_we & (w_rd != 5'd0);
    assign commit_rd       = commit_rd_we ? w_rd : 5'd0;
    assign commit_rd_wdata = commit_rd_we ? w_wdata : 32'd0;
    assign commit_wstrb    = w_wstrb;
    assign commit_st_addr  = w_st_addr;
    assign commit_st_data  = w_st_data;

    wire unused_ok = &{1'b0, unused_strb, unused_wd, unused_ld, m_misalign_unused};
endmodule
