// =============================================================================
// DMA testbench（自检查）
//   存储器 64 KB（0x0000_0000 – 0x0000_FFFF），更高的地址总线返回 err；主口每次访问随机等待 0–3 拍
//   +njob=N（默认 300）个随机任务：单段（寄存器给参数）或描述符链（1–4 段，长度 0–128 B）
//     源区 0x0000–0x7FFF，目的区 0x8000–0xBFFF，描述符区 0xC000–0xFFFF，互不重叠
//   每个任务：等 irq → 检查 STATUS / COUNT → 整个存储器与参考模型比对 → 写 1 清 DONE，irq 撤销
//   每 10 个任务插一个出错任务（轮流三种）：
//     源地址非对齐 / 写到没有映射的地址（已搬的字保留）/ 描述符链指向没有映射的地址
// =============================================================================
`timescale 1ns / 1ps

module tb_dma;
    localparam MW = 16384, BADA = 32'h0001_0000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         req = 0, we = 0;
    reg  [4:0]  addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata, m_addr, m_wdata;
    wire        m_re, irq;
    wire [3:0]  m_wstrb;
    reg  [31:0] mem [0:MW-1];
    reg  [31:0] refm [0:MW-1];

    integer wcnt = 0, wneed = 0, cyc = 0, busy_cyc = 0, n_rd = 0, n_wr = 0;
    wire    m_req   = m_re | (|m_wstrb);
    wire    m_ready = m_req && (wcnt >= wneed);
    wire    m_err   = (m_addr >= BADA);
    wire [31:0] m_rdata = m_err ? 32'hDEAD_BEEF : mem[m_addr[15:2]];

    dma u_dma (.clk(clk), .rst_n(rst_n), .req(req), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
               .m_addr(m_addr), .m_re(m_re), .m_wstrb(m_wstrb), .m_wdata(m_wdata), .m_rdata(m_rdata),
               .m_ready(m_ready), .m_err(m_err), .irq(irq));

    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (u_dma.state != 3'd0) busy_cyc = busy_cyc + 1;
        if (m_ready) begin
            wcnt  <= 0;
            wneed <= $urandom % 4;
            if (!m_err && m_wstrb == 4'hF) begin mem[m_addr[15:2]] <= m_wdata; n_wr = n_wr + 1; end
            if (!m_err && m_re) n_rd = n_rd + 1;
        end else if (m_req) wcnt <= wcnt + 1;
    end

    task rw(input w, input [4:0] a, input [31:0] d);
        begin
            @(negedge clk); req = 1; we = w; addr = a; wdata = d;
            @(negedge clk); req = 0; we = 0;
        end
    endtask

    reg [31:0] rd_v;
    task rr(input [4:0] a);
        begin
            @(negedge clk); addr = a; #1 rd_v = rdata;
        end
    endtask

    integer errors = 0, job, k, j, nseg, words, t0, ekind, exp_cnt, n_err_jobs = 0, total_words = 0;
    integer sp, dp, dsc, seg_len [0:3], seg_src [0:3], seg_dst [0:3];
    reg [31:0] exp_err;

    // iverilog 把非 ASCII 的字符串字面量当参数传递时会乱码，所以传编号，文字留在格式串里
    task chk(input ok, input integer what);
        begin
            if (!ok) begin
                if (errors < 10)
                    case (what)
                        1: $display("ERROR job %0d: irq 没有来", job);
                        2: $display("ERROR job %0d: STATUS 应为 ERR（读到 %h）", job, rd_v);
                        3: $display("ERROR job %0d: ERRADDR 不对（读到 %h）", job, rd_v);
                        4: $display("ERROR job %0d: STATUS 应为 DONE（读到 %h）", job, rd_v);
                        5: $display("ERROR job %0d: COUNT 不对（读到 %h）", job, rd_v);
                        default: $display("ERROR job %0d: 清除后 irq 仍为 1", job);
                    endcase
                errors = errors + 1;
            end
        end
    endtask

    task compare_mem;
        integer m, bad;
        begin
            bad = 0;
            for (m = 0; m < MW; m = m + 1) if (mem[m] !== refm[m]) bad = bad + 1;
            if (bad) begin
                if (errors < 10) $display("ERROR job %0d: 存储器有 %0d 个字与参考模型不同", job, bad);
                errors = errors + 1;
            end
        end
    endtask

    task wait_irq;
        begin
            t0 = cyc;
            while (!irq && cyc - t0 < 20000) @(posedge clk);
            chk(irq, 1);
        end
    endtask

    initial begin
        if (!$value$plusargs("njob=%d", k)) k = 300;
        for (j = 0; j < MW; j = j + 1) begin mem[j] = $urandom; refm[j] = mem[j]; end
        $dumpfile("dma.vcd");
        $dumpvars(1, u_dma);
        #22 rst_n = 1;

        for (job = 0; job < k; job = job + 1) begin
            ekind = (job % 10 == 9) ? (n_err_jobs % 3) + 1 : 0;
            nseg  = (ekind == 0 && $urandom % 2) ? 1 + $urandom % 4 : 1;
            sp = ($urandom % 64) * 4;
            dp = 32'h8000 + ($urandom % 64) * 4;
            dsc = 32'hC000 + ($urandom % 256) * 16;
            exp_cnt = 0;
            for (j = 0; j < nseg; j = j + 1) begin
                seg_len[j] = ($urandom % 33) * 4;
                seg_src[j] = sp; seg_dst[j] = dp;
                sp = sp + seg_len[j] + ($urandom % 8) * 4;
                dp = dp + seg_len[j] + ($urandom % 8) * 4;
            end
            if (ekind == 2) begin seg_dst[0] = BADA - 8; seg_len[0] = 16; end        // 第 3 个字写出界

            // 描述符（SG 模式，或出错种类 3 需要的链）
            for (j = 0; j < nseg; j = j + 1) begin
                mem[(dsc >> 2) + 4*j]     = seg_src[j]; refm[(dsc >> 2) + 4*j]     = seg_src[j];
                mem[(dsc >> 2) + 4*j + 1] = seg_dst[j]; refm[(dsc >> 2) + 4*j + 1] = seg_dst[j];
                mem[(dsc >> 2) + 4*j + 2] = seg_len[j]; refm[(dsc >> 2) + 4*j + 2] = seg_len[j];
                mem[(dsc >> 2) + 4*j + 3] = (j == nseg - 1) ? (ekind == 3 ? 32'h0002_0000 : 0) : dsc + 16 * (j + 1);
                refm[(dsc >> 2) + 4*j + 3] = mem[(dsc >> 2) + 4*j + 3];
            end

            // 参考模型
            exp_err = 0;
            for (j = 0; j < nseg && ekind != 1; j = j + 1)
                for (words = 0; words < seg_len[j] / 4; words = words + 1)
                    if (seg_dst[j] + 4 * words >= BADA) begin
                        if (exp_err == 0) exp_err = seg_dst[j] + 4 * words;
                    end else if (exp_err == 0) begin
                        refm[(seg_dst[j] >> 2) + words] = refm[(seg_src[j] >> 2) + words];
                        exp_cnt = exp_cnt + 1;
                    end
            if (ekind == 1) begin exp_err = seg_src[0] + 2; exp_cnt = 0; end
            if (ekind == 3) exp_err = 32'h0002_0000;

            // 编程并启动
            if (ekind == 1) begin
                rw(1, 5'h08, seg_src[0] + 2); rw(1, 5'h0C, seg_dst[0]); rw(1, 5'h10, seg_len[0]);
                rw(1, 5'h00, 32'h3);
            end else if (nseg > 1 || ekind == 3) begin
                rw(1, 5'h14, dsc);
                rw(1, 5'h00, 32'h7);                 // START | IE | SG
            end else begin
                rw(1, 5'h08, seg_src[0]); rw(1, 5'h0C, seg_dst[0]); rw(1, 5'h10, seg_len[0]);
                rw(1, 5'h00, 32'h3);                 // START | IE
            end
            wait_irq;
            rr(5'h04);
            if (ekind != 0) begin
                chk(rd_v == 32'h4, 2);
                rr(5'h1C); chk(rd_v == exp_err, 3);
                n_err_jobs = n_err_jobs + 1;
            end else begin
                chk(rd_v == 32'h2, 4);
            end
            rr(5'h18); chk(rd_v == exp_cnt, 5);
            if (errors && errors < 3) $display("  job %0d: kind=%0d nseg=%0d exp_cnt=%0d exp_err=%h", job, ekind, nseg, exp_cnt, exp_err);
            total_words = total_words + exp_cnt;
            compare_mem;
            rw(1, 5'h04, 32'h6);                     // 写 1 清 DONE / ERR
            @(negedge clk);
            chk(!irq, 6);
        end

        $display("DMA: %0d 个任务（%0d 个出错任务），搬运 %0d 字；主口读 %0d 次、写 %0d 次，忙 %0d 周期，平均 %0.2f 周期/字",
                 k, n_err_jobs, total_words, n_rd, n_wr, busy_cyc, 1.0 * busy_cyc / total_words);
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
