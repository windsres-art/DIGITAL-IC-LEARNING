// 教学 TAP：完整 16 状态，2 位 IR，8 位边界寄存器，1 位 BYPASS。
// 非完整 IEEE 1149.1 合规 IP：无 BSDL、IDCODE、双向 pad/输出使能建模。
module tap_demo (
    input wire tck,trst_n,tms,tdi,
    input wire [3:0] pad_in,core_out,
    output wire [3:0] pad_out,
    output reg tdo,
    output wire tdo_oe,
    output wire [3:0] state_debug,
    output wire [1:0] instruction_debug
);
    localparam RESET=4'd0,IDLE=4'd1,SEL_DR=4'd2,CAP_DR=4'd3,
      SHIFT_DR=4'd4,EXIT1_DR=4'd5,PAUSE_DR=4'd6,EXIT2_DR=4'd7,UPDATE_DR=4'd8,
      SEL_IR=4'd9,CAP_IR=4'd10,SHIFT_IR=4'd11,EXIT1_IR=4'd12,
      PAUSE_IR=4'd13,EXIT2_IR=4'd14,UPDATE_IR=4'd15;
    localparam EXTEST=2'b00,SAMPLE=2'b01,BYPASS=2'b11;
    reg [3:0] state,next_state;
    reg [1:0] ir_shift,ir_active;
    reg [7:0] boundary_shift;
    reg [3:0] boundary_update;
    reg bypass_shift;
    wire boundary_selected=ir_active==EXTEST || ir_active==SAMPLE;
    assign state_debug=state;
    assign instruction_debug=ir_active;
    assign pad_out=(ir_active==EXTEST) ? boundary_update : core_out;
    assign tdo_oe=state==SHIFT_DR || state==SHIFT_IR;
    always @* begin
        case(state)
            RESET: next_state=tms ? RESET : IDLE;
            IDLE: next_state=tms ? SEL_DR : IDLE;
            SEL_DR: next_state=tms ? SEL_IR : CAP_DR;
            CAP_DR: next_state=tms ? EXIT1_DR : SHIFT_DR;
            SHIFT_DR: next_state=tms ? EXIT1_DR : SHIFT_DR;
            EXIT1_DR: next_state=tms ? UPDATE_DR : PAUSE_DR;
            PAUSE_DR: next_state=tms ? EXIT2_DR : PAUSE_DR;
            EXIT2_DR: next_state=tms ? UPDATE_DR : SHIFT_DR;
            UPDATE_DR: next_state=tms ? SEL_DR : IDLE;
            SEL_IR: next_state=tms ? RESET : CAP_IR;
            CAP_IR: next_state=tms ? EXIT1_IR : SHIFT_IR;
            SHIFT_IR: next_state=tms ? EXIT1_IR : SHIFT_IR;
            EXIT1_IR: next_state=tms ? UPDATE_IR : PAUSE_IR;
            PAUSE_IR: next_state=tms ? EXIT2_IR : PAUSE_IR;
            EXIT2_IR: next_state=tms ? UPDATE_IR : SHIFT_IR;
            UPDATE_IR: next_state=tms ? SEL_DR : IDLE;
            default: next_state=RESET;
        endcase
    end
    always @(posedge tck or negedge trst_n) begin
        if(!trst_n) begin
            state<=RESET; ir_shift<=2'b01; boundary_shift<=0; bypass_shift<=0;
        end else begin
            state<=next_state;
            if(state==CAP_IR) ir_shift<=2'b01;
            else if(state==SHIFT_IR) ir_shift<={tdi,ir_shift[1]};
            if(state==CAP_DR) begin
                if(boundary_selected) boundary_shift<={pad_in,pad_out};
                else bypass_shift<=0;
            end else if(state==SHIFT_DR) begin
                if(boundary_selected) boundary_shift<={tdi,boundary_shift[7:1]};
                else bypass_shift<=tdi;
            end
        end
    end
    // Update 锁存与 TDO 在下降沿变化，驱动端在下一个上升沿采样 TDO。
    always @(negedge tck or negedge trst_n) begin
        if(!trst_n) begin ir_active<=BYPASS; boundary_update<=0; tdo<=0; end
        else begin
            if(state==RESET) ir_active<=BYPASS;
            else if(state==UPDATE_IR) ir_active<=ir_shift;
            if(state==UPDATE_DR && boundary_selected) boundary_update<=boundary_shift[3:0];
            if(state==SHIFT_IR) tdo<=ir_shift[0];
            else if(state==SHIFT_DR) tdo<=boundary_selected ? boundary_shift[0] : bypass_shift;
            else tdo<=0;
        end
    end
endmodule
