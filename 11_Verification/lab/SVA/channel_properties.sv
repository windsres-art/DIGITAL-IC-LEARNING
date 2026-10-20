`timescale 1ns/1ps
module channel_properties #(parameter W=8)(
 input clk,rst_n,in_valid,in_ready,out_valid,out_ready,op,
 input [W-1:0] a,b,result
);
 // 并发属性在时钟沿采样；|=> 的后件是下一次采样沿。
 hold_response: assert property (@(posedge clk) disable iff(!rst_n)
   out_valid && !out_ready |=> out_valid && $stable(result))
   else $fatal(1,"FAIL SVA hold_response");
 capture_response: assert property (@(posedge clk) disable iff(!rst_n)
   in_valid && in_ready |=> out_valid &&
     result == ($past(op) ? ($past(a)^$past(b)) : W'($past(a)+$past(b))))
   else $fatal(1,"FAIL SVA capture_response");
 clear_response: assert property (@(posedge clk) disable iff(!rst_n)
   in_ready && !in_valid |=> !out_valid)
   else $fatal(1,"FAIL SVA clear_response");
 ready_equation: assert property (@(posedge clk) disable iff(!rst_n)
   in_ready == (!out_valid || out_ready))
   else $fatal(1,"FAIL SVA ready_equation");
 cover property (@(posedge clk) disable iff(!rst_n)
   in_valid && in_ready && out_valid && out_ready);
endmodule
