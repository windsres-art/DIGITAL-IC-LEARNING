// =============================================================================
// Gray 码计数器：只存 Gray
//   Gray → 二进制 → +1 → Gray → 寄存
//   省 N 个触发器，但 Gray 转二进制是前缀异或链，后面再串一个加法器，组合路径长
// =============================================================================
module gray_cnt_pure #(
    parameter N = 4
)(
    input              clk,
    input              rst_n,
    input              en,
    output reg [N-1:0] gray
);
    reg     [N-1:0] b;
    integer         i;
    always @(*) begin
        b[N-1] = gray[N-1];
        for (i = N - 2; i >= 0; i = i - 1)
            b[i] = b[i+1] ^ gray[i];
    end

    wire [N-1:0] b_nxt = b + {{(N-1){1'b0}}, en};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) gray <= {N{1'b0}};
        else        gray <= b_nxt ^ (b_nxt >> 1);
    end
endmodule
