// =============================================================================
// case 写法的 ROM：32 点正弦表，8 bit 有符号，round(127 * sin(2*pi*i/32))
//   同步读（地址打一拍），和 SRAM 宏 / FPGA Block ROM 的时序一致
//   case 常量表在 ASIC 上综合成组合逻辑（小表）或由 ROM 编译器生成宏（大表）；
//   FPGA 上也常用 initial $readmemh 装载——那是 FPGA 工具支持的初始化方式，ASIC 不可用
//   有 default 分支：AW 位地址已全覆盖时它不会生效，但保证不同工具下都不推断 latch
// =============================================================================
module rom_sine (
    input                   clk,
    input      [4:0]        addr,
    output reg signed [7:0] data
);
    always @(posedge clk) begin
        case (addr)
            5'd0 : data <=  8'sd0;    5'd1 : data <=  8'sd25;   5'd2 : data <=  8'sd49;   5'd3 : data <=  8'sd71;
            5'd4 : data <=  8'sd90;   5'd5 : data <=  8'sd106;  5'd6 : data <=  8'sd117;  5'd7 : data <=  8'sd125;
            5'd8 : data <=  8'sd127;  5'd9 : data <=  8'sd125;  5'd10: data <=  8'sd117;  5'd11: data <=  8'sd106;
            5'd12: data <=  8'sd90;   5'd13: data <=  8'sd71;   5'd14: data <=  8'sd49;   5'd15: data <=  8'sd25;
            5'd16: data <=  8'sd0;    5'd17: data <= -8'sd25;   5'd18: data <= -8'sd49;   5'd19: data <= -8'sd71;
            5'd20: data <= -8'sd90;   5'd21: data <= -8'sd106;  5'd22: data <= -8'sd117;  5'd23: data <= -8'sd125;
            5'd24: data <= -8'sd127;  5'd25: data <= -8'sd125;  5'd26: data <= -8'sd117;  5'd27: data <= -8'sd106;
            5'd28: data <= -8'sd90;   5'd29: data <= -8'sd71;   5'd30: data <= -8'sd49;   5'd31: data <= -8'sd25;
            default: data <= 8'sd0;
        endcase
    end
endmodule
