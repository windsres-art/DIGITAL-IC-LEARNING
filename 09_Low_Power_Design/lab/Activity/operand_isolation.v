// 只在 valid 时采样乘积；隔离输入减少无效期间组合逻辑翻转。
module operand_isolation #(parameter W=8) (
    input wire clk,rst_n,valid,
    input wire [W-1:0] a,b,
    output wire [2*W-1:0] raw_product,isolated_product,
    output reg [2*W-1:0] q_raw,q_isolated
);
    wire [W-1:0] a_iso=valid ? a : {W{1'b0}};
    wire [W-1:0] b_iso=valid ? b : {W{1'b0}};
    assign raw_product=a*b;
    assign isolated_product=a_iso*b_iso;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin q_raw<=0; q_isolated<=0; end
        else if(valid) begin q_raw<=raw_product; q_isolated<=isolated_product; end
    end
endmodule
