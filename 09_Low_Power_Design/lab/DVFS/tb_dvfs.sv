`timescale 1ns/1ps
module tb_dvfs;
    reg clk=0,rst_n=0,req_valid=0,target_high=0;
    wire req_ready,voltage_req_high,frequency_req_high,current_high,done,busy;
    reg voltage_high=0,frequency_high=0;
    wire voltage_settled,frequency_settled;
    integer vcount=0,fcount=0,vdelay=3,fdelay=2;
    integer transactions=0,checks=0,i;
    dvfs_seq dut(.*);
    always #5 clk=~clk;
    assign voltage_settled=(voltage_high==voltage_req_high);
    assign frequency_settled=(frequency_high==frequency_req_high);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin voltage_high<=0; frequency_high<=0; vcount<=0; fcount<=0; end
        else begin
            if(voltage_settled) vcount<=0;
            else if(vcount==vdelay) begin voltage_high<=voltage_req_high; vcount<=0; end
            else vcount<=vcount+1;
            if(frequency_settled) fcount<=0;
            else if(fcount==fdelay) begin frequency_high<=frequency_req_high; fcount<=0; end
            else fcount<=fcount+1;
        end
    end
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            checks=checks+1;
            if(frequency_high && !voltage_high) $fatal(1,"FAIL unsafe physical OPP");
            if(frequency_req_high && (!voltage_high || !voltage_settled))
                $fatal(1,"FAIL raise frequency before voltage");
            if(!voltage_req_high && frequency_high) $fatal(1,"FAIL lower voltage before frequency");
            if(done && (voltage_high!==current_high || frequency_high!==current_high))
                $fatal(1,"FAIL done before settled");
        end
    end
    task request(input integer high);
        integer timeout;
        begin
            @(negedge clk);
            if(!req_ready) $fatal(1,"FAIL not ready");
            req_valid=1; target_high=high;
            @(posedge clk); #1;
            @(negedge clk); req_valid=0; target_high=!high;
            timeout=0;
            while(!done && timeout<100) begin @(negedge clk); timeout=timeout+1; end
            if(!done || current_high!==high[0] || busy!==0) $fatal(1,"FAIL request completion");
            transactions=transactions+1;
        end
    endtask
    initial begin
        $dumpfile("dvfs.vcd"); $dumpvars(0,tb_dvfs);
        #2; rst_n=1; #1; rst_n=0;
        @(negedge clk); rst_n=1;
        request(0);
        for(i=1;i<=8;i=i+1) begin
            vdelay=i; fdelay=9-i;
            request(1); request(1); request(0); request(0);
        end
        $display("PASS DVFS transactions=%0d safety_checks=%0d up=8 down=8 same_opp=17",transactions,checks);
        $finish;
    end
    initial begin #20000; $fatal(1,"FAIL global timeout"); end
endmodule
