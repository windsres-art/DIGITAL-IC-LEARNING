package alu_pkg;
    // 固定的演示协议：两个 8 bit 操作数，9 bit 结果；所有端点共享同一类型。
    typedef enum logic [1:0] {OP_ADD=2'd0, OP_XOR=2'd1, OP_AND=2'd2, OP_BAD=2'd3} op_t;
    typedef struct packed {
        op_t op;
        logic [7:0] a;
        logic [7:0] b;
    } request_t;
    typedef struct packed {
        logic error;
        logic [8:0] result;
    } response_t;
endpackage
