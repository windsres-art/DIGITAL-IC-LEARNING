// =============================================================================
// DDR 风格 DRAM 控制器（教学版，单 rank）
//   主机口：与第 3 节 cache 的内存口同一风格——整行（一次 burst）的 valid/ready 请求；
//           读在 resp_valid 时返回整行，按请求顺序返回；写在被接收时即完成（写数据先缓存）
//   命令口：每周期至多一条命令 NOP / ACT / RD / WR / PRE / REF（RD/WR 可带自动预充电 ap）
//   数据口：双沿，每周期 2 个 32 bit 拍；读数据由器件在 RD + tCL 起返回，
//           写数据由本控制器在 WR + tCWL 起驱动
//   参数：
//     MAP       地址映射  0 = row:bank:col（RBC）  1 = bank:row:col（BRC）
//                         2 = RBC，bank 与行地址低位异或（XOR 交织）
//                         3 = row:col_hi:bank:col_lo（按 cache 行交织 bank）
//     OPEN_PAGE 1 = 开页：访问完不关行，下一个访问同一行就是行命中
//               0 = 关页：每次读写都带自动预充电
//     LOOKAHEAD 1 = 队列里更年轻的请求可以提前 ACT / PRE（列命令仍严格按序）
//               0 = 只服务队首
//   调度：
//     - 每个请求在队列里按顺序"分类"一次：行命中 / 行空（bank 已关）/ 行冲突（开着别的行）。
//       分类要等前面同 bank 的请求都发出列命令之后，所以统计结果与"按序逐个访问"的
//       简单模型完全一致（dram_sim.py 复算）。刷新期间不分类。
//     - 命令优先级：刷新 > 队首的列命令 > 按年龄从老到新的 PRE / ACT
//     - 已分类的请求两两不同 bank，所以提前的 PRE 不会关掉更老的请求要用的行
//   时序约束用倒计数器实现：计数为 0 才允许，发命令时取 max(剩余, 新约束)
//   刷新：每 tREFI 置位 ref_pending；停止分类，把已分类的请求做完，
//         再把开着的 bank 逐个 PRE，全部满足 tRP 后发 REF
//   约束的取值都必须能放进 8 bit 计数器（DDR3-1600 的数值远小于 255）
// =============================================================================
module dram_ctrl #(
    parameter BA_W      = 3,               // 8 个 bank
    parameter ROW_W     = 8,               // 教学用小器件：每 bank 256 行
    parameter COL_W     = 8,               // 每行 256 列 × 4 B = 1 KB（页大小）
    parameter BL        = 8,               // burst 长度（拍）= 一个 32 B 的 cache 行
    parameter MAP       = 0,
    parameter OPEN_PAGE = 1,
    parameter LOOKAHEAD = 1,
    parameter QD        = 4,               // 请求队列深度（2 的幂）
    // DDR3-1600（tCK = 1.25 ns）11-11-11 的典型值，单位：时钟周期
    parameter tRCD = 11, tRP = 11, tCL = 11, tCWL = 8, tRAS = 28, tRC = 39,
    parameter tRRD = 5, tFAW = 24, tWR = 12, tWTR = 6, tRTP = 6, tCCD = 4,
    parameter tRFC = 208, tREFI = 6240,
    // 派生参数，不要覆盖
    parameter AW = BA_W + ROW_W + COL_W + 2,
    parameter LW = 32 * BL
)(
    input                  clk,
    input                  rst_n,
    // 主机口
    input                  req_valid,
    output                 req_ready,
    input                  req_we,
    input      [AW-1:0]    req_addr,
    input      [LW-1:0]    req_wdata,
    output reg             resp_valid,
    output reg [LW-1:0]    resp_rdata,
    // DRAM 命令口
    output reg [2:0]       cmd,
    output reg [BA_W-1:0]  cmd_ba,
    output reg [ROW_W-1:0] cmd_row,
    output reg [COL_W-1:0] cmd_col,
    output reg             cmd_ap,
    // DRAM 数据口
    output                 dq_wr_valid,
    output     [63:0]      dq_wdata,
    input                  dq_rd_valid,
    input      [63:0]      dq_rdata,
    // 统计
    output                 perf_cls_valid,     // 本拍有一个请求被分类
    output     [1:0]       perf_cls,           // 0 = 行命中，1 = 行空，2 = 行冲突
    output                 perf_ref
);
    localparam [2:0] C_NOP = 3'd0, C_ACT = 3'd1, C_RD = 3'd2, C_WR = 3'd3, C_PRE = 3'd4, C_REF = 3'd5;
    localparam NB    = 1 << BA_W;
    localparam LCB   = $clog2(BL);               // burst 内的拍地址位数
    localparam QW    = $clog2(QD);
    localparam HB    = BL / 2;                   // 一次 burst 占数据总线的周期数
    localparam HBW   = $clog2(HB);
    localparam WRPRE = tCWL + HB + tWR;          // WR 命令 → 允许预充电
    localparam WR2RD = tCWL + HB + tWTR;         // WR 命令 → 允许 RD
    localparam RD2WR = tCL + HB + 2 - tCWL;      // RD 命令 → 允许 WR（数据总线换向留 2 拍空）

    localparam [7:0] K_RCD = tRCD - 1, K_RP = tRP - 1, K_RAS = tRAS - 1, K_RC = tRC - 1,
                     K_RRD = tRRD - 1, K_FAW = tFAW - 1, K_RTP = tRTP - 1, K_CCD = tCCD - 1,
                     K_RFC = tRFC - 1, K_WRPRE = WRPRE - 1, K_WR2RD = WR2RD - 1, K_RD2WR = RD2WR - 1;
    localparam [7:0] T_RTP = tRTP, T_WRPRE = WRPRE, T_RP = tRP;
    localparam [15:0] K_REFI = tREFI - 1;
    localparam integer   HB_LAST_I = HB - 1;
    localparam [HBW-1:0] HB_LAST   = HB_LAST_I[HBW-1:0];

    // ---------------- 地址映射 ----------------
    // 输入拍地址（字节地址去掉低 2 位），返回 {bank, row, col}
    localparam DW = BA_W + ROW_W + COL_W;
    function [DW-1:0] decode(input [DW-1:0] w);
        reg [ROW_W-1:0] r;
        begin
            r = w[DW-1 -: ROW_W];
            case (MAP)
                1:       decode = w;                                         // bank:row:col
                2:       decode = {w[COL_W +: BA_W] ^ r[BA_W-1:0] ^ r[2*BA_W-1:BA_W],
                                   r, w[COL_W-1:0]};                         // RBC + 异或
                3:       decode = {w[LCB +: BA_W], r,
                                   w[LCB+BA_W +: COL_W-LCB], w[LCB-1:0]};    // row:col_hi:bank:col_lo
                default: decode = {w[COL_W +: BA_W], r, w[COL_W-1:0]};       // row:bank:col
            endcase
        end
    endfunction

    function [7:0] mx(input [7:0] x, input [7:0] y);
        mx = (x > y) ? x : y;
    endfunction

    function [7:0] dec(input [7:0] x);
        dec = (x == 8'd0) ? 8'd0 : x - 8'd1;
    endfunction

    // ---------------- 请求队列 ----------------
    reg            q_we    [0:QD-1];
    reg [DW-1:0]   q_addr  [0:QD-1];       // 拍地址
    reg [LW-1:0]   q_wdata [0:QD-1];
    reg [QW-1:0]   qh;
    reg [QW:0]     qn;                     // 队列里的请求数
    reg [QW:0]     ncls;                   // 其中已分类的（总是队列前面连续的若干个）

    localparam integer QD_I  = QD;
    localparam [QW:0]  QFULL = QD_I[QW:0];
    assign req_ready = (qn != QFULL);
    wire   accept    = req_valid & req_ready;

    // 按年龄（0 = 队首）展开每个请求的 bank / row / col
    reg [BA_W-1:0]  e_ba  [0:QD-1];
    reg [ROW_W-1:0] e_row [0:QD-1];
    reg [COL_W-1:0] e_col [0:QD-1];
    reg             e_we  [0:QD-1];
    reg [QW-1:0]    e_idx;
    integer ek;
    always @* begin
        for (ek = 0; ek < QD; ek = ek + 1) begin
            e_idx = qh + ek[QW-1:0];
            {e_ba[ek], e_row[ek], e_col[ek]} = decode(q_addr[e_idx]);
            e_we[ek] = q_we[e_idx];
        end
    end

    // ---------------- bank 状态与时序计数器 ----------------
    reg [NB-1:0]    b_open;
    reg [ROW_W-1:0] b_row  [0:NB-1];
    reg [7:0]       t_act  [0:NB-1];       // 到允许 ACT 还剩几拍（tRP / tRC / tRFC / 自动预充电）
    reg [7:0]       t_col  [0:NB-1];       // 到允许 RD / WR（tRCD）
    reg [7:0]       t_pre  [0:NB-1];       // 到允许 PRE（tRAS / tRTP / tWR）
    reg [7:0]       t_rd, t_wr, t_rrd;     // 全局：tCCD / tWTR / 换向 / tRRD
    reg [7:0]       faw    [0:3];          // 最近 4 次 ACT 各自的 tFAW 窗口
    reg [15:0]      ref_timer;
    reg             ref_pending;

    wire faw_free = (faw[0] == 8'd0) | (faw[1] == 8'd0) | (faw[2] == 8'd0) | (faw[3] == 8'd0);

    // 写数据缓冲：WR 发出时入队，tCWL 拍后开始上总线
    reg [LW-1:0] wf_data [0:3];
    reg [1:0]    wf_wp, wf_rp;
    reg [2:0]    wf_n;
    wire         wf_full = (wf_n == 3'd4);

    // ---------------- 分类：下一个未分类的请求 ----------------
    reg       cls_go;
    reg [1:0] cls_kind;
    wire [QW-1:0]   ci  = ncls[QW-1:0];
    wire [BA_W-1:0] cba = e_ba[ci];
    integer cj;
    always @* begin
        cls_go   = 1'b0;
        cls_kind = 2'd0;
        if (!ref_pending && ncls < qn) begin
            cls_go = 1'b1;
            for (cj = 0; cj < QD; cj = cj + 1)
                if (cj < ncls && e_ba[cj] == cba) cls_go = 1'b0;   // 前面还有同 bank 的请求
            if (!b_open[cba])                 cls_kind = 2'd1;
            else if (b_row[cba] != e_row[ci]) cls_kind = 2'd2;
        end
    end
    assign perf_cls_valid = cls_go;
    assign perf_cls       = cls_kind;

    // ---------------- 命令选择 ----------------
    reg all_closed, all_act_ok, picked;
    reg [BA_W-1:0] sb;
    integer sk, si;
    always @* begin
        cmd = C_NOP; cmd_ba = {BA_W{1'b0}}; cmd_row = {ROW_W{1'b0}}; cmd_col = {COL_W{1'b0}}; cmd_ap = 1'b0;
        picked = 1'b0;
        sb = {BA_W{1'b0}};
        all_closed = ~|b_open;
        all_act_ok = 1'b1;
        for (si = 0; si < NB; si = si + 1) if (t_act[si] != 8'd0) all_act_ok = 1'b0;

        if (ref_pending && ncls == {(QW+1){1'b0}}) begin
            // 刷新：已分类的请求先做完（期间不再分类新请求），再关掉所有开着的行，发 REF
            for (si = 0; si < NB; si = si + 1)
                if (!picked && b_open[si] && t_pre[si] == 8'd0) begin
                    picked = 1'b1; cmd = C_PRE; cmd_ba = si[BA_W-1:0];
                end
            if (!picked && all_closed && all_act_ok) begin
                picked = 1'b1; cmd = C_REF;
            end
        end else begin
            for (sk = 0; sk < QD; sk = sk + 1) begin
                sb = e_ba[sk];
                if (!picked && sk < ncls) begin
                    if (b_open[sb] && b_row[sb] == e_row[sk]) begin
                        // 行已打开：只有队首可以发列命令（数据按序返回）
                        if (sk == 0 && t_col[sb] == 8'd0 &&
                            (e_we[sk] ? (t_wr == 8'd0 && !wf_full) : (t_rd == 8'd0))) begin
                            picked  = 1'b1;
                            cmd     = e_we[sk] ? C_WR : C_RD;
                            cmd_ba  = sb;
                            cmd_col = e_col[sk];
                            cmd_ap  = (OPEN_PAGE == 0);
                        end
                    end else if (sk == 0 || LOOKAHEAD != 0) begin
                        if (b_open[sb]) begin
                            if (t_pre[sb] == 8'd0) begin picked = 1'b1; cmd = C_PRE; cmd_ba = sb; end
                        end else if (t_act[sb] == 8'd0 && t_rrd == 8'd0 && faw_free) begin
                            picked = 1'b1; cmd = C_ACT; cmd_ba = sb; cmd_row = e_row[sk];
                        end
                    end
                end
            end
        end
    end

    wire is_col = (cmd == C_RD) | (cmd == C_WR);     // 列命令总是队首的，发出即出队
    assign perf_ref = (cmd == C_REF);

    // ---------------- 计数器的下一状态 ----------------
    reg [7:0] n_act [0:NB-1];
    reg [7:0] n_col [0:NB-1];
    reg [7:0] n_pre [0:NB-1];
    reg [7:0] n_rd, n_wr, n_rrd;
    reg [7:0] n_faw [0:3];
    reg       faw_loaded;
    integer nb, nk;
    always @* begin
        for (nb = 0; nb < NB; nb = nb + 1) begin
            n_act[nb] = dec(t_act[nb]);
            n_col[nb] = dec(t_col[nb]);
            n_pre[nb] = dec(t_pre[nb]);
            if (cmd_ba == nb[BA_W-1:0]) begin
                case (cmd)
                    C_ACT: begin
                        n_act[nb] = mx(n_act[nb], K_RC);
                        n_col[nb] = mx(n_col[nb], K_RCD);
                        n_pre[nb] = mx(n_pre[nb], K_RAS);
                    end
                    C_PRE: n_act[nb] = mx(n_act[nb], K_RP);
                    C_RD: begin
                        n_pre[nb] = mx(n_pre[nb], K_RTP);
                        // 自动预充电在 max(tRTP, tRAS 剩余) 时发生，再过 tRP 才能 ACT
                        if (cmd_ap) n_act[nb] = mx(n_act[nb], mx(t_pre[nb], T_RTP) + T_RP - 8'd1);
                    end
                    C_WR: begin
                        n_pre[nb] = mx(n_pre[nb], K_WRPRE);
                        if (cmd_ap) n_act[nb] = mx(n_act[nb], mx(t_pre[nb], T_WRPRE) + T_RP - 8'd1);
                    end
                    default: ;
                endcase
            end
            if (cmd == C_REF) n_act[nb] = mx(n_act[nb], K_RFC);
        end
        n_rd  = dec(t_rd);
        n_wr  = dec(t_wr);
        n_rrd = dec(t_rrd);
        if (cmd == C_RD) begin n_rd = mx(n_rd, K_CCD); n_wr = mx(n_wr, K_RD2WR); end
        if (cmd == C_WR) begin n_wr = mx(n_wr, K_CCD); n_rd = mx(n_rd, K_WR2RD); end
        if (cmd == C_ACT) n_rrd = K_RRD;
        faw_loaded = 1'b0;
        for (nk = 0; nk < 4; nk = nk + 1) begin
            n_faw[nk] = dec(faw[nk]);
            if (cmd == C_ACT && !faw_loaded && faw[nk] == 8'd0) begin
                n_faw[nk] = K_FAW; faw_loaded = 1'b1;
            end
        end
    end

    // ---------------- 时序逻辑 ----------------
    reg [tCWL-1:0] wr_sr;                  // WR 发出后第 k 拍，wr_sr[k-1] = 1
    reg            wbusy;
    reg [HBW-1:0]  wcnt;
    reg [HBW-1:0]  rcnt;
    reg [LW-1:0]   rbuf;
    wire           wstart = wr_sr[tCWL-1];
    integer rb, rk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qh <= {QW{1'b0}}; qn <= {(QW+1){1'b0}}; ncls <= {(QW+1){1'b0}};
            b_open <= {NB{1'b0}};
            for (rb = 0; rb < NB; rb = rb + 1) begin
                t_act[rb] <= 8'd0; t_col[rb] <= 8'd0; t_pre[rb] <= 8'd0;
            end
            for (rk = 0; rk < 4; rk = rk + 1) faw[rk] <= 8'd0;
            t_rd <= 8'd0; t_wr <= 8'd0; t_rrd <= 8'd0;
            ref_timer   <= K_REFI;
            ref_pending <= 1'b0;
            wf_wp <= 2'd0; wf_rp <= 2'd0; wf_n <= 3'd0;
            wr_sr <= {tCWL{1'b0}};
            wbusy <= 1'b0; wcnt <= {HBW{1'b0}};
            rcnt  <= {HBW{1'b0}};
            resp_valid <= 1'b0;
        end else begin
            // 队列
            qh   <= qh + {{(QW-1){1'b0}}, is_col};
            qn   <= qn + {{QW{1'b0}}, accept} - {{QW{1'b0}}, is_col};
            ncls <= ncls + {{QW{1'b0}}, cls_go} - {{QW{1'b0}}, is_col};

            // bank 状态
            if (cmd == C_ACT) b_open[cmd_ba] <= 1'b1;
            if (cmd == C_PRE || (is_col && cmd_ap)) b_open[cmd_ba] <= 1'b0;

            // 计数器
            for (rb = 0; rb < NB; rb = rb + 1) begin
                t_act[rb] <= n_act[rb]; t_col[rb] <= n_col[rb]; t_pre[rb] <= n_pre[rb];
            end
            for (rk = 0; rk < 4; rk = rk + 1) faw[rk] <= n_faw[rk];
            t_rd <= n_rd; t_wr <= n_wr; t_rrd <= n_rrd;

            // 刷新定时：按固定周期置位，不因推迟而漂移
            if (cmd == C_REF) ref_pending <= 1'b0;
            if (ref_timer == 16'd0) begin ref_timer <= K_REFI; ref_pending <= 1'b1; end
            else                         ref_timer <= ref_timer - 16'd1;

            // 写数据：入队、延迟 tCWL、占总线 BL/2 拍后出队
            wr_sr <= {wr_sr[tCWL-2:0], cmd == C_WR};
            if (cmd == C_WR) wf_wp <= wf_wp + 2'd1;
            if (wstart) begin
                wbusy <= 1'b1; wcnt <= {{(HBW-1){1'b0}}, 1'b1};
            end else if (wbusy) begin
                if (wcnt == HB_LAST) begin wbusy <= 1'b0; wf_rp <= wf_rp + 2'd1; end
                else                  wcnt <= wcnt + 1'b1;
            end
            wf_n <= wf_n + {2'b00, cmd == C_WR} - {2'b00, wbusy && wcnt == HB_LAST};

            // 读数据：收齐 BL/2 拍后返回整行
            resp_valid <= 1'b0;
            if (dq_rd_valid) begin
                if (rcnt == HB_LAST) begin
                    resp_valid <= 1'b1;
                    resp_rdata <= {dq_rdata, rbuf[64*(HB-1)-1:0]};
                    rcnt       <= {HBW{1'b0}};
                end else begin
                    rbuf[64*rcnt +: 64] <= dq_rdata;
                    rcnt <= rcnt + 1'b1;
                end
            end
        end
    end

    // 存储体：不复位
    always @(posedge clk) begin
        if (accept) begin
            q_we   [qh + qn[QW-1:0]] <= req_we;
            q_addr [qh + qn[QW-1:0]] <= req_addr[AW-1:2];
            q_wdata[qh + qn[QW-1:0]] <= req_wdata;
        end
        if (cmd == C_ACT) b_row[cmd_ba] <= cmd_row;
        if (cmd == C_WR)  wf_data[wf_wp] <= q_wdata[qh];
    end

    wire [HBW-1:0] wsel = wbusy ? wcnt : {HBW{1'b0}};
    assign dq_wr_valid = wstart | wbusy;
    assign dq_wdata    = wf_data[wf_rp][64*wsel +: 64];

    wire unused_ok = &{1'b0, rbuf[LW-1:64*(HB-1)], req_addr[1:0]};
endmodule
