// =============================================================================
// 复位同步器：异步复位、同步释放（asynchronous assert, synchronous deassert）
//   arst_n 拉低 → 所有级立刻清 0，srst_n 立即有效（不需要时钟）
//   arst_n 释放 → 常量 1 从第 0 级逐拍移入，STAGES 个时钟上升沿后 srst_n 才释放
//
// 常见错误：
//   1. 把 arst_n 接到 D 端、用普通两级同步器同步 —— 复位拉起也要等时钟，
//      时钟没起振时复位不了，失去了异步复位的意义
//   2. 第 0 级的 D 接 arst_n 而不是常量 1 —— arst_n 本身会进入数据路径，
//      综合/CDC 工具会把它当成异步信号跨域报出来
//   3. 多个时钟域共用一个复位同步器 —— 同步释放只对它自己的时钟有效
// =============================================================================
`timescale 1ns / 1ps

module reset_sync #(
    parameter STAGES = 2          // >= 2；高频或 MTBF 要求高时用 3
)(
    input  clk,
    input  arst_n,                // 外部异步复位，低有效
    output srst_n                 // 本时钟域使用的复位：拉起异步、释放同步
);
    reg [STAGES-1:0] sync;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            sync <= {STAGES{1'b0}};
        else
            sync <= {sync[STAGES-2:0], 1'b1};
    end

    assign srst_n = sync[STAGES-1];
endmodule
