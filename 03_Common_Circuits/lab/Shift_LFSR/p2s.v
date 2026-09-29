// =============================================================================
// 并转串（parallel to serial），MSB 先出
//   - 握手：load && ready 时锁存 pin；ready 表示"可以接收下一个字"
//   - cnt = 还剩几位没输出完；sout_vld = (cnt != 0)
//   - ready 在最后一位输出的那拍就拉高（cnt <= 1），上游连续给数时字与字之间
//     没有空拍：每 WIDTH 个时钟正好输出一个字
// =============================================================================
module p2s #(
    parameter WIDTH = 8
)(
    input              clk,
    input              rst_n,
    input  [WIDTH-1:0] pin,
    input              load,
    output             ready,
    output             sout,
    output             sout_vld
);
    localparam CW = $clog2(WIDTH + 1);
    localparam integer  WIDTH_I = WIDTH;
    localparam [CW-1:0] FULL    = WIDTH_I[CW-1:0];
    localparam [CW-1:0] ONE     = {{(CW-1){1'b0}}, 1'b1};

    reg [WIDTH-1:0] sh;
    reg [CW-1:0]    cnt;

    assign sout     = sh[WIDTH-1];
    assign sout_vld = (cnt != {CW{1'b0}});
    assign ready    = (cnt <= ONE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh  <= {WIDTH{1'b0}};
            cnt <= {CW{1'b0}};
        end else if (load && ready) begin
            sh  <= pin;
            cnt <= FULL;
        end else if (sout_vld) begin
            sh  <= {sh[WIDTH-2:0], 1'b0};
            cnt <= cnt - ONE;
        end
    end

endmodule
