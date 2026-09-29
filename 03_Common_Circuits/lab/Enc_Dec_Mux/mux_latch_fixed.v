// =============================================================================
// mux_latch_bad.v 的修正版：always 开头给默认值，所有路径都有赋值 → 纯组合逻辑
// =============================================================================
module mux_latch_fixed (
    input      [1:0] sel,
    input      [2:0] d,
    output reg       y
);
    always @(*) begin
        y = 1'b0;
        case (sel)
            2'd0: y = d[0];
            2'd1: y = d[1];
            2'd2: y = d[2];
            default: ;
        endcase
    end
endmodule
