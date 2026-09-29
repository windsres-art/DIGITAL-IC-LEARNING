// =============================================================================
// retiming 实验：两次定点乘法 y = ((a*b) 取高 W 位) * c，总延迟 3 拍
// -----------------------------------------------------------------------------
// retime_mac（原始写法）：组合逻辑全堆在一级，后面只是打拍
//   a,b,c ─►[in reg]─► 乘法1 ─► 乘法2 ─►[p1]─►[y]
//   in reg → p1 包含两个乘法器；p1 → y 之间什么都没有，两级严重不平衡。
//
// retime_mac_manual（手工 retiming）：把 p1 往前搬到两个乘法器之间
//   a,b,c ─►[in reg]─► 乘法1 ─►[t_hi]─► 乘法2 ─►[y]
//                  c ─────────►[c_d] ───┘
//   功能和延迟（3 拍）不变。寄存器跨过乘法器 2 的两个输入往回搬时，
//   c 那一路也要补寄存器；这里 p1(16 bit) 换成 t_hi + c_d(8+8 bit)，总数恰好不变。
//
// 数据通路寄存器不带复位：带复位的寄存器搬动后复位值要重新计算，
// 很多工具只对无复位（或复位值可推导）的寄存器做 retiming。
// =============================================================================
module retime_mac #(
    parameter W = 8
)(
    input                clk,
    input      [W-1:0]   a,
    input      [W-1:0]   b,
    input      [W-1:0]   c,
    output reg [2*W-1:0] y
);
    reg  [W-1:0]   a_q, b_q, c_q;
    reg  [2*W-1:0] p1;
    wire [2*W-1:0] t = a_q * b_q;

    always @(posedge clk) begin
        a_q <= a;
        b_q <= b;
        c_q <= c;
        p1  <= t[2*W-1:W] * c_q;   // 两个乘法器都在这一级
        y   <= p1;                 // 这一级只是打拍，留给 retiming 搬
    end
endmodule

module retime_mac_manual #(
    parameter W = 8
)(
    input                clk,
    input      [W-1:0]   a,
    input      [W-1:0]   b,
    input      [W-1:0]   c,
    output reg [2*W-1:0] y
);
    reg  [W-1:0]   a_q, b_q, c_q, t_hi, c_d;
    wire [2*W-1:0] t = a_q * b_q;

    always @(posedge clk) begin
        a_q  <= a;
        b_q  <= b;
        c_q  <= c;
        t_hi <= t[2*W-1:W];       // 第 2 级：乘法 1
        c_d  <= c_q;              // c 跟着延迟一拍，和 t_hi 对齐
        y    <= t_hi * c_d;       // 第 3 级：乘法 2
    end
endmodule
