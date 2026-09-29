// =============================================================================
// Gray 码转二进制（组合逻辑），对数级写法
//   b ^= b >> 1; b ^= b >> 2; b ^= b >> 4; ...
//   每一步把"已经累积好的前缀异或"的跨度翻倍，ceil(log2 N) 级后每一位都覆盖到最高位
//   与 gray2bin.v 逐位等价，逻辑深度从 N-1 级降到 ceil(log2 N) 级
// =============================================================================
module gray2bin_log #(
    parameter N = 4
)(
    input      [N-1:0] gray,
    output reg [N-1:0] bin
);
    integer s;
    always @(*) begin
        bin = gray;
        for (s = 1; s < N; s = s * 2)
            bin = bin ^ (bin >> s);
    end
endmodule
