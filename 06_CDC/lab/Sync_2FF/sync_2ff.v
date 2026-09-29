// =============================================================================
// N 级电平同步器（默认两级，"打两拍"）
//   只能用于：单 bit 电平信号，或"每次只变 1 bit"的多 bit 信号（Gray 码指针）
//   不能用于：普通多 bit 总线（各 bit 到达时间不同 → 采到新旧混合值，见 tb_bus_skew.v）
//             比目的时钟周期还窄的脉冲（可能一个沿都采不到，见 ../Pulse_Sync）
//
// 工程上的额外要求（RTL 看不出来，但面试会问）：
//   - 源端信号必须直接来自源时钟域的寄存器，中间不能有组合逻辑（组合逻辑的毛刺会被采到）
//   - 同步器各级之间不插任何逻辑，布局时靠近摆放，给亚稳态恢复留足时间
//   - 综合时常加 dont_touch / 用库里专门的同步器单元，并按命名规则方便 CDC 工具识别
// =============================================================================
`timescale 1ns / 1ps

module sync_2ff #(
    parameter WIDTH  = 1,
    parameter STAGES = 2          // >= 2
)(
    input                  clk_dst,
    input                  rst_dst_n,
    input      [WIDTH-1:0] din,        // 来自源时钟域寄存器
    output     [WIDTH-1:0] dout        // 已同步到 clk_dst
);
    reg [WIDTH-1:0] sync_q [0:STAGES-1];
    integer i;

    always @(posedge clk_dst or negedge rst_dst_n) begin
        if (!rst_dst_n) begin
            for (i = 0; i < STAGES; i = i + 1)
                sync_q[i] <= {WIDTH{1'b0}};
        end else begin
            sync_q[0] <= din;                   // 第 1 级：可能亚稳
            for (i = 1; i < STAGES; i = i + 1)
                sync_q[i] <= sync_q[i-1];       // 后续各级：给亚稳态留恢复时间
        end
    end

    assign dout = sync_q[STAGES-1];
endmodule
