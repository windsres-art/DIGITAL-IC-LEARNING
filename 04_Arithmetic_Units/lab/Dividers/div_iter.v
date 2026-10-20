// NONRESTORE=0：恢复余数；=1：不恢复余数。W>=1，固定 W 拍计算。
module div_iter #(
    parameter W = 8,
    parameter NONRESTORE = 0
) (
    input wire clk, rst_n,
    input wire req_valid,
    output wire req_ready,
    input wire signed_mode,
    input wire [W-1:0] a, b,
    output reg busy, rsp_valid,
    input wire rsp_ready,
    output reg [W-1:0] quotient, remainder,
    output reg div_zero, overflow
);
    localparam CW = (W <= 1) ? 1 : $clog2(W);
    localparam [W-1:0] MINIMUM = {1'b1, {(W-1){1'b0}}};
    localparam integer LAST = W-1;
    reg [CW-1:0] count;
    reg [W-1:0] q_work, divisor, original_a;
    reg signed [W+1:0] partial;
    reg neg_q, neg_r, zero_saved, overflow_saved;
    wire [W-1:0] mag_a = (signed_mode && a[W-1]) ? -a : a;
    wire [W-1:0] mag_b = (signed_mode && b[W-1]) ? -b : b;
    // 先扩展再移位：中间值需要容纳约 +/-2D。
    wire signed [W+1:0] shifted = {partial[W:0], q_work[W-1]};
    wire signed [W+1:0] d_ext = $signed({2'b00, divisor});
    wire signed [W+1:0] trial =
        (NONRESTORE != 0 && partial[W+1]) ? shifted + d_ext : shifted - d_ext;
    wire signed [W+1:0] r_next =
        (NONRESTORE == 0 && trial[W+1]) ? shifted : trial;
    wire [W-1:0] q_next = (q_work << 1) | {{(W-1){1'b0}}, !trial[W+1]};
    // 正常除法最终校正值位于 [0,D)，取模 W 位加法不会丢失有效结果。
    wire [W-1:0] r_mag = (NONRESTORE != 0 && r_next[W+1]) ?
        r_next[W-1:0] + divisor : r_next[W-1:0];
    assign req_ready = rst_n && !busy && !rsp_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 0; q_work <= 0; divisor <= 0; original_a <= 0;
            partial <= 0; neg_q <= 0; neg_r <= 0;
            zero_saved <= 0; overflow_saved <= 0;
            busy <= 0; rsp_valid <= 0;
            quotient <= 0; remainder <= 0; div_zero <= 0; overflow <= 0;
        end else begin
            if (rsp_valid && rsp_ready) rsp_valid <= 0;
            if (req_valid && req_ready) begin
                q_work <= mag_a; divisor <= mag_b; original_a <= a;
                partial <= 0; count <= 0; busy <= 1;
                neg_q <= signed_mode && (a[W-1] ^ b[W-1]);
                neg_r <= signed_mode && a[W-1];
                zero_saved <= (b == 0);
                overflow_saved <= signed_mode && a == MINIMUM && (&b);
            end else if (busy) begin
                q_work <= q_next; partial <= r_next;
                if (count == LAST[CW-1:0]) begin
                    busy <= 0; rsp_valid <= 1;
                    div_zero <= zero_saved; overflow <= overflow_saved;
                    quotient <= zero_saved ? {W{1'b1}} :
                        (neg_q ? -q_next : q_next);
                    remainder <= zero_saved ? original_a :
                        (neg_r ? -r_mag : r_mag);
                end else count <= count + 1'b1;
            end
        end
    end
endmodule
