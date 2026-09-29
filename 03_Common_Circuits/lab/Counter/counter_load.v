// =============================================================================
// 可加载、可逆的模 (MAX+1) 计数器
//   - load 优先级高于 en：load=1 时下一拍 cnt = din（din 应 <= MAX）
//   - up=1 加计数：MAX 之后回到 0；up=0 减计数：0 之后回到 MAX
//   - tc（terminal count）：本拍 en 有效且下一拍要回绕，用来级联下一级计数器
//     或产生周期性脉冲。tc 是组合输出，下一级用它当使能，不要当时钟。
// =============================================================================
module counter_load #(
    parameter WIDTH = 4,
    parameter MAX   = 11                // 计数范围 0..MAX，模 MAX+1
)(
    input                  clk,
    input                  rst_n,
    input                  en,
    input                  load,
    input                  up,
    input      [WIDTH-1:0] din,
    output reg [WIDTH-1:0] cnt,
    output                 tc
);
    localparam [WIDTH-1:0] MAXV = MAX;

    wire at_max = (cnt == MAXV);
    wire at_min = (cnt == {WIDTH{1'b0}});

    assign tc = en & ~load & (up ? at_max : at_min);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= {WIDTH{1'b0}};
        else if (load)
            cnt <= din;
        else if (en) begin
            if (up) cnt <= at_max ? {WIDTH{1'b0}} : cnt + 1'b1;
            else    cnt <= at_min ? MAXV          : cnt - 1'b1;
        end
    end

endmodule
