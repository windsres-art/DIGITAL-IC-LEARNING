// =============================================================================
// 存储器 testbench（自检查）。输入在下降沿改变，上升沿后 1 ns 检查
//   spram     三种写模式各一个实例、同一激励：先写满初始化，定向演示写时 dout，
//             再 3000 拍随机读写与参考模型比对
//   sdpram    BYPASS = 0 / 1，地址限制在 0..3 制造大量同址读写冲突，与模型比对
//   regfile   BYPASS = 0 / 1，2 读 1 写随机 3000 拍；检查 x0 恒 0、写 x0 被忽略
//   rom_sine  32 个地址与 $sin 计算值比对，检查 1 拍读延迟
//   sram_wrap 随机字节使能写 + 读，与模型比对；读出只在读操作后更新
// =============================================================================
`timescale 1ns / 1ps

module tb_memory;
    reg clk = 0;
    always #5 clk = ~clk;
    integer errors = 0, k, i;

    // ======================= spram =======================
    reg        sp_en = 0, sp_we = 0;
    reg  [3:0] sp_addr = 0;
    reg  [7:0] sp_din = 0;
    wire [7:0] sp_q [0:2];
    spram #(.DW(8), .AW(4), .MODE(0)) u_rf (.clk(clk), .en(sp_en), .we(sp_we), .addr(sp_addr), .din(sp_din), .dout(sp_q[0]));
    spram #(.DW(8), .AW(4), .MODE(1)) u_wf (.clk(clk), .en(sp_en), .we(sp_we), .addr(sp_addr), .din(sp_din), .dout(sp_q[1]));
    spram #(.DW(8), .AW(4), .MODE(2)) u_nc (.clk(clk), .en(sp_en), .we(sp_we), .addr(sp_addr), .din(sp_din), .dout(sp_q[2]));

    reg [7:0] sp_m [0:15];
    reg [7:0] sp_exp [0:2];
    reg [7:0] old;
    integer sp_err = 0, sp_wr = 0, sp_rd = 0, md;

    always @(posedge clk) begin
        if (sp_en) begin
            old = sp_m[sp_addr];
            if (sp_we) begin sp_m[sp_addr] = sp_din; sp_wr = sp_wr + 1; end
            else sp_rd = sp_rd + 1;
            if (!sp_we) begin sp_exp[0] = old; sp_exp[1] = old; sp_exp[2] = old; end
            else begin sp_exp[0] = old; sp_exp[1] = sp_din; end
        end
        #1;
        for (md = 0; md < 3; md = md + 1)
            if (sp_q[md] !== sp_exp[md]) begin
                if (sp_err < 5) $display("ERROR spram mode%0d @%0t dout=%h exp=%h", md, $time, sp_q[md], sp_exp[md]);
                sp_err = sp_err + 1;
            end
    end

    // ======================= sdpram =======================
    reg        dp_we = 0, dp_re = 0;
    reg  [3:0] dp_wa = 0, dp_ra = 0;
    reg  [7:0] dp_wd = 0;
    wire [7:0] dp_q0, dp_q1;
    sdpram #(.DW(8), .AW(4), .BYPASS(0)) u_dp0 (.clk(clk), .we(dp_we), .waddr(dp_wa), .wdata(dp_wd), .re(dp_re), .raddr(dp_ra), .rdata(dp_q0));
    sdpram #(.DW(8), .AW(4), .BYPASS(1)) u_dp1 (.clk(clk), .we(dp_we), .waddr(dp_wa), .wdata(dp_wd), .re(dp_re), .raddr(dp_ra), .rdata(dp_q1));

    reg [7:0] dp_m [0:15];
    reg [7:0] dp_e0, dp_e1;
    integer dp_err = 0, dp_coll = 0, dp_coll_diff = 0;

    always @(posedge clk) begin
        if (dp_re) begin
            dp_e0 = dp_m[dp_ra];
            dp_e1 = (dp_we && dp_wa == dp_ra) ? dp_wd : dp_m[dp_ra];
            if (dp_we && dp_wa == dp_ra) begin
                dp_coll = dp_coll + 1;
                if (dp_wd !== dp_m[dp_ra]) dp_coll_diff = dp_coll_diff + 1;
            end
        end
        if (dp_we) dp_m[dp_wa] = dp_wd;
        #1;
        if (dp_q0 !== dp_e0 || dp_q1 !== dp_e1) begin
            if (dp_err < 5) $display("ERROR sdpram @%0t q0=%h exp0=%h q1=%h exp1=%h", $time, dp_q0, dp_e0, dp_q1, dp_e1);
            dp_err = dp_err + 1;
        end
    end

    // ======================= regfile =======================
    reg         rf_we = 0;
    reg  [4:0]  rf_wa = 0, rf_ra1 = 0, rf_ra2 = 0;
    reg  [31:0] rf_wd = 0;
    wire [31:0] rf0_q1, rf0_q2, rf1_q1, rf1_q2;
    regfile #(.BYPASS(0)) u_rf0 (.clk(clk), .we(rf_we), .waddr(rf_wa), .wdata(rf_wd),
                                 .raddr1(rf_ra1), .rdata1(rf0_q1), .raddr2(rf_ra2), .rdata2(rf0_q2));
    regfile #(.BYPASS(1)) u_rf1 (.clk(clk), .we(rf_we), .waddr(rf_wa), .wdata(rf_wd),
                                 .raddr1(rf_ra1), .rdata1(rf1_q1), .raddr2(rf_ra2), .rdata2(rf1_q2));

    reg [31:0] rf_m [0:31];
    integer rf_err = 0, rf_x0w = 0, rf_x0r = 0, rf_byp = 0, rf_on = 0;

    function [31:0] rf_exp(input [4:0] a, input byp);
        if (a == 0)                              rf_exp = 0;
        else if (byp && rf_we && rf_wa == a)     rf_exp = rf_wd;
        else                                     rf_exp = rf_m[a];
    endfunction

    // 组合读：在上升沿前 1 ns 检查
    always @(negedge clk) if (rf_on) begin
        #4;
        if (rf0_q1 !== rf_exp(rf_ra1, 0) || rf0_q2 !== rf_exp(rf_ra2, 0) ||
            rf1_q1 !== rf_exp(rf_ra1, 1) || rf1_q2 !== rf_exp(rf_ra2, 1)) begin
            if (rf_err < 5) $display("ERROR regfile @%0t ra1=%0d q=%h/%h exp=%h/%h", $time, rf_ra1,
                                     rf0_q1, rf1_q1, rf_exp(rf_ra1, 0), rf_exp(rf_ra1, 1));
            rf_err = rf_err + 1;
        end
        if (rf_ra1 == 0 || rf_ra2 == 0) rf_x0r = rf_x0r + 1;
        if (rf_we && rf_wa != 0 && (rf_wa == rf_ra1 || rf_wa == rf_ra2)) rf_byp = rf_byp + 1;
    end
    always @(posedge clk) begin
        if (rf_we && rf_wa != 0) rf_m[rf_wa] = rf_wd;
        if (rf_we && rf_wa == 0 && rf_on) rf_x0w = rf_x0w + 1;
    end

    // ======================= rom_sine =======================
    reg  [4:0]        rom_a = 0;
    wire signed [7:0] rom_q;
    rom_sine u_rom (.clk(clk), .addr(rom_a), .data(rom_q));
    integer rom_err = 0, rom_exp;
    real    rr;

    // ======================= sram_wrap =======================
    reg         sr_en = 0, sr_we = 0;
    reg  [3:0]  sr_be = 0;
    reg  [5:0]  sr_a = 0;
    reg  [31:0] sr_wd = 0;
    wire [31:0] sr_q;
    sram_wrap #(.DW(32), .AW(6)) u_sram (.clk(clk), .en(sr_en), .we(sr_we), .be(sr_be), .addr(sr_a), .wdata(sr_wd), .rdata(sr_q));

    reg  [31:0] sr_m [0:63];
    reg  [31:0] sr_e = 32'bx;          // 宏的 Q 上电是 X，第一次读之前模型也是 X
    integer sr_err = 0, sr_part = 0, sr_rd = 0, sr_on = 0, b;

    always @(posedge clk) begin
        if (sr_en) begin
            if (sr_we) begin
                for (b = 0; b < 4; b = b + 1)
                    if (sr_be[b]) sr_m[sr_a][b*8 +: 8] = sr_wd[b*8 +: 8];
                if (sr_be != 4'hf && sr_be != 0) sr_part = sr_part + 1;
            end else begin
                sr_e = sr_m[sr_a];
                sr_rd = sr_rd + 1;
            end
        end
        #1;
        if (sr_on && sr_q !== sr_e) begin
            if (sr_err < 5) $display("ERROR sram @%0t q=%h exp=%h", $time, sr_q, sr_e);
            sr_err = sr_err + 1;
        end
    end

    // ======================= 激励 =======================
    initial begin
        $dumpfile("memory.vcd");
        $dumpvars(0, tb_memory);

        // ---- 初始化：spram / sdpram 写满 mem[i] = i * 0x11，sram 写满，regfile 写 x1..x31 ----
        for (k = 0; k < 16; k = k + 1) begin
            @(negedge clk);
            sp_en = 1; sp_we = 1; sp_addr = k; sp_din = k * 8'h11;
            dp_we = 1; dp_wa = k; dp_wd = k * 8'h11; dp_re = 0;
        end
        for (k = 0; k < 64; k = k + 1) begin
            @(negedge clk);
            sp_en = 0; dp_we = 0;
            sr_en = 1; sr_we = 1; sr_be = 4'hf; sr_a = k; sr_wd = {4{k[7:0]}};
            if (k < 32) begin rf_we = 1; rf_wa = k; rf_wd = 32'h1000_0000 + k; end
            else rf_we = 0;
        end
        @(negedge clk); sr_en = 0; rf_we = 0;

        // ---- spram 定向演示：读 3，然后写 5 ----
        @(negedge clk); sp_en = 1; sp_we = 0; sp_addr = 3;
        @(negedge clk); sp_we = 1; sp_addr = 5; sp_din = 8'hBB;
        @(negedge clk); sp_en = 0;
        $display("------------------------------------------------------------");
        $display("spram: read addr3 (0x33), then write 0xBB to addr5 (old 0x55); dout in the write cycle:");
        $display("  READ_FIRST=0x%h  WRITE_FIRST=0x%h  NO_CHANGE=0x%h", sp_q[0], sp_q[1], sp_q[2]);
        if (sp_q[0] !== 8'h55 || sp_q[1] !== 8'hBB || sp_q[2] !== 8'h33) errors = errors + 1;

        // ---- sdpram 定向演示：同一拍写 0xCC 到 addr2（旧 0x22）并读 addr2 ----
        @(negedge clk); dp_we = 1; dp_wa = 2; dp_wd = 8'hCC; dp_re = 1; dp_ra = 2;
        @(negedge clk); dp_we = 0; dp_re = 0;
        $display("sdpram: write 0xCC to addr2 (old 0x22) and read addr2 in the same cycle:");
        $display("  BYPASS=0 rdata=0x%h  BYPASS=1 rdata=0x%h", dp_q0, dp_q1);
        if (dp_q0 !== 8'h22 || dp_q1 !== 8'hCC) errors = errors + 1;

        // ---- 随机 3000 拍 ----
        sr_on = 1; rf_on = 1;
        for (k = 0; k < 3000; k = k + 1) begin
            @(negedge clk);
            sp_en = ($urandom % 100) < 80; sp_we = $urandom; sp_addr = $urandom; sp_din = $urandom;
            dp_we = $urandom; dp_re = $urandom; dp_wa = $urandom % 4; dp_ra = $urandom % 4; dp_wd = $urandom;
            rf_we = $urandom; rf_wa = $urandom; rf_wd = $urandom; rf_ra1 = $urandom; rf_ra2 = $urandom;
            if (($urandom % 8) == 0) rf_ra1 = rf_wa;           // 提高同拍读写同一寄存器的概率
            sr_en = ($urandom % 100) < 80; sr_we = $urandom; sr_be = $urandom; sr_a = $urandom; sr_wd = $urandom;
        end
        @(negedge clk);
        sp_en = 0; dp_we = 0; dp_re = 0; rf_we = 0; sr_en = 0; rf_on = 0;
        @(negedge clk);

        // ---- ROM ----
        $write("rom_sine:");
        for (k = 0; k < 33; k = k + 1) begin
            @(negedge clk);
            if (k > 0) begin
                rr = 127.0 * $sin(2.0 * 3.14159265358979 * (k - 1) / 32.0);
                rom_exp = (rr >= 0) ? $rtoi(rr + 0.5) : -$rtoi(-rr + 0.5);
                if (rom_q !== rom_exp[7:0]) rom_err = rom_err + 1;
                if (k <= 9) $write(" %0d", rom_q);
            end
            rom_a = k[4:0];
        end
        $display(" ... | 32 entries vs $sin: errors=%0d", rom_err);

        $display("spram 3 modes x 3000 random cycles  : %0d writes, %0d reads, errors=%0d", sp_wr, sp_rd, sp_err);
        $display("sdpram bypass 0/1                   : %0d same-address collisions (%0d with new!=old), errors=%0d",
                 dp_coll, dp_coll_diff, dp_err);
        $display("regfile 2R1W bypass 0/1             : x0 reads=%0d, ignored x0 writes=%0d, same-cycle w/r=%0d, errors=%0d",
                 rf_x0r, rf_x0w, rf_byp, rf_err);
        $display("sram_wrap byte-enable               : %0d reads, %0d partial-byte writes, errors=%0d", sr_rd, sr_part, sr_err);
        $display("------------------------------------------------------------");

        errors = errors + sp_err + dp_err + rf_err + rom_err + sr_err;
        if (dp_coll < 100 || rf_x0w == 0 || rf_byp < 100 || sr_part < 100) errors = errors + 1;
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
