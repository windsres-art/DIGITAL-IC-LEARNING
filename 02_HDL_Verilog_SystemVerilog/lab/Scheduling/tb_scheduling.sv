`timescale 1ns/1ps
module tb_scheduling;
    reg clk = 0, rst_n = 1, en = 0;
    reg [7:0] d = 0;
    wire [7:0] q1, q2;
    reg [7:0] m1 = 0, m2 = 0;
    reg [7:0] old1, old2;
    // 仅供教学的错误写法与赋值优先级探针，绝不作为可复用 RTL。
    reg [7:0] bad1, bad2, last_wins;
    integer cycle, checked = 0, collapsed = 0;
    pipeline dut (.clk(clk), .rst_n(rst_n), .en(en), .d(d), .q1(q1), .q2(q2));
    always #5 clk = ~clk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin bad1 = 0; bad2 = 0; end
        else if (en) begin bad1 = d; bad2 = bad1; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) last_wins <= 0;
        else begin last_wins <= 8'h11; last_wins <= 8'h22; end
    end
    task check(input condition, input [255:0] label_text);
        begin
            if (condition !== 1'b1) begin
                $display("FAIL cycle=%0d check=%s", cycle, label_text);
                $fatal(1, "scheduling mismatch");
            end
        end
    endtask
    // 这个进程只读 DUT，无沿上驱动，因此 active 中可可靠观察旧寄存器。
    always @(posedge clk) if (rst_n) begin
        old1 = m1; old2 = m2;
        check(q1 === old1 && q2 === old2, "active sees old values");
        if (checked < 2)
            $display("ACTIVE t=%0t d=%0d q1=%0d q2=%0d", $time, d, q1, q2);
        if (en) begin m2 = old1; m1 = d; end
        #0;
        check(q1 === old1 && q2 === old2, "inactive is still before NBA");
        if (checked < 2)
            $display("INACTIVE t=%0t q1=%0d q2=%0d", $time, q1, q2);
        if (checked < 2)
            $strobe("POSTPONED t=%0t q1=%0d q2=%0d", $time, q1, q2);
        #1;
        check(q1 === m1 && q2 === m2, "after NBA matches pipeline model");
        check(last_wins === 8'h22, "last executed NBA in same block wins");
        if (en) begin
            check(bad2 === d, "blocking collapses pipeline");
            if (bad2 !== q2) collapsed = collapsed + 1;
        end
        checked = checked + 1;
    end
    initial begin
        $dumpfile("scheduling.vcd"); $dumpvars(0, tb_scheduling);
        #1 rst_n = 0;
        #1;
        check(q1 === 0 && q2 === 0, "asynchronous reset without posedge");
        @(negedge clk); rst_n = 1; en = 1; d = 8'd11;
        @(negedge clk); d = 8'd22;
        for (cycle = 0; cycle < 30; cycle = cycle + 1) begin
            @(negedge clk);
            d = (cycle*17+33) % 256;
            en = (cycle % 4 != 0);
        end
        @(negedge clk);
        check(checked == 32, "all cycles observed");
        check(collapsed > 0, "negative example distinguished");
        // 再次在非时钟沿复位，检查已有非零数据确实被清掉。
        #2 rst_n = 0; m1 = 0; m2 = 0;
        #1;
        check(q1 === 0 && q2 === 0, "midstream asynchronous reset");
        $display("PASS scheduling cycles=%0d blocking_differences=%0d", checked, collapsed);
        $finish;
    end
    initial begin #1000; $fatal(1, "FAIL timeout"); end
endmodule
