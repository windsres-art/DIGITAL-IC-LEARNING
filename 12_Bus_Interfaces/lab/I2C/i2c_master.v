// =============================================================================
// I2C 主机：字节级命令接口（START / WRITE / READ / STOP），支持重复起始、
//           时钟拉伸（等 SCL 真正变高）和多主机仲裁（发 1 读到 0 → 仲裁失败）
//   开漏：*_oe = 1 表示把线拉低，0 表示释放（由上拉电阻拉高）；*_i 是线上实际电平
//   每一位分 4 个阶段，每阶段 Q 个 clk：
//     A  SCL 低，阶段开始时改 SDA
//     B  释放 SCL，等线上 SCL 真的变高（从机可能拉伸）后再数 Q 拍
//     C  SCL 高，阶段开始时采样 SDA（并检查仲裁）
//     D  拉低 SCL
//   所以 SCL 高 2Q、低 2Q，SDA 在 SCL 下降后 Q 拍才变（保持时间）、上升前 Q 拍已稳定（建立时间）
//   命令：
//     START  总线空闲时产生起始；持有总线（SCL 低）时产生重复起始
//     WRITE  发 wdata 8 位，第 9 位释放 SDA 读 ACK → ack_n（0 = 从机应答）
//     READ   收 8 位 → rdata，第 9 位发 rd_nack（0 = ACK 继续读，1 = NACK 结束）
//     STOP   产生停止，释放总线
//   每条命令完成时 rsp_valid 单拍有效；arb_lost=1 表示本命令中途仲裁失败，已释放总线
// =============================================================================
module i2c_master #(
    parameter Q = 8
)(
    input            clk,
    input            rst_n,
    input            cmd_valid,
    output           cmd_ready,
    input      [1:0] cmd,
    input      [7:0] wdata,
    input            rd_nack,
    output reg       rsp_valid,
    output reg [7:0] rdata,
    output reg       ack_n,
    output reg       arb_lost,
    input            scl_i,
    output reg       scl_oe,
    input            sda_i,
    output reg       sda_oe
);
    localparam [1:0] C_START = 2'd0, C_WRITE = 2'd1, C_READ = 2'd2, C_STOP = 2'd3;
    localparam [3:0] IDLE = 4'd0, HOLD = 4'd1,
                     ST_A = 4'd2, ST_B = 4'd3, ST_C = 4'd4, ST_D = 4'd5,
                     B_A  = 4'd6, B_B  = 4'd7, B_C  = 4'd8, B_D  = 4'd9,
                     SP_A = 4'd10, SP_B = 4'd11, SP_C = 4'd12;
    localparam TW = $clog2(Q);
    localparam integer  QM1_I = Q - 1;
    localparam [TW-1:0] QM1 = QM1_I[TW-1:0];

    // SCL / SDA 是开漏总线上的异步信号，先同步
    reg [1:0] scl_r, sda_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scl_r <= 2'b11; sda_r <= 2'b11; end
        else        begin scl_r <= {scl_r[0], scl_i}; sda_r <= {sda_r[0], sda_i}; end
    end
    wire scl_s = scl_r[1];
    wire sda_s = sda_r[1];

    reg [3:0]    st;
    reg [TW-1:0] tmr;
    reg [3:0]    bitn;          // 0..8，8 是应答位
    reg [7:0]    sh;
    reg          is_read, nack, ack_r;

    wire tdone = (tmr == {TW{1'b0}});
    assign cmd_ready = (st == IDLE) | (st == HOLD);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; tmr <= {TW{1'b0}}; bitn <= 4'd0; sh <= 8'h0;
            is_read <= 1'b0; nack <= 1'b0; ack_r <= 1'b1;
            scl_oe <= 1'b0; sda_oe <= 1'b0;
            rsp_valid <= 1'b0; rdata <= 8'h0; ack_n <= 1'b1; arb_lost <= 1'b0;
        end else begin
            rsp_valid <= 1'b0;
            if (!tdone) tmr <= tmr - 1'b1;
            case (st)
                IDLE, HOLD: if (cmd_valid) begin
                    tmr <= QM1;
                    arb_lost <= 1'b0;
                    case (cmd)
                        C_START: begin sda_oe <= 1'b0; st <= ST_A; end
                        C_WRITE: begin sh <= wdata; is_read <= 1'b0; bitn <= 4'd0;
                                       sda_oe <= ~wdata[7]; st <= B_A; end
                        C_READ:  begin is_read <= 1'b1; nack <= rd_nack; bitn <= 4'd0;
                                       sda_oe <= 1'b0; st <= B_A; end
                        C_STOP:  begin sda_oe <= 1'b1; st <= SP_A; end
                        default: ;
                    endcase
                end
                // ---------- 起始 / 重复起始：SCL 高时 SDA 从高变低 ----------
                ST_A: if (tdone) begin scl_oe <= 1'b0; tmr <= QM1; st <= ST_B; end
                ST_B: if (!scl_s) tmr <= QM1;
                      else if (tdone) begin sda_oe <= 1'b1; tmr <= QM1; st <= ST_C; end
                ST_C: if (tdone) begin scl_oe <= 1'b1; tmr <= QM1; st <= ST_D; end
                ST_D: if (tdone) begin rsp_valid <= 1'b1; st <= HOLD; end
                // ---------- 一位 ----------
                B_A: if (tdone) begin scl_oe <= 1'b0; tmr <= QM1; st <= B_B; end
                B_B: if (!scl_s) tmr <= QM1;                 // 时钟拉伸 / 多主机时钟同步
                     else if (tdone) begin
                         tmr <= QM1; st <= B_C;
                         if (bitn == 4'd8)      ack_r <= sda_s;
                         else if (is_read)      sh <= {sh[6:0], sda_s};
                         else if (sh[7] && !sda_s) begin     // 发 1 却看到 0：别的主机在发 0
                             scl_oe <= 1'b0; sda_oe <= 1'b0;
                             arb_lost <= 1'b1; rsp_valid <= 1'b1;
                             st <= IDLE;
                         end
                     end
                B_C: if (tdone) begin scl_oe <= 1'b1; tmr <= QM1; st <= B_D; end
                B_D: if (tdone) begin
                    tmr <= QM1;
                    if (bitn == 4'd8) begin
                        sda_oe <= 1'b0;
                        rdata  <= sh;
                        ack_n  <= ack_r;
                        rsp_valid <= 1'b1;
                        st <= HOLD;
                    end else begin
                        bitn <= bitn + 1'b1;
                        st   <= B_A;
                        if (bitn == 4'd7)  sda_oe <= is_read ? ~nack : 1'b0;   // 应答位
                        else if (is_read)  sda_oe <= 1'b0;
                        else begin         sda_oe <= ~sh[6]; sh <= {sh[6:0], 1'b0}; end
                    end
                end
                // ---------- 停止：SCL 高时 SDA 从低变高 ----------
                SP_A: if (tdone) begin scl_oe <= 1'b0; tmr <= QM1; st <= SP_B; end
                SP_B: if (!scl_s) tmr <= QM1;
                      else if (tdone) begin sda_oe <= 1'b0; tmr <= QM1; st <= SP_C; end
                SP_C: if (tdone) begin rsp_valid <= 1'b1; st <= IDLE; end
                default: st <= IDLE;
            endcase
        end
    end
endmodule
