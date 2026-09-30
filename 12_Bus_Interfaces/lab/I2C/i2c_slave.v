// =============================================================================
// I2C 从机：7 bit 地址，16 个 8 bit 寄存器，带自增的寄存器指针（典型传感器 / EEPROM 协议）
//   写：S | ADDR+W | A | PTR | A | D0 | A | D1 | A ... | P        （Dn 写到 PTR+n）
//   读：S | ADDR+W | A | PTR | A | Sr | ADDR+R | A | D0 | A | ... | Dn | NA | P
//       也可以不设指针直接 S | ADDR+R 从当前指针读
//   运行在系统时钟上：SCL / SDA 两级同步后检测边沿
//     START：SCL 高时 SDA 下降；STOP：SCL 高时 SDA 上升（任何时候检测到都优先处理）
//     SCL 上升沿采样 SDA；SCL 下降沿之后才改 SDA（本从机只在检测到 SCL 下降时改，天然有保持时间）
//   时钟拉伸：每个字节的应答位结束（SCL 下降）后把 SCL 再拉低 stretch 个 clk，模拟"数据还没准备好"
// =============================================================================
module i2c_slave #(
    parameter [6:0] ADDR = 7'h50
)(
    input        clk,
    input        rst_n,
    input  [7:0] stretch,
    input        scl_i,
    output       scl_oe,
    input        sda_i,
    output reg   sda_oe
);
    localparam [2:0] S_IDLE = 3'd0, S_ADDR = 3'd1, S_PTR = 3'd2,
                     S_WDATA = 3'd3, S_READ = 3'd4, S_IGNORE = 3'd5;

    reg [2:0] scl_r, sda_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scl_r <= 3'b111; sda_r <= 3'b111; end
        else        begin scl_r <= {scl_r[1:0], scl_i}; sda_r <= {sda_r[1:0], sda_i}; end
    end
    wire scl_s    = scl_r[1];
    wire sda_s    = sda_r[1];
    wire scl_rise =  scl_r[1] & ~scl_r[2];
    wire scl_fall = ~scl_r[1] &  scl_r[2];
    wire start_d  = scl_s & scl_r[2] & ~sda_r[1] &  sda_r[2];
    wire stop_d   = scl_s & scl_r[2] &  sda_r[1] & ~sda_r[2];

    reg [7:0] regs [0:15];
    reg [3:0] ptr;
    reg [2:0] st;
    reg [3:0] bitc;
    reg       ackph;            // 正处在第 9 位（应答位）
    reg [7:0] sh;
    reg [6:0] tsh;              // 读数据的低 7 位；最高位在装载时直接驱动 SDA
    reg       mack_n;           // 主机读时回的 ACK/NACK
    reg [7:0] scnt;

    assign scl_oe = (scnt != 8'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; bitc <= 4'd0; ackph <= 1'b0; sh <= 8'h0; tsh <= 7'h0;
            ptr <= 4'd0; mack_n <= 1'b1; sda_oe <= 1'b0; scnt <= 8'd0;
        end else begin
            if (scnt != 8'd0) scnt <= scnt - 1'b1;
            if (start_d) begin
                st <= S_ADDR; bitc <= 4'd0; ackph <= 1'b0; sda_oe <= 1'b0;
            end else if (stop_d) begin
                st <= S_IDLE; sda_oe <= 1'b0;
            end else if (st != S_IDLE && st != S_IGNORE) begin
                if (scl_rise) begin
                    if (!ackph) begin
                        sh   <= {sh[6:0], sda_s};
                        bitc <= bitc + 1'b1;
                    end else if (st == S_READ) begin
                        mack_n <= sda_s;
                    end
                end
                if (scl_fall) begin
                    if (!ackph && bitc == 4'd8) begin           // 8 位收完，进入应答位
                        ackph <= 1'b1;
                        case (st)
                            S_ADDR:  if (sh[7:1] == ADDR) sda_oe <= 1'b1;
                                     else                  st <= S_IGNORE;
                            S_PTR:   begin ptr <= sh[3:0]; sda_oe <= 1'b1; end
                            S_WDATA: begin regs[ptr] <= sh; ptr <= ptr + 1'b1; sda_oe <= 1'b1; end
                            default: sda_oe <= 1'b0;             // S_READ：释放，听主机应答
                        endcase
                    end else if (ackph) begin                   // 应答位结束
                        ackph <= 1'b0;
                        bitc  <= 4'd0;
                        scnt  <= stretch;
                        case (st)
                            S_ADDR: if (sh[0]) begin
                                        st <= S_READ; tsh <= regs[ptr][6:0]; sda_oe <= ~regs[ptr][7];
                                        ptr <= ptr + 1'b1;
                                    end else begin
                                        st <= S_PTR; sda_oe <= 1'b0;
                                    end
                            S_PTR:  begin st <= S_WDATA; sda_oe <= 1'b0; end
                            S_READ: if (!mack_n) begin
                                        tsh <= regs[ptr][6:0]; sda_oe <= ~regs[ptr][7];
                                        ptr <= ptr + 1'b1;
                                    end else begin
                                        st <= S_IGNORE; sda_oe <= 1'b0;   // NACK：不再发，等 P / Sr
                                    end
                            default: sda_oe <= 1'b0;
                        endcase
                    end else if (st == S_READ) begin            // 读的第 2~8 位
                        sda_oe <= ~tsh[6];
                        tsh    <= {tsh[5:0], 1'b0};
                    end
                end
            end
        end
    end
endmodule
