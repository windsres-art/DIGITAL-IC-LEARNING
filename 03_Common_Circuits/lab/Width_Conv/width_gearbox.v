// =============================================================================
// 任意比例位宽转换（gearbox）：IN_W 位进、OUT_W 位出，比特流顺序不变（低位先）
//   例：24 → 32，每 4 个输入字拼出 3 个输出字；32 → 24 反过来
//   - 位缓冲 buf 共 CAP = IN_W + OUT_W 位，fill 表示低 fill 位有效
//   - fill >= OUT_W 就能输出低 OUT_W 位；取走后整体右移 OUT_W
//   - 新输入字接在"本拍取走之后"剩下的数据后面：位置 fill_aft，
//     in_ready = (fill_aft + IN_W <= CAP)
//   - in_ready 依赖 out_ready（本拍有没有取走），是组合路径；ready 依赖 ready
//     是协议允许的，但要切断就在输出端再加一级 skid buffer
//   - 插入位置可变 → 需要一个桶形移位器，面积随 CAP 增长；整数比时用
//     width_up / width_down 更省
// =============================================================================
module width_gearbox #(
    parameter IN_W  = 24,
    parameter OUT_W = 32
)(
    input                  clk,
    input                  rst_n,
    input                  in_valid,
    output                 in_ready,
    input      [IN_W-1:0]  in_data,
    output                 out_valid,
    input                  out_ready,
    output     [OUT_W-1:0] out_data
);
    localparam CAP = IN_W + OUT_W;
    localparam FW  = $clog2(CAP + 1);

    reg  [CAP-1:0] buf_q;
    reg  [FW-1:0]  fill;

    assign out_valid = (fill >= OUT_W);
    assign out_data  = buf_q[OUT_W-1:0];
    wire   out_fire  = out_valid & out_ready;

    wire [FW-1:0]  fill_aft = out_fire ? fill - OUT_W : fill;
    assign in_ready  = (fill_aft <= CAP - IN_W);
    wire   in_fire   = in_valid & in_ready;

    wire [CAP-1:0] kept   = out_fire ? (buf_q >> OUT_W) : buf_q;
    // fill_aft 以上的旧位清零再或入新字，buf_q 本身就不需要复位
    wire [CAP-1:0] mask   = ~({CAP{1'b1}} << fill_aft);
    wire [CAP-1:0] ins    = in_data << fill_aft;
    wire [CAP-1:0] buf_nx = (kept & mask) | (in_fire ? ins : 0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fill <= 0;
        else        fill <= fill_aft + (in_fire ? IN_W : 0);
    end

    always @(posedge clk) begin
        if (in_fire || out_fire) buf_q <= buf_nx;
    end

endmodule
