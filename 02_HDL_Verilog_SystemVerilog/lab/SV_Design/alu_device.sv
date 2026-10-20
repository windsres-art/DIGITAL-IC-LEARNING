module alu_device (
    input logic clk, rst_n,
    alu_link.device link
);
    // interface 只打包连接；运算与存储仍由 core 的 RTL 明确定义。
    alu_core core(
        .clk(clk), .rst_n(rst_n),
        .req_valid(link.req_valid), .req_ready(link.req_ready), .req(link.req),
        .rsp_valid(link.rsp_valid), .rsp_ready(link.rsp_ready), .rsp(link.rsp)
    );
endmodule
