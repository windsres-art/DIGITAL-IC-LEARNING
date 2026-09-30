// =============================================================================
// 小同步 FIFO（首字直通 FWFT：非空时 dout 就是队头，pop 当拍取走）
//   用作 axi_ram 的 AW / AR 命令队列和 B 响应队列。深度 2^AW，AW ≥ 1。
//   满空判断同 ../../../03_Common_Circuits/lab/FIFO/fifo_sync.v（指针多 1 bit）
// =============================================================================
module axi_fifo #(
    parameter W  = 8,
    parameter AW = 2
)(
    input          clk,
    input          rst_n,
    input          push,
    input  [W-1:0] din,
    output         full,
    input          pop,
    output [W-1:0] dout,
    output         empty
);
    localparam D = 1 << AW;

    reg [W-1:0] mem [0:D-1];
    reg [AW:0]  wp, rp;

    assign empty = (wp == rp);
    assign full  = (wp[AW] != rp[AW]) && (wp[AW-1:0] == rp[AW-1:0]);
    assign dout  = mem[rp[AW-1:0]];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= {(AW+1){1'b0}};
            rp <= {(AW+1){1'b0}};
        end else begin
            if (push & ~full) wp <= wp + 1'b1;
            if (pop & ~empty) rp <= rp + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (push & ~full) mem[wp[AW-1:0]] <= din;
    end
endmodule
