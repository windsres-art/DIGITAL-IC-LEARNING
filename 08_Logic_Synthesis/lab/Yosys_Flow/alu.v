// =============================================================================
// 参数化 ALU：本章综合实验的主线电路
// -----------------------------------------------------------------------------
// 结构：输入寄存器 → 组合 ALU → 输出寄存器
//   这样综合后既有 reg→reg 路径（给 STA 看），又有加法器、比较器、移位器、
//   多路选择这些综合工具最常处理的算子。
//
//   op   运算
//   000  ADD   a + b
//   001  SUB   a - b
//   010  AND
//   011  OR
//   100  XOR
//   101  SLT   有符号比较 a < b（结果 0/1）
//   110  SLL   a << b[SHW-1:0]
//   111  SRL   a >> b[SHW-1:0]
// =============================================================================
module alu #(
    parameter W = 16
)(
    input              clk,
    input              rst_n,
    input              in_valid,
    input      [2:0]   op,
    input      [W-1:0] a,
    input      [W-1:0] b,
    output reg         out_valid,
    output reg [W-1:0] y,
    output reg         zero
);
    localparam SHW = $clog2(W);

    localparam OP_ADD = 3'd0, OP_SUB = 3'd1, OP_AND = 3'd2, OP_OR  = 3'd3,
               OP_XOR = 3'd4, OP_SLT = 3'd5, OP_SLL = 3'd6, OP_SRL = 3'd7;

    // ---------------- 输入寄存器 ----------------
    reg [2:0]   op_q;
    reg [W-1:0] a_q, b_q;
    reg         v_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_q <= 3'd0;
            a_q  <= {W{1'b0}};
            b_q  <= {W{1'b0}};
            v_q  <= 1'b0;
        end else begin
            v_q <= in_valid;
            if (in_valid) begin   // 使能：综合会映射成带使能的 DFF 或 D 前 MUX
                op_q <= op;
                a_q  <= a;
                b_q  <= b;
            end
        end
    end

    // ---------------- 组合 ALU ----------------
    // 减法与有符号比较共用一个加法器：a - b = a + ~b + 1
    // SLT 看减法结果的符号位，并用溢出位修正：lt = sign ^ overflow
    wire [W:0]   diff = {1'b0, a_q} + {1'b0, ~b_q} + {{W{1'b0}}, 1'b1};
    wire         ovf  = (a_q[W-1] ^ b_q[W-1]) & (a_q[W-1] ^ diff[W-1]);
    wire         lt   = diff[W-1] ^ ovf;

    reg [W-1:0] y_d;
    // 组合 always 必须对每个分支都赋值（有 default），否则推断出 latch
    always @(*) begin
        case (op_q)
            OP_ADD:  y_d = a_q + b_q;
            OP_SUB:  y_d = diff[W-1:0];
            OP_AND:  y_d = a_q & b_q;
            OP_OR:   y_d = a_q | b_q;
            OP_XOR:  y_d = a_q ^ b_q;
            OP_SLT:  y_d = {{(W-1){1'b0}}, lt};
            OP_SLL:  y_d = a_q << b_q[SHW-1:0];
            OP_SRL:  y_d = a_q >> b_q[SHW-1:0];
            default: y_d = {W{1'b0}};
        endcase
    end

    // ---------------- 输出寄存器 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y         <= {W{1'b0}};
            zero      <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= v_q;
            if (v_q) begin
                y    <= y_d;
                zero <= (y_d == {W{1'b0}});
            end
        end
    end

endmodule
