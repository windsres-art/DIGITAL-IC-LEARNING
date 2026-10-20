// 故意错误的教学反例；不可复用为设计 RTL。
module bad_sensitivity(input a,b, output reg y);
    always @(a) y = a & b; // b 变化时 RTL 仿真不重新求值。
endmodule
module bad_latch(input en,d, output reg q);
    always @* if (en) q=d; // 缺少 en=0 的赋值，产生存储。
endmodule
module bad_multidriver(input clk_a,clk_b,a,b, output reg q);
    always @(posedge clk_a) q<=a;
    always @(posedge clk_b) q<=b;
endmodule
module bad_loop(output wire y);
    assign y=~y; // 无存储元件的组合反馈，不能靠 RTL 仿真判断物理振荡频率。
endmodule
module bad_wildcard(input [1:0] sel, output reg [1:0] exact, wild_x, wild_z);
    always @* begin
        exact=0; wild_x=0; wild_z=0;
        case(sel)
            2'b10,2'b11: exact=2'b10;
            2'b01: exact=2'b01;
            default: exact=0;
        endcase
        casex(sel)
            2'b1?: wild_x=2'b10;
            2'b01: wild_x=2'b01;
            default: wild_x=0;
        endcase
        casez(sel)
            2'b1?: wild_z=2'b10;
            2'b01: wild_z=2'b01;
            default: wild_z=0;
        endcase
    end
endmodule
