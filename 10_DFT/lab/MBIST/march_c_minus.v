// 破坏性字级 March C-；存储器接口为同步读，读请求后下一拍检查。
module march_c_minus #(
    parameter DEPTH=8, W=8, AW=(DEPTH<=1 ? 1 : $clog2(DEPTH))
) (
    input wire clk,rst_n,start,
    output wire busy,
    output reg done,fail,
    output reg [AW-1:0] first_fail_addr,
    output reg [2:0] first_fail_phase,
    output wire mem_en,mem_we,
    output reg [AW-1:0] mem_addr,
    output wire [W-1:0] mem_wdata,
    input wire [W-1:0] mem_rdata
);
    localparam IDLE=3'd0,WRITE=3'd1,READ_REQ=3'd2,CHECK=3'd3,FINISH=3'd4;
    localparam integer LAST=DEPTH-1;
    reg [2:0] state,phase;
    wire descending=(phase==3 || phase==4);
    wire last_address=descending ? mem_addr==0 : mem_addr==LAST[AW-1:0];
    wire expect_one=(phase==2 || phase==4);
    assign busy=state!=IDLE;
    assign mem_en=state==WRITE || state==READ_REQ;
    assign mem_we=state==WRITE;
    assign mem_wdata=(phase==1 || phase==3) ? {W{1'b1}} : {W{1'b0}};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; phase<=0; mem_addr<=0;
            done<=0; fail<=0; first_fail_addr<=0; first_fail_phase<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    phase<=0; mem_addr<=0; state<=WRITE;
                    fail<=0; first_fail_addr<=0; first_fail_phase<=0;
                end
                WRITE: begin
                    if(last_address) begin
                        phase<=phase+1'b1;
                        mem_addr<=(phase==2 || phase==3) ? LAST[AW-1:0] : {AW{1'b0}};
                        state<=READ_REQ;
                    end else begin
                        mem_addr<=descending ? mem_addr-1'b1 : mem_addr+1'b1;
                        state<=(phase==0) ? WRITE : READ_REQ;
                    end
                end
                READ_REQ: state<=CHECK;
                CHECK: begin
                    if(mem_rdata!={W{expect_one}}) begin
                        fail<=1;
                        if(!fail) begin first_fail_addr<=mem_addr; first_fail_phase<=phase; end
                    end
                    if(phase==5) begin
                        if(last_address) state<=FINISH;
                        else begin mem_addr<=mem_addr+1'b1; state<=READ_REQ; end
                    end else state<=WRITE;
                end
                FINISH: begin done<=1; state<=IDLE; end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
