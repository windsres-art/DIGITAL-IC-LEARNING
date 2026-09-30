// =============================================================================
// APB testbench（自检查）：apb_master → apb_regs
//   - 寄存器参考模型：每个上升沿先用模型算出期望的 prdata / pslverr 与总线比对，
//     再按本拍的写和 irq_set_i 更新模型（W1C 置位优先与 RTL 规则一致）
//   - 命令记录：命令口握手时入队，总线传输完成时比对地址/方向/数据/strobe（主机没改命令）
//   - 响应记录：总线传输完成时入队，rsp_valid 时比对（主机把结果正确带回）
//   - 协议检查：SETUP 固定 1 拍、SETUP→ACCESS 及等待期间信号不变、
//     完成后 PENABLE 必须拉低、读传输 PSTRB = 0
//   阶段：P0 定向（复位值、只读写、未映射、W1C） P1 随机 P2 背靠背测吞吐
//   WAIT 参数由 run_sim.sh 用 -P 覆盖
// =============================================================================
`timescale 1ns / 1ps

module tb_apb;
    parameter WAIT = 0;
    parameter AW   = 12;
    localparam NRAND = 4000;
    localparam NB2B  = 1000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg           cmd_valid = 0, cmd_write = 0;
    reg  [AW-1:0] cmd_addr  = 0;
    reg  [31:0]   cmd_wdata = 0;
    reg  [3:0]    cmd_wstrb = 0;
    wire          cmd_ready, rsp_valid, rsp_err;
    wire [31:0]   rsp_rdata;

    wire [AW-1:0] paddr;
    wire          psel, penable, pwrite, pready, pslverr;
    wire [31:0]   pwdata, prdata;
    wire [3:0]    pstrb;

    reg  [31:0]   status_i = 0, irq_set_i = 0;
    wire [31:0]   ctrl_o;
    wire          irq_o;

    apb_master #(.AW(AW), .DW(32)) u_mst (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_write(cmd_write),
        .cmd_addr(cmd_addr), .cmd_wdata(cmd_wdata), .cmd_wstrb(cmd_wstrb),
        .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .rsp_err(rsp_err),
        .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
        .pwdata(pwdata), .pstrb(pstrb), .pready(pready), .prdata(prdata), .pslverr(pslverr));

    apb_regs #(.AW(AW), .WAIT(WAIT)) u_slv (
        .pclk(clk), .presetn(rst_n),
        .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
        .pwdata(pwdata), .pstrb(pstrb), .pready(pready), .prdata(prdata), .pslverr(pslverr),
        .ctrl_o(ctrl_o), .status_i(status_i), .irq_set_i(irq_set_i), .irq_o(irq_o));

    integer errors = 0;
    task err(input [8*64-1:0] msg);
        begin
            if (errors < 10) $display("ERROR @%0t: %0s", $time, msg);
            errors = errors + 1;
        end
    endtask

    // ---------------- 参考模型 ----------------
    reg [31:0] m_ctrl = 0, m_scr = 0, m_int = 0, m_en = 0;
    reg [31:0] exp_rd, bm, w1c;
    reg        exp_err, hit;
    integer    n_rd = 0, n_wr = 0, n_err_unmap = 0, n_err_ro = 0;
    integer    n_w1c = 0, n_collide = 0, n_partial = 0, n_wait = 0, n_irq = 0, n_psel = 0;

    wire xfer = psel & penable & pready;

    function [31:0] merge(input [31:0] o, input [31:0] n, input [31:0] m);
        merge = (o & ~m) | (n & m);
    endfunction

    // 命令记录与响应记录（环形数组）
    reg [AW+32+4:0] cq [0:255];
    reg [32:0]      rq [0:255];
    integer cq_w = 0, cq_r = 0, rq_w = 0, rq_r = 0;

    always @(posedge clk) if (rst_n) begin
        // 硬件侧输出
        if (ctrl_o !== m_ctrl)             err("ctrl_o mismatch");
        if (irq_o !== |(m_int & m_en))     err("irq_o mismatch");
        if (irq_o) n_irq = n_irq + 1;
        if (psel & penable & ~pready) n_wait = n_wait + 1;
        if (psel) n_psel = n_psel + 1;

        if (cmd_valid & cmd_ready) begin
            cq[cq_w[7:0]] = {cmd_write, cmd_addr, cmd_wdata, (cmd_write ? cmd_wstrb : 4'h0)};
            cq_w = cq_w + 1;
        end

        w1c = 32'h0;
        if (xfer) begin
            // 1) 总线上的命令必须就是命令口收到的那一条
            if (cq_r == cq_w)                                   err("bus xfer without cmd");
            else begin
                if (cq[cq_r[7:0]] !== {pwrite, paddr, pwdata, (pwrite ? pstrb : 4'h0)})
                    err("bus xfer != issued cmd");
                cq_r = cq_r + 1;
            end
            // 2) 模型算期望
            hit = 1'b1;
            case (paddr[AW-1:2])
                0: exp_rd = m_ctrl;
                1: exp_rd = m_scr;
                2: exp_rd = status_i;
                3: exp_rd = m_int;
                4: exp_rd = m_en;
                default: begin exp_rd = 0; hit = 1'b0; end
            endcase
            exp_err = !hit || (pwrite && paddr[AW-1:2] == 2);
            if (!hit) n_err_unmap = n_err_unmap + 1;
            else if (exp_err) n_err_ro = n_err_ro + 1;
            if (pslverr !== exp_err)                  err("pslverr mismatch");
            if (!pwrite && prdata !== exp_rd)         err("prdata mismatch");
            rq[rq_w[7:0]] = {exp_err, pwrite ? 32'h0 : exp_rd};
            rq_w = rq_w + 1;
            // 3) 更新模型
            bm = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};
            if (pwrite) begin
                n_wr = n_wr + 1;
                if (pstrb != 4'h0 && pstrb != 4'hF) n_partial = n_partial + 1;
                case (paddr[AW-1:2])
                    0: m_ctrl = merge(m_ctrl, pwdata, bm);
                    1: m_scr  = merge(m_scr,  pwdata, bm);
                    3: w1c    = pwdata & bm;
                    4: m_en   = merge(m_en,   pwdata, bm);
                    default: ;
                endcase
            end else n_rd = n_rd + 1;
        end
        if (|(w1c & m_int))     n_w1c     = n_w1c + 1;
        if (|(w1c & irq_set_i)) n_collide = n_collide + 1;
        m_int = (m_int & ~w1c) | irq_set_i;

        if (rsp_valid) begin
            if (rq_r == rq_w) err("rsp without xfer");
            else begin
                if ({rsp_err, rsp_rdata} !== rq[rq_r[7:0]]) err("rsp mismatch");
                rq_r = rq_r + 1;
            end
        end
    end

    // ---------------- 协议检查 ----------------
    reg          p_sel = 0, p_en = 0, p_rdy = 0, p_wr = 0;
    reg [AW-1:0] p_addr;
    reg [31:0]   p_wdata;
    reg [3:0]    p_strb;
    always @(posedge clk) if (rst_n) begin
        if (penable && !psel)                        err("PENABLE without PSEL");
        if (psel && !pwrite && pstrb != 4'h0)        err("PSTRB != 0 on read");
        if (p_sel && !p_en && !(psel && penable))    err("SETUP not followed by ACCESS");
        if (p_sel && (!p_en || !p_rdy) &&
            {paddr, pwrite, pwdata, pstrb} !== {p_addr, p_wr, p_wdata, p_strb})
                                                     err("addr/ctrl changed in SETUP/wait");
        if (p_sel && p_en && !p_rdy && !(psel && penable)) err("ACCESS dropped before PREADY");
        if (p_sel && p_en && p_rdy && penable)       err("PENABLE not dropped after xfer");
        p_sel = psel; p_en = penable; p_rdy = pready; p_wr = pwrite;
        p_addr = paddr; p_wdata = pwdata; p_strb = pstrb;
    end

    // ---------------- 激励 ----------------
    // 硬件侧：下降沿随机改 status 和稀疏的 irq 脉冲
    always @(negedge clk) begin
        irq_set_i <= $urandom & $urandom & $urandom & $urandom;
        if (($urandom % 8) == 0) status_i <= $urandom;
    end

    task issue(input w, input [AW-1:0] a, input [31:0] d, input [3:0] s);
        begin
            @(negedge clk);
            cmd_valid <= 1'b1; cmd_write <= w; cmd_addr <= a; cmd_wdata <= d; cmd_wstrb <= s;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);       // 上升沿看到的是沿前的值
        end
    endtask

    task idle(input integer n);
        integer k;
        begin
            @(negedge clk); cmd_valid <= 1'b0;
            for (k = 1; k < n; k = k + 1) @(negedge clk);
        end
    endtask

    function [AW-1:0] rand_addr(input integer dummy);
        integer r;
        begin
            r = $urandom % 12;
            if (r < 10) rand_addr = (r % 5) << 2;               // 5 个有效寄存器
            else        rand_addr = (5 + $urandom % 1000) << 2; // 未映射
        end
    endfunction

    function [3:0] rand_strb(input integer dummy);
        rand_strb = (($urandom % 2) == 0) ? 4'hF : $urandom;
    endfunction

    // 看门狗：PREADY 永远不来时 issue 会一直等，正常运行约 2 万拍
    initial begin
        #5_000_000;
        $display("ERROR: timeout (PREADY stuck?)");
        $display("FAIL (%0d errors + timeout)", errors);
        $finish;
    end

    integer i, n_b2b0, c_b2b0, c_b2b1, n_b2b1;
    initial begin
        $dumpfile("apb.vcd");
        $dumpvars(0, tb_apb);
        #22 rst_n = 1;

        // P0 定向
        issue(0, 'h00, 0, 0);                 // 复位值
        issue(0, 'h0C, 0, 0);
        issue(1, 'h00, 32'hA5A5_1234, 4'hF);
        issue(1, 'h00, 32'hFFFF_FFFF, 4'h2);  // 只改 byte1
        issue(0, 'h00, 0, 0);
        issue(1, 'h08, 32'h1111_1111, 4'hF);  // 写只读 → PSLVERR
        issue(0, 'h40, 0, 0);                 // 未映射 → PSLVERR
        issue(1, 'h10, 32'hFFFF_FFFF, 4'hF);  // 打开全部中断使能
        issue(0, 'h0C, 0, 0);
        issue(1, 'h0C, 32'hFFFF_FFFF, 4'hF);  // W1C 全清
        issue(0, 'h0C, 0, 0);
        idle(3);

        // P1 随机：约 40% 空闲拍
        for (i = 0; i < NRAND; i = i + 1) begin
            issue($urandom % 2, rand_addr(0), $urandom, rand_strb(0));
            if (($urandom % 10) < 4) idle(1 + $urandom % 3);
        end
        idle(5);

        // P2 背靠背：命令口一直有效，测每笔传输占用总线（psel=1）多少拍
        n_b2b0 = n_rd + n_wr; c_b2b0 = n_psel;
        for (i = 0; i < NB2B; i = i + 1)
            issue($urandom % 2, (($urandom % 5) << 2), $urandom, 4'hF);
        idle(8);
        n_b2b1 = n_rd + n_wr; c_b2b1 = n_psel;

        if (cq_r != cq_w || rq_r != rq_w) err("cmd/rsp queue not drained");
        if (n_err_unmap == 0 || n_err_ro == 0 || n_w1c == 0 || n_collide == 0 || n_partial == 0)
            err("coverage hole");

        $display("------------------------------------------------------------");
        $display("WAIT=%0d  reads=%0d  writes=%0d  wait_cycles=%0d", WAIT, n_rd, n_wr, n_wait);
        $display("PSLVERR: unmapped=%0d  write-RO=%0d", n_err_unmap, n_err_ro);
        $display("W1C clears=%0d  set/clear same-cycle=%0d  partial PSTRB=%0d  irq_o cycles=%0d",
                 n_w1c, n_collide, n_partial, n_irq);
        $display("back-to-back: %0d xfers, PSEL high %0d cycles -> %0.2f cycles/xfer",
                 n_b2b1 - n_b2b0, c_b2b1 - c_b2b0,
                 (c_b2b1 - c_b2b0) * 1.0 / (n_b2b1 - n_b2b0));
        $display("------------------------------------------------------------");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
