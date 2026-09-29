// =============================================================================
// 同步 FIFO（读写同一时钟）
//   - 深度 DEPTH = 2^AW，指针多 1 bit：低 AW 位是 RAM 地址，最高位是"圈数"
//   - 空：指针完全相等；满：最高位不同、低位相同（写比读多绕一圈）
//   - 读口为同步读：rd_en 有效（且非空）的下一拍 rdata 才是读出的数据
//   - 满时写、空时读都会被忽略（内部 fire 信号屏蔽），不会写穿/读穿
// =============================================================================
module fifo_sync #(
    parameter DW = 8,               // 数据位宽
    parameter AW = 4                // 地址位宽，深度 = 2^AW
)(
    input                clk,
    input                rst_n,
    input                wr_en,
    input      [DW-1:0]  wdata,
    input                rd_en,
    output reg [DW-1:0]  rdata,
    output               full,
    output               empty,
    output     [AW:0]    count      // 当前存储个数 0..DEPTH，需要 AW+1 位
);
    localparam DEPTH = 1 << AW;

    reg [DW-1:0] mem [0:DEPTH-1];
    reg [AW:0]   wptr, rptr;

    wire wr_fire = wr_en & ~full;
    wire rd_fire = rd_en & ~empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       wptr <= {(AW+1){1'b0}};
        else if (wr_fire) wptr <= wptr + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       rptr <= {(AW+1){1'b0}};
        else if (rd_fire) rptr <= rptr + 1'b1;
    end

    // 存储体不带复位：这样综合工具才能把它映射成 SRAM / 寄存器堆；
    // 带复位的数组只能用触发器实现，面积大很多
    always @(posedge clk) begin
        if (wr_fire) mem[wptr[AW-1:0]] <= wdata;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       rdata <= {DW{1'b0}};
        else if (rd_fire) rdata <= mem[rptr[AW-1:0]];
    end

    assign empty = (wptr == rptr);
    assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
    // 指针差按 AW+1 位取模，绕回后依然正确
    assign count = wptr - rptr;

endmodule
