// =============================================================================
// AXI4 testbench（自检查）：随机主机 BFM → axi_ram
//   主机：生成器把一笔写拆成 1 条 AW + N 拍 W 放进两个独立队列，一笔读放进 AR 队列；
//         AW / W / AR 三个驱动各自随机延迟拉 VALID，互不等待（W 可以先于 AW 出现）；
//         RREADY / BREADY 随机。主机最多 MAX_OUT 笔写、MAX_OUT 笔读在途（outstanding）。
//   参考模型：字节数组，写在"发出"时就更新。AXI 不保证读写通道之间的顺序，
//         所以按字加锁：在途写覆盖的字不许再发读或写，在途读覆盖的字不许发写，
//         这样模型在任何时刻都是确定的。
//   记分板：按 ID 排队。R 到来时按 RID 找该 ID 最早的在途读，逐拍比对数据（只比有效字节
//         通道）和 RLAST 位置；B 按 BID 找该 ID 最早的在途写。
//   协议检查：五个通道 VALID 拉高后在握手前不许撤、负载不许变；
//         第 k 个 B 之前必须已有 k 个 AW 握手和 k 个 WLAST 握手。
//   阶段：P1 随机混合；P2 单拍读 / P3 16 拍读 / P4 单拍写 / P5 16 拍写，VALID/READY 全 1 测吞吐
// =============================================================================
`timescale 1ns / 1ps

module tb_axi;
    parameter MAX_OUT = 4;
    localparam IDW = 2, NID = 4, AW = 12, NW = 1024;   // 4 KB = 1024 字
    localparam NRAND = 1500;

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------- AXI 信号 ----------------
    reg  [IDW-1:0] awid = 0;  reg [AW-1:0] awaddr = 0; reg [7:0] awlen = 0;
    reg  [2:0]     awsize = 0; reg [1:0] awburst = 0;  reg awvalid = 0;
    wire           awready;
    reg  [31:0]    wdata = 0; reg [3:0] wstrb = 0; reg wlast = 0; reg wvalid = 0;
    wire           wready;
    wire [IDW-1:0] bid;  wire [1:0] bresp; wire bvalid; reg bready = 0;
    reg  [IDW-1:0] arid = 0;  reg [AW-1:0] araddr = 0; reg [7:0] arlen = 0;
    reg  [2:0]     arsize = 0; reg [1:0] arburst = 0;  reg arvalid = 0;
    wire           arready;
    wire [IDW-1:0] rid;  wire [31:0] rdata; wire [1:0] rresp; wire rlast, rvalid; reg rready = 0;

    axi_ram #(.AW(AW), .IDW(IDW), .QAW(2)) u_dut (
        .aclk(aclk), .aresetn(aresetn),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));

    integer errors = 0;
    task err(input [8*48-1:0] msg);
        begin
            if (errors < 10) $display("ERROR @%0t: %0s", $time, msg);
            errors = errors + 1;
        end
    endtask

    // ---------------- 参考地址计算（与 RTL 用不同写法，独立验证）----------------
    function integer beat_addr(input integer start, input integer size, input integer len,
                               input integer burst, input integer k);
        integer bytes, tot, base;
        begin
            bytes = 1 << size;
            tot   = bytes * (len + 1);
            case (burst)
                0: beat_addr = start;
                2: begin base = (start / tot) * tot; beat_addr = base + (start - base + k * bytes) % tot; end
                default: beat_addr = (k == 0) ? start : (start / bytes) * bytes + k * bytes;
            endcase
        end
    endfunction

    // 这一拍有效的字节通道：[本拍地址, 按 size 对齐后的末字节]
    function [3:0] lanes(input integer ba, input integer size);
        integer bytes, lo, hi, l;
        begin
            bytes = 1 << size;
            lo = ba % 4;
            hi = ((ba / bytes) * bytes + bytes - 1) % 4;
            for (l = 0; l < 4; l = l + 1) lanes[l] = (l >= lo) && (l <= hi);
        end
    endfunction

    // ---------------- 参考模型与锁 ----------------
    reg [7:0] mm [0:4095];
    integer   wbusy [0:NW-1];
    integer   rbusy [0:NW-1];

    // 主机发送队列
    reg [IDW+AW+8+3+2-1:0] aq [0:1023]; integer aq_w = 0, aq_r = 0;   // AW
    reg [31+4+1:0]         wq [0:8191]; integer wq_w = 0, wq_r = 0;   // W {data, strb, last}
    reg [IDW+AW+8+3+2-1:0] rq [0:1023]; integer rq_w = 0, rq_r = 0;   // AR

    // 按 ID 的在途记录（每个 ID 32 项环形）
    integer wr_lo [0:NID*32-1], wr_hi [0:NID*32-1];
    integer rd_lo [0:NID*32-1], rd_hi [0:NID*32-1], rd_ep [0:NID*32-1], rd_n [0:NID*32-1];
    integer wh [0:NID-1], wt [0:NID-1], rh [0:NID-1], rt [0:NID-1], rbeat [0:NID-1];
    reg [31:0] exp_d [0:16383];
    reg [3:0]  exp_m [0:16383];
    integer    ep = 0;

    integer out_wr = 0, out_rd = 0, n_wr_iss = 0, n_rd_iss = 0, n_retry = 0;
    integer n_aw_hs = 0, n_wlast_hs = 0, n_b_hs = 0, n_ar_hs = 0, n_rlast_hs = 0;
    integer n_wbeat = 0, n_rbeat = 0, n_cyc = 0, n_w_early = 0, n_narrow = 0, n_unalign = 0;
    integer max_out_rd = 0, max_out_wr = 0, n_rchk_bytes = 0;
    integer n_bt [0:2];

    // 当前阶段配置
    integer g_mode = 0, v_pct = 70, r_pct = 70, gen_pct = 50, tgt_wr = 0, tgt_rd = 0;
    reg     gen_on = 0;

    // 生成一笔 burst 的参数
    integer g_addr, g_len, g_size, g_burst, g_lo, g_hi, g_tot, g_bytes;
    task gen_params;
        integer r;
        begin
            if (g_mode == 1) begin                  // 单拍字读写
                g_burst = 1; g_size = 2; g_len = 0;  g_addr = ($urandom % 1024) * 4;
            end else if (g_mode == 2) begin         // 16 拍 INCR 字读写
                g_burst = 1; g_size = 2; g_len = 15; g_addr = ($urandom % 64) * 64;
            end else begin
                r = $urandom % 10;
                g_size = $urandom % 3;
                if (r < 2)      begin g_burst = 0; g_len = $urandom % 8; end
                else if (r < 5) begin g_burst = 2; g_len = (2 << ($urandom % 4)) - 1; end  // 1/3/7/15
                else            begin g_burst = 1; g_len = $urandom % 32; end
                g_bytes = 1 << g_size;
                g_addr  = $urandom % 4096;
                if (g_burst == 2 || ($urandom % 4) != 0) g_addr = (g_addr / g_bytes) * g_bytes;
                if (g_burst == 1 && (g_addr / g_bytes) * g_bytes + (g_len + 1) * g_bytes > 4096)
                    g_addr = 4096 - (g_len + 1) * g_bytes;              // INCR 不跨 4KB
            end
            g_bytes = 1 << g_size;
            g_tot   = g_bytes * (g_len + 1);
            case (g_burst)
                0: begin g_lo = g_addr / 4; g_hi = g_lo; end
                2: begin g_lo = ((g_addr / g_tot) * g_tot) / 4; g_hi = ((g_addr / g_tot) * g_tot + g_tot - 1) / 4; end
                default: begin g_lo = g_addr / 4; g_hi = beat_addr(g_addr, g_size, g_len, 1, g_len) / 4; end
            endcase
        end
    endtask

    integer i, k, l, id, ok, ba, slot;
    reg [3:0]  ln, st;
    reg [31:0] d;

    task try_write;
        begin
            gen_params;
            ok = 1;
            for (i = g_lo; i <= g_hi; i = i + 1) if (wbusy[i] != 0 || rbusy[i] != 0) ok = 0;
            if (!ok) n_retry = n_retry + 1;
            else begin
                id = $urandom % NID;
                for (i = g_lo; i <= g_hi; i = i + 1) wbusy[i] = wbusy[i] + 1;
                aq[aq_w % 1024] = {id[IDW-1:0], g_addr[AW-1:0], g_len[7:0], g_size[2:0], g_burst[1:0]};
                aq_w = aq_w + 1;
                for (k = 0; k <= g_len; k = k + 1) begin
                    ba = beat_addr(g_addr, g_size, g_len, g_burst, k);
                    ln = lanes(ba, g_size);
                    st = (($urandom % 5) == 0) ? (ln & $urandom) : ln;   // 20% 的拍只写部分字节
                    d  = $urandom;
                    wq[wq_w % 8192] = {d, st, (k == g_len)};
                    wq_w = wq_w + 1;
                    for (l = 0; l < 4; l = l + 1) if (st[l]) mm[(ba / 4) * 4 + l] = d[8*l +: 8];
                end
                slot = id * 32 + wt[id] % 32; wr_lo[slot] = g_lo; wr_hi[slot] = g_hi; wt[id] = wt[id] + 1;
                out_wr = out_wr + 1; n_wr_iss = n_wr_iss + 1;
                n_bt[g_burst] = n_bt[g_burst] + 1;
                if (g_size < 2) n_narrow = n_narrow + 1;
                if (g_addr % g_bytes != 0) n_unalign = n_unalign + 1;
            end
        end
    endtask

    task try_read;
        begin
            gen_params;
            ok = 1;
            for (i = g_lo; i <= g_hi; i = i + 1) if (wbusy[i] != 0) ok = 0;
            if (!ok) n_retry = n_retry + 1;
            else begin
                id = $urandom % NID;
                for (i = g_lo; i <= g_hi; i = i + 1) rbusy[i] = rbusy[i] + 1;
                rq[rq_w % 1024] = {id[IDW-1:0], g_addr[AW-1:0], g_len[7:0], g_size[2:0], g_burst[1:0]};
                rq_w = rq_w + 1;
                slot = id * 32 + rt[id] % 32;
                rd_lo[slot] = g_lo; rd_hi[slot] = g_hi; rd_ep[slot] = ep; rd_n[slot] = g_len + 1;
                rt[id] = rt[id] + 1;
                for (k = 0; k <= g_len; k = k + 1) begin
                    ba = beat_addr(g_addr, g_size, g_len, g_burst, k);
                    exp_m[ep % 16384] = lanes(ba, g_size);
                    for (l = 0; l < 4; l = l + 1) exp_d[ep % 16384][8*l +: 8] = mm[(ba / 4) * 4 + l];
                    ep = ep + 1;
                end
                out_rd = out_rd + 1; n_rd_iss = n_rd_iss + 1;
                n_bt[g_burst] = n_bt[g_burst] + 1;
                if (g_size < 2) n_narrow = n_narrow + 1;
                if (g_addr % g_bytes != 0) n_unalign = n_unalign + 1;
            end
        end
    endtask

    // ---------------- 主循环：先处理本沿的握手，再生成，再驱动 ----------------
    reg [31:0] m32;
    reg        v;
    always @(posedge aclk) if (aresetn) begin
        n_cyc = n_cyc + 1;
        if (wvalid && n_aw_hs <= n_wlast_hs) n_w_early = n_w_early + 1;    // W 先于它的 AW

        if (awvalid && awready) begin n_aw_hs = n_aw_hs + 1; aq_r = aq_r + 1; end
        if (wvalid && wready) begin
            n_wbeat = n_wbeat + 1; wq_r = wq_r + 1;
            if (wlast) n_wlast_hs = n_wlast_hs + 1;
        end
        if (arvalid && arready) begin n_ar_hs = n_ar_hs + 1; rq_r = rq_r + 1; end

        if (bvalid && bready) begin
            if (n_aw_hs <= n_b_hs || n_wlast_hs <= n_b_hs) err("B before its AW/WLAST");
            n_b_hs = n_b_hs + 1;
            if (bresp !== 2'b00) err("BRESP != OKAY");
            if (wh[bid] == wt[bid]) err("B with no outstanding write for BID");
            else begin
                slot = bid * 32 + wh[bid] % 32;
                for (i = wr_lo[slot]; i <= wr_hi[slot]; i = i + 1) wbusy[i] = wbusy[i] - 1;
                wh[bid] = wh[bid] + 1; out_wr = out_wr - 1;
            end
        end

        if (rvalid && rready) begin
            n_rbeat = n_rbeat + 1;
            if (rresp !== 2'b00) err("RRESP != OKAY");
            if (rh[rid] == rt[rid]) err("R with no outstanding read for RID");
            else begin
                slot = rid * 32 + rh[rid] % 32;
                k    = rd_ep[slot] + rbeat[rid];
                m32  = {{8{exp_m[k % 16384][3]}}, {8{exp_m[k % 16384][2]}},
                        {8{exp_m[k % 16384][1]}}, {8{exp_m[k % 16384][0]}}};
                if ((rdata & m32) !== (exp_d[k % 16384] & m32)) err("RDATA mismatch");
                for (l = 0; l < 4; l = l + 1) if (exp_m[k % 16384][l]) n_rchk_bytes = n_rchk_bytes + 1;
                if (rlast !== (rbeat[rid] == rd_n[slot] - 1)) err("RLAST at wrong beat");
                if (rbeat[rid] == rd_n[slot] - 1) begin
                    for (i = rd_lo[slot]; i <= rd_hi[slot]; i = i + 1) rbusy[i] = rbusy[i] - 1;
                    rh[rid] = rh[rid] + 1; rbeat[rid] = 0; out_rd = out_rd - 1;
                    n_rlast_hs = n_rlast_hs + 1;
                end else rbeat[rid] = rbeat[rid] + 1;
            end
        end

        if (n_ar_hs - n_rlast_hs > max_out_rd) max_out_rd = n_ar_hs - n_rlast_hs;
        if (n_aw_hs - n_b_hs     > max_out_wr) max_out_wr = n_aw_hs - n_b_hs;

        // 生成
        if (gen_on) begin
            if (n_wr_iss < tgt_wr && out_wr < MAX_OUT && ($urandom % 100) < gen_pct) try_write;
            if (n_rd_iss < tgt_rd && out_rd < MAX_OUT && ($urandom % 100) < gen_pct) try_read;
        end

        // 驱动：VALID 撤掉只能发生在握手之后
        v = awvalid && !awready;
        if (!v && aq_r != aq_w && ($urandom % 100) < v_pct) begin
            {awid, awaddr, awlen, awsize, awburst} <= aq[aq_r % 1024]; v = 1;
        end
        awvalid <= v;
        v = wvalid && !wready;
        if (!v && wq_r != wq_w && ($urandom % 100) < v_pct) begin
            {wdata, wstrb, wlast} <= wq[wq_r % 8192]; v = 1;
        end
        wvalid <= v;
        v = arvalid && !arready;
        if (!v && rq_r != rq_w && ($urandom % 100) < v_pct) begin
            {arid, araddr, arlen, arsize, arburst} <= rq[rq_r % 1024]; v = 1;
        end
        arvalid <= v;
        rready <= ($urandom % 100) < r_pct;
        bready <= ($urandom % 100) < r_pct;
    end

    // ---------------- 协议检查：VALID 保持、负载不变 ----------------
    reg p_aw = 0, p_w = 0, p_b = 0, p_ar = 0, p_r = 0;
    reg [IDW+AW+8+3+2-1:0] s_aw, s_ar;
    reg [36:0] s_w;
    reg [IDW+1:0] s_b;
    reg [IDW+32+2:0] s_r;
    always @(posedge aclk) if (aresetn) begin
        if (p_aw && (!awvalid || {awid, awaddr, awlen, awsize, awburst} !== s_aw)) err("AW dropped/changed while stalled");
        if (p_w  && (!wvalid  || {wdata, wstrb, wlast} !== s_w))                   err("W dropped/changed while stalled");
        if (p_ar && (!arvalid || {arid, araddr, arlen, arsize, arburst} !== s_ar)) err("AR dropped/changed while stalled");
        if (p_b  && (!bvalid  || {bid, bresp} !== s_b))                             err("B dropped/changed while stalled");
        if (p_r  && (!rvalid  || {rid, rdata, rresp, rlast} !== s_r))               err("R dropped/changed while stalled");
        p_aw = awvalid && !awready; s_aw = {awid, awaddr, awlen, awsize, awburst};
        p_w  = wvalid  && !wready;  s_w  = {wdata, wstrb, wlast};
        p_ar = arvalid && !arready; s_ar = {arid, araddr, arlen, arsize, arburst};
        p_b  = bvalid  && !bready;  s_b  = {bid, bresp};
        p_r  = rvalid  && !rready;  s_r  = {rid, rdata, rresp, rlast};
    end

    // ---------------- 阶段 ----------------
    integer c0, b0;
    task run_phase(input integer mode, input integer nwr, input integer nrd,
                   input integer vp, input integer rp, input integer gp,
                   input [8*20-1:0] name);
        begin
            g_mode = mode; v_pct = vp; r_pct = rp; gen_pct = gp;
            tgt_wr = n_wr_iss + nwr; tgt_rd = n_rd_iss + nrd;
            c0 = n_cyc; b0 = n_rbeat + n_wbeat;
            gen_on = 1;
            wait (n_wr_iss >= tgt_wr && n_rd_iss >= tgt_rd);
            gen_on = 0;
            wait (out_wr == 0 && out_rd == 0);
            @(posedge aclk);
            $display("%-20s | beats %6d | cycles %6d | beats/cycle %0.3f",
                     name, n_rbeat + n_wbeat - b0, n_cyc - c0,
                     (n_rbeat + n_wbeat - b0) * 1.0 / (n_cyc - c0));
        end
    endtask

    // 看门狗：丢拍会让在途计数永远清不了零，正常运行约 4.5 万拍
    initial begin
        #2_000_000;
        $display("ERROR: timeout, outstanding read=%0d write=%0d (beats lost?)", out_rd, out_wr);
        $display("FAIL (%0d errors + timeout)", errors);
        $finish;
    end

    initial begin
        $dumpfile("axi.vcd");
        $dumpvars(0, tb_axi);
        for (i = 0; i < NW; i = i + 1) begin
            u_dut.mem[i] = $urandom;
            for (l = 0; l < 4; l = l + 1) mm[4*i + l] = u_dut.mem[i][8*l +: 8];
            wbusy[i] = 0; rbusy[i] = 0;
        end
        for (i = 0; i < NID; i = i + 1) begin wh[i] = 0; wt[i] = 0; rh[i] = 0; rt[i] = 0; rbeat[i] = 0; end
        for (i = 0; i < 3; i = i + 1) n_bt[i] = 0;
        #22 aresetn = 1;

        $display("---------------------------------------------------------------");
        $display("MAX_OUT=%0d (slave queue depth 4)", MAX_OUT);
        run_phase(0, NRAND, NRAND, 70, 70, 50, "P1 random mixed");
        $display("  P1 bursts: FIXED=%0d INCR=%0d WRAP=%0d  narrow=%0d unaligned=%0d lock-retry=%0d",
                 n_bt[0], n_bt[1], n_bt[2], n_narrow, n_unalign, n_retry);
        $display("  P1 W-before-AW cycles=%0d  max outstanding at slave: read=%0d write=%0d",
                 n_w_early, max_out_rd, max_out_wr);
        run_phase(1, 0,    1000, 100, 100, 100, "P2 read  len=0");
        run_phase(2, 0,     200, 100, 100, 100, "P3 read  len=15");
        run_phase(1, 1000,    0, 100, 100, 100, "P4 write len=0");
        run_phase(2, 200,     0, 100, 100, 100, "P5 write len=15");
        $display("checked read bytes=%0d  max outstanding at slave (all phases): read=%0d write=%0d",
                 n_rchk_bytes, max_out_rd, max_out_wr);
        $display("---------------------------------------------------------------");
        if (aq_r != aq_w || wq_r != wq_w || rq_r != rq_w) err("master queues not drained");
        if (n_w_early == 0 || n_unalign == 0) err("coverage hole");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
