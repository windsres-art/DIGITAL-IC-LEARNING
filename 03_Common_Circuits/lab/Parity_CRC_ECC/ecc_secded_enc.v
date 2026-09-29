// =============================================================================
// SECDED 汉明码编码器（Single Error Correction, Double Error Detection），组合逻辑
//   码字位置编号 1..N（N = DW + R），2 的幂位置（1, 2, 4, 8, ...）放校验位，其余放数据
//   校验位 p_j（位置 2^j）= 所有"位置编号第 j 位为 1"的码字位的异或
//   另加总体奇偶位放在 code[0]：整个码字 1 的个数为偶数
//   R 是满足 2^R >= DW + R + 1 的最小值：DW = 8/32/64 → (13,8) / (39,32) / (72,64)
//   不用 always 里的"半成品"码字当输入：先放数据位，再算校验位，最后算总体奇偶
// =============================================================================
module ecc_secded_enc #(
    parameter DW = 8,
    parameter R  = ecc_r(DW),
    parameter N  = DW + R
)(
    input  [DW-1:0] data,
    output reg [N:0] code
);
    function integer ecc_r(input integer dw);
        begin
            ecc_r = 0;
            while ((1 << ecc_r) < dw + ecc_r + 1) ecc_r = ecc_r + 1;
        end
    endfunction

    integer p, j, di;
    reg     par;
    always @(*) begin
        code = {(N+1){1'b0}};
        di   = 0;
        for (p = 1; p <= N; p = p + 1)
            if ((p & (p - 1)) != 0) begin       // 不是 2 的幂 → 数据位
                code[p] = data[di];
                di = di + 1;
            end
        for (j = 0; j < R; j = j + 1) begin
            par = 1'b0;
            for (p = 1; p <= N; p = p + 1)
                if (((p >> j) & 1) != 0) par = par ^ code[p];   // 此时校验位还是 0
            code[1 << j] = par;
        end
        code[0] = ^code[N:1];
    end
endmodule
