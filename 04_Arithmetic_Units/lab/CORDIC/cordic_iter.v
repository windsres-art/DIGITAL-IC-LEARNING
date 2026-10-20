// 圆周 CORDIC，固定 signed (24,20)，角度单位为弧度。
// ITER 仅支持 8/12/16/20；mode=0 求 sin/cos，mode=1 求向量角度和带增益模长。
module cordic_iter #(parameter ITER=16) (
    input wire clk, rst_n, req_valid,
    output wire req_ready,
    input wire mode,
    input wire signed [23:0] x_in, y_in, angle_in,
    output reg busy, rsp_valid,
    input wire rsp_ready,
    output reg signed [23:0] x_out, y_out, angle_out,
    output reg range_error, zero_vector
);
    localparam signed [23:0] PI=24'sd3294199;
    localparam signed [23:0] HALF_PI=24'sd1647099;
    localparam signed [23:0] ONE=24'sd1048576;
    localparam integer LAST=ITER-1;
    `include "cordic_tables.vh"
    reg [4:0] step;
    reg vector_mode, bad_saved, zero_saved;
    reg signed [23:0] x, y, z;
    wire signed [23:0] x_shift=x >>> step;
    wire signed [23:0] y_shift=y >>> step;
    wire signed [23:0] alpha=atan_value(step);
    // d=+1 对应逆时针微旋转。向量模式要把 y 驱向零。
    wire positive=vector_mode ? y[23] : !z[23];
    wire signed [23:0] x_next=positive ? x-y_shift : x+y_shift;
    wire signed [23:0] y_next=positive ? y+x_shift : y-x_shift;
    wire signed [23:0] z_next=positive ? z-alpha : z+alpha;
    assign req_ready=rst_n && !busy && !rsp_valid;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            busy<=0; rsp_valid<=0; step<=0;
            x<=0; y<=0; z<=0;
            x_out<=0; y_out<=0; angle_out<=0;
            vector_mode<=0; bad_saved<=0; zero_saved<=0;
            range_error<=0; zero_vector<=0;
        end else begin
            if(rsp_valid && rsp_ready) rsp_valid<=0;
            if(req_valid && req_ready) begin
                busy<=1; step<=0; vector_mode<=mode;
                zero_saved<=mode && x_in==0 && y_in==0;
                if(!mode) begin
                    bad_saved<=angle_in>PI || angle_in< -PI;
                    y<=0;
                    if(angle_in>HALF_PI) begin x<=-KINV; z<=angle_in-PI; end
                    else if(angle_in< -HALF_PI) begin x<=-KINV; z<=angle_in+PI; end
                    else begin x<=KINV; z<=angle_in; end
                end else begin
                    bad_saved<=x_in>ONE || x_in< -ONE || y_in>ONE || y_in< -ONE;
                    // 左半平面先翻转 180 度，并预置 atan2 象限偏移。
                    if(x_in<0) begin
                        x<=-x_in; y<=-y_in;
                        z<=y_in[23] ? -PI : PI;
                    end else begin x<=x_in; y<=y_in; z<=0; end
                end
            end else if(busy) begin
                x<=x_next; y<=y_next; z<=z_next;
                if(step==LAST[4:0]) begin
                    busy<=0; rsp_valid<=1;
                    range_error<=bad_saved; zero_vector<=zero_saved;
                    // 无效请求与零向量仍等待完整 ITER 拍，输出约定为零。
                    x_out<=(bad_saved || zero_saved) ? 24'sd0 : x_next;
                    y_out<=(bad_saved || zero_saved) ? 24'sd0 : y_next;
                    angle_out<=(bad_saved || zero_saved) ? 24'sd0 : z_next;
                end else step<=step+1'b1;
            end
        end
    end
endmodule
