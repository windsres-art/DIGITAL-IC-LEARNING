// =============================================================================
// 时钟切换（clock switching）三种写法
//   clk_mux_bad   : 普通 MUX —— 错误示范，sel 在任意时刻变化都可能切出毛刺
//   clk_mux_sync  : 两个时钟同源（有确定相位关系，如 clk 和 clk/2）时的无毛刺切换
//   clk_mux_async : 两个时钟互为异步时的无毛刺切换（每路多一级同步）
//
// 无毛刺的核心思想（两条同时满足）：
//   1. 先关后开：交叉反馈保证"当前时钟的使能先撤掉，另一个时钟的使能才能打开"
//   2. 使能只在各自时钟的**低电平**期间变化：用下降沿寄存器产生使能，
//      再和时钟相与 —— 与 ICG 用低电平 latch 是同一个道理
// =============================================================================
`timescale 1ns / 1ps

module clk_mux_bad (
    input  clk0,
    input  clk1,
    input  sel,
    output clk_out
);
    assign clk_out = sel ? clk1 : clk0;
endmodule


// 同源时钟：每路一个下降沿寄存器即可
// 前提：sel 与两个时钟都有确定相位关系，不会引起亚稳态
module clk_mux_sync (
    input  clk0,
    input  clk1,
    input  rst_n,
    input  sel,        // 0 选 clk0，1 选 clk1
    output clk_out
);
    reg en0, en1;

    // 交叉反馈：~en1 保证 clk1 那一路已关闭，clk0 才能打开
    always @(negedge clk0 or negedge rst_n) begin
        if (!rst_n) en0 <= 1'b0;
        else        en0 <= ~sel & ~en1;
    end

    always @(negedge clk1 or negedge rst_n) begin
        if (!rst_n) en1 <= 1'b0;
        else        en1 <= sel & ~en0;
    end

    assign clk_out = (clk0 & en0) | (clk1 & en1);
endmodule


// 异步时钟：sel 和对侧反馈 en 对本时钟都是异步信号，要先同步
//   第 1 级：本时钟上升沿采样（可能亚稳），第 2 级：本时钟下降沿输出使能
//   第 2 级用下降沿，保证使能只在本时钟低电平时变化
// 注意：第 1 级到第 2 级只有半个周期的亚稳态恢复时间；高频下可改成两级上升沿同步
//       + 一级下降沿寄存器，代价是切换延迟多一拍
module clk_mux_async (
    input  clk0,
    input  clk1,
    input  rst_n,
    input  sel,
    output clk_out
);
    reg en0_meta, en0;
    reg en1_meta, en1;

    always @(posedge clk0 or negedge rst_n) begin
        if (!rst_n) en0_meta <= 1'b0;
        else        en0_meta <= ~sel & ~en1;
    end
    always @(negedge clk0 or negedge rst_n) begin
        if (!rst_n) en0 <= 1'b0;
        else        en0 <= en0_meta;
    end

    always @(posedge clk1 or negedge rst_n) begin
        if (!rst_n) en1_meta <= 1'b0;
        else        en1_meta <= sel & ~en0;
    end
    always @(negedge clk1 or negedge rst_n) begin
        if (!rst_n) en1 <= 1'b0;
        else        en1 <= en1_meta;
    end

    assign clk_out = (clk0 & en0) | (clk1 & en1);
endmodule
