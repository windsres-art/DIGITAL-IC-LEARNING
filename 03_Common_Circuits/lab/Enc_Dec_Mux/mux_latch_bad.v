// =============================================================================
// 反面教材：组合 always 里 case 不完整 → 推断 latch
//   sel = 3 时没有给 y 赋值，y 必须"保持上一次的值"，只能用锁存器实现
//   run_sim.sh 用 Yosys 分别综合这个模块和改好的写法，统计 latch 个数
//   修正：给 y 一个默认值（always 开头 y = 1'b0;），或者补 default 分支
// =============================================================================
module mux_latch_bad (
    input      [1:0] sel,
    input      [2:0] d,
    output reg       y
);
    always @(*) begin
        case (sel)
            2'd0: y = d[0];
            2'd1: y = d[1];
            2'd2: y = d[2];
        endcase
    end
endmodule
