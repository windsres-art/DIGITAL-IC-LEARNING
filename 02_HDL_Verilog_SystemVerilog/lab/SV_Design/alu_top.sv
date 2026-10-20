module alu_top (
    input logic clk, rst_n, req_valid, rsp_ready,
    input alu_pkg::request_t req,
    output logic req_ready, rsp_valid,
    output alu_pkg::response_t rsp
);
    // 顶层以普通端口连接环境，内部用 interface 连接设备，便于完整 lint。
    alu_link link();
    assign link.req_valid=req_valid;
    assign link.req=req;
    assign link.rsp_ready=rsp_ready;
    assign req_ready=link.req_ready;
    assign rsp_valid=link.rsp_valid;
    assign rsp=link.rsp;
    alu_device device(.clk(clk),.rst_n(rst_n),.link(link));
endmodule
