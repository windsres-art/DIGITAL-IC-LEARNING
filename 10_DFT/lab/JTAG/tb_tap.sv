`timescale 1ns/1ps
module tb_tap;
    reg tck=0,trst_n=0,tms=1,tdi=0;
    reg [3:0] pad_in=4'ha,core_out=4'h5;
    wire [3:0] pad_out,state_debug;
    wire [1:0] instruction_debug;
    wire tdo,tdo_oe;
    tap_demo dut(.*);
    integer fd,status,control,expected,i,walk_steps=0;
    reg sample_bit;
    reg [1:0] captured_ir;
    reg [7:0] captured_dr;
    reg [31:0] edge_seen=0;
    reg [3:0] previous_state;
    task tick(input reg mode_bit,data_bit,output reg sample);
        begin
            #2; tms=mode_bit; tdi=data_bit;
            #3; sample=tdo; tck=1;
            #5; tck=0; #1;
        end
    endtask
    task reset_tap;
        begin
            repeat(5) tick(1,0,sample_bit);
            if(state_debug!==0 || instruction_debug!==3) $fatal(1,"FAIL five TMS reset");
            tick(0,0,sample_bit);
        end
    endtask
    task instruction(input reg [1:0] code);
        integer j;
        begin
            tick(1,0,sample_bit); tick(1,0,sample_bit);
            tick(0,0,sample_bit); tick(0,0,sample_bit);
            for(j=0;j<2;j=j+1) tick(j==1,code[j],captured_ir[j]);
            if(captured_ir!==2'b01) $fatal(1,"FAIL Capture IR 01");
            tick(1,0,sample_bit);
            if(instruction_debug!==code) $fatal(1,"FAIL Update IR");
            tick(0,0,sample_bit);
        end
    endtask
    task boundary(input reg [7:0] value,input reg pause);
        integer j;
        reg [3:0] old_pad;
        begin
            old_pad=pad_out;
            tick(1,0,sample_bit); tick(0,0,sample_bit); tick(0,0,sample_bit);
            for(j=0;j<8;j=j+1) begin
                tick((j==7)||(pause && j==3),value[j],captured_dr[j]);
                if(pad_out!==old_pad) $fatal(1,"FAIL boundary changed during shift");
                if(pause && j==3) begin
                    tick(0,0,sample_bit); // Exit1 -> Pause
                    repeat(3) tick(0,0,sample_bit);
                    tick(1,0,sample_bit); // Pause -> Exit2
                    tick(0,0,sample_bit); // Exit2 -> Shift
                end
            end
            tick(1,0,sample_bit); // Update DR，下降沿提交
            tick(0,0,sample_bit);
        end
    endtask
    initial begin
        $dumpfile("tap.vcd"); $dumpvars(0,tb_tap);
        #1; trst_n=1; #1; trst_n=0; #1; trst_n=1;
        fd=$fopen("walk.txt","r");
        if(!fd) $fatal(1,"FAIL missing walk");
        status=$fscanf(fd,"%d %d\n",control,expected);
        while(status==2) begin
            previous_state=state_debug;
            tick(control[0],0,sample_bit);
            edge_seen[previous_state*2+control]=1;
            if(state_debug!==expected[3:0]) $fatal(1,"FAIL TAP state transition");
            walk_steps=walk_steps+1;
            status=$fscanf(fd,"%d %d\n",control,expected);
        end
        if(!$feof(fd) || edge_seen!==32'hffffffff) $fatal(1,"FAIL TAP edge coverage");
        $fclose(fd);
        reset_tap();
        // SAMPLE/PRELOAD：读 pad，写影子寄存器，不能抢占核心输出。
        instruction(2'b01);
        boundary(8'h3c,1);
        if(captured_dr!==8'ha5 || pad_out!==core_out) $fatal(1,"FAIL SAMPLE/PRELOAD");
        instruction(2'b00);
        if(pad_out!==4'hc) $fatal(1,"FAIL EXTEST preload");
        boundary(8'h06,1);
        if(captured_dr!==8'hac || pad_out!==4'h6) $fatal(1,"FAIL EXTEST update");
        // 保留操作码 10 与 BYPASS 11 均选择单 bit 路径。
        for(i=2;i<=3;i=i+1) begin
            instruction(i);
            tick(1,0,sample_bit); tick(0,0,sample_bit); tick(0,0,sample_bit);
            if(!tdo_oe) $fatal(1,"FAIL TDO enable");
            tick(0,1,sample_bit); if(sample_bit!==0) $fatal(1,"FAIL BYPASS capture");
            tick(0,0,sample_bit); if(sample_bit!==1) $fatal(1,"FAIL BYPASS delay");
            tick(1,1,sample_bit); if(sample_bit!==0) $fatal(1,"FAIL BYPASS stream");
            tick(1,0,sample_bit); tick(0,0,sample_bit);
            if(tdo_oe) $fatal(1,"FAIL TDO outside shift");
        end
        instruction(0); reset_tap();
        if(pad_out!==core_out) $fatal(1,"FAIL reset releases pads");
        #1; trst_n=0; #1;
        if(state_debug!==0 || instruction_debug!==3 || tdo!==0) $fatal(1,"FAIL async TRST");
        $display("PASS TAP walk_steps=%0d states=16 edges=32 IR_capture=01 boundary_transactions=2 bypass_opcodes=2 pause_resume=2 reset_paths=2",
                 walk_steps);
        $finish;
    end
    initial begin #20000; $fatal(1,"FAIL timeout"); end
endmodule
