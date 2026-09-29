// =============================================================================
// skid buffer（全寄存 register slice）：valid、data、ready 三个方向都从寄存器输出
//   - 主寄存器 out_*：正常情况下数据每拍直接从 in 装进来，吞吐 100%
//   - 缓存寄存器 skid_*：in_ready 是上一拍算好的寄存值，下游这一拍撤销 ready 时，
//     上游已经看到 in_ready=1 并把数据送出来了——这个"刹不住车滑出去"的数据
//     由 skid 接住，下一拍 in_ready 才变 0
//   - in_ready = ~skid_valid：只和本级寄存器有关，out_ready 到 in_ready 没有组合路径
//   - 下游恢复 ready 时先把 skid 里的数据送进主寄存器，保证顺序
// =============================================================================
module skid_buffer #(
    parameter DW = 8
)(
    input               clk,
    input               rst_n,
    input               in_valid,
    output              in_ready,
    input      [DW-1:0] in_data,
    output reg          out_valid,
    input               out_ready,
    output reg [DW-1:0] out_data
);
    reg          skid_valid;
    reg [DW-1:0] skid_data;

    assign in_ready = ~skid_valid;

    wire in_fire  = in_valid & in_ready;
    wire out_load = ~out_valid | out_ready;     // 主寄存器这一拍可以装新数据

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            skid_valid <= 1'b0;
        end else if (out_load) begin
            // skid 有数据时 in_ready=0，本拍不会有 in_fire，先把 skid 送走
            out_valid  <= skid_valid | in_valid;
            skid_valid <= 1'b0;
        end else if (in_fire) begin
            skid_valid <= 1'b1;                 // 主寄存器被反压，滑出来的数据进 skid
        end
    end

    // 数据通路不复位，只在真正装入时更新
    always @(posedge clk) begin
        if (out_load && (skid_valid || in_valid)) out_data  <= skid_valid ? skid_data : in_data;
        if (!out_load && in_fire)                 skid_data <= in_data;
    end

endmodule
