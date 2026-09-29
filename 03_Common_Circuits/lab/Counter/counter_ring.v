// =============================================================================
// 环形计数器（ring counter）：N 个触发器里只有一个 1，每拍循环左移
//   - 状态数 N，天然独热码，译码不需要任何逻辑（q[i] 就是"第 i 个状态"）
//   - N 个触发器只能表示 N 个状态，2^N - N 个是非法状态（全 0、多个 1）。
//     普通移位环一旦进入非法状态（上电、SEU）就永远出不来，所以加自启动：
//     检测到非独热就拉回初始状态。
// =============================================================================
module counter_ring #(
    parameter N          = 4,
    parameter SELF_START = 1            // 0：去掉非法状态检测，仅用于演示
)(
    input              clk,
    input              rst_n,
    input              en,
    output reg [N-1:0] q
);
    localparam [N-1:0] INIT = {{(N-1){1'b0}}, 1'b1};

    // 独热：非 0 且 q & (q-1) == 0（去掉最低位的 1 后为 0）
    wire legal = (q != {N{1'b0}}) && ((q & (q - INIT)) == {N{1'b0}});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      q <= INIT;
        else if (SELF_START && !legal) q <= INIT;
        else if (en)     q <= {q[N-2:0], q[N-1]};
    end

endmodule
