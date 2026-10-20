`timescale 1ns/1ps
module tb_sva;
 bit clk=0,rst_n=0,in_valid=0,out_ready=0,op=0;
 bit [7:0] a=0,b=0;
 wire in_ready,out_valid;
 wire [7:0] result;
 elastic_alu dut(.*);
 channel_properties props(.*);
 always #5 clk=~clk;
 int launches=0,stalls=0,clears=0;
 always @(posedge clk) if(rst_n) begin
   if(in_valid&&in_ready) launches++;
   if(out_valid&&!out_ready) stalls++;
   if(in_ready&&!in_valid) clears++;
 end
 initial begin
   $dumpfile("sva.vcd");$dumpvars(0,tb_sva);
   @(negedge clk);rst_n=1;
   for(int k=0;k<40;k++) begin
     @(negedge clk);
     // 本实验对 DUT 输入允许任意变化，集中验证输出槽属性。
     in_valid=(k%5!=4);out_ready=(k%4!=2);op=k[0];a=8'(k);b=8'(255-k);
   end
   @(negedge clk);in_valid=0;out_ready=1;
   repeat(3) @(negedge clk);
   // 中止待决属性，随后重新建立非真空的检查。
   rst_n=0;
   @(negedge clk);rst_n=1;in_valid=1;a=9;b=2;op=0;
   @(negedge clk);in_valid=0;
   repeat(3) @(negedge clk);
   if(launches==0||stalls==0||clears==0) $fatal(1,"FAIL vacuity guard");
   $display("PASS SVA launches=%0d stalls=%0d clears=%0d",launches,stalls,clears);
   $finish;
 end
 initial begin #10000;$fatal(1,"FAIL timeout");end
endmodule
