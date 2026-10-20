module scan_bank #(parameter W=4) (
    input wire clk,rst_n,scan_en,scan_in,
    input wire [W-1:0] functional_d,
    output reg [W-1:0] q,
    output wire scan_out
);
    assign scan_out=q[W-1];
    always @(posedge clk or negedge rst_n)
        if(!rst_n) q<=0;
        else if(scan_en) q<=(q<<1) | {{(W-1){1'b0}},scan_in};
        else q<=functional_d;
endmodule
