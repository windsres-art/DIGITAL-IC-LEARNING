`default_nettype none
// 形式验证比较器，不是产品数据通路：所有输入都保持符号化。
module adder_miter #(parameter W=8,B=4) (
    input wire [W-1:0] a,b,d,
    input wire cin,
    output wire ok
);
    wire [W:0] rca,cla,cselect,prefix;
    wire [W+1:0] total;
    wire [W:0] expected={1'b0,a}+{1'b0,b}+{{W{1'b0}},cin};
    wire [W+1:0] expected3={2'b00,a}+{2'b00,b}+{2'b00,d};
    adder_rca #(.W(W)) r(.a(a),.b(b),.cin(cin),.sum(rca[W-1:0]),.cout(rca[W]));
    adder_cla #(.W(W),.B(B)) l(.a(a),.b(b),.cin(cin),.sum(cla[W-1:0]),.cout(cla[W]));
    adder_cselect #(.W(W),.B(B)) s(.a(a),.b(b),.cin(cin),.sum(cselect[W-1:0]),.cout(cselect[W]));
    adder_prefix #(.W(W)) p(.a(a),.b(b),.cin(cin),.sum(prefix[W-1:0]),.cout(prefix[W]));
    adder_three #(.W(W)) t(.a(a),.b(b),.d(d),.total(total));
    assign ok=(rca==expected)&&(cla==expected)&&(cselect==expected)&&
              (prefix==expected)&&(total==expected3);
endmodule
`default_nettype wire
