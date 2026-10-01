// =============================================================================
// RV32I 单周期核：每个时钟周期取指、译码、执行、访存、写回一条指令（CPI = 1）
//   - 哈佛结构：指令口与数据口分开，两个存储器都是组合读、同步写（便于讲原理；
//     真实 SRAM 是同步读，见第 2 节流水线如何安排）
//   - 周期由最长的 load 路径决定：PC → 取指 → 译码 → 读寄存器 → ALU 算地址
//     → 数据存储器 → 对齐 / 符号扩展 → 寄存器堆写端口，这正是要做流水线的原因
//   - ecall / ebreak：提交后停住（halted），用作程序结束；非法指令、非对齐访存：trap 停住
//   - commit_* 是"提交接口"（思路同 RISC-V 的 RVFI）：每条退休指令报告一次
//     PC、写回寄存器、存储，testbench 用它和 ISS 逐条比对
// =============================================================================
module rv32i_single #(
    parameter [31:0] RESET_PC = 32'h0000_0000
)(
    input             clk,
    input             rst_n,
    // 指令存储器
    output     [31:0] imem_addr,
    input      [31:0] imem_rdata,
    // 数据存储器
    output     [31:0] dmem_addr,
    output            dmem_re,
    output     [3:0]  dmem_wstrb,
    output     [31:0] dmem_wdata,
    input      [31:0] dmem_rdata,
    // 状态
    output reg        halted,
    output reg        trap,
    // 提交接口
    output            commit_valid,
    output     [31:0] commit_pc,
    output     [31:0] commit_insn,
    output            commit_rd_we,
    output     [4:0]  commit_rd,
    output     [31:0] commit_rd_wdata,
    output     [3:0]  commit_wstrb,
    output     [31:0] commit_st_addr,
    output     [31:0] commit_st_data
);
    reg  [31:0] pc;
    wire [31:0] instr = imem_rdata;
    assign imem_addr = pc;

    // ---------------- 译码 ----------------
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [31:0] imm;
    wire [3:0]  alu_op;
    wire [1:0]  wb_sel;
    wire        alu_a_pc, alu_a_zero, alu_b_imm, reg_we, mem_re, mem_we;
    wire        is_branch, is_jal, is_jalr, is_system, uses_rs1, uses_rs2, illegal;

    rv32i_decode u_dec (
        .instr(instr), .rd(rd), .rs1(rs1), .rs2(rs2), .funct3(funct3), .imm(imm),
        .alu_op(alu_op), .alu_a_pc(alu_a_pc), .alu_a_zero(alu_a_zero), .alu_b_imm(alu_b_imm),
        .reg_we(reg_we), .mem_re(mem_re), .mem_we(mem_we), .wb_sel(wb_sel),
        .is_branch(is_branch), .is_jal(is_jal), .is_jalr(is_jalr), .is_system(is_system),
        .uses_rs1(uses_rs1), .uses_rs2(uses_rs2), .illegal(illegal));

    // ---------------- 寄存器堆 ----------------
    wire [31:0] rs1_val, rs2_val;
    reg  [31:0] wb_data;
    wire        stop;                   // 本拍不执行（已停住或要 trap）
    wire        rf_we = reg_we & ~stop;

    rv32i_regfile #(.BYPASS(0)) u_rf (  // 单周期核里读和写不会"同一条指令前后脚"，不需要旁路
        .clk(clk), .we(rf_we), .waddr(rd), .wdata(wb_data),
        .raddr1(rs1), .rdata1(rs1_val), .raddr2(rs2), .rdata2(rs2_val));

    // ---------------- 执行 ----------------
    wire [31:0] alu_a = alu_a_zero ? 32'd0 : alu_a_pc ? pc : rs1_val;
    wire [31:0] alu_b = alu_b_imm  ? imm   : rs2_val;
    wire [31:0] alu_y;
    rv32i_alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

    wire br_taken;
    rv32i_branch u_br (.a(rs1_val), .b(rs2_val), .funct3(funct3), .taken(br_taken));

    wire [31:0] pc_plus4  = pc + 32'd4;
    wire [31:0] pc_target = pc + imm;                     // jal 与分支共用一个加法器
    wire [31:0] next_pc   = is_jalr                 ? {alu_y[31:1], 1'b0} :  // 目标最低位清零
                            (is_jal | (is_branch & br_taken)) ? pc_target :
                                                      pc_plus4;

    // ---------------- 访存 ----------------
    wire [3:0]  lsu_strb;
    wire [31:0] lsu_wdata, ld_data;
    wire        misalign;
    rv32i_lsu u_lsu (
        .addr_lo(alu_y[1:0]), .funct3(funct3), .st_data(rs2_val), .ld_word(dmem_rdata),
        .wstrb(lsu_strb), .wdata(lsu_wdata), .ld_data(ld_data), .misalign(misalign));

    wire mem_bad = (mem_re | mem_we) & misalign;
    assign stop  = halted | illegal | mem_bad;

    assign dmem_addr  = {alu_y[31:2], 2'b00};
    assign dmem_re    = mem_re & ~stop;
    assign dmem_wstrb = (mem_we & ~stop) ? lsu_strb : 4'b0000;
    assign dmem_wdata = lsu_wdata;

    // ---------------- 写回 ----------------
    always @* begin
        case (wb_sel)
            2'd1:    wb_data = ld_data;
            2'd2:    wb_data = pc_plus4;
            default: wb_data = alu_y;
        endcase
    end

    // ---------------- PC 与停机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc     <= RESET_PC;
            halted <= 1'b0;
            trap   <= 1'b0;
        end else if (!halted) begin
            if (illegal | mem_bad) begin
                halted <= 1'b1;
                trap   <= 1'b1;
            end else begin
                pc     <= next_pc;
                halted <= is_system;
            end
        end
    end

    // ---------------- 提交接口 ----------------
    assign commit_valid    = rst_n & ~stop;
    assign commit_pc       = pc;
    assign commit_insn     = instr;
    assign commit_rd_we    = reg_we & (rd != 5'd0);
    assign commit_rd       = commit_rd_we ? rd : 5'd0;
    assign commit_rd_wdata = commit_rd_we ? wb_data : 32'd0;
    assign commit_wstrb    = dmem_wstrb;
    assign commit_st_addr  = dmem_addr;
    assign commit_st_data  = dmem_wdata;

    // uses_rs1 / uses_rs2 只在流水线里用于冒险检测
    wire unused_ok = &{1'b0, uses_rs1, uses_rs2};
endmodule
