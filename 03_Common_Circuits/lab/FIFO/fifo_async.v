// 深度为 2^AW，AW >= 2。传入的 wrst_n、rrst_n 须在各自时钟域同步释放。
module fifo_async #(parameter DW = 8, parameter AW = 4) (
    input wclk, wrst_n, wr_en,
    input [DW-1:0] wdata,
    output reg wfull,
    input rclk, rrst_n, rd_en,
    output reg [DW-1:0] rdata,
    output reg rempty
);
    reg [DW-1:0] mem [0:(1 << AW)-1];
    reg [AW:0] wbin, rbin;     // 低 AW 位选槽，最高位区分是否绕了一圈
    reg [AW:0] wgray, rgray;   // 寄存后送到对侧时钟域
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_w1, rgray_w2;
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_r1, wgray_r2;

    wire wr_fire = wr_en && !wfull;
    wire rd_fire = rd_en && !rempty;

    // 存储槽：写时钟改 mem，读时钟取出队首。读走后只移动读指针。
    always @(posedge wclk)
        if (wr_fire) mem[wbin[AW-1:0]] <= wdata;

    always @(posedge rclk or negedge rrst_n)
        if (!rrst_n)      rdata <= 0;
        else if (rd_fire) rdata <= mem[rbin[AW-1:0]];

    // 写域：写入才前进。写指针领先整整一圈时满，对应 Gray 高两位取反。
    wire [AW:0] wbin_next  = wr_fire ? wbin + 1 : wbin;
    wire [AW:0] wgray_next = wbin_next ^ (wbin_next >> 1);
    wire [AW:0] full_mark  = {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]};

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rgray_w1 <= 0;
            rgray_w2 <= 0;
            wbin     <= 0;
            wgray    <= 0;
            wfull    <= 1'b0;
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
            wbin     <= wbin_next;
            wgray    <= wgray_next;
            wfull    <= (wgray_next == full_mark);
        end
    end

    // 读域：读出才前进。读指针追上同步过来的写指针时空。
    wire [AW:0] rbin_next  = rd_fire ? rbin + 1 : rbin;
    wire [AW:0] rgray_next = rbin_next ^ (rbin_next >> 1);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wgray_r1 <= 0;
            wgray_r2 <= 0;
            rbin     <= 0;
            rgray    <= 0;
            rempty   <= 1'b1;
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
            rbin     <= rbin_next;
            rgray    <= rgray_next;
            rempty   <= (rgray_next == wgray_r2);
        end
    end
endmodule
