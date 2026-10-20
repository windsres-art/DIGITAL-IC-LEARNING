`timescale 1ns/1ps
module tb_fp32;
    reg [31:0] bits;
    wire sign;
    wire [5:0] kind;
    fp32_classify dut(.*);
    integer fd,status,expected,count=0;
    reg [31:0] word;
    initial begin
        $dumpfile("fp32.vcd"); $dumpvars(0,tb_fp32);
        fd=$fopen("fp32.txt","r");
        if(!fd) $fatal(1,"FAIL missing vectors");
        status=$fscanf(fd,"%h %d\n",word,expected);
        while(status==2) begin
            bits=word; #1;
            if(kind!==expected[5:0] || sign!==word[31])
                $fatal(1,"FAIL classification bits=%h got=%0d expected=%0d",word,kind,expected);
            count=count+1;
            status=$fscanf(fd,"%h %d\n",word,expected);
        end
        if(!$feof(fd) || count==0) $fatal(1,"FAIL malformed vectors");
        $display("PASS fp32 classification vectors=%0d",count);
        $finish;
    end
    initial begin #1000000; $fatal(1,"FAIL timeout"); end
endmodule
