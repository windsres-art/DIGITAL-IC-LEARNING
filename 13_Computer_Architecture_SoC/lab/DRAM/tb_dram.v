// =============================================================================
// DRAM 控制器 testbench（自检查）
//   +wl=seq|rand|streams|lat   负载（默认 rand）     +n=N  请求数（默认 4000）
//   +trace=文件                写出请求序列与刷新点，供 dram_sim.py 独立复算行命中统计
//   检查：
//     1 dram_model 的时序检查器：每条命令都合法、写数据窗口对、数据总线不冲突、刷新够
//     2 读数据：与平坦参考内存比对（参考内存的初值用 testbench 自己实现的地址映射算出，
//       所以控制器的映射写错也会表现为读错数据）
//     3 lat 负载：请求之间留足空闲，每个读的延迟必须正好等于
//         2 + tCL + BL/2           行命中
//         2 + tRCD + tCL + BL/2    行空（bank 已关）
//         2 + tRP + tRCD + tCL + BL/2  行冲突
//       MAP=0 开页时还检查每个请求的分类与手算一致
// =============================================================================
`timescale 1ns / 1ps

module tb_dram;
    parameter MAP       = 0;
    parameter OPEN_PAGE = 1;
    parameter LOOKAHEAD = 1;
    parameter QD        = 4;
    localparam BA_W = 3, ROW_W = 8, COL_W = 8, BL = 8;
    localparam AW = BA_W + ROW_W + COL_W + 2, LW = 32 * BL, HB = BL / 2;
    localparam NW = 1 << (AW - 2);
    localparam RANGE = 1 << AW;                // 2 MB
    localparam tRCD = 11, tRP = 11, tCL = 11;
    localparam real TCK_NS = 1.25;             // DDR3-1600：800 MHz 时钟

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---------------- DUT 与器件 ----------------
    reg             req_valid = 0, req_we = 0;
    reg  [AW-1:0]   req_addr = 0;
    reg  [LW-1:0]   req_wdata = 0;
    wire            req_ready, resp_valid;
    wire [LW-1:0]   resp_rdata;
    wire [2:0]      cmd;
    wire [BA_W-1:0] cmd_ba;
    wire [ROW_W-1:0] cmd_row;
    wire [COL_W-1:0] cmd_col;
    wire            cmd_ap, dq_wr_valid, dq_rd_valid;
    wire [63:0]     dq_wdata, dq_rdata;
    wire            perf_cls_valid, perf_ref;
    wire [1:0]      perf_cls;

    dram_ctrl #(.MAP(MAP), .OPEN_PAGE(OPEN_PAGE), .LOOKAHEAD(LOOKAHEAD), .QD(QD)) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .req_wdata(req_wdata), .resp_valid(resp_valid), .resp_rdata(resp_rdata),
        .cmd(cmd), .cmd_ba(cmd_ba), .cmd_row(cmd_row), .cmd_col(cmd_col), .cmd_ap(cmd_ap),
        .dq_wr_valid(dq_wr_valid), .dq_wdata(dq_wdata), .dq_rd_valid(dq_rd_valid), .dq_rdata(dq_rdata),
        .perf_cls_valid(perf_cls_valid), .perf_cls(perf_cls), .perf_ref(perf_ref));

    dram_model u_mem (
        .clk(clk), .rst_n(rst_n),
        .cmd(cmd), .cmd_ba(cmd_ba), .cmd_row(cmd_row), .cmd_col(cmd_col), .cmd_ap(cmd_ap),
        .dq_wr_valid(dq_wr_valid), .dq_wdata(dq_wdata), .dq_rd_valid(dq_rd_valid), .dq_rdata(dq_rdata));

    // ---------------- 参考内存（按主机字地址）----------------
    // 地址映射的独立实现：用整数除法 / 取模，而不是位切片
    function integer dev_index(input integer a);
        integer w, row, bank, col;
        begin
            w = a / 4;
            case (MAP)
                1: begin col = w % 256; row = (w / 256) % 256; bank = w / 65536; end
                2: begin col = w % 256; row = w / 2048; bank = ((w / 256) % 8) ^ (row % 8) ^ ((row / 8) % 8); end
                3: begin bank = (w / 8) % 8; row = w / 2048; col = ((w / 64) % 32) * 8 + w % 8; end
                default: begin col = w % 256; bank = (w / 256) % 8; row = w / 2048; end
            endcase
            dev_index = bank * 65536 + row * 256 + col;
        end
    endfunction

    reg [31:0] refm [0:NW-1];
    integer errors = 0, i, j, cyc = 0;

    // ---------------- 监视：接收、响应、统计 ----------------
    reg [LW-1:0] q_exp [0:31];
    integer      q_t   [0:31];
    integer      q_h = 0, q_n = 0;
    integer      n_acc = 0, n_rd = 0, n_resp = 0, first_acc = -1, last_resp = 0;
    integer      lat_sum = 0, last_lat = 0;
    integer      n_cls [0:2];
    integer      n_classified = 0, tfd = 0;
    reg [1023:0] tracefile;
    reg [LW-1:0] line;
    reg [1:0]    last_cls;

    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (perf_cls_valid) begin
            n_cls[perf_cls] = n_cls[perf_cls] + 1;
            n_classified = n_classified + 1;
            last_cls = perf_cls;
        end
        if (perf_ref && tfd != 0) $fdisplay(tfd, "F %0d", n_classified);
        if (resp_valid) begin
            if (q_n == 0) begin
                $display("ERROR: 多出来的读响应"); errors = errors + 1;
            end else begin
                if (resp_rdata !== q_exp[q_h]) begin
                    if (errors < 10) $display("ERROR @cycle %0d: 读数据错\n  得到 %h\n  期望 %h", cyc, resp_rdata, q_exp[q_h]);
                    errors = errors + 1;
                end
                last_lat = cyc - q_t[q_h];
                lat_sum  = lat_sum + last_lat;
                q_h = (q_h + 1) % 32; q_n = q_n - 1;
                n_resp = n_resp + 1; last_resp = cyc;
            end
        end
        if (req_valid && req_ready) begin
            if (first_acc < 0) first_acc = cyc;
            n_acc = n_acc + 1;
            if (tfd != 0) $fdisplay(tfd, "%0s %06h", req_we ? "W" : "R", req_addr);
            if (req_we) begin
                for (j = 0; j < BL; j = j + 1) refm[req_addr / 4 + j] = req_wdata[32*j +: 32];
            end else begin
                for (j = 0; j < BL; j = j + 1) line[32*j +: 32] = refm[req_addr / 4 + j];
                q_exp[(q_h + q_n) % 32] = line;
                q_t[(q_h + q_n) % 32]   = cyc;
                q_n = q_n + 1; n_rd = n_rd + 1;
            end
        end
    end

    // ---------------- 激励 ----------------
    task issue(input [AW-1:0] a, input we);
        begin
            @(negedge clk);
            req_valid = 1; req_addr = a; req_we = we;
            for (j = 0; j < LW / 32; j = j + 1) req_wdata[32*j +: 32] = $urandom;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            @(negedge clk);
            req_valid = 0;
        end
    endtask

    // lat 负载：MAP=0（row:bank:col，行号 = 地址 >> 13，bank = 地址[12:10]）下的手算分类
    reg [AW-1:0] lat_addr [0:6];
    reg [1:0]    lat_cls  [0:6];
    integer      lat_exp;

    reg [8*16-1:0] wl;
    integer n, k, s, pos [0:3];
    integer idle_wait;
    initial begin
        if (!$value$plusargs("wl=%s", wl)) wl = "rand";
        if (!$value$plusargs("n=%d", n))   n  = 4000;
        if ($value$plusargs("trace=%s", tracefile)) tfd = $fopen(tracefile, "w");
        for (i = 0; i < 3; i = i + 1) n_cls[i] = 0;
        for (i = 0; i < NW; i = i + 1) refm[i] = u_mem.init_val(dev_index(4 * i));

        lat_addr[0] = 21'h000000; lat_cls[0] = 1;   // bank 0 关着        → 行空
        lat_addr[1] = 21'h000020; lat_cls[1] = 0;   // bank 0 行 0 开着   → 行命中
        lat_addr[2] = 21'h002000; lat_cls[2] = 2;   // bank 0 要行 1      → 行冲突
        lat_addr[3] = 21'h002020; lat_cls[3] = 0;   //                    → 行命中
        lat_addr[4] = 21'h000400; lat_cls[4] = 1;   // bank 1 关着        → 行空
        lat_addr[5] = 21'h000000; lat_cls[5] = 2;   // bank 0 开着行 1    → 行冲突
        lat_addr[6] = 21'h000040; lat_cls[6] = 0;   //                    → 行命中

        $dumpfile("dram.vcd");
        $dumpvars(1, u_ctrl);

        #22 rst_n = 1;
        for (i = 0; i < 4; i = i + 1) pos[i] = 0;

        if (wl == "lat") begin
            for (k = 0; k < 7; k = k + 1) begin
                issue(lat_addr[k], 1'b0);
                while (q_n != 0) @(posedge clk);
                #1;
                lat_exp = 2 + tCL + HB + (last_cls == 1 ? tRCD : last_cls == 2 ? tRP + tRCD : 0);
                $display("  read %06h  %0s  latency %0d cyc = %0.2f ns (formula %0d)", lat_addr[k],
                         last_cls == 0 ? "row hit     " : last_cls == 1 ? "row empty   " : "row conflict",
                         last_lat, last_lat * TCK_NS, lat_exp);
                if (last_lat != lat_exp) begin
                    $display("ERROR: 延迟与公式不符"); errors = errors + 1;
                end
                if (MAP == 0 && OPEN_PAGE != 0 && last_cls != lat_cls[k]) begin
                    $display("ERROR: 分类 %0d，手算 %0d", last_cls, lat_cls[k]); errors = errors + 1;
                end
                if (OPEN_PAGE == 0 && last_cls != 1) begin
                    $display("ERROR: 关页时每次都应是行空"); errors = errors + 1;
                end
                repeat (60) @(posedge clk);
            end
            n = 7;
        end else begin
            for (k = 0; k < n; k = k + 1) begin
                if (wl == "seq")
                    issue((k * 32) % RANGE, 1'b0);
                else if (wl == "streams") begin
                    // 4 个顺序读流，起点相距 64 KB（2 的幂对齐的数组，很常见）
                    s = k % 4;
                    issue((s * 65536 + pos[s] * 32) % RANGE, 1'b0);
                    pos[s] = pos[s] + 1;
                end else
                    issue(($urandom % (RANGE / 32)) * 32, ($urandom % 100) < 30);
            end
        end

        idle_wait = 0;
        while ((q_n != 0 || u_mem.n_rd + u_mem.n_wr != n_acc) && idle_wait < 100000) begin
            @(posedge clk); idle_wait = idle_wait + 1;
        end
        repeat (40) @(posedge clk);                 // 等最后的写数据上总线
        if (idle_wait >= 100000) begin
            $display("ERROR: 还有 %0d 个读没有响应、%0d 个请求没有发出（死锁？）", q_n, n_acc - u_mem.n_rd - u_mem.n_wr);
            errors = errors + 1;
        end
        u_mem.final_check;
        if (tfd != 0) $fclose(tfd);

        if (wl != "lat") begin
            $display("cfg MAP=%0d(%0s) %0s LA=%0d wl=%0s n=%0d (写 %0d)", MAP,
                     MAP == 0 ? "RBC" : MAP == 1 ? "BRC" : MAP == 2 ? "XOR" : "LINE",
                     OPEN_PAGE ? "open-page" : "close-page", LOOKAHEAD, wl, n, n - n_rd);
            $display("row: hit=%0d empty=%0d conflict=%0d (hit %0.1f%%)  cmd: ACT=%0d PRE=%0d RD=%0d WR=%0d REF=%0d",
                     n_cls[0], n_cls[1], n_cls[2], 100.0 * n_cls[0] / n,
                     u_mem.n_act, u_mem.n_pre, u_mem.n_rd, u_mem.n_wr, u_mem.n_ref);
            $display("cycles=%0d  bus busy=%0.1f%%  BW=%0.2f GB/s (peak 6.40)  avg read lat=%0.1f cyc = %0.1f ns",
                     u_mem.last_busy - first_acc + 1,
                     100.0 * u_mem.n_busy / (u_mem.last_busy - first_acc + 1),
                     32.0 * n / ((u_mem.last_busy - first_acc + 1) * TCK_NS),
                     1.0 * lat_sum / n_rd, TCK_NS * lat_sum / n_rd);
            $display("SUMMARY %0d %0d %0d %0.1f %0.2f %0.1f %0d %0d", n_cls[0], n_cls[1], n_cls[2],
                     100.0 * n_cls[0] / n, 32.0 * n / ((u_mem.last_busy - first_acc + 1) * TCK_NS),
                     1.0 * lat_sum / n_rd, u_mem.n_act, u_mem.n_ref);
        end
        errors = errors + u_mem.errors;
        if (n_classified != n) begin
            $display("ERROR: 分类了 %0d 个请求，应为 %0d", n_classified, n); errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
