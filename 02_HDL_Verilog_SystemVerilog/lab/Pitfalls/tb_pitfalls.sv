`timescale 1ns/1ps
module tb_pitfalls;
    reg a,b,en,d;
    reg [1:0] sel;
    wire stale, synthesized, held;
    wire [1:0] exact,wild_x,wild_z;
    integer checks=0;
    bad_sensitivity bad(.a(a),.b(b),.y(stale));
    synthesized_sensitivity netlist(.a(a),.b(b),.y(synthesized));
    bad_latch latch_example(.en(en),.d(d),.q(held));
    bad_wildcard wildcard_example(.*);
    task check(input condition);
        begin
            if(condition !== 1'b1) $fatal(1,"FAIL expected diagnostic behavior check=%0d",checks);
            checks++;
        end
    endtask
    initial begin
        $dumpfile("pitfalls.vcd"); $dumpvars(0,tb_pitfalls);
        #1; a=0; b=0; en=1; d=1; sel=2'b10; #1;
        check(stale===0 && synthesized===0 && held===1);
        a=1; #1; check(stale===0 && synthesized===0);
        b=1; en=0; d=0; #1;
        check(stale===0 && synthesized===1 && held===1);
        $display("sensitivity: RTL=%b synthesized=%b; latch held=%b",stale,synthesized,held);
        sel=2'bx1; #1;
        check(exact===0 && wild_x===2 && wild_z===0);
        $display("sel=x1 exact=%b casex=%b casez=%b",exact,wild_x,wild_z);
        sel=2'bz1; #1;
        check(exact===0 && wild_x===2 && wild_z===2);
        $display("sel=z1 exact=%b casex=%b casez=%b",exact,wild_x,wild_z);
        en=1; #1; check(held===0);
        $display("PASS pitfalls expected_counterexamples=%0d",checks);
        $finish;
    end
    initial begin #1000; $fatal(1,"FAIL timeout"); end
endmodule
