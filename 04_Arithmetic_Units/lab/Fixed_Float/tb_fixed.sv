`timescale 1ns/1ps
module tb_fixed;
    parameter IW=8, OW=4, IF=4, OF=2;
    reg signed [IW-1:0] x;
    reg [1:0] mode;
    wire signed [OW-1:0] y;
    wire overflow,inexact;
    fixed_quantize #(.IW(IW),.OW(OW),.IF(IF),.OF(OF)) dut(.*);
    integer fd,status,xx,mm,yy,oo,ii,count=0;
    initial begin
        $dumpfile("fixed.vcd"); $dumpvars(0,tb_fixed);
        fd=$fopen("fixed.txt","r");
        if(!fd) $fatal(1,"FAIL missing vectors");
        status=$fscanf(fd,"%d %d %d %d %d\n",xx,mm,yy,oo,ii);
        while(status==5) begin
            x=xx; mode=mm; #1;
            if($signed(y)!==yy || overflow!==oo[0] || inexact!==ii[0])
                $fatal(1,"FAIL quantize x=%0d mode=%0d got=%0d,%0d,%0d expected=%0d,%0d,%0d",
                       xx,mm,y,overflow,inexact,yy,oo,ii);
            count=count+1;
            status=$fscanf(fd,"%d %d %d %d %d\n",xx,mm,yy,oo,ii);
        end
        if(!$feof(fd) || count==0) $fatal(1,"FAIL malformed vectors");
        $fclose(fd);
        $display("PASS fixed IW=%0d OW=%0d IF=%0d OF=%0d vectors=%0d",IW,OW,IF,OF,count);
        $finish;
    end
    initial begin #1000000; $fatal(1,"FAIL timeout"); end
endmodule
