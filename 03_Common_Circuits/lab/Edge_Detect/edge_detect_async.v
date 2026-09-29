// =============================================================================
// 异步输入的边沿检测：先两级同步，再用第 2、3 级做边沿检测
//   s[0]：第 1 级，可能亚稳，不给任何逻辑用
//   s[1]：同步后的电平
//   s[2]：s[1] 延迟一拍
//   rise = s[1] & ~s[2] 等只用到寄存器输出，没有毛刺
//   输入电平至少保持约 1.5 个 clk 周期才能保证被采到（见 ../../06_CDC/README.md 第 2 节）
// =============================================================================
module edge_detect_async #(
    parameter [0:0] INIT = 1'b0         // 输入空闲电平
)(
    input  clk,
    input  rst_n,
    input  din_async,
    output rise,
    output fall,
    output both,
    output din_sync                     // 同步后的电平，给本域其它逻辑用
);
    reg [2:0] s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s <= {3{INIT}};
        else        s <= {s[1:0], din_async};
    end

    assign rise     =  s[1] & ~s[2];
    assign fall     = ~s[1] &  s[2];
    assign both     =  s[1] ^  s[2];
    assign din_sync =  s[1];

endmodule
