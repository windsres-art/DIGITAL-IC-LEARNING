// =============================================================================
// Gray 码计数器：二进制寄存器 + Gray 寄存器（异步 FIFO 指针的写法）
//   二者都由 bin_nxt 算出并直接寄存，Gray 输出来自触发器，可以安全跨域
//   比只存 Gray 多 N 个触发器，但 +1 只走一个加法器，关键路径短；
//   二进制值还能直接当 RAM 地址
// =============================================================================
module gray_cnt_dual #(
    parameter N = 4
)(
    input              clk,
    input              rst_n,
    input              en,
    output reg [N-1:0] bin,
    output reg [N-1:0] gray
);
    wire [N-1:0] bin_nxt  = bin + {{(N-1){1'b0}}, en};
    wire [N-1:0] gray_nxt = bin_nxt ^ (bin_nxt >> 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin  <= {N{1'b0}};
            gray <= {N{1'b0}};
        end else begin
            bin  <= bin_nxt;
            gray <= gray_nxt;           // 寄存 gray_nxt，而不是 assign gray = bin ^ (bin >> 1)
        end
    end
endmodule
