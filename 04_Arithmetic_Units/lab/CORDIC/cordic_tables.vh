// 由 generate_vectors.py --write-tables 生成；弧度乘 2^20 后取最近偶数。
function signed [23:0] atan_value;
    input [4:0] index;
    begin
        case(index)
            5'd0: atan_value=24'sd823550;
            5'd1: atan_value=24'sd486170;
            5'd2: atan_value=24'sd256879;
            5'd3: atan_value=24'sd130396;
            5'd4: atan_value=24'sd65451;
            5'd5: atan_value=24'sd32757;
            5'd6: atan_value=24'sd16383;
            5'd7: atan_value=24'sd8192;
            5'd8: atan_value=24'sd4096;
            5'd9: atan_value=24'sd2048;
            5'd10: atan_value=24'sd1024;
            5'd11: atan_value=24'sd512;
            5'd12: atan_value=24'sd256;
            5'd13: atan_value=24'sd128;
            5'd14: atan_value=24'sd64;
            5'd15: atan_value=24'sd32;
            5'd16: atan_value=24'sd16;
            5'd17: atan_value=24'sd8;
            5'd18: atan_value=24'sd4;
            5'd19: atan_value=24'sd2;
            default: atan_value=24'sd0;
        endcase
    end
endfunction
localparam signed [23:0] KINV =
    (ITER==8) ? 24'sd636757 :
    (ITER==12) ? 24'sd636751 :
    (ITER==16) ? 24'sd636751 :
    24'sd636751;
