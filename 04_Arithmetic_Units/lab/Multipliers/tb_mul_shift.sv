`timescale 1ns/1ps
module tb_mul_shift;
    parameter W=8;
    reg clk=0,rst_n=1,req_valid=0,signed_mode=0,rsp_ready=0;
    reg [W-1:0] a=0,b=0;
    wire req_ready,busy,rsp_valid;
    wire [2*W-1:0] product;
    reg [2*W-1:0] expected;
    reg [W-1:0] ra,rb,minimum,ones;
    reg [31:0] rng=32'h1234abcd;
    integer i,j,mode,cycle,ai,bi,transactions=0,holds=0;
    integer sent=0,received=0,stream_cycle=0,previous_accept=0;
    mul_shift #(.W(W)) dut(.*);
    always #5 clk=~clk;
    task random_word(output reg [W-1:0] value);
        begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            value=W'(rng);
        end
    endtask
    task transact(input [W-1:0] x,y,input sm);
        begin
            ai=int'(x);bi=int'(y);
            if(sm && x[W-1]) ai=ai-(1<<W);
            if(sm && y[W-1]) bi=bi-(1<<W);
            expected=(2*W)'(ai*bi);
            @(negedge clk);a=x;b=y;signed_mode=sm;req_valid=1;rsp_ready=0;
            #1;if(req_ready!==1) $fatal(1,"FAIL not ready");
            @(posedge clk);#1;
            if(!busy || rsp_valid || req_ready) $fatal(1,"FAIL acceptance");
            // busy 期间不断请求，并改写端口；已接收的操作数/符号不得被污染。
            for(cycle=1;cycle<=W;cycle++) begin
                @(negedge clk);a=~x;b=~y;signed_mode=~sm;
                @(posedge clk);#1;
                if(cycle<W) begin
                    if(!busy || rsp_valid || req_ready) $fatal(1,"FAIL early result");
                end else if(busy || !rsp_valid || req_ready || product!==expected) begin
                    $display("FAIL iterative W=%0d a=%h b=%h signed=%b got=%h expected=%h",
                             W,x,y,sm,product,expected);
                    $fatal(1,"multiply mismatch");
                end
            end
            repeat(3) begin
                @(posedge clk);#1;
                if(!rsp_valid || busy || req_ready || product!==expected) $fatal(1,"FAIL response hold");
                holds++;
            end
            @(negedge clk);rsp_ready=1;
            @(posedge clk);#1;
            if(rsp_valid || busy || !req_ready) $fatal(1,"FAIL response retirement");
            @(negedge clk);req_valid=0;rsp_ready=0;
            transactions++;
        end
    endtask
    initial begin
        $dumpfile("mul_shift.vcd");$dumpvars(0,tb_mul_shift);
        if(W<1 || W>12) $fatal(1,"FAIL TB range");
        #1 rst_n=0;#1;
        if(busy || rsp_valid || !req_ready || product!==0) $fatal(1,"FAIL reset");
        #1 rst_n=1;
        ones={W{1'b1}};minimum=1<<(W-1);
        for(mode=0;mode<2;mode++) begin
            transact(0,ones,1'(mode));
            transact(ones,ones,1'(mode));
            transact(minimum,minimum,1'(mode));
            transact(minimum,ones,1'(mode));
            if(W<=4)
                for(i=0;i<(1<<W);i++) for(j=0;j<(1<<W);j++) transact(W'(i),W'(j),1'(mode));
            for(i=0;i<64;i++) begin random_word(ra);random_word(rb);transact(ra,rb,1'(mode));end
        end
        // 再发一笔后在第一个计算沿之前复位，检查不会留下迟到响应。
        @(negedge clk);a=ones;b=ones;req_valid=1;
        @(posedge clk);#1;
        if(!busy) $fatal(1,"FAIL abort setup");
        @(negedge clk);#1 rst_n=0;req_valid=0;
        #1;if(busy || rsp_valid || !req_ready || product!==0) $fatal(1,"FAIL abort reset");
        #1 rst_n=1;
        repeat(W+2) begin @(posedge clk);#1;if(busy || rsp_valid) $fatal(1,"FAIL ghost response");end
        transact(minimum,ones,1);
        // 连续请求、下游始终 ready，实测最小接收间隔；沿前读握手，下降沿撤请求。
        @(negedge clk);a=W'(1);b=W'(1);signed_mode=0;req_valid=1;rsp_ready=1;
        while(received<8) begin
            @(posedge clk);
            if(req_valid && req_ready) begin
                if(sent>0 && stream_cycle-previous_accept!=W+2) $fatal(1,"FAIL initiation interval");
                previous_accept=stream_cycle;sent++;
            end
            if(rsp_valid && rsp_ready) begin
                if(product!==(2*W)'(1)) $fatal(1,"FAIL streaming result");
                received++;
            end
            stream_cycle++;
            #1;
            @(negedge clk);if(sent==8) req_valid=0;
        end
        if(sent!=8) $fatal(1,"FAIL streaming conservation");
        $display("PASS iterative W=%0d transactions=%0d latency=%0d hold_checks=%0d reset_aborts=1 stream=8 interval=%0d",
                 W,transactions+received,W,holds,W+2);
        $finish;
    end
    initial begin #2000000;$fatal(1,"FAIL timeout");end
endmodule
