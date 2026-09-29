// =============================================================================
// 通用移位寄存器（类似 74x194）
//   mode 00 保持 | 01 右移（ser_msb 从最高位移入）| 10 左移（ser_lsb 从最低位移入）
//        11 并行置数
//   移位寄存器就是一串首尾相接的 D 触发器；用 <= 写成一句拼接，综合出来就是
//   WIDTH 个触发器加一个 4 选 1 MUX
// =============================================================================
module shift_reg #(
    parameter WIDTH = 8
)(
    input                  clk,
    input                  rst_n,
    input      [1:0]       mode,
    input                  ser_msb,
    input                  ser_lsb,
    input      [WIDTH-1:0] din,
    output reg [WIDTH-1:0] q
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) q <= {WIDTH{1'b0}};
        else begin
            case (mode)
                2'b01:   q <= {ser_msb, q[WIDTH-1:1]};
                2'b10:   q <= {q[WIDTH-2:0], ser_lsb};
                2'b11:   q <= din;
                default: q <= q;
            endcase
        end
    end

endmodule
