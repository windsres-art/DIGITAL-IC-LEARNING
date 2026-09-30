// =============================================================================
// AHB-Lite testbench（自检查）：周期级主机 BFM → ahb_decoder_mux → 2 × ahb_sram + 默认从机
//   主机：先把所有 burst 展开成"地址阶段条目"表（IDLE / BUSY / NONSEQ / SEQ），
//         HREADY=1 的沿上：当前地址阶段条目进入数据阶段，下一条目上地址总线。
//         HREADY=0 时地址和控制保持（ERROR 第 1 拍也保持，选择"继续"而不是取消）。
//   burst：SINGLE / INCR(1~8) / INCR4/8/16 / WRAP4/8/16，byte/half/word，INCR 不跨 1KB，
//          burst 中随机插 BUSY；40% 的写 burst 后面紧跟同地址读回（制造写后读冒险）。
//   从机：S0 4KB 随机 25% 插等待；S1 1KB 零等待；0x2000 以上未映射 → ERROR。
//   检查：字节级参考模型比对读数据；未映射必须 ERROR、映射必须 OKAY；
//         ERROR 必须是两拍（HREADY 0→1 且 HRESP 两拍都为 1）；IDLE/BUSY 必须零等待 OKAY。
// =============================================================================
`timescale 1ns / 1ps

module tb_ahb;
    localparam NBURST = 4000;
    localparam MAXIT  = 60000;
    localparam [1:0] IDLE = 2'b00, BUSY = 2'b01, NONSEQ = 2'b10, SEQ = 2'b11;

    reg hclk = 0, hresetn = 0;
    always #5 hclk = ~hclk;

    // ---------------- 总线 ----------------
    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = IDLE;
    reg         hwrite = 0;
    reg  [2:0]  hsize = 0, hburst = 0;
    wire        hready, hresp;
    wire [31:0] hrdata;
    wire        hsel0, hsel1, hreadyout0, hreadyout1, hresp0, hresp1;
    wire [31:0] hrdata0, hrdata1;
    reg         stall0 = 0;

    ahb_decoder_mux u_ic (
        .hclk(hclk), .hresetn(hresetn), .haddr(haddr), .htrans(htrans),
        .hsel0(hsel0), .hsel1(hsel1),
        .hreadyout0(hreadyout0), .hresp0(hresp0), .hrdata0(hrdata0),
        .hreadyout1(hreadyout1), .hresp1(hresp1), .hrdata1(hrdata1),
        .hready(hready), .hresp(hresp), .hrdata(hrdata));

    ahb_sram #(.AW(12)) u_s0 (
        .hclk(hclk), .hresetn(hresetn), .hsel(hsel0), .haddr(haddr[11:0]), .htrans(htrans),
        .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata), .hready(hready),
        .hreadyout(hreadyout0), .hresp(hresp0), .hrdata(hrdata0), .stall(stall0));

    ahb_sram #(.AW(10)) u_s1 (
        .hclk(hclk), .hresetn(hresetn), .hsel(hsel1), .haddr(haddr[9:0]), .htrans(htrans),
        .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata), .hready(hready),
        .hreadyout(hreadyout1), .hresp(hresp1), .hrdata(hrdata1), .stall(1'b0));

    always @(negedge hclk) stall0 <= (($urandom % 4) == 0);

    // ---------------- 地址阶段条目表 ----------------
    reg [1:0]  it_trans [0:MAXIT-1];
    reg [31:0] it_addr  [0:MAXIT-1];
    reg        it_write [0:MAXIT-1];
    reg [2:0]  it_size  [0:MAXIT-1];
    reg [2:0]  it_burst [0:MAXIT-1];
    reg [31:0] it_wdata [0:MAXIT-1];
    integer    n_it = 0;

    task push(input [1:0] t, input [31:0] a, input w, input [2:0] s, input [2:0] b);
        begin
            it_trans[n_it] = t; it_addr[n_it] = a; it_write[n_it] = w;
            it_size[n_it]  = s; it_burst[n_it] = b; it_wdata[n_it] = $urandom;
            n_it = n_it + 1;
        end
    endtask

    function integer beats_of(input [2:0] b, input integer incr_len);
        case (b)
            3'd0:       beats_of = 1;
            3'd1:       beats_of = incr_len;
            3'd2, 3'd3: beats_of = 4;
            3'd4, 3'd5: beats_of = 8;
            default:    beats_of = 16;
        endcase
    endfunction

    function is_wrap(input [2:0] b);
        is_wrap = (b == 3'd2) || (b == 3'd4) || (b == 3'd6);
    endfunction

    function [31:0] next_addr(input [31:0] a, input [2:0] s, input integer beats, input wrap);
        reg [31:0] bytes, tot;
        begin
            bytes = 32'd1 << s;
            tot   = bytes * beats;
            if (wrap) next_addr = (a & ~(tot - 1)) | ((a + bytes) & (tot - 1));
            else      next_addr = a + bytes;
        end
    endfunction

    integer n_type [0:7];
    integer b, k, beats, last_beats, rsel, gap;
    reg     w, last_w, rb;
    reg [2:0]  sz, bt, last_sz, last_bt;
    reg [31:0] a, start, last_start, base, off, bytes;

    task gen;
        begin
            last_w = 0;
            for (k = 0; k < 8; k = k + 1) n_type[k] = 0;
            for (b = 0; b < NBURST; b = b + 1) begin
                rb = last_w && (($urandom % 10) < 4);
                if (rb) begin
                    w = 0; sz = last_sz; bt = last_bt; beats = last_beats; a = last_start;
                end else begin
                    if (($urandom % 3) == 0)
                        for (gap = 0; gap < 1 + $urandom % 2; gap = gap + 1)
                            push(IDLE, $urandom % 32'h3000, $urandom % 2, 3'd2, 3'd0);
                    w = $urandom % 2; sz = $urandom % 3; bt = $urandom % 8;
                    beats = beats_of(bt, 1 + $urandom % 8);
                    rsel  = $urandom % 20;
                    if      (rsel < 9)  base = (($urandom % 4) << 10);          // S0 的某个 1KB
                    else if (rsel < 18) base = 32'h1000;                        // S1
                    else                base = 32'h2000 + (($urandom % 4) << 10); // 未映射
                    bytes = 32'd1 << sz;
                    off   = ($urandom % 1024) & ~(bytes - 1);
                    if (!is_wrap(bt) && off + beats * bytes > 1024)             // INCR 不跨 1KB
                        off = 1024 - beats * bytes;
                    a = base + off;
                end
                n_type[bt] = n_type[bt] + 1;
                start = a;
                for (k = 0; k < beats; k = k + 1) begin
                    if (k > 0 && ($urandom % 8) == 0) push(BUSY, a, w, sz, bt);
                    push((k == 0) ? NONSEQ : SEQ, a, w, sz, bt);
                    a = next_addr(a, sz, beats, is_wrap(bt));
                end
                last_w = w && !rb; last_sz = sz; last_bt = bt; last_beats = beats; last_start = start;
            end
            for (k = 0; k < 10; k = k + 1) push(IDLE, 0, 0, 3'd2, 3'd0);
        end
    endtask

    // ---------------- 主机驱动 + 检查 ----------------
    reg [7:0] mm [0:32'h13FF];              // 字节级参考模型，覆盖 S0 + S1
    integer   ap = 0, dp = 0;
    reg       dp_on = 0, prev_err1 = 0;
    integer   errors = 0, n_cyc = 0, n_beat = 0, n_rd = 0, n_wr = 0, n_wait = 0;
    integer   n_busy = 0, n_idle = 0, n_err = 0, n_raw = 0, n_chk_bytes = 0, l;
    reg [3:0] be;
    reg [31:0] ba;

    task err(input [8*48-1:0] msg);
        begin
            if (errors < 10) $display("ERROR @%0t: %0s (item %0d addr %h)", $time, msg, dp, it_addr[dp]);
            errors = errors + 1;
        end
    endtask

    function [3:0] byte_en(input [2:0] s, input [1:0] a2);
        case (s)
            3'd0:    byte_en = 4'b0001 << a2;
            3'd1:    byte_en = a2[1] ? 4'b1100 : 4'b0011;
            default: byte_en = 4'b1111;
        endcase
    endfunction

    task drive_ap(input integer i);
        begin
            haddr <= it_addr[i]; htrans <= it_trans[i]; hwrite <= it_write[i];
            hsize <= it_size[i]; hburst <= it_burst[i];
        end
    endtask

    // 数据阶段完成时的检查
    task complete(input integer i);
        begin
            if (!it_trans[i][1]) begin
                if (hresp !== 1'b0) err("IDLE/BUSY got ERROR");
            end else begin
                n_beat = n_beat + 1;
                if (it_addr[i] >= 32'h1400) begin
                    if (hresp !== 1'b1) err("unmapped but OKAY");
                    n_err = n_err + 1;
                end else begin
                    if (hresp !== 1'b0) err("mapped but ERROR");
                    be = byte_en(it_size[i], it_addr[i][1:0]);
                    ba = it_addr[i] & ~32'd3;
                    for (l = 0; l < 4; l = l + 1) if (be[l]) begin
                        if (it_write[i]) mm[ba + l] = it_wdata[i][8*l +: 8];
                        else begin
                            if (hrdata[8*l +: 8] !== mm[ba + l]) err("read data mismatch");
                            n_chk_bytes = n_chk_bytes + 1;
                        end
                    end
                    if (it_write[i]) n_wr = n_wr + 1; else n_rd = n_rd + 1;
                end
            end
        end
    endtask

    always @(posedge hclk) if (hresetn) begin
        n_cyc = n_cyc + 1;
        // ERROR 两拍检查
        if (prev_err1 && !(hresp && hready))  err("ERROR 2nd cycle missing");
        if (hresp && hready && !prev_err1)    err("single-cycle ERROR");
        prev_err1 = hresp && !hready;

        if (!hready) begin
            n_wait = n_wait + 1;
            if (dp_on && !it_trans[dp][1]) err("wait state on IDLE/BUSY");
        end else begin
            if (dp_on) complete(dp);
            // 写数据阶段与同字读地址阶段在同一沿完成 → 从机必须旁路
            if (dp_on && it_trans[dp][1] && it_write[dp] && it_trans[ap][1] && !it_write[ap] &&
                it_addr[dp] < 32'h1400 && (it_addr[dp] >> 2) == (it_addr[ap] >> 2))
                n_raw = n_raw + 1;
            if (it_trans[ap] == BUSY) n_busy = n_busy + 1;
            if (it_trans[ap] == IDLE) n_idle = n_idle + 1;
            dp = ap; dp_on = 1;
            hwdata <= it_wdata[ap];         // 写数据在数据阶段才给出
            if (ap < n_it - 1) ap = ap + 1;
            drive_ap(ap);
        end
    end

    // 看门狗：HREADY 卡在 0 时主机永远走不完条目表，正常运行约 4.2 万拍
    initial begin
        #2_000_000;
        $display("ERROR: timeout at item %0d / %0d (HREADY stuck?)", ap, n_it);
        $display("FAIL (%0d errors + timeout)", errors);
        $finish;
    end

    initial begin
        $dumpfile("ahb.vcd");
        $dumpvars(0, tb_ahb);
        gen;
        // 预置随机内容：避免读到未写过的 X 时"X === X"蒙混过关
        for (k = 0; k < 1024; k = k + 1) begin
            u_s0.mem[k] = $urandom;
            for (l = 0; l < 4; l = l + 1) mm[4*k + l] = u_s0.mem[k][8*l +: 8];
        end
        for (k = 0; k < 256; k = k + 1) begin
            u_s1.mem[k] = $urandom;
            for (l = 0; l < 4; l = l + 1) mm[32'h1000 + 4*k + l] = u_s1.mem[k][8*l +: 8];
        end
        drive_ap(0);
        #22 hresetn = 1;
        wait (ap == n_it - 1);
        repeat (5) @(posedge hclk);

        $display("------------------------------------------------------------------");
        $display("items=%0d  bursts=%0d  SINGLE=%0d INCR=%0d WRAP4=%0d INCR4=%0d WRAP8=%0d INCR8=%0d WRAP16=%0d INCR16=%0d",
                 n_it, NBURST, n_type[0], n_type[1], n_type[2], n_type[3],
                 n_type[4], n_type[5], n_type[6], n_type[7]);
        $display("beats=%0d (write %0d, read %0d, ERROR %0d)  checked bytes=%0d",
                 n_beat, n_wr, n_rd, n_err, n_chk_bytes);
        $display("cycles=%0d  wait=%0d  BUSY=%0d  IDLE=%0d  RAW same-word back-to-back=%0d",
                 n_cyc, n_wait, n_busy, n_idle, n_raw);
        $display("bus efficiency = beats / cycles = %0.3f", n_beat * 1.0 / n_cyc);
        $display("------------------------------------------------------------------");
        if (n_raw == 0 || n_err == 0 || n_busy == 0) err("coverage hole");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
