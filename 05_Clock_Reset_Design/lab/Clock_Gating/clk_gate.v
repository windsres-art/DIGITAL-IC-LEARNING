// =============================================================================
// 时钟门控三种写法对比
//   cg_and     : 直接用 AND 门控 —— 错误示范，en 在 clk 高电平期间变化会产生毛刺/截断脉冲
//   icg_latch  : 低电平透明 latch + AND —— 工业 ICG 单元的结构（面试标准答案）
//   icg_negff  : 下降沿 DFF + AND —— 另一种无毛刺写法，但 en 只剩半个周期的建立时间
//
// 真实芯片里不要自己用 RTL 拼 ICG：直接例化工艺库的 ICG 单元（如 Sky130 的
// sky130_fd_sc_hd__dlclkp），或者写成 "if (en) q <= d" 让综合工具自动插 ICG。
// 这里用 RTL 写出来只是为了在仿真里看清结构。
// =============================================================================
`timescale 1ns / 1ps

// 错误示范：gclk 直接等于 clk & en
module cg_and (
    input  clk,
    input  en,
    output gclk
);
    assign gclk = clk & en;
endmodule


// latch 型 ICG：clk 为低时 latch 透明，en 可以自由变化；
// clk 为高时 latch 关闭，锁住的 en 在整个高电平期间不变 → AND 输出不会被截断
module icg_latch (
    input  clk,
    input  en,
    input  se,      // scan enable：测试模式下强制打开时钟，保证扫描链能移位
    output gclk
);
    reg en_latch;

    // 这里是**有意**推断 latch（ICG 的一部分），不是编码错误
    /* verilator lint_off LATCH */
    always @(*) begin
        if (!clk)
            en_latch = en | se;
    end
    /* verilator lint_on LATCH */

    assign gclk = clk & en_latch;
endmodule


// 下降沿 DFF 型：en 在 clk 下降沿被采样，之后整个低电平 + 下一个高电平都保持
// 缺点：en 从上升沿发出后只有半个周期就要被下降沿采到，时序更紧
module icg_negff (
    input  clk,
    input  en,
    input  se,
    output gclk
);
    reg en_q;

    always @(negedge clk) begin
        en_q <= en | se;
    end

    assign gclk = clk & en_q;
endmodule
