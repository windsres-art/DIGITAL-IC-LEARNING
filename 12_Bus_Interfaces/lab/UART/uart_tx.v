// =============================================================================
// UART 发送器：1 起始位 + 8 数据位（LSB 先发）+ 可选校验位 + 1/2 停止位
//   tick：16 倍波特率的使能脉冲，每 16 个 tick 发一位
//   输入口 valid/ready：ready=1 时空闲，valid&ready 当拍装载一帧
//   PARITY：0 无校验，1 奇校验，2 偶校验
// =============================================================================
module uart_tx #(
    parameter PARITY = 0,
    parameter STOP   = 1
)(
    input        clk,
    input        rst_n,
    input        tick,
    input  [7:0] data,
    input        valid,
    output       ready,
    output reg   txd
);
    localparam NBITS = 1 + 8 + ((PARITY != 0) ? 1 : 0) + STOP;   // 含起始位

    // 奇校验：数据 + 校验位中 1 的个数为奇数；偶校验：为偶数
    wire        par   = (PARITY == 1) ? ~^data : ^data;
    // 起始位之后按 LSB 先出的顺序排好；高位补 1 就是停止位
    wire [10:0] frame = (PARITY == 0) ? {3'b111, data} : {2'b11, par, data};

    reg        active;
    reg [3:0]  ovs;                 // 位内 tick 计数 0..15
    reg [3:0]  bitn;                // 当前是第几位（0 = 起始位）
    reg [10:0] sh;

    assign ready = ~active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            txd    <= 1'b1;         // 空闲为高
            ovs    <= 4'd0;
            bitn   <= 4'd0;
            sh     <= 11'h7FF;
        end else if (!active) begin
            if (valid) begin
                active <= 1'b1;
                txd    <= 1'b0;     // 起始位
                sh     <= frame;
                ovs    <= 4'd0;
                bitn   <= 4'd0;
            end
        end else if (tick) begin
            if (ovs == 4'd15) begin
                ovs <= 4'd0;
                if (bitn == NBITS - 1) begin
                    active <= 1'b0;
                    txd    <= 1'b1;
                end else begin
                    txd  <= sh[0];
                    sh   <= {1'b1, sh[10:1]};
                    bitn <= bitn + 1'b1;
                end
            end else begin
                ovs <= ovs + 1'b1;
            end
        end
    end
endmodule
