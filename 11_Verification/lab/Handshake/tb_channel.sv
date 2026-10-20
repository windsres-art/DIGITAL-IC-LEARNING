`timescale 1ns/1ps
module tb_channel;
 parameter W=8;
 reg clk=0, rst_n=0, in_valid=0, out_ready=0, op=0;
 reg [W-1:0] a=0,b=0;
 wire in_ready,out_valid;
 wire [W-1:0] result;
`ifdef NETLIST
 elastic_alu dut(.*);
`else
 elastic_alu #(.W(W)) dut(.*);
`endif
 always #5 clk=~clk;
 reg [W-1:0] expected[0:4095];
 integer head=0,tail=0,received=0,cancelled=0,stalls=0,simultaneous=0;
 integer categories[0:3];
 integer seed=1,ignored;
 reg [31:0] rng;
 reg held=0, source_accepted=0;
 reg [W-1:0] held_data;
 function [31:0] next_random(input [31:0] v);
   reg [31:0] x;
   begin x=v^(v<<13); x=x^(x>>17); next_random=x^(x<<5); end
 endfunction
 // 在上升沿读旧值：这正是本拍被传输的响应，不等待 NBA 后的新值。
 always @(posedge clk) if (rst_n) begin
   source_accepted=in_valid && in_ready;
   if ((in_ready!==0 && in_ready!==1) || (out_valid!==0 && out_valid!==1))
     $fatal(1,"FAIL unknown control");
   if (held && (!out_valid || result!==held_data)) $fatal(1,"FAIL stall stability");
   held=out_valid && !out_ready; held_data=result;
   if (held) stalls=stalls+1;
   categories[{in_valid&&in_ready,out_valid&&out_ready}]++;
   if (out_valid && out_ready) begin
     if (head==tail || result!==expected[head]) $fatal(1,"FAIL scoreboard");
     head=head+1; received=received+1;
   end
   if (in_valid && in_ready) begin
     // 扩展到整数运算后再截断，模型按事务计算，不复制槽位控制。
     expected[tail]=op ? (a^b) : W'(int'(a)+int'(b));
     tail=tail+1;
   end
   if (in_valid && in_ready && out_valid && out_ready) simultaneous++;
 end
 task cycle(input bit valid_i,ready_i,op_i,input [W-1:0] aa,bb);
   begin
     @(negedge clk); in_valid=valid_i; out_ready=ready_i; op=op_i; a=aa;b=bb;
     @(posedge clk); #1;
   end
 endtask
 task reset_channel;
   begin
     @(negedge clk); rst_n=0; in_valid=0;out_ready=0;
     cancelled+=tail-head; head=tail;held=0;
     #1;
     if(out_valid!==0) $fatal(1,"FAIL async reset");
     @(negedge clk); rst_n=1;
   end
 endtask
 initial begin
   $dumpfile("channel.vcd");$dumpvars(0,tb_channel);
   for(integer k=0;k<4;k++) categories[k]=0;
   ignored=$value$plusargs("SEED=%d",seed);rng=32'(seed);
   if(rng==0) $fatal(1,"SEED must be nonzero");
   reset_channel();
   cycle(1,0,0,{W{1'b1}},W'(1));
   repeat(4) cycle(0,0,0,0,0);
   cycle(1,1,1,{W{1'b1}},0);
   cycle(0,1,0,0,0);
   // 背压时源保持 valid 和 payload，直到握手；只在槽可接收后换事务。
   for(integer k=0;k<400;k++) begin
     @(negedge clk);
     rng=next_random(rng);out_ready=rng[0]|rng[1];
     if(!in_valid || source_accepted) begin
       rng=next_random(rng);in_valid=rng[0];op=rng[1];a=W'(rng>>2);
       rng=next_random(rng);b=W'(rng);
     end
     @(posedge clk);#1;
   end
   // 随机流结束前先保证最后一个源请求已被接受。
   while(in_valid && !source_accepted) begin
     @(negedge clk);out_ready=1;
     @(posedge clk);#1;
   end
   cycle(0,1,0,0,0);
   cycle(1,0,0,W'(3),W'(4));
   reset_channel();
   cycle(1,1,1,W'(5),W'(3));
   cycle(0,1,0,0,0);
   repeat(2) cycle(0,1,0,0,0);
   if(head!=tail || cancelled!=1 || stalls==0 || simultaneous==0) $fatal(1,"FAIL completion");
   for(integer k=0;k<4;k++) if(categories[k]==0) $fatal(1,"FAIL coverage bin %0d",k);
   $display("PASS channel W=%0d seed=%0d accepted=%0d received=%0d cancelled=%0d stalls=%0d transfer_bins=4/4",W,seed,tail,received,cancelled,stalls);
   $finish;
 end
 initial begin #100000; $fatal(1,"FAIL timeout");end
endmodule
