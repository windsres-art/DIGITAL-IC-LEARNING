// =============================================================================
// 序列检测 "1101"（三段式状态机），MSB 先到，din 每拍 1 bit
//   MEALY=1：输出取决于状态和当前输入，收到最后一个 1 的当拍 dout=1（组合输出）
//   MEALY=0：Moore，多一个"已匹配"状态 S4，输出只取决于状态，晚 1 拍；
//            第三段用 next_state 寄存输出，dout 是寄存器输出、没有毛刺，
//            时序上和"state==S4"完全相同
//   OVERLAP=1：允许重叠，"1101101" 算 2 次（第二次复用了前一次末尾的 "1"）
//   OVERLAP=0：不重叠，匹配后从头开始，"1101101" 只算 1 次
// 状态含义：S0 无，S1 "1"，S2 "11"，S3 "110"，S4 "1101"（仅 Moore）
// =============================================================================
module seq_fsm_1101 #(
    parameter MEALY   = 1,
    parameter OVERLAP = 1
)(
    input      clk,
    input      rst_n,
    input      din,
    output     dout
);
    localparam [2:0] S0 = 3'd0, S1 = 3'd1, S2 = 3'd2, S3 = 3'd3, S4 = 3'd4;

    reg [2:0] state, next_state;

    // 第一段：状态寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S0;
        else        state <= next_state;
    end

    // 第二段：次态逻辑（组合）。先给默认值，避免 latch
    always @(*) begin
        next_state = S0;
        case (state)
            S0: next_state = din ? S1 : S0;
            S1: next_state = din ? S2 : S0;
            S2: next_state = din ? S2 : S3;          // "111" 的后缀仍是 "11"
            S3: begin
                if (!din)       next_state = S0;     // "1100" 没有可用的后缀
                else if (!MEALY) next_state = S4;
                else            next_state = OVERLAP ? S1 : S0;   // "1101" 的后缀 "1"
            end
            S4: begin                                // 只有 Moore 会到这里
                if (OVERLAP) next_state = din ? S2 : S0;          // "1101"+"1" 后缀 "11"
                else         next_state = din ? S1 : S0;          // 从头开始
            end
            default: next_state = S0;
        endcase
    end

    // 第三段：输出
    generate
        if (MEALY) begin : g_mealy
            assign dout = (state == S3) && din;
        end else begin : g_moore
            reg dout_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) dout_r <= 1'b0;
                else        dout_r <= (next_state == S4);
            end
            assign dout = dout_r;
        end
    endgenerate

endmodule
