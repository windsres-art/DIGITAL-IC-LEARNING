// =============================================================================
// RV32I 单周期核：每个时钟周期做完一条指令（CPI = 1）
//   一拍里面按组合逻辑走过：取指 → 译码 → 读寄存器 → 执行 →（load/store 才访存）→ 写回。
//   真正在沿上更新的只有 PC、寄存器堆、数据存储器，以及停机标志。
//   哈佛结构：指令口和数据口分开。两个存储器都是组合读、同步写
//   （真实 SRAM 是同步读，第 2 节流水线才按那个来排）。
//   周期由最长的 load 决定：
//     PC → 取指 → 译码 → 读寄存器 → ALU 算地址 → 数据存储器 → 对齐 / 符号扩展 → 写回。
//   ecall / ebreak：本条提交后 halted=1，PC 不再前进，当作程序结束。
//   非法指令、非对齐访存：trap=1 并且停住，这一拍不写寄存器、不写存储器。
//
//   commit_* 全部是测试端口。核跑起来不依赖它们，testbench 拿去和 ISS 的轨迹逐条比对。
// =============================================================================
module rv32i_single #(
    parameter [31:0] RESET_PC = 32'h0000_0000   // 复位后第一条指令的地址
)(
    input             clk,
    input             rst_n,
    // 指令存储器。imem_addr 就是当前 PC，imem_rdata 必须在本拍组合给出
    output     [31:0] imem_addr,
    input      [31:0] imem_rdata,
    // 数据存储器。读也是组合的；写靠 wstrb，全 0 表示本拍不写
    output     [31:0] dmem_addr,     // 字对齐地址，低 2 位恒 0。字节位置在 wstrb 里
    output            dmem_re,       // 1 = 本拍是一次有效 load（测试和波形里看读请求）
    output     [3:0]  dmem_wstrb,
    output     [31:0] dmem_wdata,
    input      [31:0] dmem_rdata,
    // 停机状态。功能输出，testbench 也会看
    output reg        halted,        // 1 = 遇到 ecall/ebreak，或已经 trap。停在这条之后
    output reg        trap,          // 1 = 因为非法指令或非对齐访存停住
    // ---------- 测试端口（提交接口，核内部不用）----------
    // 每条真正执行完的指令拉高一拍 commit_valid，并给出 PC、指令、写回、store。
    // 思路和 RISC-V 的 RVFI 一样：只观察“退休”的结果，不看内部组合信号。
    output            commit_valid,
    output     [31:0] commit_pc,
    output     [31:0] commit_insn,
    output            commit_rd_we,          // 1 = 这条指令写了一个非 x0 寄存器
    output     [4:0]  commit_rd,
    output     [31:0] commit_rd_wdata,
    output     [3:0]  commit_wstrb,          // 非 0 = 这条指令有 store
    output     [31:0] commit_st_addr,
    output     [31:0] commit_st_data
);
    reg  [31:0] pc;                          // 本拍正在执行的指令地址
    wire [31:0] instr = imem_rdata;
    assign imem_addr = pc;

    // ---------------- 译码 ----------------
    // 这些线都是本条指令的控制，组合译码，不寄存
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [31:0] imm;
    wire [3:0]  alu_op;
    wire [1:0]  wb_sel;                      // 0 ALU，1 load，2 PC+4
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
    reg  [31:0] wb_data;                     // 本拍要写入 rd 的值，三个来源在写回段选出
    wire        stop;                        // 1 = 本拍作废：已经停过，或本条是非法 / 非对齐
    wire        rf_we = reg_we & ~stop;

    rv32i_regfile #(.BYPASS(0)) u_rf (       // 单周期先读后写，不用写穿透
        .clk(clk), .we(rf_we), .waddr(rd), .wdata(wb_data),
        .raddr1(rs1), .rdata1(rs1_val), .raddr2(rs2), .rdata2(rs2_val));

    // ---------------- 执行 ----------------
    // A 口：lui 用 0，auipc 用 PC，其余用 rs1。B 口：立即数指令和地址计算用 imm，R 型用 rs2
    wire [31:0] alu_a = alu_a_zero ? 32'd0 : alu_a_pc ? pc : rs1_val;
    wire [31:0] alu_b = alu_b_imm  ? imm   : rs2_val;
    wire [31:0] alu_y;
    rv32i_alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

    wire br_taken;                           // 分支条件是否成立。不是分支时核也不看它
    rv32i_branch u_br (.a(rs1_val), .b(rs2_val), .funct3(funct3), .taken(br_taken));

    wire [31:0] pc_plus4  = pc + 32'd4;
    wire [31:0] pc_target = pc + imm;        // jal 和分支共用。jalr 的目标在 ALU 里算
    wire [31:0] next_pc   = is_jalr                 ? {alu_y[31:1], 1'b0} :
                            (is_jal | (is_branch & br_taken)) ? pc_target :
                                                      pc_plus4;

    // ---------------- 访存 ----------------
    // 地址用 ALU 结果。低 2 位只送给对齐模块；送到存储器的地址把低 2 位清掉
    wire [3:0]  lsu_strb;
    wire [31:0] lsu_wdata, ld_data;
    wire        misalign;
    rv32i_lsu u_lsu (
        .addr_lo(alu_y[1:0]), .funct3(funct3), .st_data(rs2_val), .ld_word(dmem_rdata),
        .wstrb(lsu_strb), .wdata(lsu_wdata), .ld_data(ld_data), .misalign(misalign));

    wire mem_bad = (mem_re | mem_we) & misalign;   // 只有 load/store 的非对齐才算错
    assign stop  = halted | illegal | mem_bad;

    assign dmem_addr  = {alu_y[31:2], 2'b00};
    assign dmem_re    = mem_re & ~stop;
    assign dmem_wstrb = (mem_we & ~stop) ? lsu_strb : 4'b0000;
    assign dmem_wdata = lsu_wdata;

    // ---------------- 写回 ----------------
    // wb_sel：load 用对齐后的数据，jal/jalr 用 PC+4，其它写寄存器的指令用 ALU
    always @* begin
        case (wb_sel)
            2'd1:    wb_data = ld_data;
            2'd2:    wb_data = pc_plus4;
            default: wb_data = alu_y;
        endcase
    end

    // ---------------- PC 与停机 ----------------
    // 正常沿：PC 换成 next_pc。ecall/ebreak 把 halted 置上，下拍开始不再取新指令。
    // 非法或非对齐：halted 和 trap 都置上，本拍的 rf_we / dmem_wstrb 已经被 stop 清掉
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

    // ---------------- 测试端口 ----------------
    // commit_valid 在复位期间、停机之后、以及本条要 trap 时为 0。
    // 写 x0 对架构不可见，所以 commit_rd_we 把它报成“没写”。
    assign commit_valid    = rst_n & ~stop;
    assign commit_pc       = pc;
    assign commit_insn     = instr;
    assign commit_rd_we    = reg_we & (rd != 5'd0);
    assign commit_rd       = commit_rd_we ? rd : 5'd0;
    assign commit_rd_wdata = commit_rd_we ? wb_data : 32'd0;
    assign commit_wstrb    = dmem_wstrb;
    assign commit_st_addr  = dmem_addr;
    assign commit_st_data  = dmem_wdata;

    // uses_rs1 / uses_rs2 只在流水线里用于冒险检测。单周期核接出来，避免未读告警
    wire unused_ok = &{1'b0, uses_rs1, uses_rs2};
endmodule
