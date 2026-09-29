// =============================================================================
// Johnson 计数器（扭环形计数器）：左移，把最高位取反后移入最低位
//   N=4：0000→0001→0011→0111→1111→1110→1100→1000→0000，共 2N 个状态
//   - 每拍只有 1 bit 翻转（和 Gray 码一样），译码每个状态只要一个 2 输入与门
//   - 合法状态的特征：相邻位之间至多有一处不同（形如 0..01..1 或 1..10..0）；
//     其余 2^N - 2N 个是非法状态，普通 Johnson 计数器进入后会在非法环里转，
//     这里检测到非法就清 0（自启动）
// =============================================================================
module counter_johnson #(
    parameter N          = 4,           // >= 3
    parameter SELF_START = 1            // 0：去掉非法状态检测，仅用于演示
)(
    input              clk,
    input              rst_n,
    input              en,
    output reg [N-1:0] q
);
    localparam [N-2:0] ONE = {{(N-2){1'b0}}, 1'b1};

    // trans[i]=1 表示 q[i+1] 和 q[i] 不同；合法 ⇔ trans 至多一个 1
    wire [N-2:0] trans = q[N-1:1] ^ q[N-2:0];
    wire         legal = ((trans & (trans - ONE)) == {(N-1){1'b0}});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      q <= {N{1'b0}};
        else if (SELF_START && !legal) q <= {N{1'b0}};
        else if (en)     q <= {q[N-2:0], ~q[N-1]};
    end

endmodule
