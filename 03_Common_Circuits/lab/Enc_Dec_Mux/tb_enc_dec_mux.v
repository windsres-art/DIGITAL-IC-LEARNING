// =============================================================================
// 编码器 / 译码器 / MUX testbench（自检查）
//   prio_enc   N = 8、N = 5 全遍历，与"最高位 1 的下标"模型比对
//   decoder    W = 3 全遍历（含 en = 0）
//   onehot2bin N = 8 所有独热输入；再演示一个多热输入的输出
//   mux_bin    N = 8 随机数据 × 所有 sel；N = 5 时 sel 越界的输出
//   mux_onehot 与 mux_bin + decoder 逐次比对；sel 全 0 / 多热时的输出
//   mux_latch_bad / fixed：sel = 3 时一个保持旧值（latch 行为）、一个输出 0
// =============================================================================
`timescale 1ns / 1ps

module tb_enc_dec_mux;
    integer errors = 0, k, t, i, m;

    // ---------------- 优先编码器 ----------------
    reg  [7:0] pe8_req;  wire [2:0] pe8_idx; wire pe8_v;
    reg  [4:0] pe5_req;  wire [2:0] pe5_idx; wire pe5_v;
    prio_enc #(.N(8)) u_pe8 (.req(pe8_req), .idx(pe8_idx), .valid(pe8_v));
    prio_enc #(.N(5)) u_pe5 (.req(pe5_req), .idx(pe5_idx), .valid(pe5_v));

    // ---------------- 译码器 ----------------
    reg  [2:0] dec_in; reg dec_en; wire [7:0] dec_out;
    decoder #(.W(3)) u_dec (.in(dec_in), .en(dec_en), .out(dec_out));

    // ---------------- 独热转二进制 ----------------
    reg  [7:0] oh; wire [2:0] oh_bin;
    onehot2bin #(.N(8)) u_o2b (.oh(oh), .bin(oh_bin));

    // ---------------- MUX ----------------
    reg  [63:0] din8;  reg [2:0] sel8;  wire [7:0] mb8, mo8;
    wire [7:0]  sel8_oh;
    reg  [7:0]  sel_raw; reg use_raw;
    mux_bin    #(.N(8), .W(8)) u_mb8 (.din(din8), .sel(sel8), .dout(mb8));
    decoder    #(.W(3))        u_sd  (.in(sel8), .en(1'b1), .out(sel8_oh));
    mux_onehot #(.N(8), .W(8)) u_mo8 (.din(din8), .sel(use_raw ? sel_raw : sel8_oh), .dout(mo8));

    reg  [39:0] din5;  reg [2:0] sel5;  wire [7:0] mb5;
    mux_bin    #(.N(5), .W(8)) u_mb5 (.din(din5), .sel(sel5), .dout(mb5));

    // ---------------- latch 演示 ----------------
    reg  [1:0] lsel; reg [2:0] ld; wire ly_bad, ly_fix;
    mux_latch_bad   u_lb (.sel(lsel), .d(ld), .y(ly_bad));
    mux_latch_fixed u_lf (.sel(lsel), .d(ld), .y(ly_fix));

    integer pe_err = 0, dec_err = 0, o2b_err = 0, mux_err = 0, oh_err = 0, x_cnt = 0;
    reg [2:0] exp_idx;

    initial begin
        $dumpfile("enc_dec_mux.vcd");
        $dumpvars(0, tb_enc_dec_mux);
        use_raw = 0; sel_raw = 0;

        // prio_enc N = 8 / 5
        for (k = 0; k < 256; k = k + 1) begin
            pe8_req = k; pe5_req = k[4:0]; #1;
            exp_idx = 0; for (i = 0; i < 8; i = i + 1) if (k[i]) exp_idx = i;
            if (pe8_idx !== exp_idx || pe8_v !== (k != 0)) pe_err = pe_err + 1;
            exp_idx = 0; for (i = 0; i < 5; i = i + 1) if (k[i]) exp_idx = i;
            if (pe5_idx !== exp_idx || pe5_v !== (k[4:0] != 0)) pe_err = pe_err + 1;
        end
        pe8_req = 8'b0010_0110; #1;
        $display("prio_enc  N=8 256 inputs, N=5 32 inputs (x8) : errors=%0d | e.g. req=%b -> idx=%0d valid=%b",
                 pe_err, pe8_req, pe8_idx, pe8_v);
        pe8_req = 8'b0000_0001; #1;
        $display("          req=%b -> idx=%0d valid=%b ; req=00000000 ->", pe8_req, pe8_idx, pe8_v);
        pe8_req = 0; #1;
        $display("          idx=%0d valid=%b  (idx same, valid tells them apart)", pe8_idx, pe8_v);

        // decoder
        for (k = 0; k < 16; k = k + 1) begin
            dec_in = k[2:0]; dec_en = k[3]; #1;
            if (dec_out !== (dec_en ? (8'b1 << dec_in) : 8'b0)) dec_err = dec_err + 1;
        end
        $display("decoder   W=3 16 inputs (with en)            : errors=%0d", dec_err);

        // onehot2bin
        for (k = 0; k < 8; k = k + 1) begin
            oh = 8'b1 << k; #1;
            if (oh_bin !== k) o2b_err = o2b_err + 1;
        end
        oh = 8'b0000_0110; #1;
        $display("onehot2bin N=8 8 one-hot inputs              : errors=%0d | multi-hot %b -> %0d (=1|2, meaningless)",
                 o2b_err, oh, oh_bin);

        // mux_bin / mux_onehot N = 8
        for (t = 0; t < 500; t = t + 1) begin
            din8 = {$urandom, $urandom};
            for (k = 0; k < 8; k = k + 1) begin
                sel8 = k; #1;
                if (mb8 !== din8[k*8 +: 8]) mux_err = mux_err + 1;
                if (mo8 !== mb8)            oh_err  = oh_err + 1;
            end
        end
        $display("mux_bin   N=8 W=8 500 x 8 selects            : errors=%0d | mux_onehot vs mux_bin mismatches=%0d",
                 mux_err, oh_err);
        din8 = 64'h77_66_55_44_33_22_11_00;
        use_raw = 1;
        sel_raw = 8'b0000_0000; #1; m = mo8;
        sel_raw = 8'b0000_0110; #1;
        $display("mux_onehot din[i]=0xii : sel=00000000 -> 0x%02h ; sel=00000110 -> 0x%02h (=0x11|0x22)",
                 m[7:0], mo8);
        use_raw = 0;

        // mux_bin N = 5：越界
        din5 = 40'h44_33_22_11_00;
        for (k = 0; k < 8; k = k + 1) begin
            sel5 = k; #1;
            if (k < 5 && mb5 !== din5[k*8 +: 8]) mux_err = mux_err + 1;
            if (k >= 5 && ^mb5 === 1'bx)       x_cnt = x_cnt + 1;
        end
        sel5 = 5; #1;
        $display("mux_bin   N=5 : sel 0..4 ok, sel 5..7 give X in %0d cases (sel=5 -> %b)", x_cnt, mb5);

        // latch 行为
        lsel = 0; ld = 3'b001; #1;
        $display("latch demo: sel=0 d=001 -> bad=%b fixed=%b", ly_bad, ly_fix);
        lsel = 3; #1;
        $display("            sel=3        -> bad=%b fixed=%b", ly_bad, ly_fix);
        ld = 3'b000; #1;
        $display("            sel=3 d=000 -> bad=%b fixed=%b  (bad keeps old value = latch)", ly_bad, ly_fix);
        if (ly_bad !== 1'b1 || ly_fix !== 1'b0) errors = errors + 1;

        errors = errors + pe_err + dec_err + o2b_err + mux_err + oh_err;
        if (oh_bin !== 3'd3 || x_cnt != 3) errors = errors + 1;
        $display("------------------------------------------------------------");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
