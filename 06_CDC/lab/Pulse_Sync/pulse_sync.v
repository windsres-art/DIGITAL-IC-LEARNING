// =============================================================================
// 脉冲同步器（toggle 型，带 busy 反馈）
//   源域：每来一个单周期脉冲，toggle 翻转一次 —— 把"脉冲"变成"电平变化"
//   目的域：toggle 打两拍同步，再用第 2、3 级做边沿检测，还原成一个目的时钟宽的脉冲
//   反馈：目的域第 2 级再同步回源域；toggle 与反馈不相等 → 上一个脉冲还在路上 → busy
//
// 为什么不能直接把脉冲打两拍：快→慢时，源脉冲可能比目的时钟周期还窄，
//   目的时钟一个沿都采不到就消失了（见 tb 的 naive 对照）。
// toggle 型的限制：两个脉冲间隔太近时，toggle 翻两次 = 没翻，脉冲被"抵消"。
//   所以源端必须在 busy=0 时才能发下一个脉冲，最小间隔约为
//   2 个目的周期（前向同步）+ 2 个源周期（反馈同步）+ 余量。
// =============================================================================
`timescale 1ns / 1ps

module pulse_sync (
    // 源时钟域
    input  clk_src,
    input  rst_src_n,
    input  pulse_src,       // 单周期脉冲
    output busy,            // 1：上一个脉冲还没被目的域确认，不能发新脉冲
    // 目的时钟域
    input  clk_dst,
    input  rst_dst_n,
    output pulse_dst        // 单周期脉冲
);
    reg       toggle_src;
    reg [2:0] sync_dst;     // [0][1] 同步器，[2] 用于边沿检测
    reg [1:0] fb_src;       // 反馈同步器

    always @(posedge clk_src or negedge rst_src_n) begin
        if (!rst_src_n)     toggle_src <= 1'b0;
        else if (pulse_src) toggle_src <= ~toggle_src;
    end

    always @(posedge clk_dst or negedge rst_dst_n) begin
        if (!rst_dst_n) sync_dst <= 3'b000;
        else            sync_dst <= {sync_dst[1:0], toggle_src};
    end

    // 边沿检测用的是已经同步好的第 1、2 级（sync_dst[1] 与 sync_dst[2]），
    // 不要用 sync_dst[0]：它可能还处在亚稳态
    assign pulse_dst = sync_dst[2] ^ sync_dst[1];

    always @(posedge clk_src or negedge rst_src_n) begin
        if (!rst_src_n) fb_src <= 2'b00;
        else            fb_src <= {fb_src[0], sync_dst[1]};
    end

    assign busy = toggle_src ^ fb_src[1];
endmodule


// 错误示范：把源脉冲当电平直接打两拍，再做上升沿检测
module pulse_sync_naive (
    input  clk_dst,
    input  rst_dst_n,
    input  pulse_src,
    output pulse_dst
);
    reg [2:0] sync_dst;
    always @(posedge clk_dst or negedge rst_dst_n) begin
        if (!rst_dst_n) sync_dst <= 3'b000;
        else            sync_dst <= {sync_dst[1:0], pulse_src};
    end
    assign pulse_dst = sync_dst[1] & ~sync_dst[2];
endmodule
