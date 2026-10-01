// =============================================================================
// PLIC（Platform-Level Interrupt Controller）：NSRC 个外部中断源 → 一个 hart 的机器模式上下文
//   寄存器（与 RISC-V PLIC 规范相同的偏移，只实现上下文 0）：
//     0x000000 + 4*i  priority[i]   0 = 永不触发，越大越优先（源 0 保留）
//     0x001000        pending       bit i = 源 i 待处理（只读）
//     0x002000        enable        bit i = 允许源 i
//     0x200000        threshold     只有 priority > threshold 的源才能打断 hart
//     0x200004        claim / complete
//                     读 = claim：返回优先级最高的待处理且允许的源号（同优先级取小号），
//                          同时清掉它的 pending；没有则返回 0
//                     写 = complete：写入源号，表示服务完毕
//   网关（gateway）按电平触发处理：源为高、且不在服务中（claim 之后、complete 之前）时置 pending。
//   服务期间源保持为高也不会重复置位；complete 之后若源仍为高，会再次置 pending。
//   irq = 存在 pending & enable & priority > threshold 的源
//   寄存器口：req 为 1 的那一拍完成一次访问（读数据组合输出，claim 的副作用也在这一拍）
// =============================================================================
module plic #(
    parameter NSRC   = 8,                       // 含保留的源 0
    parameter PRIO_W = 3
)(
    input             clk,
    input             rst_n,
    input             req,
    input             we,
    input      [21:0] addr,
    input      [31:0] wdata,
    output reg [31:0] rdata,
    input  [NSRC-1:0] src,
    output            irq
);
    localparam IDW = $clog2(NSRC);

    reg [PRIO_W-1:0] prio [0:NSRC-1];
    reg [NSRC-1:0]   pending, enable, inflight;
    reg [PRIO_W-1:0] threshold;

    // 仲裁：优先级最高的、待处理且允许的源；倒序扫描，同优先级时小号覆盖大号
    reg [IDW-1:0]    best_id;
    reg [PRIO_W-1:0] best_p;
    integer i;
    always @* begin
        best_id = {IDW{1'b0}};
        best_p  = {PRIO_W{1'b0}};
        for (i = NSRC - 1; i >= 1; i = i - 1)
            if (pending[i] && enable[i] && prio[i] != {PRIO_W{1'b0}} && prio[i] >= best_p) begin
                best_id = i[IDW-1:0];
                best_p  = prio[i];
            end
    end
    assign irq = (best_id != {IDW{1'b0}}) && (best_p > threshold);

    wire is_claim = (addr == 22'h200004);
    wire claim    = req && !we && is_claim && best_id != {IDW{1'b0}};
    wire complete = req && we && is_claim;
    wire [IDW-1:0] cid = wdata[IDW-1:0];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending   <= {NSRC{1'b0}};
            enable    <= {NSRC{1'b0}};
            inflight  <= {NSRC{1'b0}};
            threshold <= {PRIO_W{1'b0}};
            for (k = 0; k < NSRC; k = k + 1) prio[k] <= {PRIO_W{1'b0}};
        end else begin
            for (k = 1; k < NSRC; k = k + 1)
                if (src[k] && !inflight[k]) pending[k] <= 1'b1;
            if (claim) begin
                pending[best_id]  <= 1'b0;
                inflight[best_id] <= 1'b1;
            end
            if (complete && wdata[31:IDW] == {(32-IDW){1'b0}}) inflight[cid] <= 1'b0;
            if (req && we) begin
                if (addr[21:12] == 10'd0 && addr[11:2] < NSRC && addr[11:2] != 10'd0)
                    prio[addr[IDW+1:2]] <= wdata[PRIO_W-1:0];
                if (addr == 22'h002000) enable <= wdata[NSRC-1:0] & ~{{(NSRC-1){1'b0}}, 1'b1};
                if (addr == 22'h200000) threshold <= wdata[PRIO_W-1:0];
            end
        end
    end

    always @* begin
        rdata = 32'd0;
        if (addr[21:12] == 10'd0 && addr[11:2] < NSRC) rdata = {{(32-PRIO_W){1'b0}}, prio[addr[IDW+1:2]]};
        else if (addr == 22'h001000)                   rdata = {{(32-NSRC){1'b0}}, pending};
        else if (addr == 22'h002000)                   rdata = {{(32-NSRC){1'b0}}, enable};
        else if (addr == 22'h200000)                   rdata = {{(32-PRIO_W){1'b0}}, threshold};
        else if (is_claim)                             rdata = {{(32-IDW){1'b0}}, best_id};
    end

    wire unused_ok = &{1'b0, src[0]};
endmodule
