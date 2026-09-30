// =============================================================================
// APB4 从机：一组控制/状态寄存器（最常见的 APB 从机形态）
//   偏移   名称      类型   说明
//   0x00   CTRL      RW     支持 PSTRB 按字节写
//   0x04   SCRATCH   RW     软件自测用
//   0x08   STATUS    RO     硬件输入 status_i；写它返回 PSLVERR，内容不变
//   0x0C   INT_STAT  W1C    硬件 irq_set_i 置位，软件写 1 清零；同拍冲突时置位优先
//   0x10   INT_EN    RW     irq_o = |(INT_STAT & INT_EN)
//   其它   —         —      读返回 0，读写都返回 PSLVERR
//
//   WAIT：每笔传输在 ACCESS 阶段插入的等待拍数（0 = 零等待）
//   写操作在 ACCESS 阶段最后一拍（psel & penable & pready）的上升沿生效，
//   读数据 prdata 是组合输出，在同一拍被主机采样。
// =============================================================================
module apb_regs #(
    parameter AW   = 12,
    parameter WAIT = 0
)(
    input               pclk,
    input               presetn,            // 低有效复位
    input      [AW-1:0] paddr,              // 字节地址。本模块只看 [AW-1:2]，按字对齐
    input               psel,               // 1 = 主机选中本从机
    input               penable,            // 0 = SETUP，1 = ACCESS
    input               pwrite,             // 1 = 写，0 = 读
    input      [31:0]   pwdata,             // 写数据
    input      [3:0]    pstrb,              // 写字节使能，bit 0 = pwdata[7:0]
    output              pready,             // ACCESS 中数到 WAIT 拍才为 1
    output reg [31:0]   prdata,             // 读数据，组合输出，完成拍被主机采样
    output              pslverr,            // 仅完成拍可能为 1：地址未映射，或写 STATUS
    // 硬件侧：寄存器和模块外面的电路
    output     [31:0]   ctrl_o,             // CTRL 的当前值，给外设逻辑用
    input      [31:0]   status_i,           // 只读状态，直接送到 PRDATA
    input      [31:0]   irq_set_i,          // 每 bit 一拍脉冲，把 INT_STAT 对应位置 1
    output              irq_o               // INT_STAT 和 INT_EN 按位与之后，有任一位为 1
);
    // wcnt 要能数到 WAIT。WAIT = 0 时仍留 1 位，避免 0 宽度
    localparam CW = (WAIT > 0) ? $clog2(WAIT + 1) : 1;
    localparam [CW-1:0] WAIT_C = WAIT[CW-1:0];   // 数到这个值就给 PREADY

    // 字节偏移右移 2 位，变成字地址，和 paddr[AW-1:2] 比较
    localparam [AW-3:0] A_CTRL     = 'h00 >> 2;
    localparam [AW-3:0] A_SCRATCH  = 'h04 >> 2;
    localparam [AW-3:0] A_STATUS   = 'h08 >> 2;
    localparam [AW-3:0] A_INT_STAT = 'h0C >> 2;
    localparam [AW-3:0] A_INT_EN   = 'h10 >> 2;

    reg [31:0] ctrl, scratch, int_stat, int_en;

    // ---------------- 等待状态 ----------------
    reg  [CW-1:0] wcnt;                  // ACCESS 阶段已经等待的拍数
    wire          access = psel & penable;
    assign pready = (wcnt == WAIT_C);    // WAIT = 0 时第一拍 ACCESS 就是完成拍

    always @(posedge pclk or negedge presetn) begin
        if (!presetn)              wcnt <= {CW{1'b0}};
        else if (access & pready)  wcnt <= {CW{1'b0}};
        else if (access)           wcnt <= wcnt + 1'b1;
    end

    // ---------------- 地址译码 ----------------
    wire [AW-3:0] widx = paddr[AW-1:2];     // 字地址。0x00 和 0x01/0x02/0x03 都命中 CTRL
    // 低 2 位不参与译码。接进这个常量 0 的与，是为了让 lint 认为这两位被读过
    wire          unused_paddr = &{1'b0, paddr[1:0]};
    wire hit_ctrl  = (widx == A_CTRL);
    wire hit_scr   = (widx == A_SCRATCH);
    wire hit_stat  = (widx == A_STATUS);
    wire hit_int   = (widx == A_INT_STAT);
    wire hit_en    = (widx == A_INT_EN);
    wire hit_any   = hit_ctrl | hit_scr | hit_stat | hit_int | hit_en;

    wire xfer   = access & pready;              // 完成拍：写在这个沿生效，读在这个沿被采样
    wire wr     = xfer & pwrite;                // 完成拍上的写
    wire bad_wr = pwrite & hit_stat;            // 写只读的 STATUS

    // 完成拍，并且地址没有寄存器，或者在写 STATUS，才报错。其它拍为 0
    assign pslverr = xfer & (~hit_any | bad_wr);

    // 把 4 位字节使能摊成 32 位掩码。pstrb[0]=1 时低 8 位全 1
    wire [31:0] bmask = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};

    // 掩码为 1 的位用新数据，为 0 的位留旧值
    function [31:0] merge(input [31:0] old, input [31:0] nw, input [31:0] m);
        merge = (old & ~m) | (nw & m);
    endfunction

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl    <= 32'h0;
            scratch <= 32'h0;
            int_en  <= 32'h0;
        end else if (wr) begin
            if (hit_ctrl) ctrl    <= merge(ctrl,    pwdata, bmask);
            if (hit_scr)  scratch <= merge(scratch, pwdata, bmask);
            if (hit_en)   int_en  <= merge(int_en,  pwdata, bmask);
        end
    end

    // 软件要清的位：写 INT_STAT，且该字节的 PSTRB 为 1，数据位为 1
    // 后面 int_stat <= (int_stat & ~w1c) | irq_set_i，同拍置位优先
    wire [31:0] w1c = (wr & hit_int) ? (pwdata & bmask) : 32'h0;
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) int_stat <= 32'h0;
        else          int_stat <= (int_stat & ~w1c) | irq_set_i;
    end

    // ---------------- 读 ----------------
    always @(*) begin
        prdata = 32'h0;
        if (psel & ~pwrite) begin
            case (1'b1)
                hit_ctrl: prdata = ctrl;
                hit_scr:  prdata = scratch;
                hit_stat: prdata = status_i;
                hit_int:  prdata = int_stat;
                hit_en:   prdata = int_en;
                default:  prdata = 32'h0;
            endcase
        end
    end

    assign ctrl_o = ctrl;
    assign irq_o  = |(int_stat & int_en);
endmodule
