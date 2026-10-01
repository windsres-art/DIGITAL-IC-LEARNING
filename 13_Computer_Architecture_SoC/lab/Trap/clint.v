// =============================================================================
// CLINT（Core-Local Interruptor）：机器模式定时器 + 软件中断，单 hart
//   寄存器（与 SiFive / QEMU virt 相同的偏移）：
//     0x0000  msip        bit 0 = 软件中断请求（写 1 触发，写 0 清除）
//     0x4000  mtimecmp    低 32 bit       0x4004  mtimecmp 高 32 bit
//     0xBFF8  mtime       低 32 bit       0xBFFC  mtime 高 32 bit
//   mtime 每 DIV 个时钟加 1；mtip = (mtime >= mtimecmp)，是电平：
//   软件改写 mtimecmp 到将来的时刻，中断才会撤销。复位时 mtimecmp 为全 1，不会误触发。
//   寄存器口：req 为 1 的那一拍完成一次访问（读数据组合输出），只支持整字访问
// =============================================================================
module clint #(
    parameter DIV = 1
)(
    input             clk,
    input             rst_n,
    input             req,
    input             we,
    input      [15:0] addr,
    input      [31:0] wdata,
    output reg [31:0] rdata,
    output            irq_timer,
    output            irq_soft
);
    localparam integer DW = (DIV > 1) ? $clog2(DIV) : 1;
    localparam integer DIV_LAST_I = (DIV > 1) ? DIV - 1 : 0;
    localparam [DW-1:0] DIV_LAST = DIV_LAST_I[DW-1:0];

    reg [63:0]   mtime, mtimecmp;
    reg          msip;
    reg [DW-1:0] div_cnt;

    wire tick = (DIV <= 1) || (div_cnt == DIV_LAST);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime    <= 64'd0;
            mtimecmp <= {64{1'b1}};
            msip     <= 1'b0;
            div_cnt  <= {DW{1'b0}};
        end else begin
            div_cnt <= tick ? {DW{1'b0}} : div_cnt + 1'b1;
            if (tick) mtime <= mtime + 64'd1;
            if (req && we) begin
                case (addr)
                    16'h0000: msip            <= wdata[0];
                    16'h4000: mtimecmp[31:0]  <= wdata;
                    16'h4004: mtimecmp[63:32] <= wdata;
                    16'hBFF8: mtime[31:0]     <= wdata;     // 写优先于自增
                    16'hBFFC: mtime[63:32]    <= wdata;
                    default: ;
                endcase
            end
        end
    end

    always @* begin
        case (addr)
            16'h0000: rdata = {31'd0, msip};
            16'h4000: rdata = mtimecmp[31:0];
            16'h4004: rdata = mtimecmp[63:32];
            16'hBFF8: rdata = mtime[31:0];
            16'hBFFC: rdata = mtime[63:32];
            default:  rdata = 32'd0;
        endcase
    end

    assign irq_timer = (mtime >= mtimecmp);
    assign irq_soft  = msip;
endmodule
