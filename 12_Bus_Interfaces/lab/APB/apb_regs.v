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
    input               presetn,
    input      [AW-1:0] paddr,
    input               psel,
    input               penable,
    input               pwrite,
    input      [31:0]   pwdata,
    input      [3:0]    pstrb,
    output              pready,
    output reg [31:0]   prdata,
    output              pslverr,
    // 硬件侧
    output     [31:0]   ctrl_o,
    input      [31:0]   status_i,
    input      [31:0]   irq_set_i,          // 每 bit 一拍脉冲
    output              irq_o
);
    localparam CW = (WAIT > 0) ? $clog2(WAIT + 1) : 1;
    localparam [CW-1:0] WAIT_C = WAIT[CW-1:0];

    localparam [AW-3:0] A_CTRL     = 'h00 >> 2;
    localparam [AW-3:0] A_SCRATCH  = 'h04 >> 2;
    localparam [AW-3:0] A_STATUS   = 'h08 >> 2;
    localparam [AW-3:0] A_INT_STAT = 'h0C >> 2;
    localparam [AW-3:0] A_INT_EN   = 'h10 >> 2;

    reg [31:0] ctrl, scratch, int_stat, int_en;

    // ---------------- 等待状态 ----------------
    reg  [CW-1:0] wcnt;
    wire          access = psel & penable;
    assign pready = (wcnt == WAIT_C);

    always @(posedge pclk or negedge presetn) begin
        if (!presetn)              wcnt <= {CW{1'b0}};
        else if (access & pready)  wcnt <= {CW{1'b0}};
        else if (access)           wcnt <= wcnt + 1'b1;
    end

    // ---------------- 地址译码 ----------------
    wire [AW-3:0] widx = paddr[AW-1:2];     // 按字寻址，忽略低 2 位
    wire          unused_paddr = &{1'b0, paddr[1:0]};
    wire hit_ctrl  = (widx == A_CTRL);
    wire hit_scr   = (widx == A_SCRATCH);
    wire hit_stat  = (widx == A_STATUS);
    wire hit_int   = (widx == A_INT_STAT);
    wire hit_en    = (widx == A_INT_EN);
    wire hit_any   = hit_ctrl | hit_scr | hit_stat | hit_int | hit_en;

    wire xfer   = access & pready;              // 传输完成拍
    wire wr     = xfer & pwrite;
    wire bad_wr = pwrite & hit_stat;            // 写只读寄存器

    // PSLVERR 只在传输完成拍有意义，其它时候保持 0
    assign pslverr = xfer & (~hit_any | bad_wr);

    // PSTRB 展开成位掩码
    wire [31:0] bmask = {{8{pstrb[3]}}, {8{pstrb[2]}}, {8{pstrb[1]}}, {8{pstrb[0]}}};

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

    // W1C：软件写 1 的位清零；硬件置位写在后面，同拍冲突时置位优先（不丢中断）
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
