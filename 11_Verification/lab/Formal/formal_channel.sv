module formal_channel(input clk);
 (* anyseq *) reg rst_n,in_valid,out_ready,op;
 (* anyseq *) reg [3:0] a,b;
 wire in_ready,out_valid;
 wire [3:0] result;
 elastic_alu #(.W(4)) dut(.*);
 reg past_valid=0;
 reg occupied=0;
 reg [3:0] reference_data;
 always @(posedge clk) begin
   past_valid<=1;
   // 第一拍复位，此后允许任意复位和任意输入，不假定 ready 最终到来。
   if(!past_valid) assume(!rst_n);
   if(past_valid && rst_n) begin
     assert(out_valid==occupied);
     if(occupied) assert(result==reference_data);
     assert(in_ready==(!out_valid||out_ready));
     if($past(rst_n) && rst_n && $past(out_valid&&!out_ready)) begin
       assert(out_valid);
       assert(result==$past(result));
     end
   end
   if(!rst_n) occupied<=0;
   else begin
     if(out_valid&&out_ready) occupied<=0;
     if(in_valid&&in_ready) begin
       occupied<=1;
       reference_data<=op ? a^b : a+b;
     end
   end
   if(past_valid && rst_n) begin
     cover(out_valid && !out_ready);
     cover(out_valid && out_ready && in_valid && in_ready);
   end
 end
endmodule
