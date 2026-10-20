`timescale 1ns/1ps
module tb_activity;
    parameter W=8;
    reg clk=0,rst_n=0,valid=0;
    reg [W-1:0] a=0,b=0;
    wire [2*W-1:0] raw_product,isolated_product,q_raw,q_isolated;
    operand_isolation #(.W(W)) dut(.*);
    reg [31:0] rng=32'h719ac531;
    reg [2*W-1:0] prev_raw=0,prev_iso=0,expected=0;
    integer i,j,raw_toggles=0,iso_toggles=0,active=0;
    always #5 clk=~clk;
    initial begin
        $dumpfile("activity.vcd"); $dumpvars(0,tb_activity);
        #2; rst_n=1; #1; rst_n=0;
        @(negedge clk); rst_n=1;
        for(i=0;i<1024;i=i+1) begin
            @(negedge clk);
            valid=(i%64)<16;
            rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); a=rng;
            rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); b=rng;
            #1;
            for(j=0;j<2*W;j=j+1) begin
                if(raw_product[j]!==prev_raw[j]) raw_toggles=raw_toggles+1;
                if(isolated_product[j]!==prev_iso[j]) iso_toggles=iso_toggles+1;
            end
            prev_raw=raw_product; prev_iso=isolated_product;
            if(valid) begin expected=a*b; active=active+1; end
            @(posedge clk); #1;
            if(q_raw!==expected || q_isolated!==expected) $fatal(1,"FAIL functional equivalence");
        end
        if(iso_toggles>=raw_toggles || active!=256) $fatal(1,"FAIL activity scenario");
        $display("PASS activity W=%0d cycles=1024 active=%0d raw_bit_changes=%0d isolated_bit_changes=%0d",
                 W,active,raw_toggles,iso_toggles);
        $finish;
    end
    initial begin #20000; $fatal(1,"FAIL timeout"); end
endmodule
