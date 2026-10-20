module enable_bank #(parameter W=16) (
    input wire clk,rst_n,en,
    input wire [W-1:0] d,
    output reg [W-1:0] q
);
    always @(posedge clk or negedge rst_n)
        if(!rst_n) q<=0;
        else if(en) q<=d;
endmodule
