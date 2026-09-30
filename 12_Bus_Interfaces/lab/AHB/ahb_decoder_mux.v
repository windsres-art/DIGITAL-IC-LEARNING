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
    input      [31:0] haddr,
    input      [1:0]  htrans,
    output            hsel0,
    output            hsel1,
    input             hreadyout0,
    input             hresp0,
    input      [31:0] hrdata0,
    input             hreadyout1,
    input             hresp1,
    input      [31:0] hrdata1,
    output reg        hready,
    output reg        hresp,
    output reg [31:0] hrdata
);
    localparam SEL_S0 = 2'd0, SEL_S1 = 2'd1, SEL_DEF = 2'd2, SEL_NONE = 2'd3;

    assign hsel0 = ((haddr & S0_MASK) == S0_BASE);
    assign hsel1 = ((haddr & S1_MASK) == S1_BASE);
    wire   hsel_def = ~hsel0 & ~hsel1;
    wire   unused_htrans0 = htrans[0];

    wire [1:0] sel_ap = hsel0 ? SEL_S0 : hsel1 ? SEL_S1 : SEL_DEF;
    reg  [1:0] sel_dp;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)    sel_dp <= SEL_NONE;
        else if (hready) sel_dp <= sel_ap;
    end

    // ---------------- 默认从机：两拍 ERROR ----------------
    // 第 1 拍 HREADY=0 HRESP=1（给主机一拍时间决定是否取消后续传输），
    // 第 2 拍 HREADY=1 HRESP=1
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
