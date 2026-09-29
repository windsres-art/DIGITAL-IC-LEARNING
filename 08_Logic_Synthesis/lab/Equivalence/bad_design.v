// =============================================================================
// check_design 练习：故意包含 5 类常见结构问题，看 lint / check 能否抓出来
//   1. latch 推断：组合 always 里 if 没有 else
//   2. 多驱动：同一根线被两个 assign 驱动
//   3. 组合环：两个与非门首尾相接（SR 锁存器结构）
//   4. 位宽截断：8 bit 结果赋给 4 bit 输出
//   5. 输出悬空：输出端口没有被驱动；输入端口没有被使用
// 这些在仿真里未必报错，但综合后行为可能与 RTL 不一致，签核前必须清零。
// =============================================================================
module bad_design (
    input  [3:0] a,
    input  [3:0] b,
    input        en,
    input        sel,
    input        unused_in,
    output reg [3:0] q_latch,
    output [3:0] y_multi,
    output       loop_out,
    output [3:0] y_trunc,
    output       floating_out
);
    // 1. en=0 时 q_latch 保持原值 → 需要记忆 → latch
    always @(*) begin
        if (en) q_latch = a;
    end

    // 2. 两个驱动源，综合后是短路 / X
    assign y_multi = a;
    assign y_multi = b;

    // 3. n1 → n2 → n1，没有寄存器隔断
    wire n1, n2;
    assign n1 = ~(n2 & sel);
    assign n2 = ~(n1 & en);
    assign loop_out = n2;

    // 4. 进位被悄悄丢掉
    wire [7:0] sum = {4'd0, a} + {4'd0, b};
    assign y_trunc = sum;

    // 5. floating_out 没有赋值；unused_in 没有使用
endmodule
