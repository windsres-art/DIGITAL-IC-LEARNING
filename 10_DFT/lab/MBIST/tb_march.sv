`timescale 1ns/1ps
module tb_march;
    parameter DEPTH=7,W=8;
    localparam AW=DEPTH<=1 ? 1 : $clog2(DEPTH);
    reg clk=0,rst_n=0,start=0;
    wire busy,done,fail,mem_en,mem_we;
    wire [AW-1:0] first_fail_addr,mem_addr;
    wire [2:0] first_fail_phase;
    wire [W-1:0] mem_wdata;
    reg [W-1:0] mem_rdata=0;
    reg [W-1:0] memory[0:DEPTH-1];
    march_c_minus #(.DEPTH(DEPTH),.W(W)) dut(.*);
    integer fault=0,physical_addr,ops=0,runs=0,timeout;
    integer oracle_phase,oracle_addr,position;
    reg oracle_write;
    reg [W-1:0] oracle_data;
    genvar word_index;
    generate for(word_index=0;word_index<DEPTH;word_index=word_index+1) begin: memory_view
        wire [W-1:0] word_value=memory[word_index];
    end endgenerate
    reg [W-1:0] value;
    reg first_seen=0;
    reg [AW-1:0] saved_addr;
    reg [2:0] saved_phase;
    always #5 clk=~clk;
    // 故障只在 TB 存储器模型注入；不修改被测控制器。
    always @(posedge clk) begin
        if(rst_n && mem_en) begin
            if(mem_addr>=DEPTH) $fatal(1,"FAIL address bounds");
            // 按操作编号展开规范序列，独立检查方向、读写次序和背景数据。
            if(ops<DEPTH) begin
                oracle_phase=0; oracle_addr=ops; oracle_write=1; oracle_data=0;
            end else if(ops<9*DEPTH) begin
                oracle_phase=1+(ops-DEPTH)/(2*DEPTH);
                position=(ops-DEPTH)%(2*DEPTH);
                oracle_addr=(oracle_phase>=3) ? DEPTH-1-position/2 : position/2;
                oracle_write=position%2;
                oracle_data=(oracle_phase%2) ? {W{1'b1}} : {W{1'b0}};
            end else begin
                oracle_phase=5; oracle_addr=ops-9*DEPTH; oracle_write=0; oracle_data=0;
            end
            if(mem_addr!==oracle_addr[AW-1:0] || mem_we!==oracle_write ||
               (mem_we && mem_wdata!==oracle_data)) $fatal(1,"FAIL March operation order");
            ops=ops+1;
            physical_addr=(fault==4 && mem_addr==DEPTH-1) ? 0 : mem_addr;
            if(mem_we) begin
                value=mem_wdata;
                if(physical_addr==DEPTH/2) begin
                    if(fault==1) value[0]=0;
                    if(fault==2) value[0]=1;
                    if(fault==3 && memory[physical_addr][0]===0 && value[0]===1) value[0]=0;
                end
                memory[physical_addr]<=value;
            end else mem_rdata<=memory[physical_addr];
        end
    end
    always @(negedge clk) begin
        if(rst_n && fail) begin
            if(!first_seen) begin
                saved_addr=first_fail_addr; saved_phase=first_fail_phase; first_seen=1;
            end else if(first_fail_addr!==saved_addr || first_fail_phase!==saved_phase)
                $fatal(1,"FAIL first failure not sticky");
        end
    end
    initial begin
        $dumpfile("march.vcd"); $dumpvars(0,tb_march);
        #2; rst_n=1; #1; rst_n=0; @(negedge clk); rst_n=1;
        for(fault=0;fault<=4;fault=fault+1) begin
            if(!(DEPTH==1 && fault==4)) begin
                @(negedge clk); start=1; ops=0;
                @(posedge clk); #1;
                @(negedge clk); start=0; first_seen=0;
                timeout=0;
                while(!done && timeout<20*DEPTH+10) begin @(posedge clk); #1; timeout=timeout+1; end
                if(!done || busy) $fatal(1,"FAIL MBIST completion");
                if(fail!==(fault!=0)) $fatal(1,"FAIL fault detection fault=%0d fail=%b",fault,fail);
                if(ops!=10*DEPTH) $fatal(1,"FAIL operation count %0d",ops);
                if(fault!=0) begin
                    oracle_addr=(fault==4) ? DEPTH-1 : DEPTH/2;
                    oracle_phase=(fault==2 || fault==4) ? 1 : 2;
                    if(first_fail_addr!==oracle_addr[AW-1:0] ||
                       first_fail_phase!==oracle_phase[2:0]) $fatal(1,"FAIL diagnostic address/phase");
                end
                $display("PASS March DEPTH=%0d fault=%0d operations=%0d fail=%0d first_addr=%0d first_phase=%0d",
                         DEPTH,fault,ops,fail,first_fail_addr,first_fail_phase);
                runs=runs+1;
            end
        end
        // 进行到一半时复位，不能继续发送请求或产生迟到 done。
        @(negedge clk); start=1; ops=0; @(negedge clk); start=0;
        repeat(2) @(negedge clk);
        rst_n=0; #1;
        if(busy!==0 || mem_en!==0 || done!==0) $fatal(1,"FAIL reset abort");
        @(negedge clk); rst_n=1;
        repeat(3) begin @(posedge clk); #1; if(done || mem_en) $fatal(1,"FAIL ghost operation"); end
        $display("PASS MBIST DEPTH=%0d runs=%0d reset_aborts=1",DEPTH,runs);
        $finish;
    end
    initial begin #100000; $fatal(1,"FAIL global timeout"); end
endmodule
