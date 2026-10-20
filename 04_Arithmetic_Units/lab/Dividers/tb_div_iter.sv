`timescale 1ns/1ps
module tb_div_iter;
    parameter W=8;
    localparam integer N=1<<W;
    reg clk=0, rst_n=0, req_valid=0, rsp_ready=0, signed_mode=0;
    reg [W-1:0] a=0,b=0;
    wire [1:0] ready, valid, busy, dz, ov;
    wire [W-1:0] q[0:1], r[0:1];
    genvar g;
    generate for(g=0;g<2;g=g+1) begin: impl
        div_iter #(.W(W),.NONRESTORE(g)) dut(
            .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(ready[g]),
            .signed_mode(signed_mode),.a(a),.b(b),.busy(busy[g]),
            .rsp_valid(valid[g]),.rsp_ready(rsp_ready),.quotient(q[g]),
            .remainder(r[g]),.div_zero(dz[g]),.overflow(ov[g]));
    end endgenerate
    always #5 clk=~clk;
    integer transactions=0, holds=0, corrections=0, cycles=0;
    integer x,y,m,i,j,k, previous_accept=-1;
    reg [31:0] rng=32'h9173ac42;
    always @(posedge clk) cycles=cycles+1;
    task random_word;
        begin rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); end
    endtask
    task run_case(input integer aa,bb,mode,stall,stream);
        integer av,bv,eq,er,t,c,pr,pn,d;
        reg ez,eo;
        begin
            av=aa; bv=bb;
            if(mode && aa>=N/2) av=aa-N;
            if(mode && bb>=N/2) bv=bb-N;
            ez=(bb==0); eo=mode && aa==N/2 && bb==N-1;
            if(ez) begin eq=N-1; er=aa; end
            else if(eo) begin eq=N/2; er=0; end
            else begin eq=av/bv; er=av%bv; end
            d=(bv<0)?-bv:bv;
            @(negedge clk);
            if(ready!==2'b11) $fatal(1,"FAIL ready");
            a=aa; b=bb; signed_mode=mode; req_valid=1; rsp_ready=0;
            @(posedge clk); #1;
            if(stream && previous_accept>=0 && cycles-previous_accept!=W+2)
                $fatal(1,"FAIL initiation interval");
            previous_accept=cycles;
            if(busy!==3 || valid!==0) $fatal(1,"FAIL acceptance");
            @(negedge clk); req_valid=0;
            // valid=0 时改变总线，验证实现确实锁存了输入。
            a=~aa; b=~bb; signed_mode=!mode;
            for(t=1;t<=W;t=t+1) begin
                @(posedge clk); #1;
                if(valid !== ((t==W)?2'b11:2'b00)) $fatal(1,"FAIL latency");
                if(ready!==0) $fatal(1,"FAIL busy/response ready");
                pr=$signed(impl[0].dut.partial);
                pn=$signed(impl[1].dut.partial);
                if(!ez && (pr<0 || pr>=d || pn < -d || pn>=d))
                    $fatal(1,"FAIL partial invariant");
                if(W==4 && aa==13 && bb==3 && mode==0)
                    $display("TRACE step=%0d restoring_R=%0d nonrestoring_R=%0d Q=%0d",
                             t,pr,pn,impl[1].dut.q_work);
            end
            if(!ez && impl[1].dut.partial[W+1]) corrections=corrections+1;
            for(c=0;c<2;c=c+1) begin
                if(q[c] !== (eq & (N-1)) || r[c] !== (er & (N-1)) ||
                   dz[c]!==ez || ov[c]!==eo)
                    $fatal(1,"FAIL division mismatch W=%0d alg=%0d a=%0d b=%0d mode=%0d q=%0d r=%0d expected=%0d,%0d",
                           W,c,aa,bb,mode,q[c],r[c],eq,er);
            end
            for(t=0;t<stall;t=t+1) begin
                @(posedge clk); #1;
                for(c=0;c<2;c=c+1)
                    if(valid[c]!==1 || q[c] !== (eq & (N-1)) ||
                       r[c] !== (er & (N-1)) || dz[c]!==ez || ov[c]!==eo)
                        $fatal(1,"FAIL response hold");
                holds=holds+1;
            end
            @(negedge clk); rsp_ready=1;
            @(posedge clk); #1;
            if(valid!==0 || ready!==3) $fatal(1,"FAIL retirement");
            transactions=transactions+1;
        end
    endtask
    task abort_case(input integer completed);
        begin
            @(negedge clk); a=N-1; b=1; signed_mode=0; req_valid=1; rsp_ready=0;
            @(posedge clk); #1;
            @(negedge clk); req_valid=0;
            if(completed) repeat(W) begin @(posedge clk); #1; end
            #2; rst_n=0; #1;
            if(valid!==0 || busy!==0 || ready!==0) $fatal(1,"FAIL async reset");
            @(negedge clk); rst_n=1;
            repeat(W+2) begin
                @(posedge clk); #1;
                if(valid!==0 || busy!==0) $fatal(1,"FAIL ghost response");
            end
        end
    endtask
    initial begin
        $dumpfile("dividers.vcd"); $dumpvars(0,tb_div_iter);
        #2; rst_n=1; #1; rst_n=0;
        @(negedge clk); rst_n=1;
        for(m=0;m<2;m=m+1) begin
            if(W<=4)
                for(x=0;x<N;x=x+1) for(y=0;y<N;y=y+1) run_case(x,y,m,2,0);
            else begin
                // 0、1、最大正数、最小负数、全 1 的笛卡尔积。
                for(i=0;i<5;i=i+1) for(j=0;j<5;j=j+1) begin
                    case(i) 0:x=0; 1:x=1; 2:x=N/2-1; 3:x=N/2; default:x=N-1; endcase
                    case(j) 0:y=0; 1:y=1; 2:y=N/2-1; 3:y=N/2; default:y=N-1; endcase
                    run_case(x,y,m,2,0);
                end
                for(k=0;k<512;k=k+1) begin
                    random_word(); x=rng & (N-1);
                    random_word(); y=rng & (N-1);
                    run_case(x,y,m,2,0);
                end
            end
        end
        abort_case(0); abort_case(1);
        previous_accept=-1;
        for(k=0;k<8;k=k+1) run_case(N-1,1,0,0,1);
        $display("PASS dividers W=%0d transactions=%0d algorithms=2 latency=%0d hold_cycles=%0d corrections=%0d reset_aborts=2 interval=%0d",
                 W,transactions,W,holds,corrections,W+2);
        $finish;
    end
    initial begin #10000000; $fatal(1,"FAIL timeout"); end
endmodule
