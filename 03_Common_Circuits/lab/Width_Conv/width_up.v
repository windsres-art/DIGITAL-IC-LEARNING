// =============================================================================
// 窄转宽（upsizer）：RATIO 个 IN_W 位窄字拼成一个 IN_W*RATIO 位宽字，valid/ready
//   - 先到的窄字放低位（小端，和 AXI-Stream 的字节顺序一致）
//   - in_last 提前到达时输出不满的宽字，out_keep 标出哪些槽有效（每个窄字 1 位），
//     out_last 跟着输出；keep=0 的槽里是上一个字留下的旧数据，下游不能用
//   - 拼字寄存器兼作输出寄存器：宽字被取走的那一拍就可以同时写新字的第 0 槽，
//     in_ready = ~out_valid | out_ready，输入端每拍一个，不断流
// =============================================================================
module width_up #(
    parameter IN_W  = 8,
    parameter RATIO = 4
)(
    input                       clk,
    input                       rst_n,
    input                       in_valid,
    output                      in_ready,
    input      [IN_W-1:0]       in_data,
    input                       in_last,
    output reg                  out_valid,
    input                       out_ready,
    output reg [IN_W*RATIO-1:0] out_data,
    output reg [RATIO-1:0]      out_keep,
    output reg                  out_last
);
    localparam CW = (RATIO > 1) ? $clog2(RATIO) : 1;
    localparam integer  LAST_I = RATIO - 1;
    localparam [CW-1:0] LAST   = LAST_I[CW-1:0];

    reg  [CW-1:0] cnt;                  // 下一个窄字写哪个槽
    assign in_ready = ~out_valid | out_ready;

    wire in_fire   = in_valid & in_ready;
    wire done_word = in_fire & ((cnt == LAST) | in_last);
    wire [RATIO-1:0] slot = {{(RATIO-1){1'b0}}, 1'b1} << cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt       <= {CW{1'b0}};
            out_valid <= 1'b0;
            out_keep  <= {RATIO{1'b0}};
            out_last  <= 1'b0;
        end else begin
            if (in_fire) begin
                cnt      <= done_word ? {CW{1'b0}} : cnt + 1'b1;
                // cnt == 0 是新字的第一个窄字：清掉上一个字的 keep
                out_keep <= ((cnt == {CW{1'b0}}) ? {RATIO{1'b0}} : out_keep) | slot;
            end
            if (done_word)              out_valid <= 1'b1;
            else if (out_ready)         out_valid <= 1'b0;
            if (done_word)              out_last  <= in_last;
        end
    end

    always @(posedge clk) begin
        if (in_fire) out_data[cnt*IN_W +: IN_W] <= in_data;
    end

endmodule
