// =============================================================================
// DRAM 器件模型 + 时序检查器（仅用于仿真）
//   - 存储：按 {bank, row, col} 寻址，每列一个 32 bit 拍（beat）
//   - 数据总线双沿：每个时钟周期传 2 拍（64 bit），一次 burst（BL 拍）占 BL/2 个周期
//   - 用绝对时间（周期号）检查每条命令是否合法，与控制器里的倒计数器是两套独立实现：
//       ACT  tRP（预充电后）、tRC（同 bank 两次 ACT）、tRRD（任意 bank 两次 ACT）、
//            tFAW（任意 tFAW 窗口内最多 4 次 ACT）、tRFC（刷新后）
//       RD   tRCD、tCCD、tWTR（写数据结束后）
//       WR   tRCD、tCCD、读后写的数据总线换向
//       PRE  tRAS、tRTP（读后）、tWR（写数据结束后）
//       REF  所有 bank 已预充电且满足 tRP；两次刷新间隔
//     自动预充电（RDA / WRA）：器件在 max(tRTP 或 tWR 满足, tRAS 满足) 时自己预充电
//   - 写数据：控制器必须恰好在 WR + tCWL 起的 BL/2 个周期驱动 dq_wr_valid
//   - 读数据：RD + tCL 起的 BL/2 个周期由本模型驱动
// =============================================================================
`timescale 1ns / 1ps

module dram_model #(
    parameter BA_W = 3, ROW_W = 8, COL_W = 8, BL = 8,
    parameter tRCD = 11, tRP = 11, tCL = 11, tCWL = 8, tRAS = 28, tRC = 39,
    parameter tRRD = 5, tFAW = 24, tWR = 12, tWTR = 6, tRTP = 6, tCCD = 4,
    parameter tRFC = 208, tREFI = 6240
)(
    input                  clk,
    input                  rst_n,
    input      [2:0]       cmd,
    input      [BA_W-1:0]  cmd_ba,
    input      [ROW_W-1:0] cmd_row,
    input      [COL_W-1:0] cmd_col,
    input                  cmd_ap,
    input                  dq_wr_valid,
    input      [63:0]      dq_wdata,
    output reg             dq_rd_valid,
    output reg [63:0]      dq_rdata
);
    localparam [2:0] C_NOP = 3'd0, C_ACT = 3'd1, C_RD = 3'd2, C_WR = 3'd3, C_PRE = 3'd4, C_REF = 3'd5;
    localparam NB   = 1 << BA_W;
    localparam NW   = 1 << (BA_W + ROW_W + COL_W);
    localparam HB   = BL / 2;
    localparam NEVER = -1000000;

    reg [31:0] mem [0:NW-1];

    integer now = 0;                        // 刚结束的这个周期的编号
    integer errors = 0;
    integer n_act = 0, n_pre = 0, n_rd = 0, n_wr = 0, n_ref = 0, n_busy = 0;
    integer last_busy = 0;                  // 最后一个数据总线忙的周期

    // bank 状态
    reg     b_open [0:NB-1];
    reg [ROW_W-1:0] b_row [0:NB-1];
    integer b_act_t [0:NB-1];               // 最近一次 ACT
    integer b_pre_t [0:NB-1];               // 最近一次预充电（含自动预充电的生效时刻，可能在将来）
    integer b_rd_t  [0:NB-1];
    integer b_wr_t  [0:NB-1];
    integer last_act = NEVER, last_col = NEVER, last_rd = NEVER, last_wr = NEVER;
    integer last_ref = 0;                   // 刷新间隔从复位算起
    integer ref_t = NEVER;                  // 最近一次真正的 REF 命令（tRFC 用）
    integer act_h0 = NEVER, act_h1 = NEVER, act_h2 = NEVER, act_h3 = NEVER;   // 最近 4 次 ACT

    // 读 / 写数据窗口队列
    integer rq_t [0:15], rq_base [0:15], wq_t [0:15], wq_base [0:15];
    integer rq_h = 0, rq_n = 0, wq_h = 0, wq_n = 0;

    integer i, b, idx, off;
    reg     in_w;

    function integer imax(input integer x, input integer y);
        imax = (x > y) ? x : y;
    endfunction

    // 初值：每个存储单元一个由地址决定的伪随机值（testbench 用同一个函数计算期望）
    function [31:0] init_val(input integer k);
        init_val = (k * 32'h9E37_79B1) ^ (k >> 5) ^ 32'h5A5A_0F0F;
    endfunction

    initial begin
        for (i = 0; i < NW; i = i + 1) mem[i] = init_val(i);
        for (i = 0; i < NB; i = i + 1) begin
            b_open[i] = 1'b0; b_row[i] = 0;
            b_act_t[i] = NEVER; b_pre_t[i] = NEVER; b_rd_t[i] = NEVER; b_wr_t[i] = NEVER;
        end
        dq_rd_valid = 1'b0;
        dq_rdata    = 64'd0;
    end

    task chk(input ok, input [8*16-1:0] what);
        begin
            if (!ok) begin
                if (errors < 10)
                    $display("ERROR @cycle %0d: 违反 %0s（命令 %0d，bank %0d）", now, what, cmd, cmd_ba);
                errors = errors + 1;
            end
        end
    endtask

    always @(posedge clk) if (rst_n) begin
        now = now + 1;

        // ---------------- 本周期的写数据 ----------------
        in_w = (wq_n > 0) && (now >= wq_t[wq_h]) && (now < wq_t[wq_h] + HB);
        if (dq_wr_valid !== in_w) begin
            if (errors < 10)
                $display("ERROR @cycle %0d: 写数据时序错（dq_wr_valid=%b，应为 %b）", now, dq_wr_valid, in_w);
            errors = errors + 1;
        end
        if (in_w) begin
            off = 2 * (now - wq_t[wq_h]);
            mem[wq_base[wq_h] + off]     = dq_wdata[31:0];
            mem[wq_base[wq_h] + off + 1] = dq_wdata[63:32];
            if (now == wq_t[wq_h] + HB - 1) begin wq_h = (wq_h + 1) % 16; wq_n = wq_n - 1; end
        end
        if (in_w && dq_rd_valid) begin
            if (errors < 10) $display("ERROR @cycle %0d: 数据总线读写冲突", now);
            errors = errors + 1;
        end
        if (in_w || dq_rd_valid) begin n_busy = n_busy + 1; last_busy = now; end

        // ---------------- 命令检查与执行 ----------------
        b = cmd_ba;
        case (cmd)
            C_NOP: ;
            C_ACT: begin
                chk(!b_open[b],                     "ACT open bank");
                chk(now >= b_pre_t[b] + tRP,        "ACT tRP");
                chk(now >= b_act_t[b] + tRC,        "ACT tRC");
                chk(now >= last_act + tRRD,         "ACT tRRD");
                chk(now >= act_h3 + tFAW,           "ACT tFAW");
                chk(now >= ref_t + tRFC,            "ACT tRFC");
                b_open[b] = 1'b1; b_row[b] = cmd_row; b_act_t[b] = now;
                last_act = now;
                act_h3 = act_h2; act_h2 = act_h1; act_h1 = act_h0; act_h0 = now;
                n_act = n_act + 1;
            end
            C_RD, C_WR: begin
                chk(b_open[b],                      "RD/WR closed");
                chk(now >= b_act_t[b] + tRCD,       "RD/WR tRCD");
                chk(now >= last_col + tCCD,         "RD/WR tCCD");
                chk(cmd_col % BL == 0,              "col align");
                idx = (b << (ROW_W + COL_W)) + (b_row[b] << COL_W) + cmd_col;
                last_col = now;
                if (cmd == C_RD) begin
                    chk(now >= last_wr + tCWL + HB + tWTR, "RD tWTR");
                    rq_t[(rq_h + rq_n) % 16] = now + tCL; rq_base[(rq_h + rq_n) % 16] = idx; rq_n = rq_n + 1;
                    b_rd_t[b] = now; last_rd = now; n_rd = n_rd + 1;
                    if (cmd_ap) begin b_open[b] = 1'b0; b_pre_t[b] = imax(now + tRTP, b_act_t[b] + tRAS); end
                end else begin
                    chk(now >= last_rd + tCL + HB + 2 - tCWL, "WR rd->wr");
                    wq_t[(wq_h + wq_n) % 16] = now + tCWL; wq_base[(wq_h + wq_n) % 16] = idx; wq_n = wq_n + 1;
                    b_wr_t[b] = now; last_wr = now; n_wr = n_wr + 1;
                    if (cmd_ap) begin b_open[b] = 1'b0; b_pre_t[b] = imax(now + tCWL + HB + tWR, b_act_t[b] + tRAS); end
                end
            end
            C_PRE: begin
                chk(b_open[b],                      "PRE idle bank");
                chk(now >= b_act_t[b] + tRAS,       "PRE tRAS");
                chk(now >= b_rd_t[b] + tRTP,        "PRE tRTP");
                chk(now >= b_wr_t[b] + tCWL + HB + tWR, "PRE tWR");
                b_open[b] = 1'b0; b_pre_t[b] = now;
                n_pre = n_pre + 1;
            end
            C_REF: begin
                for (i = 0; i < NB; i = i + 1) begin
                    chk(!b_open[i],                 "REF open bank");
                    chk(now >= b_pre_t[i] + tRP,    "REF tRP");
                end
                chk(now >= ref_t + tRFC,            "REF tRFC");
                chk(now - last_ref <= 9 * tREFI,    "REF interval");
                last_ref = now;
                ref_t    = now;
                n_ref = n_ref + 1;
            end
            default: chk(1'b0, "bad cmd");
        endcase

        // ---------------- 下一个周期的读数据 ----------------
        dq_rd_valid <= 1'b0;
        if (rq_n > 0 && now + 1 >= rq_t[rq_h] && now + 1 < rq_t[rq_h] + HB) begin
            off = 2 * (now + 1 - rq_t[rq_h]);
            dq_rd_valid <= 1'b1;
            dq_rdata    <= {mem[rq_base[rq_h] + off + 1], mem[rq_base[rq_h] + off]};
            if (now + 1 == rq_t[rq_h] + HB - 1) begin rq_h = (rq_h + 1) % 16; rq_n = rq_n - 1; end
        end
    end

    // 仿真结束时调用：刷新次数是否够（平均间隔 tREFI，JEDEC 允许最多推迟 8 次）
    task final_check;
        begin
            if (n_ref < now / tREFI - 1) begin
                $display("ERROR: %0d 个周期里只刷新了 %0d 次（至少需要 %0d 次）", now, n_ref, now / tREFI - 1);
                errors = errors + 1;
            end
            if (now - last_ref > 9 * tREFI) begin
                $display("ERROR: 最后 %0d 个周期没有刷新", now - last_ref);
                errors = errors + 1;
            end
        end
    endtask
endmodule
