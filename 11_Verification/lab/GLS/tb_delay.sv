`timescale 1ns/1ps
module tb_delay;
 reg A=0;
 wire Y;
 delay_cell dut(.*);
 initial begin
   $dumpfile("delay.vcd");$dumpvars(0,tb_delay);
   $sdf_annotate("../delay.sdf",tb_delay);
   #10;
   if(Y!==0) $fatal(1,"FAIL initial buffer");
   A=1;
   #2;
   if(Y!==0) $fatal(1,"FAIL SDF too early or missing");
   #1.1;
   if(Y!==1) $fatal(1,"FAIL SDF too late");
   #5;A=0;
   #2;
   if(Y!==1) $fatal(1,"FAIL fall too early");
   #1.1;
   if(Y!==0) $fatal(1,"FAIL fall too late");
   $display("PASS SDF typ=3ns rise/fall measured between 2ns and 3.1ns");
   $finish;
 end
 initial begin #100;$fatal(1,"FAIL timeout");end
endmodule
