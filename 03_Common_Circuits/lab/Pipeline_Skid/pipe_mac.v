// =============================================================================
// 3 级流水线乘加：y = sat( a * b + c )，带 valid/ready 反压
//   S1: p = a * b          S2: s = p + c（多 1 位进位）     S3: y = 饱和到 2*DW 位
//   每级一个 valid 位随数据往下走；两种反压方式由 MODE 选择：
//   MODE = 0 全局停顿（global stall）：stall = v3 & ~out_ready，所有级一起停。
//            控制最简单，但停顿时流水线里的气泡（valid=0 的级）也一起停住，
//            挤不掉
//   MODE = 1 逐级握手（气泡可压缩）：en_i = ~v_i | en_{i+1}，本级空或者本级数据
//            会被下一级取走就能前进，停顿时空的级照样收数据
//   两种方式 in_ready 都是 out_ready 经组合逻辑穿过全部级得到的——级数多、
//   扇出大（真实流水线每级几百个寄存器的使能）时就是关键路径，见 skid_buffer.v
// =============================================================================
module pipe_mac #(
    parameter DW   = 8,
    parameter MODE = 1
)(
    input                 clk,
    input                 rst_n,
    input                 in_valid,
    output                in_ready,
    input      [DW-1:0]   a,
    input      [DW-1:0]   b,
    input      [2*DW-1:0] c,
    output                out_valid,
    input                 out_ready,
    output     [2*DW-1:0] y
);
    reg            v1, v2, v3;
    reg [2*DW-1:0] p1, c1;          // S1 结果；c 跟着数据一起打拍，保持对齐
    reg [2*DW:0]   s2;
    reg [2*DW-1:0] y3;

    wire en1, en2, en3;
    generate
        if (MODE == 0) begin : g_global
            wire stall = v3 & ~out_ready;
            assign en3 = ~stall;
            assign en2 = ~stall;
            assign en1 = ~stall;
        end else begin : g_local
            assign en3 = ~v3 | out_ready;
            assign en2 = ~v2 | en3;
            assign en1 = ~v1 | en2;
        end
    endgenerate

    assign in_ready  = en1;
    assign out_valid = v3;
    assign y         = y3;

    // 控制通路（valid）复位；数据通路不复位，只在本级接收有效数据时更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0;
            v2 <= 1'b0;
            v3 <= 1'b0;
        end else begin
            if (en1) v1 <= in_valid;
            if (en2) v2 <= v1;
            if (en3) v3 <= v2;
        end
    end

    always @(posedge clk) begin
        if (en1 && in_valid) begin
            p1 <= a * b;
            c1 <= c;
        end
        if (en2 && v1) s2 <= {1'b0, p1} + {1'b0, c1};
        if (en3 && v2) y3 <= s2[2*DW] ? {(2*DW){1'b1}} : s2[2*DW-1:0];
    end

endmodule
