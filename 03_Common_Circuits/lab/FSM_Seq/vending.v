// =============================================================================
// 自动售货机：饮料 1.5 元，只收 5 角（coin5）和 1 元（coin10），多付找 5 角
//   金额以 5 角为单位：状态 = 已投金额 0 / 5 角 / 1 元
//   投满 1.5 元出货（dispense）；投到 2 元（1 元 + 1 元）出货并找零（change）
//   输出由第三段寄存：投币的下一拍 dispense / change 为 1，单拍脉冲
//   约定同一拍 coin5、coin10 不会同时为 1（投币口一次只进一枚）
// =============================================================================
module vending (
    input      clk,
    input      rst_n,
    input      coin5,
    input      coin10,
    output reg dispense,
    output reg change
);
    localparam [1:0] IDLE = 2'd0, C5 = 2'd1, C10 = 2'd2;

    reg [1:0] state, next_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    always @(*) begin
        next_state = state;             // 默认保持：没投币就不动
        case (state)
            IDLE:    if (coin5) next_state = C5;  else if (coin10) next_state = C10;
            C5:      if (coin5) next_state = C10; else if (coin10) next_state = IDLE;
            C10:     if (coin5 || coin10) next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dispense <= 1'b0;
            change   <= 1'b0;
        end else begin
            dispense <= (state == C5  && coin10) || (state == C10 && (coin5 || coin10));
            change   <= (state == C10 && coin10);
        end
    end

endmodule
