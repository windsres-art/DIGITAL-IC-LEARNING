`timescale 1ns/1ps
module tb_fault;
    reg a,b,c,fault_enable,stuck_value;
    reg [2:0] fault_site;
    wire y;
    fault_cone dut(.*);
    integer fd,status,aa,bb,cc,en,site,stuck,expected,count=0;
    initial begin
        $dumpfile("fault.vcd"); $dumpvars(0,tb_fault);
        fd=$fopen("vectors.txt","r");
        if(!fd) $fatal(1,"FAIL missing vectors");
        status=$fscanf(fd,"%d %d %d %d %d %d %d\n",aa,bb,cc,en,site,stuck,expected);
        while(status==7) begin
            a=aa; b=bb; c=cc; fault_enable=en; fault_site=site; stuck_value=stuck; #1;
            if(y!==expected[0]) $fatal(1,"FAIL fault oracle");
            count=count+1;
            status=$fscanf(fd,"%d %d %d %d %d %d %d\n",aa,bb,cc,en,site,stuck,expected);
        end
        if(!$feof(fd) || count!=120) $fatal(1,"FAIL vector count");
        $display("PASS fault RTL oracle vectors=%0d",count); $finish;
    end
    initial begin #10000; $fatal(1,"FAIL timeout"); end
endmodule
