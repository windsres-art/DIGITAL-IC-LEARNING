`timescale 1ns/1ps
module tb_power_seq;
    reg clk=0,rst_n=0,sleep_req=1;
    wire idle_ack,save_ack,power_good,restore_ack,init_done;
    wire quiesce,save_req,restore_req,iso_en,clk_en,power_en,active;
    wire [3:0] state_out;
    power_seq dut(.*);
    integer delay_cycles=2,idle_count=0,save_count=0,power_count=0,restore_count=0,init_count=0;
    reg [15:0] shadow=0,domain_q=0,expected=0;
    wire [15:0] observed=iso_en ? 16'b0 : domain_q;
    integer round_idx,checks=0,saves=0,restores=0;
    reg previous_power=0;
    always #5 clk=~clk;
    assign idle_ack=idle_count>=delay_cycles;
    assign save_ack=save_count>=delay_cycles;
    assign power_good=power_en && power_count>=delay_cycles;
    assign restore_ack=restore_count>=delay_cycles;
    assign init_done=init_count>=delay_cycles;
    // 延迟应答模型；所有计数器在常供电域中运行。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            idle_count<=0; save_count<=0; power_count<=0; restore_count<=0; init_count<=0;
            shadow<=0; expected<=0; saves<=0; restores<=0;
        end else begin
            idle_count<=(state_out==5) ? idle_count+1 : 0;
            save_count<=save_req ? save_count+1 : 0;
            power_count<=power_en ? power_count+1 : 0;
            restore_count<=restore_req ? restore_count+1 : 0;
            init_count<=(state_out==3) ? init_count+1 : 0;
            if(active) expected<=expected+1'b1;
            if(save_req && save_count==delay_cycles-1) begin shadow<=domain_q; saves<=saves+1; end
            if(restore_req && restore_count==delay_cycles-1) restores<=restores+1;
        end
    end
    // 仅仿真模型：掉电时主动污染为 X，恢复时从常供电 shadow 读回。
    // 这不是 retention 单元的可综合实现，也没有模拟真实电压。
    always @(posedge clk or negedge rst_n or negedge power_en) begin
        if(!rst_n) domain_q<=0;
        else if(!power_en) domain_q<=16'hxxxx;
        else if(restore_req && restore_count==delay_cycles-1) domain_q<=shadow;
        else if(active && clk_en) domain_q<=domain_q+1'b1;
    end
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            checks=checks+1;
            if(!power_en && (!iso_en || clk_en)) $fatal(1,"FAIL unsafe power off");
            if(restore_req && !power_good) $fatal(1,"FAIL restore before power good");
            if(iso_en && observed!==0) $fatal(1,"FAIL isolation");
            if(active && observed!==expected) $fatal(1,"FAIL retention data");
            if(previous_power && !power_en && shadow!==expected) $fatal(1,"FAIL save before off");
            previous_power=power_en;
        end
    end
    task await_active;
        integer timeout;
        begin
            timeout=0;
            while(!active && timeout<100) begin @(negedge clk); timeout=timeout+1; end
            if(!active) $fatal(1,"FAIL wake timeout");
        end
    endtask
    initial begin
        $dumpfile("power_seq.vcd"); $dumpvars(0,tb_power_seq);
        #2; rst_n=1; #1; rst_n=0;
        @(negedge clk); rst_n=1; sleep_req=0;
        await_active();
        for(round_idx=1;round_idx<=6;round_idx=round_idx+1) begin
            repeat(10+round_idx) @(negedge clk);
            delay_cycles=round_idx; sleep_req=1;
            wait(!power_en); #1;
            if(domain_q!==16'hxxxx || observed!==0) $fatal(1,"FAIL power corruption/isolation");
            repeat(5) @(negedge clk);
            sleep_req=0;
            await_active();
        end
        @(negedge clk);
        $display("PASS power sequence cycles_checked=%0d sleeps=6 saves=%0d restores=%0d retained=%0d",
                 checks,saves,restores,expected);
        // 在保存等待中复位，控制器必须回到隔离/关电状态。
        sleep_req=1; wait(save_req); @(negedge clk); rst_n=0; #1;
        if(power_en!==0 || iso_en!==1 || clk_en!==0) $fatal(1,"FAIL reset safe state");
        $display("PASS power sequence reset_abort=1");
        $finish;
    end
    initial begin #20000; $fatal(1,"FAIL global timeout"); end
endmodule
