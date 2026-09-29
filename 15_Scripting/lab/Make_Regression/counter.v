// =============================================================================
// 可加载计数器：Makefile 与回归脚本实验的被测电路（电路本身很简单，重点在流程）
// -----------------------------------------------------------------------------
//   优先级 load > en；计到全 1 后再加 1 回绕到 0，同时 wrap 拉高一拍
//   编译时加 -DINJECT_BUG 会打开一个故意埋的 corner case bug，
//   用来演示“回归要跑多种子、多配置，还要有 corner 偏置”
// =============================================================================
`timescale 1ns/1ps

module counter #(
    parameter W = 8
)(
    input              clk,
    input              rst_n,
    input              en,
    input              load,
    input      [W-1:0] load_val,
    output reg [W-1:0] cnt,
    output reg         wrap
);
    localparam [W-1:0] ONE = 1;   // 写成 cnt + 1'b1 时 Verilator -Wall 会报位宽不匹配

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= {W{1'b0}};
            wrap <= 1'b0;
        end else begin
            wrap <= 1'b0;
`ifdef INJECT_BUG
            // bug：load 与 en 同时有效且装载值为全 1 时，错误地走了计数分支
            if (load && !(en && (&load_val))) begin
`else
            if (load) begin
`endif
                cnt <= load_val;
            end else if (en) begin
                cnt  <= cnt + ONE;
                wrap <= &cnt;
            end
        end
    end

endmodule
