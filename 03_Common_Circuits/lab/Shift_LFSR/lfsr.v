// =============================================================================
// 线性反馈移位寄存器（LFSR），异或型，两种结构可选
//   TAPS：抽头掩码，抽头编号 k（1..N）对应 bit k-1，最高位（抽头 N）必须为 1。
//         例：N=8 抽头 8,6,5,4 → 8'b1011_1000，对应多项式 x^8+x^6+x^5+x^4+1
//   GALOIS=0 Fibonacci（外部异或）：各抽头异或后移入最低位，异或是多输入串联，
//            抽头多时反馈路径长
//   GALOIS=1 Galois（内部异或）：移出的最高位异或进各抽头位置，每级最多一个
//            2 输入异或，适合高频
//   两种结构用同一个本原多项式都是最大长度 2^N-1，但输出序列不同（互为逆序）。
//   全 0 是异或型 LFSR 的死状态（0 异或任何抽头还是 0），SEED 不能为 0。
// =============================================================================
module lfsr #(
    parameter           N      = 8,
    parameter [N-1:0]   TAPS   = 8'b1011_1000,
    parameter           GALOIS = 0,
    parameter [N-1:0]   SEED   = {{(N-1){1'b0}}, 1'b1}
)(
    input              clk,
    input              rst_n,
    input              en,
    output reg [N-1:0] q,
    output             out              // 串行输出（伪随机比特流）
);
    // Galois 的异或掩码 = 多项式去掉 x^N 后的低 N 位：抽头 k(<N) 放到 bit k，常数项放到 bit 0
    localparam [N-1:0] GMASK = {TAPS[N-2:0], 1'b1};

    wire fib_fb = ^(q & TAPS);

    assign out = q[N-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            q <= SEED;
        else if (en) begin
            if (GALOIS) q <= {q[N-2:0], 1'b0} ^ (q[N-1] ? GMASK : {N{1'b0}});
            else        q <= {q[N-2:0], fib_fb};
        end
    end

endmodule
