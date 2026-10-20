// 教学故障注入网络；sites=0:a,1:b,2:c,3:p,4:q,5:dead,6:y。
// fault_enable=0 为无故障电路。故障 mux 不是生产 DFT 插入结构。
module fault_cone (
    input wire a,b,c,fault_enable,stuck_value,
    input wire [2:0] fault_site,
    output wire y
);
    function inject;
        input value;
        input [2:0] site;
        input enable_fault,stuck;
        input [2:0] selected;
        begin inject=(enable_fault && selected==site) ? stuck : value; end
    endfunction
    // 把控制信号显式作为函数输入，避免依赖隐藏的外部变量敏感性。
    wire fa=inject(a,3'd0,fault_enable,stuck_value,fault_site);
    wire fb=inject(b,3'd1,fault_enable,stuck_value,fault_site);
    wire fc=inject(c,3'd2,fault_enable,stuck_value,fault_site);
    wire p=inject(fa & fb,3'd3,fault_enable,stuck_value,fault_site);
    wire q=inject(~fa & fc,3'd4,fault_enable,stuck_value,fault_site);
    wire dead=inject(fa & ~fa,3'd5,fault_enable,stuck_value,fault_site);
    assign y=inject(p | q | dead,3'd6,fault_enable,stuck_value,fault_site);
endmodule
