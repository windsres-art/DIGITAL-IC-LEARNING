// signed 定点格式转换；W 含符号位，F 是小数位数。
// 参数约束：IW,OW>=1，0<=IF<IW，0<=OF<OW。
// mode: 0 floor，1 toward zero，2 nearest ties-to-even，3 ceil。
module fixed_quantize #(
    parameter IW=8, OW=4, IF=4, OF=2
) (
    input wire signed [IW-1:0] x,
    input wire [1:0] mode,
    output reg signed [OW-1:0] y,
    output reg overflow,
    output wire inexact
);
    localparam EW=IW+OW+2;
    localparam signed [EW-1:0] MAXIMUM =
        {{(EW-OW){1'b0}}, 1'b0, {(OW-1){1'b1}}};
    localparam signed [EW-1:0] MINIMUM =
        {{(EW-OW){1'b1}}, 1'b1, {(OW-1){1'b0}}};
    wire signed [EW-1:0] extended = {{(EW-IW){x[IW-1]}}, x};
    wire signed [EW-1:0] base;
    wire lost, above_half, tie;
    generate if (IF > OF) begin: right_scale
        localparam SHIFT=IF-OF;
        localparam [SHIFT-1:0] HALF={1'b1, {(SHIFT-1){1'b0}}};
        wire [SHIFT-1:0] tail=x[SHIFT-1:0];
        assign base=extended >>> SHIFT;
        assign lost=|tail;
        if(SHIFT==1) begin: one_bit
            assign above_half=1'b0;
        end else begin: more_bits
            assign above_half=tail[SHIFT-1] && (|tail[SHIFT-2:0]);
        end
        assign tie=tail==HALF;
    end else begin: exact_scale
        // 扩宽在前，避免左移在输入位宽内溢出。
        assign base=extended <<< (OF-IF);
        assign lost=1'b0;
        assign above_half=1'b0;
        assign tie=1'b0;
    end endgenerate
    reg increment;
    reg signed [EW-1:0] rounded;
    always @* begin
        increment=1'b0;
        case(mode)
            2'd0: increment=1'b0;
            2'd1: increment=x[IW-1] && lost;
            2'd2: increment=above_half || (tie && base[0]);
            2'd3: increment=lost;
        endcase
        rounded=base + {{(EW-1){1'b0}}, increment};
        overflow=1'b0;
        // 先舍入、后比较，不能先窄化再检查符号。
        if(rounded>MAXIMUM) begin y=MAXIMUM[OW-1:0]; overflow=1'b1; end
        else if(rounded<MINIMUM) begin y=MINIMUM[OW-1:0]; overflow=1'b1; end
        else y=rounded[OW-1:0];
    end
    // 本接口表示输出数值不精确，包含因饱和而丢失的数值。
    assign inexact=lost || overflow;
endmodule
