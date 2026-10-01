// =============================================================================
// AXI4 从机：32 bit 数据的 RAM（容量 2^AW 字节）
//   支持：五通道独立握手、ID、FIXED / INCR / WRAP burst、窄传输（AxSIZE < 字）、
//         INCR/FIXED 首拍非对齐、WSTRB、多个 outstanding（AW/AR 命令队列深度 2^QAW）
//   不支持：乱序返回（同一时刻只处理队头命令，按接收顺序返回——对任何 ID 都合法）、
//           读写交织顺序保证（AXI 本身不保证读写通道之间的顺序）、exclusive、
//           AxLOCK/AxCACHE/AxPROT/AxQOS（未引出）
//
//   和 APB/AHB 不同，这里没有一根“当前相位”的状态线。五个通道各握手各的。
//   从机里真正的状态只有两类：
//     1. 命令队列。AW/AR 先整笔收进来，队头那一笔才是正在做的 burst。
//     2. 拍计数。一条 burst 里面走到第几拍、下一拍地址是多少、WLAST 有没有对错。
//   名字对照：
//     wc_* / rc_*  队头那条命令本身（整笔 burst 的身份证，做完才换）
//     w_*  / r_*   这条命令内部的进度（每拍更新）
//     *_hs         本拍握手成功（valid 且 ready）
//     *_q          为下一拍预先算好、寄存在寄存器里的值
//
//   写：AW 进队列；W 只处理队头命令对应的数据（AW 没到时 WREADY=0，这是规范允许的）；
//       最后一拍写完后把 {BID, BRESP} 压进 B 队列，所以 BVALID 一定晚于 WLAST 握手。
//       WLAST 与按 AWLEN 数的拍数不一致时 BRESP 返回 SLVERR。
//   读：AR 进队列；R 输出是一级寄存器（../../../03_Common_Circuits 第 8 节的 pipe 写法），
//       只在"输出空或本拍被取走"时装载下一拍，保证 RVALID 拉高后数据不变。
// =============================================================================
module axi_ram #(
    parameter AW  = 12,                 // 字节地址位宽（≥ 9，用于 WRAP 掩码计算）
    parameter IDW = 4,
    parameter QAW = 2                   // 命令队列深度 2^QAW。同时在途的写命令、读命令各自最多这么多
)(
    input                aclk,
    input                aresetn,            // 低有效复位
    // ---------- 写地址通道 AW ----------
    // 一条写命令只在这里出现一次：首地址、拍数、每拍多大、地址怎么变、ID。
    // 后面的数据拍不再重复这些。AWLEN+1 才是拍数，AWSIZE 是每拍字节数的 log2。
    input      [IDW-1:0] awid,               // 这笔写的 ID，原样回到 BID。本模块不按 ID 乱序
    input      [AW-1:0]  awaddr,             // 首拍字节地址。INCR/FIXED 可以不对齐，WRAP 必须已对齐
    input      [7:0]     awlen,              // 拍数减 1。0 = 只传 1 拍，3 = 传 4 拍
    input      [2:0]     awsize,             // 0 字节，1 半字，2 字。本模块数据总线固定 32 位
    input      [1:0]     awburst,            // 00 FIXED 每拍同址，01 INCR 递增，10 WRAP 窗口内环绕
    input                awvalid,
    output               awready,            // 命令队列未满就能收。和当前是不是正在写数据无关
    // ---------- 写数据通道 W ----------
    // 和 AW 分开握手，可以晚到，也可以先到。先到时本模块 WREADY=0，数据停在主机侧。
    // 一条 AW 对应 AWLEN+1 拍 W。只有按拍数数到的最后一拍会弹出这条 AW。
    input      [31:0]    wdata,
    input      [3:0]     wstrb,              // 字节写使能，bit 0 = 最低字节。从机按它写，不自己从地址重算
    input                wlast,              // 主机自己标的“这是最后一拍”。必须和 AWLEN 一致，否则 SLVERR
    input                wvalid,
    output               wready,             // 队头有写命令，且写响应队列还有空位，才收数据
    // ---------- 写响应通道 B ----------
    // 每条写 burst 只回一个响应，不是每拍一个。最后一拍 W 握手的下一拍起，BVALID 才可能为 1。
    output     [IDW-1:0] bid,
    output     [1:0]     bresp,              // 00 OKAY，10 SLVERR（WLAST 和拍数对不上）
    output               bvalid,
    input                bready,
    // ---------- 读地址通道 AR ----------
    // 和 AW 同一套字段。读命令收进队列后，R 通道再按拍把数据吐出去。
    input      [IDW-1:0] arid,
    input      [AW-1:0]  araddr,
    input      [7:0]     arlen,
    input      [2:0]     arsize,
    input      [1:0]     arburst,
    input                arvalid,
    output               arready,
    // ---------- 读数据通道 R ----------
    // 一级输出寄存器。RVALID=1 期间 RID/RDATA/RLAST 保持不变，直到 RREADY 把它取走。
    // 每拍一个响应；RLAST=1 的那拍是这条 burst 的最后一拍。
    output reg [IDW-1:0] rid,
    output reg [31:0]    rdata,              // 窄传输也给整个字，主机自己按地址和 SIZE 取字节
    output     [1:0]     rresp,              // 本模块读恒为 OKAY
    output reg           rlast,              // 1 = 按 ARLEN 数，这一拍是最后一拍
    output reg           rvalid,
    input                rready
);
    localparam CW = IDW + AW + 8 + 3 + 2;               // 一条命令打包宽度：{id, addr, len, size, burst}
    localparam [1:0] FIXED = 2'b00, WRAP = 2'b10;      // 其余（INCR=01、保留的 11）按 INCR 处理
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    reg [31:0] mem [0:(1 << (AW - 2)) - 1];            // 按字存储。字节地址的低 2 位不进下标，字节选择靠 WSTRB

    // 同一条 burst 里，由“这一拍地址”算出“下一拍地址”。len/size/burst 来自命令，整笔不变。
    //   bytes = 2^size，每拍字节数
    //   INCR：先按 size 向下对齐再加 bytes。所以只有首拍可以非对齐。
    //         例：首拍地址 0x1、size=2（4 字节）→ 对齐到 0x0，下一拍是 0x4
    //   WRAP：窗口字节数 = (len+1) × bytes，wmask = 窗口-1（低位全 1）。
    //         高位 (a & ~wmask) 不动，低位 (a+bytes) 在窗口里环绕。
    //         例：WRAP4、size=2 → 窗口 16 字节，地址在 16 字节对齐块内转圈
    //   FIXED：每拍都用同一个地址
    function [AW-1:0] next_addr(input [AW-1:0] a, input [2:0] size, input [7:0] len, input [1:0] burst);
        reg [AW-1:0] bytes, wmask;
        begin
            bytes = {{(AW-1){1'b0}}, 1'b1} << size;                      // 每拍字节数
            wmask = (({{(AW-8){1'b0}}, len} + 1'b1) << size) - 1'b1;     // 回绕窗口减 1，低位全 1
            case (burst)
                FIXED:   next_addr = a;                                  // 每拍同一地址
                WRAP:    next_addr = (a & ~wmask) | ((a + bytes) & wmask);
                default: next_addr = (a & ~(bytes - 1'b1)) + bytes;       // INCR
            endcase
        end
    endfunction

    // ======================= 写通道 =======================
    // 队头命令 wc_*：整笔 burst 的描述，来自 AW 队列的出口。
    // 最后一拍数据握手成功才 pop，所以一条命令的 wc_* 在它的所有数据拍期间不变。
    // 队列空时 dout 是上一笔留下的值，但 wready 会被 awq_empty 拉低，不会拿去用。
    wire [CW-1:0]  awq_dout;
    wire           awq_full, awq_empty;
    wire [IDW-1:0] wc_id;          // 队头命令的 ID，最后一拍原样写进 BID
    wire [AW-1:0]  wc_addr;        // 队头命令的首地址。只有第一拍数据用它
    wire [7:0]     wc_len;         // 队头的 AWLEN。最后一拍的判断是“已经收下的拍数 == wc_len”
    wire [2:0]     wc_size;
    wire [1:0]     wc_burst;
    assign {wc_id, wc_addr, wc_len, wc_size, wc_burst} = awq_dout;

    wire bq_full, bq_empty;        // 写响应队列。每条 burst 完成时压入一个 {BID,BRESP}

    // 拍进度。复位后 w_first=1、w_cnt=0，表示“还没吃过数据，下一拍用命令首地址”。
    // 以 AWLEN=3（共 4 拍）为例，每一拍握手成功后的寄存器：
    //   拍 0：用 wc_addr，           之后 w_first=0，w_cnt=1，w_addr_q=下一拍地址
    //   拍 1：用 w_addr_q，          之后 w_cnt=2
    //   拍 2：用 w_addr_q，          之后 w_cnt=3
    //   拍 3：w_cnt==wc_len，是最后一拍；之后 w_first=1，w_cnt=0，准备下一条命令
    reg          w_first;          // 1 = 这一拍是本条 burst 的第一拍，地址取 wc_addr
    reg  [AW-1:0] w_addr_q;        // 上一拍握手时算好的“下一拍地址”。w_first=1 时不看它
    reg  [7:0]    w_cnt;           // 本条 burst 已经收下的拍数。当前这一拍还没算进去
    reg           w_err;           // 前面某拍的 WLAST 和“是不是最后一拍”不一致。留到结束再报
    wire [AW-1:0] w_addr      = w_first ? wc_addr : w_addr_q;
    wire          w_last_beat = (w_cnt == wc_len);   // 按 AWLEN 数，正在握手的这一拍应该是最后一拍

    assign awready = ~awq_full;
    // 没排队的写命令：不能收 W（W 可以先到，但从机有权等 AW）。
    // B 队列满：再完成一条 burst 也塞不进响应，所以整条数据通道停住，避免写了却没处回 B。
    assign wready  = ~awq_empty & ~bq_full;
    wire   w_hs      = wvalid & wready;         // 本拍写数据握手成功：存储器要写，拍计数要走
    wire   w_last_hs = w_hs & w_last_beat;      // 按长度数到的最后一拍。这一拍弹出 AW、压入 B
    // 主机给的 WLAST 应只在最后一拍为 1。任一拍对不上就记住，最后一拍的 BRESP 用这个结果
    wire   w_err_now = w_err | (wlast != w_last_beat);

    axi_fifo #(.W(CW), .AW(QAW)) u_awq (
        .clk(aclk), .rst_n(aresetn),
        .push(awvalid & awready), .din({awid, awaddr, awlen, awsize, awburst}), .full(awq_full),
        .pop(w_last_hs), .dout(awq_dout), .empty(awq_empty));

    // 只在真正收下数据的沿更新进度。w_last_beat 为 1 时把进度清回“下一条的第一拍”
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            w_first <= 1'b1;
            w_cnt   <= 8'd0;
            w_err   <= 1'b0;
        end else if (w_hs) begin
            w_first <= w_last_beat;
            w_cnt   <= w_last_beat ? 8'd0 : w_cnt + 8'd1;
            w_err   <= w_last_beat ? 1'b0 : w_err_now;
        end
    end

    always @(posedge aclk) begin
        if (w_hs) w_addr_q <= next_addr(w_addr, wc_size, wc_len, wc_burst);
    end

    // WSTRB 摊成 32 位：为 1 的字节用 WDATA，为 0 的字节留存储器里的旧值。
    // 字下标只用地址去掉低 2 位。字节写、半字写都靠这层掩码，不另做窄存储
    wire [31:0] wmask32 = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};
    always @(posedge aclk) begin
        if (w_hs) mem[w_addr[AW-1:2]] <= (mem[w_addr[AW-1:2]] & ~wmask32) | (wdata & wmask32);
    end

    // B 队列出口就是当前要回的响应。空队列时 bvalid=0，bid/bresp 是旧值，主机不该采样
    wire [IDW+1:0] bq_dout;
    assign {bid, bresp} = bq_dout;
    assign bvalid = ~bq_empty;

    axi_fifo #(.W(IDW + 2), .AW(QAW)) u_bq (
        .clk(aclk), .rst_n(aresetn),
        .push(w_last_hs), .din({wc_id, (w_err_now ? SLVERR : OKAY)}), .full(bq_full),
        .pop(bvalid & bready), .dout(bq_dout), .empty(bq_empty));

    // ======================= 读通道 =======================
    // 和写命令同一套：rc_* 是队头整笔读命令，做完最后一拍才 pop。
    // 返回顺序就是 AR 的接收顺序，不按 RID 插队。
    wire [CW-1:0]  arq_dout;
    wire           arq_full, arq_empty;
    wire [IDW-1:0] rc_id;          // 每一拍 R 都带这个 ID
    wire [AW-1:0]  rc_addr;        // 本条读的首地址
    wire [7:0]     rc_len;
    wire [2:0]     rc_size;
    wire [1:0]     rc_burst;
    assign {rc_id, rc_addr, rc_len, rc_size, rc_burst} = arq_dout;

    // 拍进度，含义和写侧 w_first / w_cnt / w_addr_q 相同，只是这里是“已经发出去”的拍数
    reg           r_first;         // 1 = 下一拍要发的是本条 burst 的第一拍，地址取 rc_addr
    reg  [AW-1:0] r_addr_q;        // 上一拍装载时算好的下一拍地址
    reg  [7:0]    r_cnt;           // 本条 burst 已经发出的拍数
    wire [AW-1:0] r_addr      = r_first ? rc_addr : r_addr_q;
    wire          r_last_beat = (r_cnt == rc_len);

    // 输出寄存器能装下一拍的条件（两个都要）：
    //   队头有读命令；
    //   并且输出是空的（rvalid=0），或者主机本拍正好把当前拍取走（rready=1）。
    // rvalid=1 且 rready=0 时 r_load=0，rdata/rid/rlast 保持，符合“VALID 期间数据不许变”。
    wire r_load = ~arq_empty & (~rvalid | rready);

    assign arready = ~arq_full;
    assign rresp   = OKAY;

    // 装载的是最后一拍时，同一沿弹出这条 AR。队头 dout 要到下一拍才变成下一条命令，
    // 所以本拍用的 rc_* 仍然是正在结束的这一条
    axi_fifo #(.W(CW), .AW(QAW)) u_arq (
        .clk(aclk), .rst_n(aresetn),
        .push(arvalid & arready), .din({arid, araddr, arlen, arsize, arburst}), .full(arq_full),
        .pop(r_load & r_last_beat), .dout(arq_dout), .empty(arq_empty));

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rvalid  <= 1'b0;
            r_first <= 1'b1;
            r_cnt   <= 8'd0;
        end else begin
            // 装上新拍 → 有数据；没装上但主机把旧拍取走了 → 变空。两件都发生时保持 1（换上一拍新的）
            if (r_load)      rvalid <= 1'b1;
            else if (rready) rvalid <= 1'b0;
            if (r_load) begin
                r_first <= r_last_beat;                              // 最后一拍之后，下一条从第一拍开始
                r_cnt   <= r_last_beat ? 8'd0 : r_cnt + 8'd1;
            end
        end
    end

    always @(posedge aclk) begin
        if (r_load) begin
            rdata    <= mem[r_addr[AW-1:2]];    // 窄传输也返回整个字，主机按地址取字节
            rid      <= rc_id;
            rlast    <= r_last_beat;
            r_addr_q <= next_addr(r_addr, rc_size, rc_len, rc_burst);
        end
    end
endmodule
