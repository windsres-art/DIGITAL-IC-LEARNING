// =============================================================================
// FSM 编码实验：序列检测 1011（可重叠，输出打一拍）
// -----------------------------------------------------------------------------
// RTL 里用二进制写状态常量，但综合工具会识别出状态机并重新编码。
// run.sh 用同一份 RTL 综合三次：
//   fsm            工具自己决定（Yosys 默认 auto）
//   fsm -encoding binary    3 个状态 FF
//   fsm -encoding one-hot   5 个状态 FF，次态逻辑更浅
// DC 里对应 fsm 相关的编码选项（以工具文档为准）；Yosys 也支持在状态寄存器上
// 加 (* fsm_encoding = "one-hot" *) 属性。
// =============================================================================
module seq_det (
    input      clk,
    input      rst_n,
    input      din,
    output reg hit
);
    localparam IDLE  = 3'd0,   // 还没匹配
               S1    = 3'd1,   // 已匹配 "1"
               S10   = 3'd2,   // 已匹配 "10"
               S101  = 3'd3,   // 已匹配 "101"
               S1011 = 3'd4;   // 已匹配 "1011"

    reg [2:0] st, nxt;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) st <= IDLE;
        else        st <= nxt;

    // 可重叠：S1011 之后的 "1" 可以作为下一个序列的开头
    always @(*) begin
        case (st)
            IDLE:    nxt = din ? S1    : IDLE;
            S1:      nxt = din ? S1    : S10;
            S10:     nxt = din ? S101  : IDLE;
            S101:    nxt = din ? S1011 : S10;
            S1011:   nxt = din ? S1    : S10;
            default: nxt = IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) hit <= 1'b0;
        else        hit <= (nxt == S1011);
endmodule
