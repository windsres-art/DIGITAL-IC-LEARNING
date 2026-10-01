// =============================================================================
// trap 核 testbench
//   +prog=build/x   +log=build/x.log   [+ws=1 每次访存随机插 0–3 个等待周期]
//   地址映射：
//     0x0000_0000  指令存储器 16 KB（组合读）
//     0x1000_0000  数据存储器 16 KB；第一个字是 tohost（1 = 程序自检查通过）
//     0x0200_0000  CLINT              0x0C00_0000  PLIC（7 个源）
//     0x3000_0000  测试设备：+0 写 {延迟[31:16], 源掩码[7:0]}，延迟若干周期后把这些源拉高（电平）
//                            +4 写 源掩码，把这些源拉低（相当于外设的"清中断"寄存器）
//                            +8 读 当前各源电平
//     其它地址：总线返回 err（访问错误异常）
//   检查：
//     1 日志交给 trap_iss.py 逐条复核（每条退休、每次 trap）
//     2 tohost == 1（程序自己检查 mcause / mepc / 中断次数 / 顺序等）
// =============================================================================
`timescale 1ns / 1ps

module tb_trap;
    localparam MEMW = 4096, TIMEOUT = 300000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [31:0] imem [0:MEMW-1];
    reg [31:0] dmem [0:MEMW-1];

    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_re;
    wire        irq_ext, irq_timer, irq_soft;
    wire        c_valid, c_rd_we, t_valid;
    wire [4:0]  c_rd;
    wire [31:0] c_pc, c_insn, c_wdata, c_st_addr, c_st_data, t_cause, t_epc, t_tval;
    wire [3:0]  c_wstrb;
    wire [11:0] t_mip;
    reg  [31:0] dmem_rdata;
    reg         dmem_err;
    wire        dmem_ready;

    rv32i_trap u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_rdata(imem[imem_addr[13:2]]),
        .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_wstrb(dmem_wstrb), .dmem_wdata(dmem_wdata),
        .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready), .dmem_err(dmem_err),
        .irq_ext(irq_ext), .irq_timer(irq_timer), .irq_soft(irq_soft),
        .commit_valid(c_valid), .commit_pc(c_pc), .commit_insn(c_insn), .commit_rd_we(c_rd_we),
        .commit_rd(c_rd), .commit_rd_wdata(c_wdata), .commit_wstrb(c_wstrb),
        .commit_st_addr(c_st_addr), .commit_st_data(c_st_data),
        .trap_valid(t_valid), .trap_cause(t_cause), .trap_epc(t_epc), .trap_tval(t_tval), .trap_mip(t_mip));

    // ---------------- 等待周期 ----------------
    wire       req = dmem_re | (|dmem_wstrb);
    wire       we  = |dmem_wstrb;
    integer    ws_en = 0, wcnt = 0, wneed = 0;
    assign dmem_ready = req && (wcnt >= wneed);
    always @(posedge clk) if (rst_n) begin
        if (dmem_ready) begin
            wcnt  <= 0;
            wneed <= ws_en ? $urandom % 4 : 0;
        end else if (req) wcnt <= wcnt + 1;
    end

    // ---------------- 地址译码 ----------------
    wire sel_ram   = dmem_addr[31:14] == 18'h04000;            // 0x1000_0000 – 0x1000_3FFF
    wire sel_clint = dmem_addr[31:16] == 16'h0200;
    wire sel_plic  = dmem_addr[31:22] == 10'h030;             // 0x0C00_0000 – 0x0C3F_FFFF
    wire sel_dev   = dmem_addr[31:8]  == 24'h300000;
    wire [31:0] clint_rdata, plic_rdata;
    reg  [7:0]  dev_src = 8'd0;

    clint u_clint (.clk(clk), .rst_n(rst_n), .req(dmem_ready & sel_clint), .we(we),
                   .addr(dmem_addr[15:0]), .wdata(dmem_wdata), .rdata(clint_rdata),
                   .irq_timer(irq_timer), .irq_soft(irq_soft));
    plic #(.NSRC(8)) u_plic (.clk(clk), .rst_n(rst_n), .req(dmem_ready & sel_plic), .we(we),
                   .addr(dmem_addr[21:0]), .wdata(dmem_wdata), .rdata(plic_rdata),
                   .src(dev_src), .irq(irq_ext));

    always @* begin
        dmem_err   = !(sel_ram | sel_clint | sel_plic | sel_dev);
        dmem_rdata = sel_ram   ? dmem[dmem_addr[13:2]] :
                     sel_clint ? clint_rdata :
                     sel_plic  ? plic_rdata :
                     sel_dev && dmem_addr[3:0] == 4'h8 ? {24'd0, dev_src} : 32'hDEAD_BEEF;
    end

    // 测试设备：最多同时排队一个"延迟拉高"
    integer    raise_t = -1, cyc = 0;
    reg [7:0]  raise_m = 8'd0;
    integer    i;
    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (raise_t >= 0 && cyc >= raise_t) begin dev_src <= dev_src | raise_m; raise_t = -1; end
        if (dmem_ready && !dmem_err) begin
            if (sel_ram)
                for (i = 0; i < 4; i = i + 1)
                    if (dmem_wstrb[i]) dmem[dmem_addr[13:2]][8*i +: 8] <= dmem_wdata[8*i +: 8];
            if (sel_dev && we && dmem_addr[3:0] == 4'h0) begin
                raise_m = dmem_wdata[7:0];
                raise_t = cyc + dmem_wdata[31:16];
            end
            if (sel_dev && we && dmem_addr[3:0] == 4'h4) dev_src <= dev_src & ~dmem_wdata[7:0];
        end
    end

    // ---------------- 日志与结束条件 ----------------
    integer fd = 0, ncommit = 0, ntrap = 0, done = 0, errors = 0;
    integer en_t [0:11];
    integer lat, lat_min = 1 << 30, lat_max = 0, lat_sum = 0, lat_n = 0, q;
    reg [1023:0] prog, logf, fname;
    reg [31:0]   w;
    always @(posedge clk) if (rst_n) begin
        if (c_valid) begin
            $fdisplay(fd, "C %08h %08h %0d %0d %08h %h %08h %08h", c_pc, c_insn, c_rd_we, c_rd,
                      c_wdata, c_wstrb, c_st_addr, c_st_data);
            ncommit = ncommit + 1;
            if (c_wstrb != 4'd0 && c_st_addr == 32'h1000_0000) done = 1;
        end
        if (t_valid) begin
            $fdisplay(fd, "T %08h %08h %08h %03h", t_cause, t_epc, t_tval, t_mip);
            ntrap = ntrap + 1;
            // 中断延迟：从中断线变高（且 MIE、mie 都已允许）到 trap 在 WB 生效
            if (t_cause[31] && en_t[t_cause[3:0]] >= 0) begin
                lat = cyc - en_t[t_cause[3:0]];
                if (lat < lat_min) lat_min = lat;
                if (lat > lat_max) lat_max = lat;
                lat_sum = lat_sum + lat; lat_n = lat_n + 1;
                en_t[t_cause[3:0]] = -1;
            end
        end
    end

    // 记录每种中断"变得可以被响应"的时刻
    wire [11:0] can = {irq_ext, 3'b0, irq_timer, 3'b0, irq_soft, 3'b0} &
                      {u_core.ie_meie, 3'b0, u_core.ie_mtie, 3'b0, u_core.ie_msie, 3'b0} &
                      {12{u_core.st_mie}};
    reg  [11:0] can_q = 12'd0;
    initial for (q = 0; q < 12; q = q + 1) en_t[q] = -1;
    always @(posedge clk) if (rst_n) begin
        for (q = 0; q < 12; q = q + 1) begin
            if (can[q] && !can_q[q] && en_t[q] < 0) en_t[q] = cyc;
            if (!can[q]) en_t[q] = -1;
        end
        can_q <= can;
    end

    task load_hex(input [1023:0] suffix, input is_text);
        integer f, n;
        begin
            $sformat(fname, "%0s%0s", prog, suffix);
            f = $fopen(fname, "r");
            if (f == 0) begin $display("ERROR: 打不开 %0s", fname); $finish; end
            n = 0;
            while ($fscanf(f, "%h\n", w) == 1) begin
                if (is_text) imem[n] = w; else dmem[n] = w;
                n = n + 1;
            end
            $fclose(f);
        end
    endtask

    initial begin
        if (!$value$plusargs("prog=%s", prog) || !$value$plusargs("log=%s", logf)) begin
            $display("用法: vvp sim +prog=build/<程序> +log=build/<程序>.log [+ws=1]");
            $finish;
        end
        if (!$value$plusargs("ws=%d", ws_en)) ws_en = 0;
        for (i = 0; i < MEMW; i = i + 1) begin imem[i] = 32'h0; dmem[i] = 32'h0; end
        load_hex(".text.hex", 1);
        load_hex(".data.hex", 0);
        for (i = 0; i < 32; i = i + 1) u_core.u_rf.rf[i] = 32'h0;
        fd = $fopen(logf, "w");
        $dumpfile("trap.vcd");
        $dumpvars(1, u_core);

        #22 rst_n = 1;
        while (!done && cyc < TIMEOUT) @(posedge clk);
        repeat (2) @(posedge clk);
        $fclose(fd);
        if (!done) begin $display("ERROR: 超时（%0d 周期）", cyc); errors = errors + 1; end
        if (dmem[0] !== 32'd1) begin
            $display("ERROR: tohost = %0d（程序自检查失败，测试号 %0d）", dmem[0], dmem[0] >> 1);
            errors = errors + 1;
        end
        $display("ws=%0d  cycles=%0d  instret=%0d  traps=%0d", ws_en, cyc, ncommit, ntrap);
        if (lat_n > 0)
            $display("irq latency (可响应 → trap 生效): n=%0d  min=%0d  avg=%0.1f  max=%0d 周期",
                     lat_n, lat_min, 1.0 * lat_sum / lat_n, lat_max);
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
