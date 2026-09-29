// =============================================================================
// 串转并（serial to parallel），MSB 先到
//   - sin_vld=1 的拍才移入一位；收满 WIDTH 位后 pout 更新、pout_vld 打一拍
//   - pout 单独寄存：移位寄存器 sh 在收下一个字时还在变，下游在 pout_vld 之后
//     的任意时刻读 pout 都拿到完整的上一个字
// =============================================================================
module s2p #(
    parameter WIDTH = 8
)(
    input                  clk,
    input                  rst_n,
    input                  sin,
    input                  sin_vld,
    output reg [WIDTH-1:0] pout,
    output reg             pout_vld
);
    localparam CW = $clog2(WIDTH);
    localparam integer  LAST_I = WIDTH - 1;
    localparam [CW-1:0] LAST   = LAST_I[CW-1:0];

    // 只需 WIDTH-1 位：第 WIDTH 位到达的那拍直接和 sh 拼进 pout，不必先存
    reg  [WIDTH-2:0] sh;
    reg  [CW-1:0]    cnt;               // 本字已收到的位数
    wire [WIDTH-1:0] sh_nxt = {sh, sin};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh       <= {(WIDTH-1){1'b0}};
            cnt      <= {CW{1'b0}};
            pout     <= {WIDTH{1'b0}};
            pout_vld <= 1'b0;
        end else begin
            pout_vld <= 1'b0;
            if (sin_vld) begin
                sh <= sh_nxt[WIDTH-2:0];
                if (cnt == LAST) begin
                    cnt      <= {CW{1'b0}};
                    pout     <= sh_nxt;     // 用移位后的值，否则会少最后一位
                    pout_vld <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
