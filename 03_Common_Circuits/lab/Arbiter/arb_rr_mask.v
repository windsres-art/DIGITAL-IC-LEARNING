// =============================================================================
// 轮询仲裁器，掩码写法（两个固定优先级仲裁器）
//   mask 只保留"比上次授权位置更高"的位：
//     高于 last 的位 = ~(last | (last - 1))
//   masked 请求非空 → 用它的固定优先级结果；否则说明要绕回，用原始请求的结果
//   行为与 arb_rr.v 完全相同（testbench 逐拍比对），面试两种写法都常见
// =============================================================================
module arb_rr_mask #(
    parameter N = 4
)(
    input              clk,
    input              rst_n,
    input      [N-1:0] req,
    output     [N-1:0] gnt
);
    localparam [N-1:0] ONE = {{(N-1){1'b0}}, 1'b1};

    reg  [N-1:0] last;
    wire [N-1:0] mask     = ~(last | (last - ONE));
    wire [N-1:0] req_m    = req & mask;
    wire [N-1:0] gnt_m    = req_m & ~(req_m - ONE);
    wire [N-1:0] gnt_u    = req   & ~(req   - ONE);

    assign gnt = (|req_m) ? gnt_m : gnt_u;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    last <= {1'b1, {(N-1){1'b0}}};
        else if (|req) last <= gnt;
    end

endmodule
