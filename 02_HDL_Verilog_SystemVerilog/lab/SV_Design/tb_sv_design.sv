`timescale 1ns/1ps
module tb_sv_design;
    import alu_pkg::*;
    logic clk=0, rst_n=1;
    alu_link link();
    alu_top dut(.clk(clk),.rst_n(rst_n),
        .req_valid(link.req_valid),.req_ready(link.req_ready),.req(link.req),
        .rsp_valid(link.rsp_valid),.rsp_ready(link.rsp_ready),.rsp(link.rsp));
    bit full=0;
    response_t expected='0;
    integer k, sends=0, receives=0, stalls=0, simultaneous=0;
    integer counts[4]='{default:0};
    bit take_in, take_out;
    always #5 clk=~clk;
    task check_output;
        if (link.rsp_valid !== full || link.req_ready !== (!full || link.rsp_ready))
            $fatal(1,"FAIL handshake cycle=%0d",k);
        else if (full && link.rsp !== expected)
            $fatal(1,"FAIL data cycle=%0d got=%h expected=%h",k,link.rsp,expected);
    endtask
    initial begin
        $dumpfile("sv_design.vcd"); $dumpvars(0,tb_sv_design);
        link.req_valid=0; link.rsp_ready=0; link.req='0;
        #1 rst_n=0; #1; check_output();
        #1 rst_n=1;
        // 只在旧请求被接受后换内容；反压期间请求也必须保持。
        for(k=0;k<120;k++) begin
            @(negedge clk);
            link.rsp_ready=(k>=115 || k%5>=2);
            if (!link.req_valid || take_in) begin
                link.req_valid=(k<115 && k%7!=0);
                link.req.op=op_t'(k%4);
                link.req.a=8'(k*17+250);
                link.req.b=8'(k*31+9);
            end
            #1; check_output();
            @(posedge clk);
            take_in=link.req_valid && (!full || link.rsp_ready);
            take_out=full && link.rsp_ready;
            if (take_out) receives++;
            if (full && !link.rsp_ready) stalls++;
            if (take_out && take_in) simultaneous++;
            if (take_in) begin
                sends++; counts[int'(link.req.op)]++;
                expected='0;
                // 用整数算术/逐位运算建模，不调用设计函数。
                case (int'(link.req.op))
                    0: expected.result=9'(int'(link.req.a)+int'(link.req.b));
                    1: expected.result=9'(link.req.a ^ link.req.b);
                    2: expected.result=9'(link.req.a & link.req.b);
                    3: expected.error=1;
                endcase
            end
            if (take_in || take_out) full=take_in;
            #1; check_output();
        end
        // 最后五周期停止发新请求并排空，不能撤回被反压的有效请求。
        if(link.req_valid) $fatal(1,"FAIL pending source request");
        @(negedge clk); link.req_valid=0; link.rsp_ready=1;
        @(posedge clk); if(full) receives++; full=0;
        #1; check_output();
        if(sends!=receives || stalls==0 || simultaneous==0) $fatal(1,"FAIL coverage/conservation");
        foreach(counts[i]) if(counts[i]==0) $fatal(1,"FAIL opcode uncovered");
        $display("PASS SV sends=%0d receives=%0d stalls=%0d replacements=%0d ops=%0d,%0d,%0d,%0d",
                 sends,receives,stalls,simultaneous,counts[0],counts[1],counts[2],counts[3]);
        $finish;
    end
    initial begin #10000; $fatal(1,"FAIL timeout"); end
endmodule
