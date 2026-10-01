// =============================================================================
// 最小 SoC：第 5 节的核 + 启动 ROM + RAM + CLINT + PLIC + DMA + APB 桥 + UART
//
//            ┌──────── 取指（ROM 的第二个读口）─────────────┐
//   rv32i_trap ── M0 ─┐                                       ▼
//   dma ───────── M1 ─┴─ soc_bus ─┬─ S0 ROM 16 KB（数据读口，写 → err）
//                                 ├─ S1 RAM 16 KB
//                                 ├─ S2 CLINT ──── irq_timer / irq_soft ──► 核
//                                 ├─ S3 PLIC  ◄─── 源 1 = DMA，源 2 = UART ── irq_ext ► 核
//                                 ├─ S4 apb_bridge ── APB ── uart_tx ── txd
//                                 ├─ S5 DMA 寄存器
//                                 └─ 默认从机（err）
//   ROM / RAM 是行为级数组（不复位、没有 initial），由 testbench 装入内容。
//   ROM 的前 8 KB 放代码，后 8 KB 放 .data 的初值，启动代码负责把它拷进 RAM。
// =============================================================================
module soc_top #(
    parameter UART_DIV = 16
)(
    input         clk,
    input         rst_n,
    output        uart_txd,
    // 观察口（testbench 用）
    output        commit_valid,
    output [31:0] commit_pc,
    output [31:0] commit_insn,
    output        commit_rd_we,
    output [4:0]  commit_rd,
    output [31:0] commit_rd_wdata,
    output [3:0]  commit_wstrb,
    output [31:0] commit_st_addr,
    output [31:0] commit_st_data,
    output        trap_valid,
    output [31:0] trap_cause,
    output [31:0] trap_epc,
    output [31:0] trap_tval,
    output [11:0] trap_mip,
    output        perf_cpu_blocked
);
    localparam NS = 6;

    /* verilator lint_off UNDRIVEN */
    reg [31:0] rom [0:4095];                    // 内容由 testbench 装入
    /* verilator lint_on UNDRIVEN */
    reg [31:0] ram [0:4095];

    // ---------------- 核 ----------------
    wire [31:0] imem_addr, c_addr, c_wdata, c_rdata;
    wire [3:0]  c_wstrb;
    wire        c_re, c_ready, c_err;
    wire        irq_ext, irq_timer, irq_soft;

    rv32i_trap u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_rdata(rom[imem_addr[13:2]]),
        .dmem_addr(c_addr), .dmem_re(c_re), .dmem_wstrb(c_wstrb), .dmem_wdata(c_wdata),
        .dmem_rdata(c_rdata), .dmem_ready(c_ready), .dmem_err(c_err),
        .irq_ext(irq_ext), .irq_timer(irq_timer), .irq_soft(irq_soft),
        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_we(commit_rd_we), .commit_rd(commit_rd), .commit_rd_wdata(commit_rd_wdata),
        .commit_wstrb(commit_wstrb), .commit_st_addr(commit_st_addr), .commit_st_data(commit_st_data),
        .trap_valid(trap_valid), .trap_cause(trap_cause), .trap_epc(trap_epc),
        .trap_tval(trap_tval), .trap_mip(trap_mip));

    // ---------------- DMA ----------------
    wire [31:0] d_addr, d_wdata, d_rdata, dma_rdata;
    wire [3:0]  d_wstrb;
    wire        d_re, d_ready, d_err, dma_irq;

    // ---------------- 互联 ----------------
    wire [NS-1:0]    s_sel, s_we, s_ready, s_err;
    wire [32*NS-1:0] s_addr, s_wdata, s_rdata;
    wire [4*NS-1:0]  s_wstrb;

    soc_bus #(.NS(NS)) u_bus (
        .clk(clk), .rst_n(rst_n),
        .m0_addr(c_addr), .m0_re(c_re), .m0_wstrb(c_wstrb), .m0_wdata(c_wdata),
        .m0_rdata(c_rdata), .m0_ready(c_ready), .m0_err(c_err),
        .m1_addr(d_addr), .m1_re(d_re), .m1_wstrb(d_wstrb), .m1_wdata(d_wdata),
        .m1_rdata(d_rdata), .m1_ready(d_ready), .m1_err(d_err),
        .s_sel(s_sel), .s_we(s_we), .s_addr(s_addr), .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_rdata(s_rdata), .s_ready(s_ready), .s_err(s_err),
        .perf_m0_blocked(perf_cpu_blocked));

    // S0 ROM：只读
    assign s_rdata[0 +: 32] = rom[s_addr[13:2]];
    assign s_ready[0] = 1'b1;
    assign s_err[0]   = s_we[0];

    // S1 RAM
    assign s_rdata[32 +: 32] = ram[s_addr[32+13:32+2]];
    assign s_ready[1] = 1'b1;
    assign s_err[1]   = 1'b0;
    integer b;
    always @(posedge clk)
        if (s_sel[1])
            for (b = 0; b < 4; b = b + 1)
                if (s_wstrb[4+b]) ram[s_addr[32+13:32+2]][8*b +: 8] <= s_wdata[32+8*b +: 8];

    // S2 CLINT
    clint u_clint (.clk(clk), .rst_n(rst_n), .req(s_sel[2]), .we(s_we[2]),
                   .addr(s_addr[64 +: 16]), .wdata(s_wdata[64 +: 32]), .rdata(s_rdata[64 +: 32]),
                   .irq_timer(irq_timer), .irq_soft(irq_soft));
    assign s_ready[2] = 1'b1;
    assign s_err[2]   = 1'b0;

    // S3 PLIC：源 1 = DMA，源 2 = UART
    wire uart_irq;
    plic #(.NSRC(4)) u_plic (.clk(clk), .rst_n(rst_n), .req(s_sel[3]), .we(s_we[3]),
                   .addr(s_addr[96 +: 22]), .wdata(s_wdata[96 +: 32]), .rdata(s_rdata[96 +: 32]),
                   .src({1'b0, uart_irq, dma_irq, 1'b0}), .irq(irq_ext));
    assign s_ready[3] = 1'b1;
    assign s_err[3]   = 1'b0;

    // S4 APB 桥 + UART
    wire        psel, penable, pwrite, pready, pslverr;
    wire [31:0] paddr, pwdata, prdata;
    wire [3:0]  pstrb;
    apb_bridge u_apb (.clk(clk), .rst_n(rst_n), .sel(s_sel[4]), .we(s_we[4]),
                      .addr(s_addr[128 +: 32]), .wdata(s_wdata[128 +: 32]), .wstrb(s_wstrb[16 +: 4]),
                      .rdata(s_rdata[128 +: 32]), .ready(s_ready[4]), .err(s_err[4]),
                      .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
                      .pwdata(pwdata), .pstrb(pstrb), .prdata(prdata), .pready(pready), .pslverr(pslverr));
    uart_tx #(.DIV_RST(UART_DIV)) u_uart (
        .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .pstrb(pstrb), .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .txd(uart_txd), .irq(uart_irq));

    // S5 DMA 寄存器
    dma u_dma (.clk(clk), .rst_n(rst_n), .req(s_sel[5]), .we(s_we[5]), .addr(s_addr[160 +: 5]),
               .wdata(s_wdata[160 +: 32]), .rdata(dma_rdata),
               .m_addr(d_addr), .m_re(d_re), .m_wstrb(d_wstrb), .m_wdata(d_wdata), .m_rdata(d_rdata),
               .m_ready(d_ready), .m_err(d_err), .irq(dma_irq));
    assign s_rdata[160 +: 32] = dma_rdata;
    assign s_ready[5] = 1'b1;
    assign s_err[5]   = 1'b0;

    wire unused_ok = &{1'b0, s_addr[31:14], s_addr[63:46], s_addr[95:80], s_addr[127:118],
                       s_addr[191:165], s_wstrb[3:0], s_wstrb[11:8], s_wstrb[15:12], s_wstrb[23:20],
                       s_wdata[31:0], s_we[1], s_sel[0], imem_addr[31:14], imem_addr[1:0], s_addr[1:0],
                       s_addr[33:32]};
endmodule
