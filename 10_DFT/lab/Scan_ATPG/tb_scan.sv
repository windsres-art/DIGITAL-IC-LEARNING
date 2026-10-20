`timescale 1ns/1ps
module tb_scan;
    parameter W=4;
    reg clk=0,rst_n=0,scan_en=0,scan_in=0;
    reg [W-1:0] functional_d=0;
    wire [W-1:0] q;
    wire scan_out;
    scan_bank #(.W(W)) dut(.*);
    integer p,i,checks=0;
    reg [W-1:0] loaded,response,expected;
    always #5 clk=~clk;
    initial begin
        $dumpfile("scan.vcd"); $dumpvars(0,tb_scan);
        #2; rst_n=1; #1; rst_n=0; @(negedge clk); rst_n=1;
        for(p=0;p<32;p=p+1) begin
            loaded=p*13+7;
            for(i=W-1;i>=0;i=i-1) begin
                @(negedge clk); scan_en=1; scan_in=loaded[i];
                @(posedge clk); #1;
            end
            if(q!==loaded) $fatal(1,"FAIL scan load");
            @(negedge clk); scan_en=0; functional_d=~loaded;
            expected=~loaded;
            @(posedge clk); #1;
            if(q!==expected) $fatal(1,"FAIL capture");
            response=0;
            for(i=W-1;i>=0;i=i-1) begin
                @(negedge clk); scan_en=1; scan_in=0;
                response[i]=scan_out;
                @(posedge clk); #1;
            end
            if(response!==expected || q!==0) $fatal(1,"FAIL scan unload");
            checks=checks+1;
        end
        @(negedge clk); rst_n=0; #1;
        if(q!==0) $fatal(1,"FAIL scan reset");
        $display("PASS scan W=%0d load_capture_unload=%0d",W,checks); $finish;
    end
    initial begin #20000; $fatal(1,"FAIL timeout"); end
endmodule
