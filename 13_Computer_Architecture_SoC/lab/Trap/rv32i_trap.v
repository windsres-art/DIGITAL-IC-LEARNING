// =============================================================================
// RV32I + Zicsr 五级流水线，机器模式（M-mode）trap：异常与中断都精确
//   在第 2 节流水线（前递 + load-use 停 1 拍，总预测不跳）的基础上增加：
//     CSR    mstatus(MIE/MPIE，MPP 恒为 M) misa mie mip mtvec(直接 / 向量) mscratch
//            mepc mcause mtval mcycle[h] minstret[h] mvendorid marchid mimpid mhartid
//     异常   取指地址非对齐(0，跳转目标) 非法指令(2) ebreak(3) load / store 非对齐(4 / 6)
//            load / store 访问错误(5 / 7，总线返回 err) ecall(11)
//     中断   外部 MEI(11) > 软件 MSI(3) > 定时器 MTI(7)，条件 mstatus.MIE & mie & mip
//     指令   csrrw/s/c[i]、mret、wfi（没有使能的中断待处理时停在 WB 等待）
//   数据口带 ready / err：MEM 级访存没完成时整条流水线停住（WB 插气泡）
//   精确性的安排：
//     - "串行化"指令（CSR、mret、wfi、ecall、ebreak、任何异常）进入 EX 时杀掉所有更年轻的
//       指令并停止取指，自己走到 WB 再生效，然后从正确的地址重新取指。
//       WB 是唯一修改 CSR、进入 trap 的地方，此时流水线里没有别的指令。
//     - 中断在 EX 级采样：EX 里那条指令被标记为"被中断"，不执行（不访存、不写回），
//       到 WB 时以它的 PC 作为 mepc 进入 trap。比它老的指令都正常完成。
//     - 访问错误在 MEM 级才知道：杀掉 EX 及更年轻的指令，本条带异常走到 WB。
//   提交接口：每条退休的指令一个 commit；每次进入 trap 一个 trap 事件（cause / epc / tval，
//   中断还附带采样时的 mip），供 testbench 写成日志、由 trap_iss.py 逐条复核。
// =============================================================================
module rv32i_trap #(
    parameter [31:0] RESET_PC = 32'h0000_0000
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
    input             dmem_ready,               // 本拍访存完成
    input             dmem_err,                 // 与 ready 同拍有效：访问错误
    input             irq_ext,                  // 来自 PLIC
    input             irq_timer,                // 来自 CLINT：mtime >= mtimecmp
    input             irq_soft,                 // 来自 CLINT：msip
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
    output            trap_valid,
    output     [31:0] trap_cause,
    output     [31:0] trap_epc,
    output     [31:0] trap_tval,
    output     [11:0] trap_mip
);
    localparam [2:0] S_NONE = 3'd0, S_CSR = 3'd1, S_MRET = 3'd2, S_WFI = 3'd3;

    // ---------------- CSR 状态 ----------------
    reg        st_mie, st_mpie;
    reg        ie_msie, ie_mtie, ie_meie;
    reg [31:0] mtvec, mscratch, mcause, mtval;
    reg [31:2] mepc;
    reg [63:0] mcycle, minstret;

    wire [11:0] mip_now = {irq_ext, 3'b000, irq_timer, 3'b000, irq_soft, 3'b000};
    wire [11:0] mie_v   = {ie_meie, 3'b000, ie_mtie, 3'b000, ie_msie, 3'b000};
    wire [11:0] pend    = mip_now & mie_v;
    wire        irq_any = st_mie & (|pend);
    // 优先级：MEI > MSI > MTI
    wire [3:0]  irq_code = pend[11] ? 4'd11 : pend[3] ? 4'd3 : 4'd7;

    // =========================================================================
    // 级间寄存器
    // =========================================================================
    reg        d_valid;
    reg [31:0] d_pc, d_instr;
    reg        x_valid;
    reg [31:0] x_pc, x_instr, x_rs1_val, x_rs2_val, x_imm;
    reg [4:0]  x_rs1, x_rs2, x_rd;
    reg [3:0]  x_alu_op;
    reg [2:0]  x_funct3, x_sys;
    reg [1:0]  x_wb_sel;
    reg        x_alu_a_pc, x_alu_a_zero, x_alu_b_imm, x_reg_we, x_mem_re, x_mem_we;
    reg        x_is_branch, x_is_jal, x_is_jalr, x_illegal, x_ecall, x_ebreak;
    reg        m_valid;
    reg [31:0] m_pc, m_instr, m_result, m_rs2_val, m_tval;
    reg [4:0]  m_rd;
    reg [2:0]  m_funct3, m_sys;
    reg [3:0]  m_code;
    reg [11:0] m_mip;
    reg        m_reg_we, m_mem_re, m_mem_we, m_exc, m_irq;
    reg        w_valid;
    reg [31:0] w_pc, w_instr, w_wdata, w_st_addr, w_st_data, w_tval;
    reg [4:0]  w_rd;
    reg [3:0]  w_wstrb, w_code;
    reg [2:0]  w_funct3, w_sys;
    reg [11:0] w_mip;
    reg        w_reg_we, w_exc, w_irq;
    reg        fetch_stop;

    // =========================================================================
    // IF
    // =========================================================================
    reg [31:0] f_pc;
    assign imem_addr = f_pc;

    // =========================================================================
    // ID
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

    // 第 1 节的译码器只认 ecall / ebreak，其余 SYSTEM 指令在这里补充
    wire d_sys_op = (d_instr[6:0] == 7'b1110011);
    wire d_csr    = d_sys_op & (d_funct3 != 3'b000) & (d_funct3 != 3'b100);
    wire d_mret   = (d_instr == 32'h3020_0073);
    wire d_wfi    = (d_instr == 32'h1050_0073);
    wire d_ecall  = (d_instr == 32'h0000_0073);
    wire d_ebreak = (d_instr == 32'h0010_0073);
    wire d_ill    = d_sys_op ? ~(d_csr | d_mret | d_wfi | d_ecall | d_ebreak) : d_illegal;
    wire d_use1   = d_uses_rs1 | (d_csr & ~d_funct3[2]);
    wire [2:0] d_sys = d_csr ? S_CSR : d_mret ? S_MRET : d_wfi ? S_WFI : S_NONE;

    wire [31:0] d_rs1_val, d_rs2_val, wb_val;
    wire        wb_we;
    rv32i_regfile #(.BYPASS(1)) u_rf (
        .clk(clk), .we(wb_we), .waddr(w_rd), .wdata(wb_val),
        .raddr1(d_rs1), .rdata1(d_rs1_val), .raddr2(d_rs2), .rdata2(d_rs2_val));

    wire load_use = x_valid && x_mem_re && (x_rd != 5'd0) &&
                    ((d_use1 && x_rd == d_rs1) || (d_uses_rs2 && x_rd == d_rs2));

    // =========================================================================
    // EX
    // =========================================================================
    reg [31:0] ex_a_fwd, ex_b_fwd;
    always @* begin
        ex_a_fwd = x_rs1_val;
        ex_b_fwd = x_rs2_val;
        if (w_valid && w_reg_we && w_rd != 5'd0 && w_rd == x_rs1) ex_a_fwd = wb_val;
        if (m_valid && m_reg_we && m_rd != 5'd0 && m_rd == x_rs1) ex_a_fwd = m_result;
        if (w_valid && w_reg_we && w_rd != 5'd0 && w_rd == x_rs2) ex_b_fwd = wb_val;
        if (m_valid && m_reg_we && m_rd != 5'd0 && m_rd == x_rs2) ex_b_fwd = m_result;
    end

    wire [31:0] alu_a = x_alu_a_zero ? 32'd0 : x_alu_a_pc ? x_pc : ex_a_fwd;
    wire [31:0] alu_b = x_alu_b_imm  ? x_imm : ex_b_fwd;
    wire [31:0] alu_y;
    rv32i_alu u_alu (.a(alu_a), .b(alu_b), .op(x_alu_op), .y(alu_y));

    wire br_cond;
    rv32i_branch u_br (.a(ex_a_fwd), .b(ex_b_fwd), .funct3(x_funct3), .taken(br_cond));

    wire [31:0] x_pc_plus4 = x_pc + 32'd4;
    wire        ex_taken   = x_is_jal | x_is_jalr | (x_is_branch & br_cond);
    wire [31:0] ex_target  = x_is_jalr ? {alu_y[31:1], 1'b0} : x_pc + x_imm;

    wire [3:0]  unused_strb;
    wire [31:0] unused_wd, unused_ld;
    wire        ex_misalign;
    rv32i_lsu u_lsu_chk (
        .addr_lo(alu_y[1:0]), .funct3(x_funct3), .st_data(32'd0), .ld_word(32'd0),
        .wstrb(unused_strb), .wdata(unused_wd), .ld_data(unused_ld), .misalign(ex_misalign));

    // CSR 地址是否存在、是否可写（地址 [11:10] = 11 是只读）
    wire [11:0] x_csr_a  = x_instr[31:20];
    wire        x_csr_wr = (x_funct3[1:0] == 2'b01) | (x_rs1 != 5'd0);
    reg         x_csr_ok;
    always @* begin
        case (x_csr_a)
            12'h300, 12'h301, 12'h304, 12'h305, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
            12'hB00, 12'hB02, 12'hB80, 12'hB82, 12'hF11, 12'hF12, 12'hF13, 12'hF14: x_csr_ok = 1'b1;
            default: x_csr_ok = 1'b0;
        endcase
        if (x_csr_wr && x_csr_a[11:10] == 2'b11) x_csr_ok = 1'b0;
    end

    // 同一条指令的同步异常（一条指令最多命中一种）
    reg        ex_exc;
    reg [3:0]  ex_code;
    reg [31:0] ex_tval;
    always @* begin
        ex_exc = 1'b1; ex_code = 4'd0; ex_tval = 32'd0;
        if (x_illegal || (x_sys == S_CSR && !x_csr_ok)) begin ex_code = 4'd2;  ex_tval = x_instr; end
        else if (x_ebreak)                    begin ex_code = 4'd3;  ex_tval = x_pc;    end
        else if (x_ecall)                     ex_code = 4'd11;
        else if (x_mem_re && ex_misalign)     begin ex_code = 4'd4;  ex_tval = alu_y;   end
        else if (x_mem_we && ex_misalign)     begin ex_code = 4'd6;  ex_tval = alu_y;   end
        else if (ex_taken && ex_target[1])    begin ex_code = 4'd0;  ex_tval = ex_target; end
        else ex_exc = 1'b0;
    end

    // =========================================================================
    // MEM
    // =========================================================================
    wire [3:0]  m_strb;
    wire [31:0] m_wdata_bus, m_ld_data;
    wire        m_misalign_unused;
    rv32i_lsu u_lsu (
        .addr_lo(m_result[1:0]), .funct3(m_funct3), .st_data(m_rs2_val), .ld_word(dmem_rdata),
        .wstrb(m_strb), .wdata(m_wdata_bus), .ld_data(m_ld_data), .misalign(m_misalign_unused));

    wire m_go     = m_valid & ~m_exc & ~m_irq;
    wire mem_req  = m_go & (m_mem_re | m_mem_we);
    wire mem_wait = mem_req & ~dmem_ready;
    wire m_fault  = mem_req & dmem_ready & dmem_err;
    wire adv      = ~mem_wait;
    assign dmem_addr  = {m_result[31:2], 2'b00};
    assign dmem_re    = m_go & m_mem_re;
    assign dmem_wstrb = (m_go & m_mem_we) ? m_strb : 4'b0000;
    assign dmem_wdata = m_wdata_bus;

    // =========================================================================
    // WB：退休、CSR、trap
    // =========================================================================
    wire w_trap   = w_valid & (w_exc | w_irq);
    wire w_csr    = w_valid & ~w_trap & (w_sys == S_CSR);
    wire wfi_wait = w_valid & ~w_trap & (w_sys == S_WFI) & ~(|(mip_now & mie_v));

    // CSR 读
    wire [11:0] w_csr_a = w_instr[31:20];
    reg  [31:0] csr_old;
    always @* begin
        case (w_csr_a)
            12'h300: csr_old = {19'd0, 2'b11, 3'd0, st_mpie, 3'd0, st_mie, 3'd0};
            12'h301: csr_old = 32'h4000_0100;                   // RV32I
            12'h304: csr_old = {20'd0, mie_v};
            12'h305: csr_old = mtvec;
            12'h340: csr_old = mscratch;
            12'h341: csr_old = {mepc, 2'b00};
            12'h342: csr_old = mcause;
            12'h343: csr_old = mtval;
            12'h344: csr_old = {20'd0, mip_now};
            12'hB00: csr_old = mcycle[31:0];
            12'hB80: csr_old = mcycle[63:32];
            12'hB02: csr_old = minstret[31:0];
            12'hB82: csr_old = minstret[63:32];
            default: csr_old = 32'd0;                           // mvendorid 等：0
        endcase
    end
    // w_wdata 里放的是操作数：rs1 的值或 5 bit 立即数
    wire [31:0] csr_new = (w_funct3[1:0] == 2'b01) ? w_wdata :
                          (w_funct3[1:0] == 2'b10) ? (csr_old | w_wdata) : (csr_old & ~w_wdata);
    wire        csr_we  = w_csr & ((w_funct3[1:0] == 2'b01) | (w_instr[19:15] != 5'd0));

    assign wb_val = (w_sys == S_CSR) ? csr_old : w_wdata;
    assign wb_we  = w_valid & w_reg_we & ~w_trap & ~wfi_wait;

    wire [31:0] tvec_base = {mtvec[31:2], 2'b00};
    reg         wb_redirect;
    reg  [31:0] wb_target;
    always @* begin
        wb_redirect = 1'b0;
        wb_target   = w_pc + 32'd4;
        if (w_trap) begin
            wb_redirect = 1'b1;
            wb_target   = (w_irq && mtvec[0]) ? tvec_base + {26'd0, w_code, 2'b00} : tvec_base;
        end else if (w_valid && w_sys == S_MRET) begin
            wb_redirect = 1'b1;
            wb_target   = {mepc, 2'b00};
        end else if (w_valid && (w_sys == S_CSR || (w_sys == S_WFI && !wfi_wait))) begin
            wb_redirect = 1'b1;
        end
    end

    assign commit_valid    = w_valid & ~w_trap & ~wfi_wait;
    assign commit_pc       = w_pc;
    assign commit_insn     = w_instr;
    assign commit_rd_we    = w_reg_we & (w_rd != 5'd0);
    assign commit_rd       = commit_rd_we ? w_rd : 5'd0;
    assign commit_rd_wdata = commit_rd_we ? wb_val : 32'd0;
    assign commit_wstrb    = w_wstrb;
    assign commit_st_addr  = w_st_addr;
    assign commit_st_data  = w_st_data;
    assign trap_valid      = w_trap;
    assign trap_cause      = {w_irq, 27'd0, w_code};
    assign trap_epc        = w_pc;
    assign trap_tval       = w_irq ? 32'd0 : w_tval;
    assign trap_mip        = w_irq ? w_mip : 12'd0;

    // =========================================================================
    // 流水线控制
    // =========================================================================
    wire x_irq    = x_valid & irq_any;                              // 本条被中断
    wire x_serial = (x_sys != S_NONE) | x_ecall | x_ebreak;
    wire ex_kill  = x_valid & (x_irq | x_serial | ex_exc);
    wire redirect = x_valid & ~ex_kill & ~m_fault & ex_taken;       // 总预测不跳
    wire flush_young = redirect | ex_kill | m_fault;
    wire stall    = d_valid & load_use & ~flush_young;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       f_pc <= RESET_PC;
        else if (wb_redirect)             f_pc <= wb_target;
        else if (!adv)                    f_pc <= f_pc;
        else if (redirect)                f_pc <= ex_target;
        else if (stall | fetch_stop | ex_kill | m_fault) f_pc <= f_pc;
        else                              f_pc <= f_pc + 32'd4;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                              fetch_stop <= 1'b0;
        else if (wb_redirect)                    fetch_stop <= 1'b0;
        else if (adv && (ex_kill || m_fault))    fetch_stop <= 1'b1;
    end

    // IF/ID
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_valid <= 1'b0;
        end else if (adv) begin
            if (flush_young | fetch_stop | wb_redirect) d_valid <= 1'b0;
            else if (!stall) begin
                d_valid <= 1'b1;
                d_pc    <= f_pc;
                d_instr <= imem_rdata;
            end
        end
    end

    // ID/EX
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_valid <= 1'b0;
        end else if (!adv) begin
            // 访存等待时 EX 冻结、WB 却在排空：前递源下一拍就不在了，先把前递后的值存下来
            x_rs1_val <= ex_a_fwd;
            x_rs2_val <= ex_b_fwd;
        end else begin
            if (flush_young | stall | !d_valid) begin
                x_valid <= 1'b0;
            end else begin
                x_valid      <= 1'b1;
                x_pc         <= d_pc;
                x_instr      <= d_instr;
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
                x_reg_we     <= d_reg_we | d_csr;
                x_mem_re     <= d_mem_re;
                x_mem_we     <= d_mem_we;
                x_is_branch  <= d_is_branch;
                x_is_jal     <= d_is_jal;
                x_is_jalr    <= d_is_jalr;
                x_illegal    <= d_ill;
                x_ecall      <= d_ecall;
                x_ebreak     <= d_ebreak;
                x_sys        <= d_sys;
            end
        end
    end

    // EX/MEM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
        end else if (adv) begin
            m_valid   <= x_valid & ~m_fault;
            m_pc      <= x_pc;
            m_instr   <= x_instr;
            // CSR 指令的"结果"是操作数：rs1 的值（csrrw/s/c）或 rs1 字段的 5 bit 立即数（*i）
            m_result  <= (x_sys == S_CSR) ? (x_funct3[2] ? {27'd0, x_rs1} : ex_a_fwd) :
                         (x_wb_sel == 2'd2) ? x_pc_plus4 : alu_y;
            m_rs2_val <= ex_b_fwd;
            m_rd      <= x_rd;
            m_funct3  <= x_funct3;
            m_reg_we  <= x_reg_we;
            m_mem_re  <= x_mem_re;
            m_mem_we  <= x_mem_we;
            m_sys     <= x_sys;
            m_irq     <= x_irq;
            m_exc     <= ~x_irq & ex_exc;
            m_code    <= x_irq ? irq_code : ex_code;
            m_tval    <= ex_tval;
            m_mip     <= mip_now;
        end
    end

    // MEM/WB（wfi 等待时保持）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_valid <= 1'b0;
        end else if (!wfi_wait) begin
            w_valid   <= m_valid & adv;
            w_pc      <= m_pc;
            w_instr   <= m_instr;
            w_wdata   <= m_mem_re ? m_ld_data : m_result;
            w_rd      <= m_rd;
            w_reg_we  <= m_reg_we;
            w_funct3  <= m_funct3;
            w_sys     <= m_sys;
            w_irq     <= m_irq;
            w_exc     <= m_exc | m_fault;
            w_code    <= m_fault ? (m_mem_we ? 4'd7 : 4'd5) : m_code;
            w_tval    <= m_fault ? m_result : m_tval;
            w_mip     <= m_mip;
            w_wstrb   <= m_fault ? 4'b0000 : dmem_wstrb;
            w_st_addr <= dmem_addr;
            w_st_data <= dmem_wdata;
        end
    end

    // CSR 与计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_mie <= 1'b0; st_mpie <= 1'b0;
            ie_msie <= 1'b0; ie_mtie <= 1'b0; ie_meie <= 1'b0;
            mtvec <= 32'd0; mscratch <= 32'd0; mepc <= 30'd0; mcause <= 32'd0; mtval <= 32'd0;
            mcycle <= 64'd0; minstret <= 64'd0;
        end else begin
            mcycle   <= mcycle + 64'd1;
            if (commit_valid) minstret <= minstret + 64'd1;
            if (w_trap) begin
                mepc    <= w_pc[31:2];
                mcause  <= trap_cause;
                mtval   <= trap_tval;
                st_mpie <= st_mie;
                st_mie  <= 1'b0;
            end else if (w_valid && w_sys == S_MRET) begin
                st_mie  <= st_mpie;
                st_mpie <= 1'b1;
            end else if (csr_we) begin
                // 写优先于计数器自增
                case (w_csr_a)
                    12'h300: begin st_mie <= csr_new[3]; st_mpie <= csr_new[7]; end
                    12'h304: begin ie_msie <= csr_new[3]; ie_mtie <= csr_new[7]; ie_meie <= csr_new[11]; end
                    12'h305: mtvec    <= {csr_new[31:2], 1'b0, csr_new[0]};
                    12'h340: mscratch <= csr_new;
                    12'h341: mepc     <= csr_new[31:2];
                    12'h342: mcause   <= csr_new;
                    12'h343: mtval    <= csr_new;
                    12'hB00: mcycle[31:0]    <= csr_new;
                    12'hB80: mcycle[63:32]   <= csr_new;
                    12'hB02: minstret[31:0]  <= csr_new;
                    12'hB82: minstret[63:32] <= csr_new;
                    default: ;
                endcase
            end
        end
    end

    wire unused_ok = &{1'b0, unused_strb, unused_wd, unused_ld, m_misalign_unused, d_is_system, w_funct3[2]};
endmodule
