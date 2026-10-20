`timescale 1ns/1ps
module tb_request_fsm;
    reg clk = 0, rst_n = 1, req = 0, finish = 0, ack = 0;
    wire accept, busy, valid;
    integer phase = 0, steps = 0, accepted = 0, responded = 0, retired = 0;
    integer holds = 0, k;
    request_fsm dut(.*);
    always #5 clk = ~clk;
    // 模型用事务阶段，不读取 DUT 的状态编码。
    task step(input r, input f, input a);
        begin
            @(negedge clk); req = r; finish = f; ack = a;
            @(posedge clk);
            case (phase)
                0: if (r) begin phase = 1; accepted++; end
                1: if (f) begin phase = 2; responded++; end
                2: if (a) begin phase = 0; retired++; end
                   else holds++;
            endcase
            #1;
            if ({accept,busy,valid} !==
                ((phase==0) ? 3'b100 : (phase==1) ? 3'b010 : 3'b001))
                $fatal(1, "FAIL FSM phase=%0d outputs=%b%b%b", phase, accept,busy,valid);
            steps++;
        end
    endtask
    initial begin
        $dumpfile("fsm.vcd"); $dumpvars(0, tb_request_fsm);
        #1 rst_n = 0; #1;
        if ({accept,busy,valid} !== 3'b100) $fatal(1,"FAIL reset");
        #1 rst_n = 1;
        // 提前 finish/ack、工作时 req、响应停顿时 req 都不能跳过状态。
        for (k=0; k<10; k++) begin
            step(0,1,1); step(1,1,1);
            step(1,0,1); step(1,1,1);
            step(1,0,0); step(0,1,0); step(1,1,1);
        end
        step(1,0,0);
        @(negedge clk); #1 rst_n=0; #1;
        if ({accept,busy,valid} !== 3'b100) $fatal(1,"FAIL abort reset");
        phase=0; req=0; finish=0; ack=0; rst_n=1;
        step(0,0,0);
        if (accepted!=11 || responded!=10 || retired!=10 || holds!=20)
            $fatal(1,"FAIL coverage");
        $display("PASS FSM steps=%0d accepted=%0d responded=%0d retired=%0d response_holds=%0d",
                 steps,accepted,responded,retired,holds);
        $finish;
    end
    initial begin #10000; $fatal(1,"FAIL timeout"); end
endmodule
