// =============================================================================
// 奇偶校验：生成 + 检查（组合逻辑）
//   偶校验 ODD = 0：par 让 {data, par} 中 1 的个数为偶数，par = ^data
//   奇校验 ODD = 1：1 的个数为奇数，par = ~^data
//   检查：err = ^{data, par_in} ^ ODD。能查出所有奇数个 bit 的错误，
//   偶数个 bit 同时出错查不出来，也不知道错在哪一位，不能纠错
// =============================================================================
module parity #(
    parameter DW  = 8,
    parameter ODD = 0
)(
    input  [DW-1:0] data,
    input           par_in,
    output          par,
    output          err
);
    wire odd = (ODD != 0);
    assign par = (^data) ^ odd;
    assign err = (^{data, par_in}) ^ odd;
endmodule
