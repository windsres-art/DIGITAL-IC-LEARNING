interface alu_link;
    import alu_pkg::*;
    logic req_valid, req_ready, rsp_valid, rsp_ready;
    request_t req;
    response_t rsp;
    // 方向从连接到该 modport 的模块看；不能把方向理解成 interface 自身的方向。
    modport device(input req_valid, req, rsp_ready,
                   output req_ready, rsp_valid, rsp);
    modport host(output req_valid, req, rsp_ready,
                 input req_ready, rsp_valid, rsp);
endinterface
