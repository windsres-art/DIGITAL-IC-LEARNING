`timescale 1ns/1ps
// 教学用缓冲单元模型，不是工艺库；SDF 覆盖 specify 中默认 1ns。
module delay_cell(input A, output Y);
 buf(Y,A);
 specify
   (A=>Y)=(1,1);
 endspecify
endmodule
