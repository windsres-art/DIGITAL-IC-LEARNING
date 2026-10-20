// 常供电域 FSM；所有 ack/请求已同步到 clk，物理电源器件不在此模块中。
module power_seq (
    input wire clk,rst_n,sleep_req,
    input wire idle_ack,save_ack,power_good,restore_ack,init_done,
    output reg quiesce,save_req,restore_req,iso_en,clk_en,power_en,active,
    output wire [3:0] state_out
);
    localparam OFF=4'd0, RAMP=4'd1, RESTORE=4'd2, INIT=4'd3,
               ON=4'd4, DRAIN=4'd5, SAVE=4'd6, ISOLATE=4'd7, STOP=4'd8;
    reg [3:0] state,next_state;
    assign state_out=state;
    always @* begin
        next_state=state;
        case(state)
            OFF: if(!sleep_req) next_state=RAMP;
            RAMP: if(power_good) next_state=RESTORE;
            RESTORE: if(restore_ack) next_state=INIT;
            INIT: if(init_done) next_state=ON;
            ON: if(sleep_req) next_state=DRAIN;
            DRAIN: if(idle_ack) next_state=SAVE;
            SAVE: if(save_ack) next_state=ISOLATE;
            ISOLATE: next_state=STOP;
            STOP: next_state=OFF;
            default: next_state=OFF;
        endcase
    end
    // 控制输出寄存，避免直接用多位状态译码驱动隔离/电源控制。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=OFF; active<=0; quiesce<=1; save_req<=0; restore_req<=0;
            iso_en<=1; clk_en<=0; power_en<=0;
        end else begin
            state<=next_state;
            active<=next_state==ON;
            quiesce<=next_state!=ON;
            save_req<=next_state==SAVE;
            restore_req<=next_state==RESTORE;
            iso_en<=next_state!=ON && next_state!=DRAIN && next_state!=SAVE;
            clk_en<=next_state==ON || next_state==DRAIN || next_state==SAVE ||
                    next_state==ISOLATE || next_state==RESTORE || next_state==INIT;
            power_en<=next_state!=OFF;
        end
    end
endmodule
