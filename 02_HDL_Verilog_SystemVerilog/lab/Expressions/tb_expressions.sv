`timescale 1ns/1ps
module tb_expressions;
    parameter W = 4;
    localparam N = 1 << W;
    reg [W-1:0] a, b;
    reg signed [W-1:0] sa, sb;
    wire [W:0] sum;
    wire [W-1:0] sum_wrap;
    wire signed [W:0] signed_sum;
    wire signed [W-1:0] shifted;
    wire signed_lt, overflow;
    integer i, j, ai, bi, half, checks = 0;
    expr_datapath #(.W(W)) dut (
        .a(a), .b(b), .sa(sa), .sb(sb), .sum(sum), .sum_wrap(sum_wrap),
        .signed_sum(signed_sum), .shifted(shifted),
        .signed_lt(signed_lt), .overflow(overflow)
    );

    // 故意固定 8 bit 的语义探针，不作为推荐设计代码。
    reg [7:0] x, y;
    reg signed [7:0] sx;
    reg [3:0] unknown_value, merged;
    reg decision;
    wire [8:0] context_sum = x + y;
    wire [8:0] concat_sum = {x + y};
    wire [15:0] signed_ext = sx;
    wire [15:0] slice_ext = sx[7:0];
    wire [7:0] logical_shift = sx >> 1;
    wire [7:0] arithmetic_shift = sx >>> 1;
    wire mixed_lt = sx < y;
    wire fixed_lt = $signed({sx[7], sx}) < $signed({1'b0, y});

    task check(input condition, input [255:0] label_text);
        begin
            if (condition !== 1'b1) begin
                $display("FAIL W=%0d check=%s a=%0d b=%0d", W, label_text, i, j);
                $fatal(1, "expression mismatch");
            end
            checks = checks + 1;
        end
    endtask

    initial begin
        $dumpfile("expressions.vcd");
        $dumpvars(0, tb_expressions);
        // TB 参数范围受穷举次数限制；RTL 不限于这些小位宽。
        if (W < 2 || W > 8) $fatal(1, "TB requires 2 <= W <= 8");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                a = i; b = j; sa = i; sb = j;
                ai = i < N/2 ? i : i-N;
                bi = j < N/2 ? j : j-N;
                // integer 除法向零截断；负奇数的算术右移却向负无穷取整。
                half = ai >= 0 ? ai/2 : (ai-1)/2;
                #1;
                check(sum == i+j, "unsigned full sum");
                check(sum_wrap == (i+j)%N, "unsigned wrap");
                check(signed_sum == ai+bi, "signed full sum");
                check(shifted == half, "arithmetic shift");
                check(signed_lt == (ai < bi), "signed compare");
                check(overflow == ((ai+bi < -N/2) || (ai+bi > N/2-1)),
                      "signed overflow");
            end
        x = 8'hff; y = 8'h01; sx = -8'sd1; #1;
        check(context_sum === 9'h100, "assignment context width");
        check(concat_sum === 9'h000, "concat self determined");
        check(signed_ext === 16'hffff, "signed extension");
        check(slice_ext === 16'h00ff, "slice unsigned");
        check(logical_shift === 8'h7f, "logical right shift");
        check(arithmetic_shift === 8'hff, "arithmetic right shift");
        check(mixed_lt === 1'b0, "mixed signed unsigned");
        check(fixed_lt === 1'b1, "explicit signed compare");
        $display("width: context_sum=%h concat_sum=%h signed_ext=%h slice_ext=%h",
                 context_sum, concat_sum, signed_ext, slice_ext);
        $display("signed: mixed_lt=%b fixed_lt=%b logical_shift=%h arithmetic_shift=%h",
                 mixed_lt, fixed_lt, logical_shift, arithmetic_shift);
        unknown_value = 4'b10x1;
        check((unknown_value == 4'b1001) === 1'bx, "logical equality X");
        check((unknown_value === 4'b1001) === 1'b0, "case equality known");
        decision = 1'bx;
        merged = decision ? 4'b1010 : 4'b1000;
        check(merged === 4'b10x0, "ternary merge X");
        if (decision) merged = 4'b1010; else merged = 4'b1000;
        check(merged === 4'b1000, "if X takes else");
        check((4'b0010 & 4'b0100) === 4'b0000, "bitwise and");
        check((4'b0010 && 4'b0100) === 1'b1, "logical and");
        check((&4'b1111) === 1'b1, "reduction and");
        $display("PASS expressions W=%0d pairs=%0d checks=%0d", W, N*N, checks);
        $finish;
    end
    initial begin #100000; $fatal(1, "FAIL timeout"); end
endmodule
