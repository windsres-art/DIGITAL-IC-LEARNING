// =============================================================================
// 为什么多 bit 总线不能直接打两拍：bit 间走线偏斜（skew）实验
//   源域：4 bit 计数器，每个 src 周期 +1（10 ns）
//   跨域走线：bit i 延时 0.4 + 0.8*i ns（模拟布线长度不同，最大偏斜 2.4 ns）
//   目的域：13 ns 时钟，两路 sync_2ff 分别同步 二进制总线 和 Gray 码总线
//
// 检查：目的端第 1 级在每个上升沿采到的值，解码后必须是 cnt 或 cnt-1（旧值或新值）
//   - 二进制：采样点落在偏斜窗口内时，会采到"部分 bit 新、部分 bit 旧"的非法值
//   - Gray 码：相邻值只差 1 bit，混合态只能是旧值或新值之一
// 期望：二进制出现非法值（演示问题），Gray 码 0 个
// =============================================================================
`timescale 1ns / 1ps

module tb_bus_skew;
    localparam integer W = 4;
    localparam integer NSAMPLE = 2000;

    reg clk_src = 0, clk_dst = 0, rst_n = 0;
    always #5.0 clk_src = ~clk_src;
    initial begin #0.37; forever #6.5 clk_dst = ~clk_dst; end

    reg  [W-1:0] cnt = 0;
    wire [W-1:0] bin_bus  = cnt;
    wire [W-1:0] gray_bus = cnt ^ (cnt >> 1);
    always @(posedge clk_src) if (rst_n) cnt <= cnt + 1'b1;

    // 每个 bit 不同的走线延时
    wire [W-1:0] bin_sk, gray_sk;
    genvar g;
    generate
        for (g = 0; g < W; g = g + 1) begin : skew
            assign #(0.4 + 0.8 * g) bin_sk[g]  = bin_bus[g];
            assign #(0.4 + 0.8 * g) gray_sk[g] = gray_bus[g];
        end
    endgenerate

    wire [W-1:0] bin_dst, gray_dst;
    sync_2ff #(.WIDTH(W)) u_bin  (.clk_dst(clk_dst), .rst_dst_n(rst_n), .din(bin_sk),  .dout(bin_dst));
    sync_2ff #(.WIDTH(W)) u_gray (.clk_dst(clk_dst), .rst_dst_n(rst_n), .din(gray_sk), .dout(gray_dst));

    function [W-1:0] gray2bin(input [W-1:0] gv);
        integer b;
        begin
            gray2bin[W-1] = gv[W-1];
            for (b = W-2; b >= 0; b = b - 1)
                gray2bin[b] = gray2bin[b+1] ^ gv[b];
        end
    endfunction

    integer n = 0, bad_bin = 0, bad_gray = 0, shown = 0;
    reg [W-1:0] v_bin, v_gray;

    // 在目的时钟上升沿读取"第 1 级此刻要采的值"（TB 读的是沿前的值）
    always @(posedge clk_dst) if (rst_n && n < NSAMPLE && $realtime > 100) begin
        n      = n + 1;
        v_bin  = bin_sk;
        v_gray = gray2bin(gray_sk);
        if (v_bin != cnt && v_bin != cnt - 1'b1) begin
            bad_bin = bad_bin + 1;
            if (shown < 3) begin
                $display("  t=%7.2f  old=%b new=%b  binary sync captured=%b  <- 非法值",
                         $realtime, cnt - 1'b1, cnt, v_bin);
                shown = shown + 1;
            end
        end
        if (v_gray != cnt && v_gray != cnt - 1'b1)
            bad_gray = bad_gray + 1;
    end

    initial begin
        $dumpfile("bus_skew.vcd");
        $dumpvars(0, tb_bus_skew);
        #20 rst_n = 1;
        wait (n == NSAMPLE);
        $display("----------------------------------------------------------");
        $display("samples=%0d  binary incoherent=%0d  gray incoherent=%0d", n, bad_bin, bad_gray);
        $display("----------------------------------------------------------");
        if (bad_bin > 0 && bad_gray == 0) $display("PASS");
        else                              $display("FAIL");
        $finish;
    end
endmodule
