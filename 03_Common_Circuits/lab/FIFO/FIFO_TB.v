// =============================================================================
// 异步 FIFO 测试平台（Testbench）—— 已整理 + 中文讲解注释
// -----------------------------------------------------------------------------
// 仿真环境（见 ascon-aead128-fast/README.md）：
//   Windows 本机不要跑；在 WSL2 Ubuntu 里用 OSS CAD Suite：
//     source ~/oss-cad-suite/environment   # 本机也可能在 /root/oss-cad-suite
//     iverilog -g2012 -o fifo_sim FIFO.v FIFO_TB.v
//     vvp fifo_sim
//     gtkwave fifo_async.vcd              # 可选看波形
// =============================================================================

`timescale 1ns / 1ns

module tb_FIFO_async;

	// 小深度方便人工看波形：addr_size=2 → 深度 4；data 3 bit
	parameter FIFO_data_size = 3;
	parameter FIFO_addr_size = 2;

	reg                         clk_r;
	reg                         rst_r;
	reg                         r_en;

	reg                         clk_w;
	reg                         rst_w;
	reg                         w_en;

	reg  [FIFO_data_size-1:0]   data_in;
	wire [FIFO_data_size-1:0]   data_out;
	wire                        empty;
	wire                        full;

	integer i;

	// -------------------------------------------------------------------------
	// 时钟：写快读慢，刻意造成跨时钟域场景
	//   clk_w 周期 50ns  → 20 MHz
	//   clk_r 周期 100ns → 10 MHz
	// -------------------------------------------------------------------------
	initial begin
		clk_w = 1'b0;
		forever #25 clk_w = ~clk_w;
	end

	initial begin
		clk_r = 1'b0;
		forever #50 clk_r = ~clk_r;
	end

	// -------------------------------------------------------------------------
	// 复位：低有效；两域各自释放（释放时刻略错开，更贴近真实）
	// -------------------------------------------------------------------------
	initial begin
		rst_w   = 1'b1;
		data_in = {FIFO_data_size{1'b0}};
		#15  rst_w = 1'b0;   // 拉低复位
		#20  rst_w = 1'b1;   // 释放
	end

	initial begin
		rst_r = 1'b1;
		r_en  = 1'b0;
		#25  rst_r = 1'b0;
		#50  rst_r = 1'b1;
	end

	// -------------------------------------------------------------------------
	// 写使能时序：先写一段 → 停 → 再写（观察 full）
	// -------------------------------------------------------------------------
	initial begin
		w_en = 1'b0;
		#450 w_en = 1'b1;
		#400 w_en = 1'b0;
		#750 w_en = 1'b1;
		#500 w_en = 1'b0;
	end

	// -------------------------------------------------------------------------
	// 读使能时序：写了一阵再读（观察 empty / 数据顺序）
	// -------------------------------------------------------------------------
	initial begin
		r_en = 1'b0;
		#900  r_en = 1'b1;
		#400  r_en = 1'b0;
		#300  r_en = 1'b1;
		#800  r_en = 1'b0;
	end

	// 写数据每隔 100ns 换一次（与写时钟不同步没关系，采样在写沿）
	initial begin
		for (i = 0; i <= 50; i = i + 1) begin
			#100 data_in = i[FIFO_data_size-1:0];
		end
	end

	// -------------------------------------------------------------------------
	// DUT
	// -------------------------------------------------------------------------
	FIFO_async #(
		.FIFO_data_size(FIFO_data_size),
		.FIFO_addr_size(FIFO_addr_size)
	) inst_FIFO_async (
		.clk_w    (clk_w),
		.rst_w    (rst_w),
		.w_en     (w_en),
		.clk_r    (clk_r),
		.rst_r    (rst_r),
		.r_en     (r_en),
		.data_in  (data_in),
		.data_out (data_out),
		.empty    (empty),
		.full     (full)
	);

	// -------------------------------------------------------------------------
	// 波形 + 简单监控 + 结束仿真
	// -------------------------------------------------------------------------
	initial begin
		$dumpfile("fifo_async.vcd");
		$dumpvars(0, tb_FIFO_async);
		// Icarus 的 $dumpvars 默认不录 memory 数组，要按元素显式 dump
		// 路径：tb → FIFO 例化 → RAM 例化 → mem[i]
		$dumpvars(0, inst_FIFO_async.inst_RAM.mem[0]);
		$dumpvars(0, inst_FIFO_async.inst_RAM.mem[1]);
		$dumpvars(0, inst_FIFO_async.inst_RAM.mem[2]);
		$dumpvars(0, inst_FIFO_async.inst_RAM.mem[3]);
		// addr_size=2 → DEPTH=4；若以后加深，继续加 mem[4]...
	end

	// 读口是同步读：本拍采样 mem，data_out 在同一拍非阻塞更新，
	// 所以要下一拍再打印，才能看到真正读出的值。
	reg read_fire_d;
	always @(posedge clk_r or negedge rst_r) begin
		if (~rst_r)
			read_fire_d <= 1'b0;
		else
			read_fire_d <= (r_en && !empty);
	end

	always @(posedge clk_r) begin
		if (read_fire_d)
			$display("%0t ns  READ  data_out=%0d  empty=%b full=%b",
			         $time, data_out, empty, full);
	end

	always @(posedge clk_w) begin
		if (rst_w && w_en && !full)
			$display("%0t ns  WRITE data_in=%0d   empty=%b full=%b",
			         $time, data_in, empty, full);
	end

	initial begin
		#3000;
		$display("---- simulation done ----");
		$finish;
	end

endmodule
