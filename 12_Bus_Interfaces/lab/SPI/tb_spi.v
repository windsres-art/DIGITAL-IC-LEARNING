// =============================================================================
// SPI testbench（自检查）：spi_master ↔ spi_slave
//   每笔传输双向比对：主机收到 = 从机发的，从机收到 = 主机发的。
//   引脚级监视器（独立于 RTL，只按模式定义解码）：
//     - CS 下降时 SCLK 必须在空闲电平（CPOL），CS 无效时 SCLK 不许翻转
//     - 在采样沿直接采 MOSI / MISO 引脚，每个 CS 期间必须正好 8 个采样沿，解码值与期望一致
//   阶段：
//     P1 4 种模式 × 250 字节，div 随机 4..8（监视器开启）
//     P2 主从模式不匹配矩阵：16 种组合各 50 字节，统计两个方向正确的字节数
//     P3 分频扫描：div = 1..6，每种模式 50 字节（过采样从机需要多快的系统时钟）
//   PASS 条件：P1 全对，P2 对角线全对，P3 div ≥ 4 全对
// =============================================================================
`timescale 1ns / 1ps

module tb_spi;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        m_cpol = 0, m_cpha = 0, s_cpol = 0, s_cpha = 0;
    reg  [7:0] div = 4;
    reg        start = 0;
    reg  [7:0] m_tx = 0, s_tx = 0;
    wire [7:0] m_rx, s_rx;
    wire       busy, done, s_rx_valid;
    wire       sclk, cs_n, mosi, s_miso, s_miso_oe;
    wire       miso = s_miso_oe ? s_miso : 1'bz;

    spi_master u_m (
        .clk(clk), .rst_n(rst_n), .cpol(m_cpol), .cpha(m_cpha), .div(div),
        .start(start), .tx(m_tx), .busy(busy), .done(done), .rx(m_rx),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(miso));

    spi_slave u_s (
        .clk(clk), .rst_n(rst_n), .cpol(s_cpol), .cpha(s_cpha),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(s_miso), .miso_oe(s_miso_oe),
        .tx_data(s_tx), .rx_data(s_rx), .rx_valid(s_rx_valid));

    integer errors = 0;
    task err(input [8*48-1:0] msg);
        begin
            if (errors < 10) $display("ERROR @%0t: %0s", $time, msg);
            errors = errors + 1;
        end
    endtask

    // ---------------- 引脚级监视器 ----------------
    reg       mon_on = 0;
    integer   mbits = 0, n_mon = 0;
    reg [7:0] mon_mosi, mon_miso;
    always @(negedge cs_n) if (mon_on) begin
        if (sclk !== m_cpol) err("CS fell with SCLK not at CPOL");
        mbits = 0;
    end
    always @(sclk) if (mon_on && rst_n) begin
        if (cs_n) err("SCLK toggled with CS high");
        // 前沿：离开空闲电平（sclk 新值 != CPOL）；CPHA=0 前沿采样，CPHA=1 后沿采样
        else if ((sclk !== m_cpol) ^ m_cpha) begin
            mon_mosi = {mon_mosi[6:0], mosi};
            mon_miso = {mon_miso[6:0], miso};
            mbits = mbits + 1;
        end
    end
    always @(posedge cs_n) if (mon_on && rst_n) begin
        if (mbits != 8)          err("not 8 sample edges in CS window");
        if (mon_mosi !== m_tx)   err("MOSI pin decode mismatch");
        if (mon_miso !== s_tx)   err("MISO pin decode mismatch");
        n_mon = n_mon + 1;
    end

    // ---------------- 传输 ----------------
    reg [7:0] s_got;
    reg       s_got_v;
    always @(posedge clk) if (s_rx_valid) begin s_got = s_rx; s_got_v = 1; end

    integer ok_m2s, ok_s2m;
    task xfer(input [7:0] a, input [7:0] b);
        begin
            @(negedge clk);
            m_tx = a; s_tx = b; s_got_v = 0; start = 1;
            @(negedge clk); start = 0;
            @(posedge done);
            repeat (6) @(negedge clk);          // 从机经过同步器，rx_valid 比主机 done 晚几拍
            if (s_got_v && s_got === a) ok_m2s = ok_m2s + 1;
            if (m_rx === b)             ok_s2m = ok_s2m + 1;
            wait (!busy);
        end
    endtask

    integer i, mm, sm, d, n;
    initial begin
        $dumpfile("spi.vcd");
        $dumpvars(0, tb_spi);
        #22 rst_n = 1;
        repeat (4) @(negedge clk);

        // P1
        $display("---------------------------------------------------------------");
        for (mm = 0; mm < 4; mm = mm + 1) begin
            mon_on = 0;                          // 改模式时 CS 为高，SCLK 跳到新 CPOL，不算违规
            m_cpol = mm[1]; m_cpha = mm[0]; s_cpol = mm[1]; s_cpha = mm[0];
            repeat (4) @(negedge clk);
            mon_on = 1;
            ok_m2s = 0; ok_s2m = 0;
            for (i = 0; i < 250; i = i + 1) begin
                div = 4 + $urandom % 5;
                xfer($urandom, $urandom);
            end
            $display("P1 mode %0d (CPOL=%0d CPHA=%0d): M->S ok %0d/250  S->M ok %0d/250",
                     mm, mm[1], mm[0], ok_m2s, ok_s2m);
            if (ok_m2s != 250 || ok_s2m != 250) err("P1 transfer mismatch");
        end
        $display("P1 pin monitor decoded %0d frames", n_mon);
        mon_on = 0;
        $dumpoff;

        // P2 模式不匹配
        div = 6;
        $display("P2 mode mismatch (50 bytes, 'M->S/S->M' correct):");
        $display("            slave m0   slave m1   slave m2   slave m3");
        for (mm = 0; mm < 4; mm = mm + 1) begin
            $write("master m%0d ", mm);
            for (sm = 0; sm < 4; sm = sm + 1) begin
                m_cpol = mm[1]; m_cpha = mm[0]; s_cpol = sm[1]; s_cpha = sm[0];
                repeat (4) @(negedge clk);
                ok_m2s = 0; ok_s2m = 0;
                for (i = 0; i < 50; i = i + 1) xfer($urandom, $urandom);
                $write("   %2d/%2d  ", ok_m2s, ok_s2m);
                if (mm == sm && (ok_m2s != 50 || ok_s2m != 50)) err("P2 matched mode failed");
            end
            $write("\n");
        end

        // P3 分频扫描
        $display("P3 div sweep (SCLK half period = div clk; 'M->S/S->M' correct of 50):");
        $display("       mode0     mode1     mode2     mode3");
        for (d = 1; d <= 6; d = d + 1) begin
            div = d;
            $write("div=%0d ", d);
            for (mm = 0; mm < 4; mm = mm + 1) begin
                m_cpol = mm[1]; m_cpha = mm[0]; s_cpol = mm[1]; s_cpha = mm[0];
                repeat (8) @(negedge clk);
                ok_m2s = 0; ok_s2m = 0;
                for (i = 0; i < 50; i = i + 1) xfer($urandom, $urandom);
                $write(" %2d/%2d    ", ok_m2s, ok_s2m);
                if (d >= 4 && (ok_m2s != 50 || ok_s2m != 50)) err("P3 failed at div>=4");
            end
            $write("\n");
        end

        $display("---------------------------------------------------------------");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("ERROR: timeout");
        $display("FAIL (%0d errors + timeout)", errors);
        $finish;
    end
endmodule
