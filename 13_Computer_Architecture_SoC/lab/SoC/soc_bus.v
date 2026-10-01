// =============================================================================
// 2 主 × 6 从的交叉开关（crossbar），外加默认从机（default slave）
//   主口 M0 = 核的数据口，M1 = DMA 主口。握手与核的数据口相同：
//     请求（re 或 wstrb ≠ 0）保持到 ready；err 与 ready 同拍有效
//   从口 s_sel[k] = 1 表示本拍有主机在访问从机 k；从机给出 s_ready / s_err / s_rdata
//   地址映射：
//     S0 ROM    0x0000_0000 – 0x0000_3FFF        S1 RAM   0x1000_0000 – 0x1000_3FFF
//     S2 CLINT  0x0200_0000 – 0x0200_FFFF        S3 PLIC  0x0C00_0000 – 0x0C3F_FFFF
//     S4 APB    0x2000_0000 – 0x2000_0FFF        S5 DMA   0x2000_1000 – 0x2000_1FFF
//     其它      默认从机：立即 ready + err（核产生访问错误异常，DMA 置 ERR）
//   仲裁：每个从机一个轮转（round-robin）指针。两个主机同时访问同一个从机时，
//         上次输给对方的那个优先；访问不同从机时互不影响（交叉开关的意义）
// =============================================================================
module soc_bus #(
    parameter NS = 6
)(
    input              clk,
    input              rst_n,
    // 主口 0：核
    input      [31:0]  m0_addr,
    input              m0_re,
    input      [3:0]   m0_wstrb,
    input      [31:0]  m0_wdata,
    output     [31:0]  m0_rdata,
    output             m0_ready,
    output             m0_err,
    // 主口 1：DMA
    input      [31:0]  m1_addr,
    input              m1_re,
    input      [3:0]   m1_wstrb,
    input      [31:0]  m1_wdata,
    output     [31:0]  m1_rdata,
    output             m1_ready,
    output             m1_err,
    // 从口（扁平化：从机 k 占 [32k +: 32] / [4k +: 4]）
    output     [NS-1:0]    s_sel,
    output     [NS-1:0]    s_we,
    output     [32*NS-1:0] s_addr,
    output     [32*NS-1:0] s_wdata,
    output     [4*NS-1:0]  s_wstrb,
    input      [32*NS-1:0] s_rdata,
    input      [NS-1:0]    s_ready,
    input      [NS-1:0]    s_err,
    // 统计：本拍 M0 因为 M1 占着同一个从机而等待
    output             perf_m0_blocked
);
    localparam [2:0] S_ERR = 3'd7;

    function [2:0] decode(input [19:0] a);      // a = 地址 [31:12]
        begin
            if      (a[19:2] == 18'h00000)  decode = 3'd0;
            else if (a[19:2] == 18'h04000)  decode = 3'd1;
            else if (a[19:4] == 16'h0200)   decode = 3'd2;
            else if (a[19:10] == 10'h030)   decode = 3'd3;
            else if (a == 20'h20000)        decode = 3'd4;
            else if (a == 20'h20001)        decode = 3'd5;
            else                            decode = S_ERR;
        end
    endfunction

    wire       r0 = m0_re | (|m0_wstrb);
    wire       r1 = m1_re | (|m1_wstrb);
    wire [2:0] t0 = decode(m0_addr[31:12]);
    wire [2:0] t1 = decode(m1_addr[31:12]);

    reg  [NS-1:0] rr;                       // rr[k] = 1：从机 k 下次冲突时 M1 优先
    wire [NS-1:0] g1;                       // 从机 k 本拍授权给 M1
    wire [NS-1:0] want0, want1;

    genvar k;
    generate
        for (k = 0; k < NS; k = k + 1) begin : g_slave
            assign want0[k] = r0 && t0 == k;
            assign want1[k] = r1 && t1 == k;
            assign g1[k]    = want1[k] && (!want0[k] || rr[k]);
            assign s_sel[k] = want0[k] | want1[k];
            assign s_we[k]  = g1[k] ? (|m1_wstrb) : (|m0_wstrb);
            assign s_addr [32*k +: 32] = g1[k] ? m1_addr  : m0_addr;
            assign s_wdata[32*k +: 32] = g1[k] ? m1_wdata : m0_wdata;
            assign s_wstrb[4*k +: 4]   = g1[k] ? m1_wstrb : m0_wstrb;
        end
    endgenerate

    // 主机看到的结果
    wire       hit0 = (t0 != S_ERR) && !g1[t0];          // M0 拿到了它要的从机
    wire       hit1 = (t1 != S_ERR) &&  g1[t1];
    assign m0_ready = r0 && ((t0 == S_ERR) || (hit0 && s_ready[t0]));
    assign m0_err   = r0 && ((t0 == S_ERR) || (hit0 && s_err[t0]));
    assign m0_rdata = (t0 == S_ERR) ? 32'd0 : s_rdata[32*t0 +: 32];
    assign m1_ready = r1 && ((t1 == S_ERR) || (hit1 && s_ready[t1]));
    assign m1_err   = r1 && ((t1 == S_ERR) || (hit1 && s_err[t1]));
    assign m1_rdata = (t1 == S_ERR) ? 32'd0 : s_rdata[32*t1 +: 32];
    assign perf_m0_blocked = r0 && (t0 != S_ERR) && g1[t0];

    // 一次冲突的传输完成后，把优先权交给输的那一方
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rr <= {NS{1'b0}};
        else
            for (j = 0; j < NS; j = j + 1)
                if (want0[j] && want1[j] && s_ready[j]) rr[j] <= !g1[j];
    end
endmodule
