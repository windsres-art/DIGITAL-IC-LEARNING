// =============================================================================
// 用移位寄存器做任意序列检测（对比状态机写法）
//   窗口 win 保存最近 LEN-1 位，和当前输入拼起来与 PATTERN 比较，匹配当拍 dout=1
//   （时序和 Mealy 状态机相同）。换序列只改参数，不用重画状态图。
//   fill：窗口里已收到的有效位数。复位后窗口是全 0，如果 PATTERN 以 0 开头
//   （如 0010），不等收满就比较会把复位值当成数据，出现假匹配——USE_FILL=0
//   只用于演示这个错误。
//   OVERLAP=0：匹配后 fill 清零，下一次必须收满 LEN 个新位
// =============================================================================
module seq_detect_shift #(
    parameter           LEN      = 4,
    parameter [LEN-1:0] PATTERN  = 4'b1101,
    parameter           OVERLAP  = 1,
    parameter           USE_FILL = 1
)(
    input  clk,
    input  rst_n,
    input  din,
    output dout
);
    localparam CW = $clog2(LEN);
    localparam integer  LAST_I = LEN - 1;
    localparam [CW-1:0] LAST   = LAST_I[CW-1:0];

    reg [LEN-2:0] win;
    reg [CW-1:0]  fill;                 // 饱和在 LEN-1

    wire full_enough = USE_FILL ? (fill == LAST) : 1'b1;
    assign dout = full_enough && ({win, din} == PATTERN);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win  <= {(LEN-1){1'b0}};
            fill <= {CW{1'b0}};
        end else begin
            win <= {win[LEN-3:0], din}; // 丢掉最老的一位（LEN >= 3）
            if (dout && !OVERLAP)  fill <= {CW{1'b0}};
            else if (fill != LAST) fill <= fill + 1'b1;
        end
    end

endmodule
