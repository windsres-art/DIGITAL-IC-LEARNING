`timescale 1ns/1ps
module tb_adders;
    parameter W=8,B=4;
    reg [W-1:0] a,b,d;
    reg cin;
    wire [W:0] rca,cla,cselect,prefix;
    wire [W-1:0] saved_sum;
    wire [W:0] saved_carry;
    wire [W+1:0] total;
    reg [W:0] expected;
    reg [W+1:0] expected3,recombined;
    reg [W-1:0] ra,rb,rd,ones,mask;
    reg [31:0] rng=32'h13579bdf;
    integer i,j,k,h,n,checks=0,exhaustive2=0,exhaustive3=0;
    adder_rca #(.W(W)) u_rca(.a(a),.b(b),.cin(cin),.sum(rca[W-1:0]),.cout(rca[W]));
    adder_cla #(.W(W),.B(B)) u_cla(.a(a),.b(b),.cin(cin),.sum(cla[W-1:0]),.cout(cla[W]));
    adder_cselect #(.W(W),.B(B)) u_select(.a(a),.b(b),.cin(cin),.sum(cselect[W-1:0]),.cout(cselect[W]));
    adder_prefix #(.W(W)) u_prefix(.a(a),.b(b),.cin(cin),.sum(prefix[W-1:0]),.cout(prefix[W]));
    csa3 #(.W(W)) u_csa(.a(a),.b(b),.d(d),.saved_sum(saved_sum),.saved_carry(saved_carry));
    adder_three #(.W(W)) u_total(.a(a),.b(b),.d(d),.total(total));
    // 自己维护固定种子，结果不依赖不同仿真器的随机数实现。
    task random_word(output reg [W-1:0] value);
        integer t;
        begin
            for(t=0;t<W;t=t+1) begin
                rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
                value[t]=rng[0];
            end
        end
    endtask
    task check(input [W-1:0] aa,bb,dd,input ci);
        begin
            a=aa;b=bb;d=dd;cin=ci;
            expected={1'b0,aa}+{1'b0,bb}+{{W{1'b0}},ci};
            expected3={2'b00,aa}+{2'b00,bb}+{2'b00,dd};
            #1;
            recombined={2'b00,saved_sum}+{1'b0,saved_carry};
            if(rca!==expected || cla!==expected || cselect!==expected ||
               prefix!==expected || total!==expected3 || recombined!==expected3) begin
                $display("FAIL W=%0d B=%0d a=%h b=%h d=%h cin=%b expected=%h rca=%h cla=%h select=%h prefix=%h total=%h expected3=%h",
                         W,B,a,b,d,cin,expected,rca,cla,cselect,prefix,total,expected3);
                $fatal(1,"arithmetic mismatch");
            end
            checks++;
        end
    endtask
    initial begin
        $dumpfile("adders.vcd");$dumpvars(0,tb_adders);
        if(W<1 || W>64 || B<1) $fatal(1,"FAIL invalid TB parameters");
        ones={W{1'b1}};
        check(0,0,0,0); check(ones,0,0,1);
        check(ones,ones,ones,1);
        // 每一种传播长度都测，包含跨组边界与最高位 carry。
        mask=0;
        for(i=0;i<W;i++) begin
            mask[i]=1;
            check(mask,0,ones,1);
            check(mask,{{(W-1){1'b0}},1'b1},0,0);
            check(~mask,mask,mask,1);
        end
        if(W<=5) begin
            n=1<<W;
            for(i=0;i<n;i++) for(j=0;j<n;j++) for(h=0;h<2;h++) begin
                check(W'(i),W'(j),0,1'(h)); exhaustive2++;
            end
        end
        if(W<=3) begin
            n=1<<W;
            for(i=0;i<n;i++) for(j=0;j<n;j++) for(k=0;k<n;k++) begin
                check(W'(i),W'(j),W'(k),0); exhaustive3++;
            end
        end
        for(i=0;i<2048;i++) begin
            random_word(ra);random_word(rb);random_word(rd);
            check(ra,rb,rd,rng[7]);
        end
        check(ones,ones,ones,0);
        $display("max3 W=%0d saved_sum=%h saved_carry=%h total=%h",W,saved_sum,saved_carry,total);
        $display("PASS adders W=%0d B=%0d vectors=%0d exhaustive2=%0d exhaustive3=%0d",
                 W,B,checks,exhaustive2,exhaustive3);
        $finish;
    end
    initial begin #100000; $fatal(1,"FAIL timeout"); end
endmodule
