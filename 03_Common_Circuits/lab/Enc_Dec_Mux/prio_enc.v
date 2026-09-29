// =============================================================================
// 参数化优先编码器：N 个请求，输出最高位 1 的下标（bit N-1 优先级最高，同 74HC148 习惯）
//   for 循环从低到高扫描，后面的赋值覆盖前面的 → 最后留下的是最高位的 1
//   先给 idx 默认值，保证任何输入下都被赋值，不推断 latch
//   valid = |req 区分"没有请求"和"bit 0 有请求"（两者 idx 都是 0）
//   只需要独热形式（而不是下标）时用 req & ~(req - 1) 更简单（第 7 节，最低位优先）
// =============================================================================
module prio_enc #(
    parameter N = 8,
    parameter W = (N > 1) ? $clog2(N) : 1
)(
    input      [N-1:0] req,
    output reg [W-1:0] idx,
    output             valid
);
    integer i;
    always @(*) begin
        idx = {W{1'b0}};
        for (i = 0; i < N; i = i + 1)
            if (req[i]) idx = i[W-1:0];
    end

    assign valid = |req;
endmodule
