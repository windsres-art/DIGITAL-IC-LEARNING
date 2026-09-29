// =============================================================================
// 轮询仲裁器（Round Robin），双倍宽度写法
//   上次授权给 i，这次优先级从 i+1 开始循环：
//     base   = 上次授权左移 1 位（循环），是本次优先级最高的位置（独热）
//     把 req 复制成 2N 位，从 base 开始找第一个 1：
//       dgnt = dreq & ~(dreq - base)   （与固定优先级同一技巧，只是起点换成 base）
//     高低两半或起来，就把"绕回去"的那部分折回来
//   grant 组合输出；有请求的每一拍都更新优先级（每拍一次仲裁）
//   复位后 last = bit N-1，所以 base = bit 0，第一次和固定优先级相同
// =============================================================================
module arb_rr #(
    parameter N = 4
)(
    input              clk,
    input              rst_n,
    input      [N-1:0] req,
    output     [N-1:0] gnt
);
    reg  [N-1:0]   last;
    wire [N-1:0]   base = {last[N-2:0], last[N-1]};
    wire [2*N-1:0] dreq = {req, req};
    wire [2*N-1:0] dgnt = dreq & ~(dreq - {{N{1'b0}}, base});

    assign gnt = dgnt[N-1:0] | dgnt[2*N-1:N];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    last <= {1'b1, {(N-1){1'b0}}};
        else if (|req) last <= gnt;
    end

endmodule
