`default_nettype none
// 有符号 radix-4 Modified Booth。此版本用串联加法累计重编码行，尚非压缩树。
module mul_booth #(parameter W=8) (
    input wire signed [W-1:0] a,b,
    output wire signed [2*W-1:0] product
);
    localparam GROUPS=(W+1)/2;
    localparam PAD=2*GROUPS-W;
    wire [2*GROUPS:0] b_ext={{PAD{b[W-1]}},b,1'b0};
    wire signed [2*W-1:0] a_ext={{W{a[W-1]}},a};
    reg signed [2*W-1:0] partial,acc;
    integer i;
    always @* begin
        partial=0; acc=0;
        for(i=0;i<GROUPS;i=i+1) begin
            case(b_ext[2*i +: 3])
                3'b000,3'b111: partial=0;
                3'b001,3'b010: partial=a_ext;
                3'b011: partial=a_ext<<<1;
                3'b100: partial=-(a_ext<<<1);
                3'b101,3'b110: partial=-a_ext;
                default: partial=0;
            endcase
            acc=acc+(partial<<<(2*i));
        end
    end
    assign product=acc;
endmodule
`default_nettype wire
