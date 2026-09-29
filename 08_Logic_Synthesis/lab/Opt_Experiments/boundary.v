// =============================================================================
// 边界优化（boundary optimization）与 dont_touch 实验
// -----------------------------------------------------------------------------
// arith_unit 是一个通用子模块：mode=1 做乘法，mode=0 做加法。
// boundary_top 例化它时把 mode 接成常量 0 —— 乘法器在功能上永远用不到。
//
//   打平（flatten）后：常量 0 穿过层次边界传播进来，乘法器被删掉
//   保留层次：子模块单独综合，看不到外面的常量，乘法器留下来
//
// DC 里对应 compile -boundary_optimization / ungroup；Yosys 里对应 flatten。
// =============================================================================
module arith_unit #(
    parameter W = 8
)(
    input  [W-1:0]   a,
    input  [W-1:0]   b,
    input            mode,
    output [2*W-1:0] y
);
    assign y = mode ? a * b : {{W{1'b0}}, a} + {{W{1'b0}}, b};
endmodule

module boundary_top #(
    parameter W = 8
)(
    input                clk,
    input                rst_n,
    input      [W-1:0]   a,
    input      [W-1:0]   b,
    output reg [2*W-1:0] y
);
    wire [2*W-1:0] r;

    arith_unit #(.W(W)) u_arith (.a(a), .b(b), .mode(1'b0), .y(r));

    always @(posedge clk or negedge rst_n)
        if (!rst_n) y <= {2*W{1'b0}};
        else        y <= r;
endmodule

// =============================================================================
// 寄存器复制与 keep（≈ DC 的 set_dont_touch）
// -----------------------------------------------------------------------------
// en 要驱动很多负载，设计者手工复制了两份寄存器，各带一半负载（降低扇出、改善时序）。
// 两个寄存器的 D、时钟、复位完全相同，综合的“合并等价单元”优化会把它们合回一个。
//
// dup_keep 在 reg 声明上加了 (* keep *)——实测在 Yosys 里不够：属性落在 wire 上，
// 寄存器单元照样被合并。要保住，得把 keep 设在寄存器“单元”上（run.sh 里用
// setattr 做，相当于 DC 的 set_dont_touch [get_cells en_a_reg]）。
// =============================================================================
module dup_nokeep (
    input             clk,
    input             rst_n,
    input             en_in,
    input      [15:0] d,
    output reg [15:0] q
);
    reg en_a, en_b;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin en_a <= 1'b0; en_b <= 1'b0; end
        else        begin en_a <= en_in; en_b <= en_in; end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 16'd0;
        else begin
            if (en_a) q[7:0]  <= d[7:0];
            if (en_b) q[15:8] <= d[15:8];
        end
endmodule

module dup_keep (
    input             clk,
    input             rst_n,
    input             en_in,
    input      [15:0] d,
    output reg [15:0] q
);
    (* keep *) reg en_a;
    (* keep *) reg en_b;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin en_a <= 1'b0; en_b <= 1'b0; end
        else        begin en_a <= en_in; en_b <= en_in; end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 16'd0;
        else begin
            if (en_a) q[7:0]  <= d[7:0];
            if (en_b) q[15:8] <= d[15:8];
        end
endmodule
