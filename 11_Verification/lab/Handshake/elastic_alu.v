`timescale 1ns/1ps
// 单槽响应：未被接收时保持；同拍取走旧响应并接受新请求。
module elastic_alu #(parameter W=8)(
 input clk, rst_n, in_valid, out_ready, op,
 input [W-1:0] a,b,
 output in_ready,
 output reg out_valid,
 output reg [W-1:0] result
);
 assign in_ready = !out_valid || out_ready;
 always @(posedge clk or negedge rst_n)
   if (!rst_n) begin out_valid<=0; result<=0; end
   else if (in_ready) begin
     out_valid<=in_valid;
     if (in_valid) result<=op ? (a^b) : (a+b);
   end
endmodule
