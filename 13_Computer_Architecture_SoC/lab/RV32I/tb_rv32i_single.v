// =============================================================================
// 单周期核 testbench（自检查）
//   +prog=build/x   读 x.text.hex / x.data.hex / x.trace.hex（由 rv32_asm.py 和 rv32_iss.py 生成）
//   两层检查：
//     1 lockstep：每条提交的指令与 ISS 轨迹逐条比对 PC、写回寄存器与数值、存储地址 / 字节使能 / 数据
//     2 程序自检查：结束时数据存储器第一个字 tohost 必须为 1
//   另外检查：提交条数与轨迹长度一致、访存不越界、没有 trap、不超时。
// =============================================================================
`timescale 1ns / 1ps

module tb_rv32i_single;
    localparam MEMW     = 4096;                     // 16 KB
    localparam MAXN     = 65536;                    // 轨迹最多条数
    localparam [31:0] DBASE = 32'h1000_0000;
    localparam TIMEOUT  = 200000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [31:0] imem [0:MEMW-1];
    reg [31:0] dmem [0:MEMW-1];
    reg [31:0] exp_t [0:5*MAXN-1];

    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_re, halted, trap;
    wire        c_valid, c_rd_we;
    wire [4:0]  c_rd;
    wire [31:0] c_pc, c_insn, c_wdata, c_st_addr, c_st_data;
    wire [3:0]  c_wstrb;

    // 地址只取用得到的位；越界由下面的检查报错
    wire [31:0] imem_rdata = imem[imem_addr[13:2]];
    wire [31:0] dmem_rdata = dmem[dmem_addr[13:2]];

    rv32i_single u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_wstrb(dmem_wstrb),
        .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
        .halted(halted), .trap(trap),
        .commit_valid(c_valid), .commit_pc(c_pc), .commit_insn(c_insn),
        .commit_rd_we(c_rd_we), .commit_rd(c_rd), .commit_rd_wdata(c_wdata),
        .commit_wstrb(c_wstrb), .commit_st_addr(c_st_addr), .commit_st_data(c_st_data));

    integer errors = 0, ncommit = 0, ntrace = 0, cycles = 0, i, fd, r;
    reg [1023:0] prog;
    reg [31:0] e_pc, e_flags, e_wd, e_sa, e_sd, lane_mask, w;

    always @(posedge clk) if (rst_n) begin
        for (i = 0; i < 4; i = i + 1)
            if (dmem_wstrb[i]) dmem[dmem_addr[13:2]][8*i +: 8] <= dmem_wdata[8*i +: 8];
    end

    function [31:0] strb_mask(input [3:0] s);
        strb_mask = {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}};
    endfunction

    task err(input [8*32-1:0] what);
        begin
            if (errors < 10)
                $display("ERROR #%0d pc=%08h: %0s  got(rd_we=%b rd=%0d wd=%08h strb=%b sa=%08h sd=%08h) exp(pc=%08h flags=%08h wd=%08h sa=%08h sd=%08h)",
                         ncommit, c_pc, what, c_rd_we, c_rd, c_wdata, c_wstrb, c_st_addr, c_st_data,
                         e_pc, e_flags, e_wd, e_sa, e_sd);
            errors = errors + 1;
        end
    endtask

    // ---------------- 访存越界 ----------------
    always @(posedge clk) if (rst_n && !halted) begin
        if ((dmem_re || dmem_wstrb != 0) && (dmem_addr < DBASE || dmem_addr >= DBASE + 4*MEMW)) begin
            $display("ERROR: dmem 访问越界 addr=%08h pc=%08h", dmem_addr, c_pc);
            errors = errors + 1;
        end
        if (imem_addr >= 4*MEMW) begin
            $display("ERROR: 取指越界 pc=%08h", imem_addr);
            errors = errors + 1;
        end
    end

    // ---------------- lockstep 比对 ----------------
    always @(posedge clk) if (rst_n && c_valid) begin
        if (ncommit >= ntrace) begin
            e_pc = 0; e_flags = 0; e_wd = 0; e_sa = 0; e_sd = 0;
            err("more commits than ISS trace");
        end else begin
            e_pc    = exp_t[5*ncommit];
            e_flags = exp_t[5*ncommit+1];
            e_wd    = exp_t[5*ncommit+2];
            e_sa    = exp_t[5*ncommit+3];
            e_sd    = exp_t[5*ncommit+4];
            lane_mask = strb_mask(e_flags[11:8]);
            if (c_pc !== e_pc)                                   err("pc mismatch");
            else if (c_rd_we !== e_flags[5])                     err("rd_we mismatch");
            else if (c_rd_we && (c_rd !== e_flags[4:0] || c_wdata !== e_wd))
                                                                 err("rd / wdata mismatch");
            else if (c_wstrb !== e_flags[11:8])                  err("store strobe mismatch");
            else if (c_wstrb != 0 && (c_st_addr !== e_sa || (c_st_data & lane_mask) !== (e_sd & lane_mask)))
                                                                 err("store addr / data mismatch");
        end
        ncommit = ncommit + 1;
    end

    // 按行读十六进制文件（不用 $readmemh：文件比数组短时 Icarus 会告警）
    reg [1023:0] fname;
    task open_hex(input [1023:0] suffix);
        begin
            $sformat(fname, "%0s%0s", prog, suffix);    // 直接 {prog, suffix} 拼接，中间会夹着补位的 0 字节
            fd = $fopen(fname, "r");
            if (fd == 0) begin $display("ERROR: 打不开 %0s", fname); $finish; end
        end
    endtask

    initial begin
        if (!$value$plusargs("prog=%s", prog)) begin
            $display("用法: vvp sim +prog=build/<程序名>");
            $finish;
        end
        for (i = 0; i < MEMW; i = i + 1) begin imem[i] = 32'h0; dmem[i] = 32'h0; end
        open_hex(".text.hex");  i = 0; while ($fscanf(fd, "%h\n", w) == 1) begin imem[i] = w; i = i + 1; end
        $fclose(fd);
        open_hex(".data.hex");  i = 0; while ($fscanf(fd, "%h\n", w) == 1) begin dmem[i] = w; i = i + 1; end
        $fclose(fd);
        open_hex(".trace.hex"); i = 0; while ($fscanf(fd, "%h\n", w) == 1) begin exp_t[i] = w; i = i + 1; end
        $fclose(fd);
        ntrace = i / 5;
        // 寄存器堆没有复位（真实硬件上电是随机值）。ISS 假定初值为 0，这里对齐这个假设；
        // 否则 fib 里保存"从没写过的 s0/s1"会把 X 存进栈，和 ISS 的 0 对不上
        for (i = 0; i < 32; i = i + 1) u_core.u_rf.rf[i] = 32'h0;

        $dumpfile("rv32i_single.vcd");
        $dumpvars(0, tb_rv32i_single);

        #22 rst_n = 1;
        while (!halted && cycles < TIMEOUT) begin
            @(posedge clk);
            cycles = cycles + 1;
            #1;                             // 等非阻塞赋值生效后再看 halted
        end
        @(negedge clk);

        if (cycles >= TIMEOUT) begin $display("ERROR: 超时"); errors = errors + 1; end
        if (trap)              begin $display("ERROR: trap（非法指令或非对齐访存）pc=%08h", c_pc); errors = errors + 1; end
        if (ncommit != ntrace) begin
            $display("ERROR: 提交 %0d 条，ISS 轨迹 %0d 条", ncommit, ntrace);
            errors = errors + 1;
        end
        if (dmem[0] !== 32'd1) begin
            $display("ERROR: tohost = %0d（程序自检查失败，测试号 %0d）", dmem[0], dmem[0] >> 1);
            errors = errors + 1;
        end
        $display("%0s: instret=%0d cycles=%0d CPI=%0.3f tohost=%0d",
                 prog, ncommit, cycles, (cycles * 1.0) / ncommit, dmem[0]);
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
