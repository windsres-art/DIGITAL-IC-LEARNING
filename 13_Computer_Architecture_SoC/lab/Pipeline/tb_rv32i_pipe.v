// =============================================================================
// 五级流水线 testbench（自检查）
//   +prog=../RV32I/build/x   程序与 ISS 轨迹（先在 ../RV32I 跑 run_sim.sh 或由本目录 run_sim.sh 生成）
//   +exp_cycles=N            可选：ISS 时序模型预测的周期数，给出时要求实测完全相等
//   检查：
//     1 lockstep：WB 级每条提交与 ISS 逐条比对（PC、写回、存储）
//     2 tohost == 1
//     3 周期恒等式：cycles = instret + 4（填充）+ stalls + 2 × redirects
//       —— 每个气泡都能归因到一次停顿或一次冲刷，没有"来历不明"的空拍
//     4 与 ISS 时序模型的预测一致（BP = 0 / 1）
// =============================================================================
`timescale 1ns / 1ps

module tb_rv32i_pipe;
    parameter FWD = 1;
    parameter BP  = 0;
    localparam MEMW     = 4096;
    localparam MAXN     = 65536;
    localparam [31:0] DBASE = 32'h1000_0000;
    localparam TIMEOUT  = 400000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [31:0] imem [0:MEMW-1];
    reg [31:0] dmem [0:MEMW-1];
    reg [31:0] exp_t [0:5*MAXN-1];

    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_re, halted, trap;
    wire        c_valid, c_rd_we, perf_stall, perf_redirect;
    wire [4:0]  c_rd;
    wire [31:0] c_pc, c_insn, c_wdata, c_st_addr, c_st_data;
    wire [3:0]  c_wstrb;

    wire [31:0] imem_rdata = imem[imem_addr[13:2]];
    wire [31:0] dmem_rdata = dmem[dmem_addr[13:2]];

    rv32i_pipe #(.FWD(FWD), .BP(BP)) u_core (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_wstrb(dmem_wstrb),
        .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
        .halted(halted), .trap(trap),
        .commit_valid(c_valid), .commit_pc(c_pc), .commit_insn(c_insn),
        .commit_rd_we(c_rd_we), .commit_rd(c_rd), .commit_rd_wdata(c_wdata),
        .commit_wstrb(c_wstrb), .commit_st_addr(c_st_addr), .commit_st_data(c_st_data),
        .perf_stall(perf_stall), .perf_redirect(perf_redirect));

    integer errors = 0, ncommit = 0, ntrace = 0, cycles = 0, i, fd;
    integer n_stall = 0, n_redir = 0, n_br = 0, n_jal = 0, n_jalr = 0, exp_cycles = -1;
    reg [1023:0] prog, fname;
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

    // 性能事件
    always @(posedge clk) if (rst_n && !halted) begin
        if (perf_stall)    n_stall = n_stall + 1;
        if (perf_redirect) n_redir = n_redir + 1;
        if ((dmem_re || dmem_wstrb != 0) && (dmem_addr < DBASE || dmem_addr >= DBASE + 4*MEMW)) begin
            $display("ERROR: dmem 访问越界 addr=%08h", dmem_addr);
            errors = errors + 1;
        end
    end

    // lockstep 比对
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
        case (c_insn[6:0])
            7'b1100011: n_br   = n_br + 1;
            7'b1101111: n_jal  = n_jal + 1;
            7'b1100111: n_jalr = n_jalr + 1;
            default: ;
        endcase
        ncommit = ncommit + 1;
    end

    task open_hex(input [1023:0] suffix);
        begin
            $sformat(fname, "%0s%0s", prog, suffix);
            fd = $fopen(fname, "r");
            if (fd == 0) begin $display("ERROR: 打不开 %0s", fname); $finish; end
        end
    endtask

    integer fill;
    initial begin
        if (!$value$plusargs("prog=%s", prog)) begin
            $display("用法: vvp sim +prog=../RV32I/build/<程序名> [+exp_cycles=N]");
            $finish;
        end
        if (!$value$plusargs("exp_cycles=%d", exp_cycles)) exp_cycles = -1;
        for (i = 0; i < MEMW; i = i + 1) begin imem[i] = 32'h0; dmem[i] = 32'h0; end
        open_hex(".text.hex");  i = 0; while ($fscanf(fd, "%h\n", w) == 1) begin imem[i] = w; i = i + 1; end
        $fclose(fd);
        open_hex(".data.hex");  i = 0; while ($fscanf(fd, "%h\n", w) == 1) begin dmem[i] = w; i = i + 1; end
        $fclose(fd);
        open_hex(".trace.hex"); i = 0; while ($fscanf(fd, "%h\n", w) == 1) begin exp_t[i] = w; i = i + 1; end
        $fclose(fd);
        ntrace = i / 5;
        for (i = 0; i < 32; i = i + 1) u_core.u_rf.rf[i] = 32'h0;   // 与 ISS 的初值假设一致

        $dumpfile("rv32i_pipe.vcd");
        $dumpvars(0, tb_rv32i_pipe);

        #22 rst_n = 1;
        while (!halted && cycles < TIMEOUT) begin
            @(posedge clk);
            cycles = cycles + 1;
            #1;
        end
        @(negedge clk);

        if (cycles >= TIMEOUT) begin $display("ERROR: 超时"); errors = errors + 1; end
        if (trap)              begin $display("ERROR: trap"); errors = errors + 1; end
        if (ncommit != ntrace) begin
            $display("ERROR: 提交 %0d 条，ISS 轨迹 %0d 条", ncommit, ntrace);
            errors = errors + 1;
        end
        if (dmem[0] !== 32'd1) begin
            $display("ERROR: tohost = %0d（程序自检查失败，测试号 %0d）", dmem[0], dmem[0] >> 1);
            errors = errors + 1;
        end
        fill = cycles - ncommit - n_stall - 2 * n_redir;
        if (fill != 4) begin
            $display("ERROR: 周期恒等式不成立：cycles - instret - stalls - 2*redirects = %0d（应为 4）", fill);
            errors = errors + 1;
        end
        if (exp_cycles >= 0 && exp_cycles != cycles) begin
            $display("ERROR: 实测 %0d 周期，ISS 时序模型预测 %0d", cycles, exp_cycles);
            errors = errors + 1;
        end
        $display("FWD=%0d BP=%0d  instret=%0d cycles=%0d CPI=%0.3f  stalls=%0d redirects=%0d  ctrl(br/jal/jalr)=%0d/%0d/%0d%0s",
                 FWD, BP, ncommit, cycles, (cycles * 1.0) / ncommit, n_stall, n_redir,
                 n_br, n_jal, n_jalr, (exp_cycles >= 0) ? "  =model" : "");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
