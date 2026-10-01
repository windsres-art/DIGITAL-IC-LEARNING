// =============================================================================
// 参数化组相联 cache（阻塞式，一次处理一个缺失）
//   地址划分：| tag | index | offset |，offset = log2(LINE_WORDS × 4)
//   WAYS = 1 即直接映射；SETS = 1 即全相联
//   替换：真 LRU（每路一个"年龄"，0 = 最近用过，WAYS-1 = 最久没用）；有无效路时先填编号最小的无效路
//   写策略（WRITE_BACK）：
//     1 = 写回 + 写分配：写命中只改 cache 并置脏；缺失先把脏的牺牲行写回，再整行读入
//     0 = 写直达 + 写不分配：写命中同时改 cache 和内存；写缺失只写内存，不读入
//   时序：
//     命中：请求被接收的下一拍给出响应，同一拍可以接收下一个请求（每拍一个命中）
//     缺失：LOOKUP →（WB 写回脏行）→ REQ 读请求 → WAIT 等数据 → 回到 LOOKUP 重查（必然命中）
//   CPU 口：valid/ready 请求，响应只有 valid（CPU 必须能接）；读写都有响应
//   内存口：整行宽度的 valid/ready 请求；读在 mem_resp_valid 时返回整行，写在握手时即完成
//   存储体按 {路, 组} 拼接寻址（组数、路数都是 2 的幂），避免乘法
// =============================================================================
module cache #(
    parameter AW         = 32,
    parameter LINE_WORDS = 4,               // 每行字数（2 的幂，≥ 2）
    parameter SETS       = 16,              // 组数（2 的幂）
    parameter WAYS       = 2,               // 路数（2 的幂）
    parameter WRITE_BACK = 1
)(
    input                          clk,
    input                          rst_n,
    // CPU 侧
    input                          cpu_req_valid,
    output                         cpu_req_ready,
    input                          cpu_req_we,
    input      [AW-1:0]            cpu_req_addr,
    input      [31:0]              cpu_req_wdata,
    input      [3:0]               cpu_req_wstrb,
    output                         cpu_resp_valid,
    output     [31:0]              cpu_resp_rdata,
    // 内存侧
    output                         mem_req_valid,
    input                          mem_req_ready,
    output                         mem_req_we,
    output     [AW-1:0]            mem_req_addr,
    output     [32*LINE_WORDS-1:0] mem_req_wdata,
    output     [4*LINE_WORDS-1:0]  mem_req_wstrb,
    input                          mem_resp_valid,
    input      [32*LINE_WORDS-1:0] mem_resp_rdata,
    // 统计事件：每个请求第一次 LOOKUP 时报一次命中或缺失
    output                         perf_hit,
    output                         perf_miss,
    output                         perf_writeback
);
    localparam WW   = $clog2(LINE_WORDS);                  // 行内字地址位宽
    localparam OFFW = WW + 2;                              // 行内字节偏移位宽
    localparam IDXB = $clog2(SETS);                        // index 在地址里占的位数（全相联为 0）
    localparam IDXW = (SETS > 1) ? IDXB : 1;
    localparam AGEW = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam TAGW = AW - IDXB - OFFW;
    localparam LIW  = AGEW + IDXW;                         // 行号 = {路, 组}
    localparam NLA  = 1 << LIW;
    localparam integer    OLDEST_I = WAYS - 1;
    localparam [AGEW-1:0] OLDEST   = OLDEST_I[AGEW-1:0];

    localparam S_IDLE = 3'd0, S_LOOKUP = 3'd1, S_WB = 3'd2, S_REQ = 3'd3,
               S_WAIT = 3'd4, S_WT = 3'd5;

    // ---------------- 存储体 ----------------
    // 数据和标签不复位（可映射成 SRAM）；有效、脏、年龄要复位
    reg [31:0]     data  [0:NLA*LINE_WORDS-1];
    reg [TAGW-1:0] tag   [0:NLA-1];
    reg [NLA-1:0]  valid, dirty;
    reg [AGEW-1:0] age   [0:NLA-1];

    // ---------------- 请求寄存器 ----------------
    reg [2:0]      state;
    reg            r_we, r_retry;
    reg [AW-1:0]   r_addr;
    reg [31:0]     r_wdata;
    reg [3:0]      r_wstrb;
    reg [AGEW-1:0] r_victim;

    wire [TAGW-1:0] r_tag  = r_addr[AW-1 -: TAGW];
    wire [WW-1:0]   r_word = r_addr[2 +: WW];
    wire [IDXW-1:0] r_idx;
    generate                                 // 全相联时没有 index 位
        if (SETS > 1) begin : g_idx  assign r_idx = r_addr[OFFW +: IDXB]; end
        else          begin : g_idx0 assign r_idx = 1'b0; end
    endgenerate
    wire unused_lo = &{1'b0, r_addr[1:0]};   // 字内字节地址由字节使能体现

    // ---------------- 命中判断（所有路并行比较标签）----------------
    reg            hit, has_inv;
    reg [AGEW-1:0] hit_way, inv_way, lru_way;
    integer w;
    always @* begin
        hit = 1'b0; hit_way = {AGEW{1'b0}};
        has_inv = 1'b0; inv_way = {AGEW{1'b0}}; lru_way = {AGEW{1'b0}};
        for (w = WAYS - 1; w >= 0; w = w - 1) begin     // 倒序：最后留下的是编号最小的无效路
            if (valid[{w[AGEW-1:0], r_idx}] && tag[{w[AGEW-1:0], r_idx}] == r_tag) begin
                hit = 1'b1; hit_way = w[AGEW-1:0];
            end
            if (!valid[{w[AGEW-1:0], r_idx}]) begin
                has_inv = 1'b1; inv_way = w[AGEW-1:0];
            end
            if (age[{w[AGEW-1:0], r_idx}] == OLDEST) lru_way = w[AGEW-1:0];
        end
    end
    wire [AGEW-1:0] victim = has_inv ? inv_way : lru_way;

    wire lookup     = (state == S_LOOKUP);
    wire wt_write   = (WRITE_BACK == 0) && r_we;          // 写直达：写请求都要访问内存
    wire serve_hit  = lookup & hit & ~wt_write;           // 本拍直接完成
    wire need_fill  = lookup & ~hit & ~wt_write;          // 写不分配：写缺失不读入
    wire vict_dirty = (WRITE_BACK != 0) && valid[{victim, r_idx}] && dirty[{victim, r_idx}];

    assign cpu_req_ready = (state == S_IDLE) | serve_hit;
    wire   accept        = cpu_req_valid & cpu_req_ready;

    // ---------------- 内存请求 ----------------
    wire [AW-1:0] line_addr = {r_addr[AW-1:OFFW], {OFFW{1'b0}}};
    wire [AW-1:0] vict_addr;
    generate
        if (SETS > 1) begin : g_va  assign vict_addr = {tag[{r_victim, r_idx}], r_idx, {OFFW{1'b0}}}; end
        else          begin : g_va0 assign vict_addr = {tag[{r_victim, r_idx}], {OFFW{1'b0}}}; end
    endgenerate

    reg [32*LINE_WORDS-1:0] vict_line;
    integer k;
    always @* begin
        for (k = 0; k < LINE_WORDS; k = k + 1)
            vict_line[32*k +: 32] = data[{r_victim, r_idx, k[WW-1:0]}];
    end

    // 写直达只写一个字：字节使能移到行内这个字的位置，数据复制到每个字
    wire [4*LINE_WORDS-1:0] wt_strb = {{(4*LINE_WORDS-4){1'b0}}, r_wstrb} << {r_word, 2'b00};

    assign mem_req_valid = (state == S_WB) | (state == S_REQ) | (state == S_WT);
    assign mem_req_we    = (state != S_REQ);
    assign mem_req_addr  = (state == S_WB) ? vict_addr : line_addr;
    assign mem_req_wdata = (state == S_WB) ? vict_line : {LINE_WORDS{r_wdata}};
    assign mem_req_wstrb = (state == S_WB) ? {(4*LINE_WORDS){1'b1}} : wt_strb;
    wire   mem_fire      = mem_req_valid & mem_req_ready;

    // ---------------- 响应 ----------------
    wire [31:0] hit_word  = data[{hit_way, r_idx, r_word}];
    assign cpu_resp_valid = serve_hit | ((state == S_WT) & mem_fire);
    assign cpu_resp_rdata = hit_word;        // 只对读有意义

    assign perf_hit       = lookup & ~r_retry & hit;
    assign perf_miss      = lookup & ~r_retry & ~hit;
    assign perf_writeback = (state == S_WB) & mem_fire;

    function [31:0] merge(input [31:0] old, input [31:0] nw, input [3:0] s);
        merge = {s[3] ? nw[31:24] : old[31:24], s[2] ? nw[23:16] : old[23:16],
                 s[1] ? nw[15:8]  : old[15:8],  s[0] ? nw[7:0]   : old[7:0]};
    endfunction

    // ---------------- 状态机 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            r_retry <= 1'b0;
        end else begin
            case (state)
                S_IDLE:   if (accept) begin state <= S_LOOKUP; r_retry <= 1'b0; end
                S_LOOKUP: begin
                    if (serve_hit) begin
                        state   <= accept ? S_LOOKUP : S_IDLE;     // 命中时背靠背接下一个
                        r_retry <= 1'b0;
                    end else if (wt_write) begin
                        state   <= S_WT;
                    end else begin
                        state   <= vict_dirty ? S_WB : S_REQ;
                    end
                end
                S_WB:     if (mem_fire) state <= S_REQ;
                S_REQ:    if (mem_fire) state <= S_WAIT;
                S_WAIT:   if (mem_resp_valid) begin state <= S_LOOKUP; r_retry <= 1'b1; end
                S_WT:     if (mem_fire) state <= S_IDLE;
                default:  state <= S_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        if (accept) begin
            r_we    <= cpu_req_we;
            r_addr  <= cpu_req_addr;
            r_wdata <= cpu_req_wdata;
            r_wstrb <= cpu_req_wstrb;
        end
        if (need_fill) r_victim <= victim;               // 牺牲路在缺失那拍定下，填充过程中不变
    end

    // ---------------- 存储体更新 ----------------
    // 访问 = LOOKUP 命中（含写直达的写命中：同时改 cache 和内存）；填充 = 缺失数据返回
    wire access = lookup & hit;
    wire fill   = (state == S_WAIT) & mem_resp_valid;
    wire [AGEW-1:0] hit_age = age[{hit_way, r_idx}];

    integer s2, w2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= {NLA{1'b0}};
            dirty <= {NLA{1'b0}};
            for (s2 = 0; s2 < (1 << IDXW); s2 = s2 + 1)
                for (w2 = 0; w2 < (1 << AGEW); w2 = w2 + 1)
                    age[{w2[AGEW-1:0], s2[IDXW-1:0]}] <= w2[AGEW-1:0];   // 第 w 路初始年龄 = w，构成排列
        end else begin
            if (access) begin
                // 真 LRU：被访问的路年龄清 0，比它年轻的各加 1，比它老的不变
                for (w2 = 0; w2 < WAYS; w2 = w2 + 1)
                    if (w2[AGEW-1:0] == hit_way)
                        age[{w2[AGEW-1:0], r_idx}] <= {AGEW{1'b0}};
                    else if (age[{w2[AGEW-1:0], r_idx}] < hit_age)
                        age[{w2[AGEW-1:0], r_idx}] <= age[{w2[AGEW-1:0], r_idx}] + 1'b1;
                if (r_we && WRITE_BACK != 0) dirty[{hit_way, r_idx}] <= 1'b1;
            end
            if (fill) begin
                valid[{r_victim, r_idx}] <= 1'b1;
                dirty[{r_victim, r_idx}] <= 1'b0;
            end
        end
    end

    integer k2;
    always @(posedge clk) begin                          // 数据 / 标签：不带复位
        if (access && r_we)
            data[{hit_way, r_idx, r_word}] <= merge(hit_word, r_wdata, r_wstrb);
        if (fill) begin
            for (k2 = 0; k2 < LINE_WORDS; k2 = k2 + 1)
                data[{r_victim, r_idx, k2[WW-1:0]}] <= mem_resp_rdata[32*k2 +: 32];
            tag[{r_victim, r_idx}] <= r_tag;
        end
    end
endmodule
