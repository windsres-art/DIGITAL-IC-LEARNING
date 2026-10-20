`timescale 1ns/1ps
module tb_x;
 reg sel;
 reg optimistic;
 wire merged=sel ? 1'b1 : 1'b0;
 always @* if(sel) optimistic=1; else optimistic=0;
 initial begin
   $dumpfile("x.vcd");$dumpvars(0,tb_x);
   sel=0;#1;sel=1'bx;#1;
   if(optimistic!==0 || merged!==1'bx) $fatal(1,"FAIL X semantics");
   // == 会产生 X；if(X) 不进入 true 分支，因此失配可能被漏报。
   if(merged!=1'b0) $fatal(1,"FAIL unexpected 4-state semantics");
   if(!(merged!==1'b0)) $fatal(1,"FAIL case inequality");
   $display("PASS X probe: if masks X, ternary merges X, !== detects mismatch");
   $finish;
 end
 initial begin #100;$fatal(1,"FAIL timeout");end
endmodule
