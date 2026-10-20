// binary32 位模式分类，不执行浮点运算，不产生 IEEE 异常标志。
module fp32_classify (
    input wire [31:0] bits,
    output wire sign,
    output reg [5:0] kind
);
    assign sign=bits[31];
    // one-hot: bit0 zero, bit1 subnormal, bit2 normal,
    // bit3 infinity, bit4 quiet NaN, bit5 signaling NaN。
    always @* begin
        if(bits[30:23]==0)
            kind=(bits[22:0]==0) ? 6'b000001 : 6'b000010;
        else if(bits[30:23]==8'hff) begin
            if(bits[22:0]==0) kind=6'b001000;
            else kind=bits[22] ? 6'b010000 : 6'b100000;
        end else kind=6'b000100;
    end
endmodule
