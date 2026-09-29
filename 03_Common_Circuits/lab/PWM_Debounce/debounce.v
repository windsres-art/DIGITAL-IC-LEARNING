// =============================================================================
// 按键消抖
//   1. 两级同步：按键是异步输入，先同步到 clk 域（../06_CDC 第 2 节）
//   2. 稳定计数：同步后的值和当前输出不同，就开始计数；连续 N 拍都不同才翻转
//      输出，中途只要变回去一次计数就清零——宽度 < N 拍的抖动和毛刺全部被滤掉
//   3. 翻转那一拍给出单周期的 press / release 脉冲，供下游直接当事件用
//   IDLE：按键没按下时的电平。常见接法是上拉电阻 + 按下接地，IDLE = 1、按下为 0
//   实际 N 按时间算：50 MHz 时钟、20 ms 消抖时间 → N = 1,000,000，计数器 20 位
// =============================================================================
module debounce #(
    parameter N    = 1000000,
    parameter IDLE = 1'b1
)(
    input      clk,
    input      rst_n,
    input      key_in,              // 异步，来自引脚
    output reg key_level,           // 消抖后的电平
    output reg press,               // 按下（离开 IDLE）单周期脉冲
    output reg release_p            // 松开（回到 IDLE）单周期脉冲
);
    localparam CW = (N > 1) ? $clog2(N) : 1;
    localparam integer  LAST_I = N - 1;
    localparam [CW-1:0] LAST   = LAST_I[CW-1:0];

    // 同步器复位成 IDLE：复位释放时不会误报一次按下
    reg [1:0]    sync;
    reg [CW-1:0] cnt;
    wire         key_s = sync[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sync <= {2{IDLE}};
        else        sync <= {sync[0], key_in};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt       <= {CW{1'b0}};
            key_level <= IDLE;
            press     <= 1'b0;
            release_p <= 1'b0;
        end else begin
            press     <= 1'b0;
            release_p <= 1'b0;
            if (key_s == key_level) begin
                cnt <= {CW{1'b0}};                  // 一回到原电平就重新计
            end else if (cnt == LAST) begin
                cnt       <= {CW{1'b0}};
                key_level <= key_s;
                press     <= (key_s != IDLE);
                release_p <= (key_s == IDLE);
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end

endmodule
