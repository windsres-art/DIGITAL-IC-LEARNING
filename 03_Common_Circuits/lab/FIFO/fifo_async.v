// =============================================================================
// 异步 FIFO（整理版，Cummings 风格）
//   与同目录早期版本 FIFO.v 功能相同，区别：
//   1. Gray 指针由寄存器直接输出（wgray/rgray 是触发器），再送去跨域。
//      FIFO.v 里 Gray 是二进制寄存器后面的组合 XOR，组合输出在二进制多位
//      同时翻转时可能出毛刺，被对侧时钟采到就是错误指针——违反"跨域信号必须
//      来自寄存器"的规则。RTL 仿真看不出来，CDC 工具会报。
//   2. full / empty 也用寄存器输出，用本域"下一拍的指针"提前比较：本域的写/读
//      造成的满/空在同一拍就反映出来；对侧指针的变化则比组合比较晚 1 拍被看到
//      （更保守，仍然安全）。
//   3. 存储体不带复位，可以映射成双口 SRAM。
//   要求 AW >= 2（满判断要取 Gray 指针的高 2 位）。
// =============================================================================
module fifo_async #(
    parameter DW = 8,
    parameter AW = 4                    // 深度 = 2^AW
)(
    // 写时钟域
    input               wclk,
    input               wrst_n,
    input               wr_en,
    input      [DW-1:0] wdata,
    output reg          wfull,
    // 读时钟域
    input               rclk,
    input               rrst_n,
    input               rd_en,
    output reg [DW-1:0] rdata,
    output reg          rempty
);
    localparam DEPTH = 1 << AW;

    reg [DW-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wbin, wgray;
    reg  [AW:0] rbin, rgray;
    reg  [AW:0] rgray_w1, rgray_w2;     // 读 Gray 同步到写域（两级）
    reg  [AW:0] wgray_r1, wgray_r2;     // 写 Gray 同步到读域（两级）

    // ------------------------------ 写域 ------------------------------
    wire        wr_fire   = wr_en & ~wfull;
    wire [AW:0] wbin_nxt  = wbin + {{AW{1'b0}}, wr_fire};
    wire [AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
            wfull <= 1'b0;
        end else begin
            wbin  <= wbin_nxt;
            wgray <= wgray_nxt;
            // 满：写 Gray 与"读 Gray 高 2 位取反、其余相同"相等
            wfull <= (wgray_nxt == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
        end
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rgray_w1 <= {(AW+1){1'b0}};
            rgray_w2 <= {(AW+1){1'b0}};
        end else begin
            rgray_w1 <= rgray;          // 第 1 级可能亚稳，不给任何逻辑用
            rgray_w2 <= rgray_w1;
        end
    end

    always @(posedge wclk) begin
        if (wr_fire) mem[wbin[AW-1:0]] <= wdata;
    end

    // ------------------------------ 读域 ------------------------------
    wire        rd_fire   = rd_en & ~rempty;
    wire [AW:0] rbin_nxt  = rbin + {{AW{1'b0}}, rd_fire};
    wire [AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin   <= {(AW+1){1'b0}};
            rgray  <= {(AW+1){1'b0}};
            rempty <= 1'b1;             // 复位后为空
        end else begin
            rbin   <= rbin_nxt;
            rgray  <= rgray_nxt;
            rempty <= (rgray_nxt == wgray_r2);
        end
    end

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wgray_r1 <= {(AW+1){1'b0}};
            wgray_r2 <= {(AW+1){1'b0}};
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
        end
    end

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n)      rdata <= {DW{1'b0}};
        else if (rd_fire) rdata <= mem[rbin[AW-1:0]];
    end

endmodule
