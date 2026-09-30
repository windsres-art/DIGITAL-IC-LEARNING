// =============================================================================
// AXI4 从机：32 bit 数据的 RAM（容量 2^AW 字节）
//   支持：五通道独立握手、ID、FIXED / INCR / WRAP burst、窄传输（AxSIZE < 字）、
//         INCR/FIXED 首拍非对齐、WSTRB、多个 outstanding（AW/AR 命令队列深度 2^QAW）
//   不支持：乱序返回（同一时刻只处理队头命令，按接收顺序返回——对任何 ID 都合法）、
//           读写交织顺序保证（AXI 本身不保证读写通道之间的顺序）、exclusive、
//           AxLOCK/AxCACHE/AxPROT/AxQOS（未引出）
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
    parameter QAW = 2                   // 命令队列深度 2^QAW
)(
    input                aclk,
    input                aresetn,
    // 写地址
    input      [IDW-1:0] awid,
    input      [AW-1:0]  awaddr,
    input      [7:0]     awlen,
    input      [2:0]     awsize,
    input      [1:0]     awburst,
    input                awvalid,
    output               awready,
    // 写数据
    input      [31:0]    wdata,
    input      [3:0]     wstrb,
    input                wlast,
    input                wvalid,
    output               wready,
    // 写响应
    output     [IDW-1:0] bid,
    output     [1:0]     bresp,
    output               bvalid,
    input                bready,
    // 读地址
    input      [IDW-1:0] arid,
    input      [AW-1:0]  araddr,
    input      [7:0]     arlen,
    input      [2:0]     arsize,
    input      [1:0]     arburst,
    input                arvalid,
    output               arready,
    // 读数据
    output reg [IDW-1:0] rid,
    output reg [31:0]    rdata,
    output     [1:0]     rresp,
    output reg           rlast,
    output reg           rvalid,
    input                rready
);
    localparam CW = IDW + AW + 8 + 3 + 2;               // 命令宽度 {id, addr, len, size, burst}
    localparam [1:0] FIXED = 2'b00, WRAP = 2'b10;      // 其余（INCR=01、保留的 11）按 INCR 处理
    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    reg [31:0] mem [0:(1 << (AW - 2)) - 1];

    // 下一拍地址。INCR 先按 size 对齐再加，所以只有首拍可以非对齐；
    // WRAP 的回绕窗口 = 拍数 × 每拍字节数，起始地址必须按 size 对齐（主机保证）
    function [AW-1:0] next_addr(input [AW-1:0] a, input [2:0] size, input [7:0] len, input [1:0] burst);
        reg [AW-1:0] bytes, wmask;
        begin
            bytes = {{(AW-1){1'b0}}, 1'b1} << size;
            wmask = (({{(AW-8){1'b0}}, len} + 1'b1) << size) - 1'b1;
            case (burst)
                FIXED:   next_addr = a;
                WRAP:    next_addr = (a & ~wmask) | ((a + bytes) & wmask);
                default: next_addr = (a & ~(bytes - 1'b1)) + bytes;     // INCR
            endcase
        end
    endfunction

    // ======================= 写通道 =======================
    wire [CW-1:0]  awq_dout;
    wire           awq_full, awq_empty;
    wire [IDW-1:0] wc_id;
    wire [AW-1:0]  wc_addr;
    wire [7:0]     wc_len;
    wire [2:0]     wc_size;
    wire [1:0]     wc_burst;
    assign {wc_id, wc_addr, wc_len, wc_size, wc_burst} = awq_dout;

    wire bq_full, bq_empty;
    reg          w_first;               // 下一拍是 burst 的第一拍（地址取自命令本身）
    reg  [AW-1:0] w_addr_q;
    reg  [7:0]    w_cnt;
    reg           w_err;
    wire [AW-1:0] w_addr      = w_first ? wc_addr : w_addr_q;
    wire          w_last_beat = (w_cnt == wc_len);

    assign awready = ~awq_full;
    assign wready  = ~awq_empty & ~bq_full;     // 有命令、B 队列有空位才收数据
    wire   w_hs      = wvalid & wready;
    wire   w_last_hs = w_hs & w_last_beat;
    wire   w_err_now = w_err | (wlast != w_last_beat);

    axi_fifo #(.W(CW), .AW(QAW)) u_awq (
        .clk(aclk), .rst_n(aresetn),
        .push(awvalid & awready), .din({awid, awaddr, awlen, awsize, awburst}), .full(awq_full),
        .pop(w_last_hs), .dout(awq_dout), .empty(awq_empty));

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

    wire [31:0] wmask32 = {{8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}}};
    always @(posedge aclk) begin
        if (w_hs) mem[w_addr[AW-1:2]] <= (mem[w_addr[AW-1:2]] & ~wmask32) | (wdata & wmask32);
    end

    wire [IDW+1:0] bq_dout;
    assign {bid, bresp} = bq_dout;
    assign bvalid = ~bq_empty;

    axi_fifo #(.W(IDW + 2), .AW(QAW)) u_bq (
        .clk(aclk), .rst_n(aresetn),
        .push(w_last_hs), .din({wc_id, (w_err_now ? SLVERR : OKAY)}), .full(bq_full),
        .pop(bvalid & bready), .dout(bq_dout), .empty(bq_empty));

    // ======================= 读通道 =======================
    wire [CW-1:0]  arq_dout;
    wire           arq_full, arq_empty;
    wire [IDW-1:0] rc_id;
    wire [AW-1:0]  rc_addr;
    wire [7:0]     rc_len;
    wire [2:0]     rc_size;
    wire [1:0]     rc_burst;
    assign {rc_id, rc_addr, rc_len, rc_size, rc_burst} = arq_dout;

    reg           r_first;
    reg  [AW-1:0] r_addr_q;
    reg  [7:0]    r_cnt;
    wire [AW-1:0] r_addr      = r_first ? rc_addr : r_addr_q;
    wire          r_last_beat = (r_cnt == rc_len);

    // 输出寄存器空、或者本拍正在被取走，才能装下一拍
    wire r_load = ~arq_empty & (~rvalid | rready);

    assign arready = ~arq_full;
    assign rresp   = OKAY;

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
            if (r_load)      rvalid <= 1'b1;
            else if (rready) rvalid <= 1'b0;
            if (r_load) begin
                r_first <= r_last_beat;
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
