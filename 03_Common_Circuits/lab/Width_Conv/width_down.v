// =============================================================================
// 宽转窄（downsizer）：一个 OUT_W*RATIO 位宽字拆成 RATIO 个 OUT_W 位窄字，低位先出
//   - 宽字装进移位寄存器，每送出一个窄字右移 OUT_W 位；keep 同步右移 1 位，
//     out_valid = keep[0]。移固定位数只是连线 + 二选一，比按下标选的 RATIO 选 1 MUX 省
//   - in_keep 要求从低位开始连续（如 0011），不满的宽字只输出有效的几个窄字
//   - 最后一个窄字被取走的那一拍就接收下一个宽字，输出端每拍一个，不断流：
//     in_ready = ~out_valid | (out_ready & 本字没有剩余)
// =============================================================================
module width_down #(
    parameter OUT_W = 8,
    parameter RATIO = 4
)(
    input                    clk,
    input                    rst_n,
    input                    in_valid,
    output                   in_ready,
    input  [OUT_W*RATIO-1:0] in_data,
    input  [RATIO-1:0]       in_keep,
    input                    in_last,
    output                   out_valid,
    input                    out_ready,
    output [OUT_W-1:0]       out_data,
    output                   out_last
);
    reg [OUT_W*RATIO-1:0] sh;
    reg [RATIO-1:0]       keep;
    reg                   last;

    wire more     = |(keep >> 1);           // 当前窄字之后本字还有没有
    assign out_valid = keep[0];
    assign out_data  = sh[OUT_W-1:0];
    assign out_last  = last & ~more;
    assign in_ready  = ~out_valid | (out_ready & ~more);

    wire in_fire  = in_valid & in_ready;
    wire out_fire = out_valid & out_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            keep <= {RATIO{1'b0}};
            last <= 1'b0;
        end else if (in_fire) begin
            keep <= in_keep;
            last <= in_last;
        end else if (out_fire) begin
            keep <= keep >> 1;
        end
    end

    always @(posedge clk) begin
        if (in_fire)       sh <= in_data;
        else if (out_fire) sh <= sh >> OUT_W;
    end

endmodule
