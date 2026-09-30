// =============================================================================
// UART testbench（自检查）
//   clk 100 MHz，DIV = 4 → 16x tick 25 MHz → 1 位 = 64 clk = 640 ns（1.5625 Mbps）
//   检查：
//     - TX 线检查器：独立于 RTL，看到下降沿后在理想位中心采样，核对起始/数据/校验/停止位
//     - RX 输出检查器：按期望队列比对 data / parity_err / frame_err
//   阶段：
//     P1 环回：uart_tx → uart_rx，300 字节背靠背
//     P2 波特率偏差扫描：TB 按 (1+δ) 倍位宽发送，统计 200 帧中正确的帧数（只统计，不判错）
//     P3 噪声：每个数据位中心附近 30 ns 反相毛刺（< 1 个 tick）；1~5 tick 宽的假起始脉冲
//     P4 错误注入：停止位为 0 → frame_err；校验位取反 → parity_err（有校验时）
//   PASS 条件：P1/P3/P4 全对，P2 中 |δ| ≤ 3% 全对
// =============================================================================
`timescale 1ns / 1ps

module tb_uart;
    parameter PARITY = 0;
    parameter STOP   = 1;
    localparam DIV    = 4;
    localparam real BIT_NS = 16 * DIV * 10.0;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire tick;
    uart_baud #(.DIV(DIV)) u_baud (.clk(clk), .rst_n(rst_n), .tick(tick));

    reg  [7:0] tx_data = 0;
    reg        tx_valid = 0;
    wire       tx_ready, txd;
    uart_tx #(.PARITY(PARITY), .STOP(STOP)) u_tx (
        .clk(clk), .rst_n(rst_n), .tick(tick),
        .data(tx_data), .valid(tx_valid), .ready(tx_ready), .txd(txd));

    reg  use_line = 0, line = 1;
    wire rxd = use_line ? line : txd;
    wire [7:0] rx_data;
    wire       rx_valid, rx_perr, rx_ferr;
    uart_rx #(.PARITY(PARITY)) u_rx (
        .clk(clk), .rst_n(rst_n), .tick(tick), .rxd(rxd),
        .data(rx_data), .valid(rx_valid), .parity_err(rx_perr), .frame_err(rx_ferr));

    integer errors = 0;
    task err(input [8*48-1:0] msg);
        begin
            if (errors < 10) $display("ERROR @%0t: %0s", $time, msg);
            errors = errors + 1;
        end
    endtask

    function par_of(input [7:0] b);
        par_of = (PARITY == 1) ? ~^b : ^b;
    endfunction

    // ---------------- TX 线检查器 ----------------
    reg [7:0] txq [0:1023];
    integer   txq_w = 0, txq_r = 0, n_tx_chk = 0;
    reg [7:0] cap;
    reg       pb;
    integer   k;
    initial begin
        forever begin
            @(negedge txd);
            #(BIT_NS / 2);
            if (txd !== 1'b0) err("TX start bit not low at center");
            for (k = 0; k < 8; k = k + 1) begin #(BIT_NS); cap[k] = txd; end
            if (PARITY != 0) begin
                #(BIT_NS); pb = txd;
                if (pb !== par_of(cap)) err("TX parity bit wrong");
            end
            for (k = 0; k < STOP; k = k + 1) begin
                #(BIT_NS); if (txd !== 1'b1) err("TX stop bit not high");
            end
            if (txq_r == txq_w) err("TX frame not requested");
            else begin
                if (cap !== txq[txq_r % 1024]) err("TX data mismatch");
                txq_r = txq_r + 1; n_tx_chk = n_tx_chk + 1;
            end
        end
    end

    // ---------------- RX 输出检查器 ----------------
    reg [9:0] rq [0:1023];          // {frame_err, parity_err, data}
    integer   rq_w = 0, rq_r = 0;
    reg       sweep = 0;
    integer   n_ok = 0, n_bad = 0, n_extra = 0, n_rx = 0;
    always @(posedge clk) if (rx_valid) begin
        n_rx = n_rx + 1;
        if (rq_r == rq_w) begin
            n_extra = n_extra + 1;
            if (!sweep) err("RX frame not expected");
        end else begin
            if ({rx_ferr, rx_perr, rx_data} === rq[rq_r % 1024]) n_ok = n_ok + 1;
            else begin
                n_bad = n_bad + 1;
                if (!sweep) begin
                    if (errors < 10) $display("  got {ferr,perr,data}=%b expect=%b", {rx_ferr, rx_perr, rx_data}, rq[rq_r % 1024]);
                    err("RX frame mismatch");
                end
            end
            rq_r = rq_r + 1;
        end
    end

    // ---------------- TB 串口发送模型 ----------------
    // d：位宽相对偏差；bad_par / bad_stop：注入错误；glitch：数据位中心附近加 30 ns 反相
    task send_line(input [7:0] b, input real d, input bad_par, input bad_stop, input glitch);
        real    T, off;
        integer j;
        reg     v;
        begin
            T = BIT_NS * (1.0 + d);
            rq[rq_w % 1024] = {bad_stop, (PARITY != 0) && bad_par, b};
            rq_w = rq_w + 1;
            line = 1'b0; #(T);
            for (j = 0; j < 8; j = j + 1) begin
                v = b[j];
                line = v;
                if (glitch) begin
                    off = (($urandom % 81) - 40) * 1.0;                 // 中心 ±40 ns
                    #(T / 2 + off - 15); line = ~v; #(30); line = v; #(T / 2 - off - 15);
                end else #(T);
            end
            if (PARITY != 0) begin line = par_of(b) ^ bad_par; #(T); end
            line = ~bad_stop; #(T);
            line = 1'b1;
        end
    endtask

    task tx_send(input [7:0] b);
        begin
            @(negedge clk);
            tx_valid = 1; tx_data = b;
            @(posedge clk); while (!tx_ready) @(posedge clk);
            txq[txq_w % 1024] = b; txq_w = txq_w + 1;
            rq[rq_w % 1024] = {2'b00, b}; rq_w = rq_w + 1;
            #1 tx_valid = 0;
        end
    endtask

    integer i, n, pct_i, fs_before, gpass;
    real    dlt;
    integer pcts [0:12];
    initial begin
        $dumpfile("uart.vcd");
        $dumpvars(0, tb_uart);
        pcts[0] = -60; pcts[1] = -50; pcts[2] = -45; pcts[3] = -40; pcts[4] = -30; pcts[5] = -20;
        pcts[6] = 0;   pcts[7] = 20;  pcts[8] = 30;  pcts[9] = 40;  pcts[10] = 45; pcts[11] = 50;
        pcts[12] = 60;                                  // 单位 0.1%
        #22 rst_n = 1;
        #1000;

        // P1 环回（valid 在 ready 前就拉高、握手后下一帧立刻装载 → 背靠背）
        for (i = 0; i < 300; i = i + 1) tx_send($urandom);
        wait (tx_ready); #(BIT_NS * 3);
        $display("--------------------------------------------------------------");
        $display("config 8%s%0d | P1 loopback: TX frames checked=%0d  RX ok=%0d",
                 (PARITY == 0) ? "N" : (PARITY == 1) ? "O" : "E", STOP, n_tx_chk, n_ok);
        if (n_tx_chk != 300 || n_ok != 300) err("P1 count mismatch");

        // P2 波特率偏差扫描（波形只录 P1，后面的阶段太长）
        $dumpoff;
        use_line = 1; sweep = 1;
        $display("P2 baud offset sweep (200 frames each, 1.5-bit idle gap):");
        for (pct_i = 0; pct_i < 13; pct_i = pct_i + 1) begin
            dlt = pcts[pct_i] / 1000.0;
            n_ok = 0; n_bad = 0; n_extra = 0; n = 0; rq_r = rq_w;
            for (i = 0; i < 200; i = i + 1) begin
                send_line($urandom, dlt, 0, 0, 0);
                #(BIT_NS * 1.5);
                if (rq_r != rq_w) begin n = n + 1; rq_r = rq_w; end   // 这一帧没收到
            end
            #(BIT_NS * 4);
            $display("   offset %5.1f%% : ok %3d  bad %3d  lost %3d  extra %2d",
                     pcts[pct_i] / 10.0, n_ok, n_bad, n, n_extra);
            if ((pcts[pct_i] <= 30 && pcts[pct_i] >= -30) && (n_ok != 200 || n_extra != 0))
                err("frames lost within +-3%");
            rq_r = rq_w;
        end
        sweep = 0;

        // P3 噪声
        n_ok = 0;
        for (i = 0; i < 200; i = i + 1) begin send_line($urandom, 0.0, 0, 0, 1); #(BIT_NS); end
        #(BIT_NS * 4);
        gpass = n_ok;
        fs_before = n_rx;
        for (i = 0; i < 100; i = i + 1) begin
            line = 0; #(40.0 * (1 + i % 5)); line = 1;          // 1~5 个 tick 宽的低脉冲
            #(BIT_NS * 2);
        end
        $display("P3 noise: glitched frames ok=%0d/200  false-start pulses -> frames=%0d/100",
                 gpass, n_rx - fs_before);
        if (gpass != 200)           err("glitch frames corrupted");
        if (n_rx != fs_before)      err("false start accepted");

        // P4 错误注入
        n_ok = 0;
        for (i = 0; i < 50; i = i + 1) begin send_line($urandom, 0.0, 0, 1, 0); #(BIT_NS * 2); end
        if (PARITY != 0)
            for (i = 0; i < 50; i = i + 1) begin send_line($urandom, 0.0, 1, 0, 0); #(BIT_NS * 2); end
        #(BIT_NS * 4);
        $display("P4 error inject: flagged correctly=%0d/%0d", n_ok, (PARITY != 0) ? 100 : 50);
        if (n_ok != ((PARITY != 0) ? 100 : 50)) err("error flags wrong");

        $display("--------------------------------------------------------------");
        if (rq_r != rq_w) err("RX queue not drained");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
