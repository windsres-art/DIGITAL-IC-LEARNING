// =============================================================================
// SoC testbench
//   +prog=build/hello  +log=build/hello.log  +expect=programs/hello.expect  [+seed=N]
//   装载：.text → ROM 字 0 起；.data 初值 → ROM 字节 0x2000 起（crt0 负责拷到 RAM）
//   上电状态：RAM 和通用寄存器都是随机值（真实芯片的 SRAM / 寄存器堆没有复位）
//   检查：
//     1 UART 监视器：从 txd 上按 8N1 解码（起始位中点对齐、每比特中点采样、停止位必须为 1），
//       逐字符与 expect 文件比对
//     2 tohost == 1（程序自检查：DMA 数据、COUNT、异常 cause、定时器次数……）
//     3 日志（R / C / T / D 行）交给 ../Trap/trap_iss.py --map soc 逐条复核
//     4 仲裁公平性：任何主机被另一个主机连续挡住不超过 1 拍
//   统计：CPU 因 DMA 占用同一从机而等待的周期、UART 反压（PREADY=0）的周期
// =============================================================================
`timescale 1ns / 1ps

module tb_soc;
    localparam TIMEOUT = 200000, ROM_DATA_W = 32'h800;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire        txd, c_valid, c_rd_we, t_valid, blocked;
    wire [4:0]  c_rd;
    wire [31:0] c_pc, c_insn, c_wdata, c_st_addr, c_st_data, t_cause, t_epc, t_tval;
    wire [3:0]  c_wstrb;
    wire [11:0] t_mip;

    soc_top #(.UART_DIV(16)) u_soc (
        .clk(clk), .rst_n(rst_n), .uart_txd(txd),
        .commit_valid(c_valid), .commit_pc(c_pc), .commit_insn(c_insn), .commit_rd_we(c_rd_we),
        .commit_rd(c_rd), .commit_rd_wdata(c_wdata), .commit_wstrb(c_wstrb),
        .commit_st_addr(c_st_addr), .commit_st_data(c_st_data),
        .trap_valid(t_valid), .trap_cause(t_cause), .trap_epc(t_epc), .trap_tval(t_tval),
        .trap_mip(t_mip), .perf_cpu_blocked(blocked));

    // ---------------- 日志、统计、结束条件 ----------------
    integer fd = 0, cyc = 0, ncommit = 0, ntrap = 0, ndma = 0, nblock = 0, nbp = 0, done = 0;
    integer run0 = 0, run1 = 0, max0 = 0, max1 = 0;
    wire dma_ram_wr = u_soc.d_ready && !u_soc.d_err && (|u_soc.d_wstrb) &&
                      u_soc.d_addr[31:14] == 18'h04000;
    // 本拍 DMA 想要的从机被授权给了 CPU
    wire dma_blocked = |(u_soc.u_bus.want1 & ~u_soc.u_bus.g1);
    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (blocked) nblock = nblock + 1;
        // 公平性：所有从机都是单拍完成，轮转仲裁下任何一方最多连续输 1 拍
        run0 = blocked     ? run0 + 1 : 0;
        run1 = dma_blocked ? run1 + 1 : 0;
        if (run0 > max0) max0 = run0;
        if (run1 > max1) max1 = run1;
        if (u_soc.psel && u_soc.penable && !u_soc.pready) nbp = nbp + 1;
        // 同一拍里先写退休 / trap，再写 DMA：WB 的指令在上一拍就已经访问过存储器
        if (c_valid) begin
            $fdisplay(fd, "C %08h %08h %0d %0d %08h %h %08h %08h", c_pc, c_insn, c_rd_we, c_rd,
                      c_wdata, c_wstrb, c_st_addr, c_st_data);
            ncommit = ncommit + 1;
            if (c_wstrb != 4'd0 && c_st_addr == 32'h1000_0000 && c_st_data != 32'd0) done = 1;
        end
        if (t_valid) begin
            $fdisplay(fd, "T %08h %08h %08h %03h", t_cause, t_epc, t_tval, t_mip);
            ntrap = ntrap + 1;
        end
        if (dma_ram_wr) begin
            $fdisplay(fd, "D %08h %08h", u_soc.d_addr, u_soc.d_wdata);
            ndma = ndma + 1;
        end
    end

    // ---------------- UART 监视器 ----------------
    reg  [7:0] exp_c [0:255];
    integer    nexp = 0, nrx = 0, uerr = 0, k, div;
    reg  [7:0] ch;
    reg  [8*256-1:0] rx_str;
    initial begin
        rx_str = 0;
        @(posedge rst_n);
        forever begin
            @(negedge txd);
            div = u_soc.u_uart.div;
            repeat (div / 2) @(posedge clk);
            if (txd !== 1'b0) begin
                $display("ERROR: UART 起始位毛刺（周期 %0d）", cyc); uerr = uerr + 1;
            end else begin
                for (k = 0; k < 8; k = k + 1) begin
                    repeat (div) @(posedge clk);
                    ch[k] = txd;                            // 低位先发
                end
                repeat (div) @(posedge clk);
                if (txd !== 1'b1) begin
                    $display("ERROR: UART 停止位不是 1（字符 %0d）", nrx); uerr = uerr + 1;
                end
                if (nrx >= nexp || ch !== exp_c[nrx]) begin
                    $display("ERROR: UART 第 %0d 个字符 = %h，期望 %h", nrx, ch,
                             nrx < nexp ? exp_c[nrx] : 8'h00);
                    uerr = uerr + 1;
                end
                rx_str = {rx_str[8*255-1:0], ch};
                nrx = nrx + 1;
            end
        end
    end

    // ---------------- 装载与主流程 ----------------
    reg [1023:0] prog, logf, expf, fname;
    reg [31:0]   w;
    integer      i, f, n, c, seed, errors = 0;

    task load_hex(input [1023:0] suffix, input integer base, input integer maxw);
        begin
            $sformat(fname, "%0s%0s", prog, suffix);
            f = $fopen(fname, "r");
            if (f == 0) begin $display("ERROR: 打不开 %0s", fname); $finish; end
            n = 0;
            while ($fscanf(f, "%h\n", w) == 1) begin
                if (n >= maxw) begin $display("ERROR: %0s 超出 ROM 分区", fname); $finish; end
                u_soc.rom[base + n] = w;
                n = n + 1;
            end
            $fclose(f);
        end
    endtask

    initial begin
        if (!$value$plusargs("prog=%s", prog) || !$value$plusargs("log=%s", logf) ||
            !$value$plusargs("expect=%s", expf)) begin
            $display("用法: vvp sim +prog=build/hello +log=build/hello.log +expect=programs/hello.expect");
            $finish;
        end
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        for (i = 0; i < 4096; i = i + 1) begin
            u_soc.rom[i] = 32'h0;
            u_soc.ram[i] = $random(seed);
        end
        load_hex(".text.hex", 0, ROM_DATA_W);
        load_hex(".data.hex", ROM_DATA_W, 4096 - ROM_DATA_W);
        u_soc.u_core.u_rf.rf[0] = 32'h0;
        for (i = 1; i < 32; i = i + 1) u_soc.u_core.u_rf.rf[i] = $random(seed);
        $display("上电 RAM[0] = %08h，x1 = %08h", u_soc.ram[0], u_soc.u_core.u_rf.rf[1]);
        f = $fopen(expf, "r");
        if (f == 0) begin $display("ERROR: 打不开 %0s", expf); $finish; end
        c = $fgetc(f);
        while (c >= 0 && nexp < 256) begin
            if (c != 13) begin exp_c[nexp] = c[7:0]; nexp = nexp + 1; end
            c = $fgetc(f);
        end
        $fclose(f);
        fd = $fopen(logf, "w");
        // 寄存器堆上电值也写进日志：保存现场时把"还没写过的寄存器"存进栈是合法的
        $fwrite(fd, "R");
        for (i = 1; i < 32; i = i + 1) $fwrite(fd, " %08h", u_soc.u_core.u_rf.rf[i]);
        $fwrite(fd, "\n");
        $dumpfile("soc.vcd");
        $dumpvars(1, u_soc);

        #22 rst_n = 1;
        while (!done && cyc < TIMEOUT) @(posedge clk);
        repeat (2) @(posedge clk);
        $fclose(fd);
        if (!done) begin $display("ERROR: 超时（%0d 周期）", cyc); errors = errors + 1; end
        if (u_soc.ram[0] !== 32'd1) begin
            $display("ERROR: tohost = %0d（程序自检查失败，测试号 %0d）", u_soc.ram[0], u_soc.ram[0] >> 1);
            errors = errors + 1;
        end
        if (nrx != nexp) begin
            $display("ERROR: UART 收到 %0d 个字符，期望 %0d 个", nrx, nexp); errors = errors + 1;
        end
        errors = errors + uerr;
        if (max0 > 1 || max1 > 1) begin
            $display("ERROR: 仲裁不公平：CPU 最长连续被挡 %0d 拍，DMA %0d 拍（应 ≤ 1）", max0, max1);
            errors = errors + 1;
        end
        $display("UART 收到：");
        for (i = nrx - 1; i >= 0; i = i - 1) $write("%c", rx_str[8*i +: 8]);
        $display("cycles=%0d  instret=%0d  traps=%0d  dma_words=%0d", cyc, ncommit, ntrap, ndma);
        $display("CPU 因 DMA 占用同一从机而等待 %0d 周期（最长连续 %0d），DMA 被 CPU 挡最长连续 %0d 拍",
                 nblock, max0, max1);
        $display("UART 反压（PREADY=0）%0d 周期", nbp);
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
