`default_nettype none
// req 仅在 IDLE 被接收；finish 结束处理；响应必须保持到 ack。
module request_fsm (
    input wire clk, rst_n, req, finish, ack,
    output reg accept, busy, valid
);
    localparam [1:0] IDLE = 2'd0, WORK = 2'd1, RESP = 2'd2;
    reg [1:0] state, next_state;
    // 第一段：只有此过程拥有状态寄存器。
    always @(posedge clk or negedge rst_n)
        if (!rst_n) state <= IDLE;
        else state <= next_state;

    // 第二段：先给默认值，再写转移，避免隐含存储。
    always @* begin
        next_state = state;
        case (state)
            IDLE: if (req) next_state = WORK;
            WORK: if (finish) next_state = RESP;
            RESP: if (ack) next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end
    // 第三段：Moore 输出仅依赖当前状态；accept 表示本周期可接收。
    always @* begin
        accept = 1'b0;
        busy = 1'b0;
        valid = 1'b0;
        case (state)
            IDLE: accept = 1'b1;
            WORK: busy = 1'b1;
            RESP: valid = 1'b1;
            default: begin end
        endcase
    end
endmodule
`default_nettype wire
