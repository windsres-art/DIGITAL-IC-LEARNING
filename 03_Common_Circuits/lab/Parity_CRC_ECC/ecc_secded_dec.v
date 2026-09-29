// =============================================================================
// SECDED 汉明码译码器（组合逻辑），码字格式见 ecc_secded_enc.v
//   校验子 syn[j] = 所有"位置编号第 j 位为 1"的码字位（含校验位）的异或
//     单 bit 错在位置 e：syn = e（错误位置的二进制编号），这就是汉明码能纠错的原因
//   总体奇偶 ovr = ^code
//     syn = 0, ovr = 0 ：无错
//     ovr = 1         ：奇数个错，按单错处理：翻转位置 syn（syn = 0 表示错在 code[0]）
//                       syn > N 不是合法位置，一定是多 bit 错 → 报不可纠正
//     syn != 0, ovr = 0：偶数个错（两位错）→ 报不可纠正，不改数据
//   三位及以上错误可能被"纠"成错误数据（误纠），这是 SECDED 的能力边界
// =============================================================================
module ecc_secded_dec #(
    parameter DW = 8,
    parameter R  = ecc_r(DW),
    parameter N  = DW + R
)(
    input      [N:0]    code,
    output reg [DW-1:0] data,
    output reg          err_corr,     // 发现并纠正了 1 bit 错
    output reg          err_uncorr,   // 发现不可纠正的错（两位错）
    output reg [R-1:0]  syn
);
    function integer ecc_r(input integer dw);
        begin
            ecc_r = 0;
            while ((1 << ecc_r) < dw + ecc_r + 1) ecc_r = ecc_r + 1;
        end
    endfunction

    localparam [R-1:0] NMAX = N[R-1:0];     // 2^R >= N + 1，N 一定放得下

    integer p, j, di;
    reg     ovr;
    reg [N:0] fixed;
    always @(*) begin
        syn = {R{1'b0}};
        for (j = 0; j < R; j = j + 1)
            for (p = 1; p <= N; p = p + 1)
                if (((p >> j) & 1) != 0) syn[j] = syn[j] ^ code[p];
        ovr = ^code;

        fixed      = code;
        err_corr   = 1'b0;
        err_uncorr = 1'b0;
        if (ovr) begin
            if (syn <= NMAX) begin
                fixed[syn] = ~fixed[syn];
                err_corr   = 1'b1;
            end else begin
                err_uncorr = 1'b1;
            end
        end else if (syn != {R{1'b0}}) begin
            err_uncorr = 1'b1;
        end

        data = {DW{1'b0}};
        di   = 0;
        for (p = 1; p <= N; p = p + 1)
            if ((p & (p - 1)) != 0) begin
                data[di] = fixed[p];
                di = di + 1;
            end
    end
endmodule
