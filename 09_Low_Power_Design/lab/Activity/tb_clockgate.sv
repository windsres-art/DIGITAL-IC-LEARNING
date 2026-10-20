`timescale 1ns/1ps
module tb_clockgate;
    reg clk=0,rst_n=0,en=0;
    reg [15:0] d=0;
    wire [15:0] q_ref,q_mapped;
    enable_bank ref_dut(.clk(clk),.rst_n(rst_n),.en(en),.d(d),.q(q_ref));
    enable_bank_gated mapped(.clk(clk),.rst_n(rst_n),.en(en),.d(d),.q(q_mapped));
    integer i,enabled=0;
    always #5 clk=~clk;
    initial begin
        $dumpfile("clockgate.vcd"); $dumpvars(0,tb_clockgate);
        #2; rst_n=1; #1; rst_n=0;
        @(negedge clk); rst_n=1;
        for(i=0;i<128;i=i+1) begin
            @(negedge clk); en=(i%16)<4; d=i*37;
            if(en) enabled=enabled+1;
            @(posedge clk); #1;
            if(q_ref!==q_mapped) $fatal(1,"FAIL clockgate equivalence");
        end
        // 门控关闭时异步复位仍必须起作用。
        @(negedge clk); en=0; #2; rst_n=0; #1;
        if(q_ref!==0 || q_mapped!==0) $fatal(1,"FAIL gated reset");
        $display("PASS clockgate mapped_equivalence cycles=128 enabled=%0d async_reset=1",enabled);
        $finish;
    end
    initial begin #5000; $fatal(1,"FAIL timeout"); end
endmodule
