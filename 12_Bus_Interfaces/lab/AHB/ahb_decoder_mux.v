// =============================================================================
// AHB-Lite 单主机互联：地址译码器 + 从机响应多路选择器 + 默认从机
//   地址映射（参数可改）：
//     S0  0x0000_0000 – 0x0000_0FFF  4 KB
//     S1  0x0000_1000 – 0x0000_13FF  1 KB
//     其它 → 默认从机：NONSEQ/SEQ 回两拍 ERROR，IDLE/BUSY 回零等待 OKAY
//   关键点：HSEL 是地址阶段的组合译码，而 HRDATA/HREADY/HRESP 属于数据阶段，
//   所以响应 MUX 的选择信号必须是"地址阶段完成时寄存下来"的 sel_dp。
// =============================================================================
module ahb_decoder_mux #(
    parameter [31:0] S0_BASE = 32'h0000_0000,
    parameter [31:0] S0_MASK = 32'hFFFF_F000,
    parameter [31:0] S1_BASE = 32'h0000_1000,
    parameter [31:0] S1_MASK = 32'hFFFF_FC00
)(
    input             hclk,
    input             hresetn,
    input      [31:0] haddr,          // 地址阶段的地址，用来译码 HSEL
    input      [1:0]  htrans,         // 只看 bit 1：NONSEQ/SEQ 才让默认从机进入 ERROR
    output            hsel0,          // 地址落在 S0 窗口
    output            hsel1,          // 地址落在 S1 窗口
    input             hreadyout0,     // S0 数据阶段是否结束
    input             hresp0,         // S0 响应，0=OKAY，1=ERROR
    input      [31:0] hrdata0,
    input             hreadyout1,
    input             hresp1,
    input      [31:0] hrdata1,
    output reg        hready,         // 送回主机的全局 HREADY，按数据阶段那一台从机选
    output reg        hresp,
    output reg [31:0] hrdata
);
    localparam SEL_S0 = 2'd0, SEL_S1 = 2'd1, SEL_DEF = 2'd2, SEL_NONE = 2'd3;

    // 掩码把窗口以外的位清掉，再和基址比。S0 低 12 位忽略 = 4 KB，S1 低 10 位忽略 = 1 KB
    assign hsel0 = ((haddr & S0_MASK) == S0_BASE);
    assign hsel1 = ((haddr & S1_MASK) == S1_BASE);
    wire   hsel_def = ~hsel0 & ~hsel1;     // 两个窗口都不是，交给默认从机
    wire   unused_htrans0 = htrans[0];     // 不区分 SEQ / NONSEQ，接出来避免未读告警

    wire [1:0] sel_ap = hsel0 ? SEL_S0 : hsel1 ? SEL_S1 : SEL_DEF;  // 地址阶段选中谁
    reg  [1:0] sel_dp;                     // 数据阶段选中谁。响应 MUX 必须用它，不能用当前 HSEL

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)    sel_dp <= SEL_NONE;
        else if (hready) sel_dp <= sel_ap;
    end

    // ---------------- 默认从机：两拍 ERROR ----------------
    // err1：ERROR 的第一拍，HREADY=0、HRESP=1，给主机一拍决定要不要取消后续 burst
    // err2：第二拍，HREADY=1、HRESP=1，传输在这一拍结束
    reg err1, err2;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            err1 <= 1'b0;
            err2 <= 1'b0;
        end else if (err1) begin
            err1 <= 1'b0;
            err2 <= 1'b1;
        end else if (hready) begin
            err2 <= 1'b0;
            err1 <= hsel_def & htrans[1];
        end
    end

    // ---------------- 响应 MUX（按数据阶段选择）----------------
    always @(*) begin
        case (sel_dp)
            SEL_S0:  begin hready = hreadyout0; hresp = hresp0;      hrdata = hrdata0; end
            SEL_S1:  begin hready = hreadyout1; hresp = hresp1;      hrdata = hrdata1; end
            SEL_DEF: begin hready = ~err1;      hresp = err1 | err2; hrdata = 32'h0;   end
            default: begin hready = 1'b1;       hresp = 1'b0;        hrdata = 32'h0;   end
        endcase
    end
endmodule
