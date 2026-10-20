`timescale 1ns/1ps
// 事务类只描述激励；驱动任务负责时序，参考模型只负责算术规格。
class transaction;
 rand bit op;
 rand bit [7:0] a,b;
 constraint legal { a inside {[0:15]}; b inside {[0:15]}; }
 virtual function bit [7:0] predict();
   return op ? a^b : 8'(int'(a)+int'(b));
 endfunction
endclass
class corner_transaction extends transaction;
 constraint corner { a inside {0,15}; b inside {0,15}; }
endclass
module tb_objects;
 bit clk=0,rst_n=0,in_valid=0,out_ready=0,op=0;
 bit [7:0] a=0,b=0;
 wire in_ready,out_valid;
 wire [7:0] result;
 elastic_alu dut(.*);
 always #5 clk=~clk;
 mailbox #(transaction) requests=new(2);
 semaphore serial_driver=new(1);
 int hits[2][2][2];
 int consumed=0, produced=0;
 covergroup operations with function sample(bit opcode, bit azero, bit bzero);
   cp_op: coverpoint opcode;
   cp_a: coverpoint azero;
   cp_b: coverpoint bzero;
   combinations: cross cp_op, cp_a, cp_b;
 endgroup
 operations cov=new;
 task drive(transaction tr);
   serial_driver.get(1);
   @(negedge clk);in_valid=1;op=tr.op;a=tr.a;b=tr.b;out_ready=0;
   do begin @(posedge clk); end while(!in_ready);
   #1;
   @(negedge clk);in_valid=0;
   // 每笔响应背压两拍，检查保存的数据。
   repeat(2) begin
     @(posedge clk);
     assert(out_valid && result==tr.predict()) else $fatal(1,"FAIL class scoreboard");
   end
   @(negedge clk);out_ready=1;
   @(posedge clk);
   assert(out_valid && result==tr.predict()) else $fatal(1,"FAIL consume");
   hits[int'(tr.op)][int'(tr.a==0)][int'(tr.b==0)]++;
   cov.sample(tr.op,tr.a==0,tr.b==0);
   consumed++;
   #1;
   serial_driver.put(1);
 endtask
 initial begin
   $dumpfile("objects.vcd");$dumpvars(0,tb_objects);
   @(negedge clk);rst_n=1;
   fork
     begin : generator
       transaction tr;
       corner_transaction ct;
       // 定向关闭全部交叉 bin，然后添加约束随机；不靠运气满足完成条件。
       for(int k=0;k<8;k++) begin
         tr=new;tr.op=1'(k>>2);tr.a=k[1]?0:15;tr.b=k[0]?0:15;
         requests.put(tr);produced++;
       end
       for(int k=0;k<64;k++) begin
         if(k%2==0) begin
           ct=new;
           assert(ct.randomize()!=0) else $fatal(1,"FAIL corner randomize");
           tr=ct;
         end else begin
           tr=new;
           assert(tr.randomize()!=0) else $fatal(1,"FAIL randomize");
         end
         assert(tr.a<=15 && tr.b<=15) else $fatal(1,"FAIL constraint");
         requests.put(tr);produced++;
       end
     end
     begin : driver
       transaction tr;
       repeat(72) begin requests.get(tr);drive(tr);end
     end
   join
   foreach(hits[i,j,k]) if(hits[i][j][k]==0) $fatal(1,"FAIL coverage");
   if(produced!=72 || consumed!=72 || requests.num()!=0) $fatal(1,"FAIL drain");
   $display("PASS SV objects produced=%0d consumed=%0d cross_bins=8/8 coverage=%0.1f",produced,consumed,cov.get_inst_coverage());
   $finish;
 end
 initial begin #100000;$fatal(1,"FAIL timeout");end
endmodule
