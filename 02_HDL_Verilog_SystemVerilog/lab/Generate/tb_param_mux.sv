`timescale 1ns/1ps
module tb_param_mux;
    parameter W=8, N=3, PIPE=0;
    localparam SW=(N<=1)?1:$clog2(N);
    reg clk=0, rst_n=1;
    reg [W*N-1:0] din;
    reg [SW-1:0] sel;
    wire [W-1:0] dout;
    wire [N-1:0] parity;
    reg [W-1:0] model [0:N-1];
    reg [W-1:0] expected;
    reg p;
    integer k, j, b, s, checks=0, invalid=0;
    param_mux #(.W(W),.N(N),.PIPE(PIPE)) dut(.*);
    always #5 clk=~clk;
    task verify;
        begin
            expected=0;
            // 用独立数组建模，逐 bit 异或，不读取 DUT 的 lanes。
            if (sel < N) expected=model[sel];
            else invalid++;
            if (dout !== expected) $fatal(1,"FAIL mux W=%0d N=%0d PIPE=%0d",W,N,PIPE);
            for(j=0;j<N;j++) begin
                p=0;
                for(b=0;b<W;b++) p=p^model[j][b];
                if(parity[j] !== p) $fatal(1,"FAIL parity lane=%0d",j);
            end
            checks++;
        end
    endtask
    initial begin
        $dumpfile("generate.vcd"); $dumpvars(0,tb_param_mux);
        // 用显式输入变化启动 Verilog @*，不依赖 time-zero 初始化事件次序。
        #1 rst_n=0; din=0; sel=0; #1;
        for(j=0;j<N;j++) model[j]=0;
        verify();
        @(negedge clk); rst_n=1;
        for(k=0;k<24;k++) begin
            @(negedge clk);
            for(j=0;j<N;j++) din[j*W +: W]=(k*19+j*37+5);
            sel=k % (1<<SW);
            if(!PIPE) for(j=0;j<N;j++) model[j]=din[j*W +: W];
            #1; verify(); // PIPE=1 此时必须仍为上周期的通道数据。
            @(posedge clk);
            if(PIPE) for(j=0;j<N;j++) model[j]=din[j*W +: W];
            #1; verify();
        end
        // 在同一拍内遍历全部选择编码，证明选择信号自身没有被寄存。
        @(negedge clk);
        for(s=0;s<(1<<SW);s++) begin
            sel=s; #0.1; verify();
        end
        $display("PASS generate W=%0d N=%0d PIPE=%0d checks=%0d invalid_selects=%0d",
                 W,N,PIPE,checks,invalid);
        $finish;
    end
    initial begin #10000; $fatal(1,"FAIL timeout"); end
endmodule
