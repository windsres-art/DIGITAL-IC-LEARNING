// =============================================================================
// N 位十进制（BCD）计数器：每 4 bit 表示一位 0~9，低位到 9 时向高位进位
//   - 进位链 carry[i] 是第 i 位的计数使能：低位全是 9 且 en 有效，高位才加 1
//   - 所有位用同一个 clk，进位走使能，不用低位输出当高位时钟（那是行波计数器，
//     各位翻转时刻不同，会产生中间态，也给 STA 和 CTS 添麻烦）
//   - co：整个计数器从 99..9 回到 00..0 的那一拍为 1，可继续级联
// =============================================================================
module counter_bcd #(
    parameter DIGITS = 3
)(
    input                   clk,
    input                   rst_n,
    input                   en,
    output [4*DIGITS-1:0]   bcd,
    output                  co
);
    wire [DIGITS:0] carry;
    assign carry[0] = en;

    genvar g;
    generate
        for (g = 0; g < DIGITS; g = g + 1) begin : g_digit
            reg [3:0] d;
            wire      is9 = (d == 4'd9);

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)        d <= 4'd0;
                else if (carry[g]) d <= is9 ? 4'd0 : d + 4'd1;
            end

            assign carry[g+1]    = carry[g] & is9;
            assign bcd[4*g +: 4] = d;
        end
    endgenerate

    assign co = carry[DIGITS];

endmodule
