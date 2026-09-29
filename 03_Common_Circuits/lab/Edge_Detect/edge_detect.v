// =============================================================================
// 边沿检测（输入已与 clk 同步）
//   把输入打一拍得到 din_d（"上一拍的值"），比较本拍与上一拍：
//     rise = din & ~din_d     fall = ~din & din_d     both = din ^ din_d
//   REG_OUT=0：输出是 din 的组合函数，比 din 变化晚 0 拍出现、持续 1 拍；
//              din 若来自同一时钟的寄存器，输出就不会有毛刺
//   REG_OUT=1：输出再打一拍，晚 1 拍但是纯寄存器输出，适合送到模块外
//   INIT：din_d 的复位值，应等于 din 的空闲电平。空闲为高却复位成 0，
//         复位释放后会多出一个假的上升沿
// =============================================================================
module edge_detect #(
    parameter REG_OUT = 0,
    parameter [0:0] INIT = 1'b0
)(
    input  clk,
    input  rst_n,
    input  din,
    output rise,
    output fall,
    output both
);
    reg din_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) din_d <= INIT;
        else        din_d <= din;
    end

    wire rise_c =  din & ~din_d;
    wire fall_c = ~din &  din_d;
    wire both_c =  din ^  din_d;

    generate
        if (REG_OUT) begin : g_reg
            reg rise_r, fall_r, both_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rise_r <= 1'b0; fall_r <= 1'b0; both_r <= 1'b0;
                end else begin
                    rise_r <= rise_c; fall_r <= fall_c; both_r <= both_c;
                end
            end
            assign rise = rise_r;
            assign fall = fall_r;
            assign both = both_r;
        end else begin : g_comb
            assign rise = rise_c;
            assign fall = fall_c;
            assign both = both_c;
        end
    endgenerate

endmodule
