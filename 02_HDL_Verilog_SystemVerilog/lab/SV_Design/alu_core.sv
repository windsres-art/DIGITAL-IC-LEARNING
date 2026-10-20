module alu_core (
    input logic clk, rst_n,
    input logic req_valid, rsp_ready,
    input alu_pkg::request_t req,
    output logic req_ready, rsp_valid,
    output alu_pkg::response_t rsp
);
    import alu_pkg::*;
    response_t calculated;
    always_comb begin
        calculated = '0;
        case (req.op)
            OP_ADD: calculated.result = {1'b0,req.a}+{1'b0,req.b};
            OP_XOR: calculated.result = {1'b0,(req.a ^ req.b)};
            OP_AND: calculated.result = {1'b0,(req.a & req.b)};
            default: calculated.error = 1'b1;
        endcase
    end
    // 单槽响应寄存器：空槽或旧响应本拍被取走时才能接收新请求。
    assign req_ready = !rsp_valid || rsp_ready;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_valid <= 1'b0;
            rsp <= '0;
        end else if (req_ready) begin
            rsp_valid <= req_valid;
            if (req_valid) rsp <= calculated;
        end
    end
endmodule
