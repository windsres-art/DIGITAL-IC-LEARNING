// =============================================================================
// cache testbench（自检查）
//   参考模型两层：
//     1 平坦内存 ref_mem：请求被接收时按序更新，读响应的数据必须与它一致
//     2 行为级 tag / LRU 模型：在接收时预测本请求命中还是缺失、会不会写回脏行，
//       与 RTL 的 perf_hit / perf_miss / perf_writeback 逐个请求比对
//   激励：顺序流、热点区、同组冲突（WAYS+1 个标签轮流访问，专测 LRU）、全范围随机，
//         40% 写、随机字节使能，请求之间随机空拍；内存延迟 LAT + 随机抖动
//   结束后把整个地址范围读一遍，确认被换出的脏数据都正确写回了
//   +trace=文件  把第一阶段的请求序列写出来，供 cache_sim.py 独立复算命中数
// =============================================================================
`timescale 1ns / 1ps

module tb_cache;
    parameter SETS       = 16;
    parameter WAYS       = 2;
    parameter LINE_WORDS = 4;
    parameter WRITE_BACK = 1;
    parameter LAT        = 8;                 // 内存访问占用的周期数
    parameter NREQ       = 20000;
    parameter SEED       = 1;

    localparam AW          = 32;
    localparam NL          = SETS * WAYS;
    localparam LBYTES      = 4 * LINE_WORDS;
    localparam CACHE_BYTES = NL * LBYTES;
    localparam RANGE_BYTES = 4 * CACHE_BYTES; // 地址空间是 cache 容量的 4 倍
    localparam RW          = RANGE_BYTES / 4;
    localparam LB          = 32 * LINE_WORDS;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---------------- DUT ----------------
    reg               cpu_req_valid = 0, cpu_req_we = 0;
    reg  [AW-1:0]     cpu_req_addr = 0;
    reg  [31:0]       cpu_req_wdata = 0;
    reg  [3:0]        cpu_req_wstrb = 0;
    wire              cpu_req_ready, cpu_resp_valid;
    wire [31:0]       cpu_resp_rdata;
    wire              mem_req_valid, mem_req_we;
    wire              mem_req_ready;
    wire [AW-1:0]     mem_req_addr;
    wire [LB-1:0]     mem_req_wdata;
    wire [4*LINE_WORDS-1:0] mem_req_wstrb;
    reg               mem_resp_valid = 0;
    reg  [LB-1:0]     mem_resp_rdata = 0;
    wire              perf_hit, perf_miss, perf_wb;

    cache #(.AW(AW), .LINE_WORDS(LINE_WORDS), .SETS(SETS), .WAYS(WAYS), .WRITE_BACK(WRITE_BACK)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_req_valid(cpu_req_valid), .cpu_req_ready(cpu_req_ready), .cpu_req_we(cpu_req_we),
        .cpu_req_addr(cpu_req_addr), .cpu_req_wdata(cpu_req_wdata), .cpu_req_wstrb(cpu_req_wstrb),
        .cpu_resp_valid(cpu_resp_valid), .cpu_resp_rdata(cpu_resp_rdata),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready), .mem_req_we(mem_req_we),
        .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
        .perf_hit(perf_hit), .perf_miss(perf_miss), .perf_writeback(perf_wb));

    integer errors = 0;
    integer i, j;

    // ---------------- 内存模型 ----------------
    reg [31:0] mem [0:RW-1];
    reg [7:0]  busy = 0;                      // 内存被占用的剩余周期
    reg        rd_pending = 0;
    reg [AW-1:0] rd_addr;
    integer    mem_rd_bytes = 0, mem_wr_bytes = 0, mj;
    integer    phase = 0;                     // 0 = 随机测试（统计），1 = 读回检查

    // busy / rd_pending 用非阻塞更新：DUT 在同一个沿采样 ready，不能和 TB 抢
    assign mem_req_ready = (busy == 0) && !rd_pending;

    always @(posedge clk) begin
        mem_resp_valid <= 1'b0;
        if (busy != 0) busy <= busy - 1'b1;
        if (rd_pending && busy == 0) begin
            for (mj = 0; mj < LINE_WORDS; mj = mj + 1)
                mem_resp_rdata[32*mj +: 32] <= mem[rd_addr / 4 + mj];
            mem_resp_valid <= 1'b1;
            rd_pending     <= 1'b0;
        end
        if (mem_req_valid && mem_req_ready) begin
            if (mem_req_addr % LBYTES != 0 || mem_req_addr >= RANGE_BYTES) begin
                $display("ERROR: 内存请求地址非法 %08h", mem_req_addr);
                errors = errors + 1;
            end
            busy <= LAT + ($urandom % 3);
            if (mem_req_we) begin
                for (mj = 0; mj < 4 * LINE_WORDS; mj = mj + 1)
                    if (mem_req_wstrb[mj]) begin
                        mem[mem_req_addr / 4 + mj / 4][8*(mj%4) +: 8] = mem_req_wdata[8*mj +: 8];
                        if (phase == 0) mem_wr_bytes = mem_wr_bytes + 1;
                    end
            end else begin
                rd_pending <= 1'b1;
                rd_addr    <= mem_req_addr;
                if (phase == 0) mem_rd_bytes = mem_rd_bytes + LBYTES;
            end
        end
    end

    // ---------------- 行为级 cache 模型（预测命中 / 缺失 / 写回）----------------
    reg            m_v [0:NL-1];
    reg            m_d [0:NL-1];
    integer        m_t [0:NL-1];
    integer        m_age [0:NL-1];

    task model_access(input [AW-1:0] a, input we, output hit, output wb);
        integer idx, tg, w, hw, vw, old;
        begin
            idx = (a / LBYTES) % SETS;
            tg  = a / LBYTES / SETS;
            hit = 0; wb = 0; hw = -1;
            for (w = 0; w < WAYS; w = w + 1)
                if (m_v[w*SETS+idx] && m_t[w*SETS+idx] == tg) begin hit = 1; hw = w; end
            if (!hit && we && !WRITE_BACK) begin
                // 写直达 + 写不分配：不碰 cache
            end else begin
                if (!hit) begin
                    vw = -1;
                    for (w = WAYS - 1; w >= 0; w = w - 1) if (!m_v[w*SETS+idx]) vw = w;
                    if (vw < 0)
                        for (w = 0; w < WAYS; w = w + 1) if (m_age[w*SETS+idx] == WAYS - 1) vw = w;
                    wb = WRITE_BACK && m_v[vw*SETS+idx] && m_d[vw*SETS+idx];
                    m_v[vw*SETS+idx] = 1; m_t[vw*SETS+idx] = tg; m_d[vw*SETS+idx] = 0;
                    hw = vw;
                end
                old = m_age[hw*SETS+idx];
                for (w = 0; w < WAYS; w = w + 1)
                    if (w == hw) m_age[w*SETS+idx] = 0;
                    else if (m_age[w*SETS+idx] < old) m_age[w*SETS+idx] = m_age[w*SETS+idx] + 1;
                if (we && WRITE_BACK) m_d[hw*SETS+idx] = 1;
            end
        end
    endtask

    // ---------------- 在途请求队列 ----------------
    reg [31:0] ref_mem [0:RW-1];
    reg        q_we   [0:3];
    reg [31:0] q_exp  [0:3];
    reg        q_hit  [0:3];
    reg        q_wb   [0:3];
    reg [AW-1:0] q_addr [0:3];
    integer    q_t    [0:3];
    integer    q_head = 0, q_cnt = 0;
    integer    now = 0;
    integer    n_req = 0, n_rd = 0, n_wr = 0, n_hit = 0, n_miss = 0, n_wb = 0, n_exp_wb = 0;
    integer    lat_hit = 0, lat_miss = 0, lat_all = 0, n_lat_hit = 0, n_lat_miss = 0;
    integer    tfd = 0;
    reg [1023:0] tracefile;
    reg        p_hit, p_wb;
    integer    wb_pending = 0;

    function [31:0] merge(input [31:0] old, input [31:0] nw, input [3:0] s);
        merge = {s[3] ? nw[31:24] : old[31:24], s[2] ? nw[23:16] : old[23:16],
                 s[1] ? nw[15:8]  : old[15:8],  s[0] ? nw[7:0]   : old[7:0]};
    endfunction

    always @(posedge clk) if (rst_n) begin
        now = now + 1;
        // 统计事件对应队首请求（它正在 LOOKUP）
        if (perf_hit || perf_miss) begin
            if (q_cnt == 0) begin
                $display("ERROR: 没有在途请求却报了命中 / 缺失"); errors = errors + 1;
            end else if (perf_hit !== q_hit[q_head]) begin
                if (errors < 10)
                    $display("ERROR @%0t: addr=%08h RTL %0s，模型预测 %0s", $time, q_addr[q_head],
                             perf_hit ? "hit" : "miss", q_hit[q_head] ? "hit" : "miss");
                errors = errors + 1;
            end
            if (phase == 0) begin
                if (perf_hit) n_hit = n_hit + 1; else n_miss = n_miss + 1;
            end
        end
        if (perf_wb) begin
            wb_pending = wb_pending - 1;
            if (phase == 0) n_wb = n_wb + 1;
        end
        // 响应
        if (cpu_resp_valid) begin
            if (q_cnt == 0) begin
                $display("ERROR: 多出来的响应"); errors = errors + 1;
            end else begin
                if (!q_we[q_head] && cpu_resp_rdata !== q_exp[q_head]) begin
                    if (errors < 10)
                        $display("ERROR @%0t: 读 %08h 得到 %08h，期望 %08h", $time,
                                 q_addr[q_head], cpu_resp_rdata, q_exp[q_head]);
                    errors = errors + 1;
                end
                if (phase == 0) begin
                    // 分两类：在 cache 里直接完成的（命中，且不是写直达的写）与要访问内存的
                    lat_all = lat_all + (now - q_t[q_head]);
                    if (q_hit[q_head] && !(q_we[q_head] && !WRITE_BACK)) begin lat_hit  = lat_hit  + (now - q_t[q_head]); n_lat_hit  = n_lat_hit + 1; end
                    else               begin lat_miss = lat_miss + (now - q_t[q_head]); n_lat_miss = n_lat_miss + 1; end
                end
                q_head = (q_head + 1) % 4;
                q_cnt  = q_cnt - 1;
            end
        end
        // 接收：按接收顺序更新参考内存和行为模型
        if (cpu_req_valid && cpu_req_ready) begin
            j = (q_head + q_cnt) % 4;
            model_access(cpu_req_addr, cpu_req_we, p_hit, p_wb);
            q_we[j] = cpu_req_we; q_addr[j] = cpu_req_addr; q_t[j] = now;
            q_hit[j] = p_hit; q_wb[j] = p_wb;
            q_exp[j] = ref_mem[cpu_req_addr / 4];
            if (cpu_req_we)
                ref_mem[cpu_req_addr / 4] = merge(ref_mem[cpu_req_addr / 4], cpu_req_wdata, cpu_req_wstrb);
            if (p_wb) begin
                wb_pending = wb_pending + 1;
                if (phase == 0) n_exp_wb = n_exp_wb + 1;
            end
            q_cnt = q_cnt + 1;
            if (phase == 0) begin
                n_req = n_req + 1;
                if (cpu_req_we) n_wr = n_wr + 1; else n_rd = n_rd + 1;
                if (tfd != 0) $fdisplay(tfd, "%0s %08h", cpu_req_we ? "W" : "R", cpu_req_addr);
            end
        end
    end

    // 看门狗：有在途请求却长时间没有响应 = 状态机卡死
    integer idle_cyc = 0;
    always @(posedge clk) begin
        idle_cyc = (cpu_resp_valid || q_cnt == 0) ? 0 : idle_cyc + 1;
        if (idle_cyc > 2000) begin
            $display("ERROR: 2000 拍没有响应，state=%0d addr=%08h", u_dut.state, q_addr[q_head]);
            $display("FAIL (deadlock)");
            $finish;
        end
    end

    // ---------------- 激励 ----------------
    task issue(input [AW-1:0] a, input we);
        begin
            @(negedge clk);
            while ($urandom % 4 == 0) @(negedge clk);    // 随机空拍
            cpu_req_valid = 1;
            cpu_req_addr  = a;
            cpu_req_we    = we;
            cpu_req_wdata = $urandom;
            cpu_req_wstrb = we ? (($urandom % 15) + 1) : 4'b0000;
            @(posedge clk);
            while (!cpu_req_ready) @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 0;
        end
    endtask

    integer mode, len, base, cnt, tg, seed_v;
    reg [AW-1:0] a;
    initial begin
        if ($value$plusargs("trace=%s", tracefile)) tfd = $fopen(tracefile, "w");
        seed_v = SEED;
        i = $urandom(seed_v);
        for (i = 0; i < RW; i = i + 1) begin
            mem[i] = $urandom; ref_mem[i] = mem[i];
        end
        for (i = 0; i < NL; i = i + 1) begin
            m_v[i] = 0; m_d[i] = 0; m_t[i] = 0; m_age[i] = i / SETS;   // 与 RTL 复位值一致：第 w 路年龄 = w
        end
        // 只录 DUT（第一层信号 + 状态寄存器）：TB 的参考数组很大，全录 VCD 会到 GB 级
        $dumpfile("cache.vcd");
        $dumpvars(1, u_dut);

        #22 rst_n = 1;
        cnt = 0;
        while (cnt < NREQ) begin
            mode = $urandom % 100;
            len  = 1 + $urandom % 16;
            base = ($urandom % RW) * 4;
            tg   = 0;
            for (i = 0; i < len && cnt < NREQ; i = i + 1) begin
                if (mode < 35)       a = (base + 4 * i) % RANGE_BYTES;                     // 顺序流
                else if (mode < 65)  a = ($urandom % (CACHE_BYTES / 2 / 4)) * 4;           // 热点：半个 cache 大小
                else if (mode < 85)  begin                                                 // 同组冲突
                    a  = ((base / LBYTES) % SETS) * LBYTES + (tg % (WAYS + 1)) * SETS * LBYTES
                         + ($urandom % LINE_WORDS) * 4;
                    tg = tg + 1;
                end
                else                 a = ($urandom % RW) * 4;                              // 全范围随机
                issue(a, ($urandom % 100) < 40);
                cnt = cnt + 1;
            end
        end
        while (q_cnt != 0) @(posedge clk);
        if (tfd != 0) $fclose(tfd);

        // 读回：确认被换出的脏数据都写回了
        phase = 1;
        for (i = 0; i < RW; i = i + 1) issue(i * 4, 1'b0);
        while (q_cnt != 0) @(posedge clk);
        repeat (LAT + 5) @(posedge clk);

        if (n_wb != n_exp_wb || wb_pending != 0) begin
            $display("ERROR: 写回次数 RTL %0d，模型 %0d（未完成 %0d）", n_wb, n_exp_wb, wb_pending);
            errors = errors + 1;
        end
        $display("cfg SETS=%0d WAYS=%0d LINE=%0dB %0s LAT=%0d | size=%0dB range=%0dB",
                 SETS, WAYS, LBYTES, WRITE_BACK ? "WB" : "WT", LAT, CACHE_BYTES, RANGE_BYTES);
        $display("reqs=%0d (R %0d / W %0d)  hits=%0d misses=%0d  hit_rate=%0.2f%%  writebacks=%0d",
                 n_req, n_rd, n_wr, n_hit, n_miss, 100.0 * n_hit / n_req, n_wb);
        $display("latency: in-cache=%0.2f  needs-mem=%0.2f  avg(AMAT)=%0.2f cycles   mem traffic: rd=%0dB wr=%0dB",
                 1.0 * lat_hit / n_lat_hit, 1.0 * lat_miss / n_lat_miss, 1.0 * lat_all / n_req,
                 mem_rd_bytes, mem_wr_bytes);
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
