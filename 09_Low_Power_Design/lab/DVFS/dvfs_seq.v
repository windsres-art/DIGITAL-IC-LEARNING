// 两个已签核 OPP 的顺序控制；status/settled 均已同步到常供电 clk。
module dvfs_seq (
    input wire clk,rst_n,req_valid,target_high,
    output wire req_ready,
    input wire voltage_high,voltage_settled,frequency_high,frequency_settled,
    output reg voltage_req_high,frequency_req_high,
    output reg current_high,done,
    output wire busy
);
    localparam IDLE=3'd0,UP_V=3'd1,UP_F=3'd2,DOWN_F=3'd3,DOWN_V=3'd4;
    reg [2:0] state;
    assign req_ready=rst_n && state==IDLE;
    assign busy=state!=IDLE;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; voltage_req_high<=0; frequency_req_high<=0;
            current_high<=0; done<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(req_valid) begin
                    if(target_high==current_high) done<=1;
                    else if(target_high) begin voltage_req_high<=1; state<=UP_V; end
                    else begin frequency_req_high<=0; state<=DOWN_F; end
                end
                UP_V: if(voltage_settled && voltage_high) begin
                    frequency_req_high<=1; state<=UP_F;
                end
                UP_F: if(frequency_settled && frequency_high) begin
                    current_high<=1; done<=1; state<=IDLE;
                end
                DOWN_F: if(frequency_settled && !frequency_high) begin
                    voltage_req_high<=0; state<=DOWN_V;
                end
                DOWN_V: if(voltage_settled && !voltage_high) begin
                    current_high<=0; done<=1; state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
