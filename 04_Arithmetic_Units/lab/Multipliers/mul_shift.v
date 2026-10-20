`default_nettype none
// 单请求迭代乘法器：接收后 W 个计算沿产生响应，响应保持到被消费。
module mul_shift #(parameter W=8) (
    input wire clk,rst_n,req_valid,signed_mode,rsp_ready,
    input wire [W-1:0] a,b,
    output wire req_ready,
    output reg busy,rsp_valid,
    output reg [2*W-1:0] product
);
    localparam CW=(W<=1)?1:$clog2(W);
    localparam LAST=W-1;
    reg [CW-1:0] count;
    reg [W-1:0] multiplier;
    reg [2*W-1:0] multiplicand,acc;
    reg negative;
    wire [W-1:0] abs_a=(signed_mode && a[W-1])?
        (~a+{{(W-1){1'b0}},1'b1}):a;
    wire [W-1:0] abs_b=(signed_mode && b[W-1])?
        (~b+{{(W-1){1'b0}},1'b1}):b;
    wire [2*W-1:0] next_acc=acc+(multiplier[0]?multiplicand:{(2*W){1'b0}});
    assign req_ready=!busy && !rsp_valid;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            busy<=0; rsp_valid<=0; product<=0;
            count<=0; multiplier<=0; multiplicand<=0; acc<=0; negative<=0;
        end else begin
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            if(req_valid && req_ready) begin
                multiplier<=abs_b;
                multiplicand<={{W{1'b0}},abs_a};
                acc<=0; count<=0; busy<=1;
                negative<=signed_mode && (a[W-1]^b[W-1]);
            end else if(busy) begin
                acc<=next_acc;
                multiplicand<=multiplicand<<1;
                multiplier<=multiplier>>1;
                if(count==LAST[CW-1:0]) begin
                    // 最后一位贡献在 next_acc 中，不能使用旧 acc。
                    product<=negative?(~next_acc+{{(2*W-1){1'b0}},1'b1}):next_acc;
                    busy<=0; rsp_valid<=1;
                end else count<=count+{{(CW-1){1'b0}},1'b1};
            end
        end
    end
endmodule
`default_nettype wire
