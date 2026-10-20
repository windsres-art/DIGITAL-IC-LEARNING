`timescale 1ns/1ps
module tb_mul_comb;
    parameter W=8;
    reg [W-1:0] a,b;
    wire [2*W-1:0] unsigned_product,signed_product;
    reg [2*W-1:0] eu,es;
    reg [W-1:0] ra,rb,minimum,maximum,ones;
    reg [31:0] rng=32'h31415926;
    integer i,j,k,ai,bi,checks=0,code,covered=0;
    integer codes[0:7];
    mul_wallace #(.W(W)) uw(.a(a),.b(b),.product(unsigned_product));
    mul_booth #(.W(W)) sb(.a(a),.b(b),.product(signed_product));
    task random_word(output reg [W-1:0] value);
        begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            value=W'(rng);
        end
    endtask
    task check(input [W-1:0] x,y);
        begin
            a=x;b=y;
            ai=int'(x);bi=int'(y);
            eu=(2*W)'(ai*bi);
            if(x[W-1]) ai=ai-(1<<W);
            if(y[W-1]) bi=bi-(1<<W);
            es=(2*W)'(ai*bi);
            for(k=0;k<(W+1)/2;k++) begin
                code=((bi<<1) >>> (2*k)) & 7;
                codes[code]++;
            end
            #1;
            if(unsigned_product!==eu || signed_product!==es) begin
                $display("FAIL comb W=%0d a=%h b=%h unsigned=%h/%h signed=%h/%h",
                         W,a,b,unsigned_product,eu,signed_product,es);
                $fatal(1,"multiply mismatch");
            end
            checks++;
        end
    endtask
    initial begin
        $dumpfile("mul_comb.vcd");$dumpvars(0,tb_mul_comb);
        if(W<1 || W>12) $fatal(1,"FAIL TB range");
        for(i=0;i<8;i++) codes[i]=0;
        ones={W{1'b1}};minimum=1<<(W-1);maximum=minimum-1'b1;
        check(0,ones);check(ones,ones);check(minimum,minimum);
        check(minimum,ones);check(minimum,maximum);check(maximum,maximum);
        if(W<=4) for(i=0;i<(1<<W);i++) for(j=0;j<(1<<W);j++) check(W'(i),W'(j));
        for(i=0;i<1024;i++) begin random_word(ra);random_word(rb);check(ra,rb);end
        for(i=0;i<8;i++) if(codes[i]!=0) covered++;
        // 3 位的最高窗口包含重复符号位，最低窗口含常量 0，只有 6 种可达。
        if((W>=4 && covered!=8) || (W==3 && covered!=6) || (W==1 && covered!=2))
            $fatal(1,"FAIL Booth code coverage");
        check(minimum,minimum);
        $display("min_times_min W=%0d bits=%h signed_product=%h",W,minimum,signed_product);
        $display("PASS comb W=%0d vectors=%0d booth_codes=%0d",W,checks,covered);
        $finish;
    end
    initial begin #100000; $fatal(1,"FAIL timeout");end
endmodule
