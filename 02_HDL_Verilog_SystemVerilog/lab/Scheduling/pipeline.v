`default_nettype none
module pipeline #(parameter W = 8) (
    input wire clk, rst_n, en,
    input wire [W-1:0] d,
    output reg [W-1:0] q1, q2
);
    // 两级寄存器同时采样沿前的输入；不把代码行次序当作时钟。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1 <= {W{1'b0}};
            q2 <= {W{1'b0}};
        end else if (en) begin
            q1 <= d;
            q2 <= q1;
        end
    end
endmodule
`default_nettype wire
