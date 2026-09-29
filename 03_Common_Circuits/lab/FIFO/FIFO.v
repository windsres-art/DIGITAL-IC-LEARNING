// =============================================================================
// 异步 FIFO（Async FIFO）学习示例 —— 已 debug + 中文讲解注释
// -----------------------------------------------------------------------------
// 教学目标：理解「跨时钟域」下如何安全地传递读写指针，并产生 full / empty。
//
// 整体结构（Cummings 经典五块）：
//   1. RAM           —— 双口存储（写时钟写、读时钟读）
//   2. write_full    —— 写侧二进制指针 + Gray 编码 + full 判断
//   3. read_empty    —— 读侧二进制指针 + Gray 编码 + empty 判断
//   4/5. synchronization ×2 —— 两级触发器，把对侧 Gray 指针同步到本侧时钟域
//
// 为什么指针要转成 Gray 码再跨域？
//   二进制码一次可能翻转多位（如 0111→1000），在另一时钟采样会采到中间态。
//   Gray 码相邻值只翻 1 位，同步后要么采到旧值要么新值，不会出现「半新旧」乱码。
//
// 深度：地址位宽 FIFO_addr_size → 深度 DEPTH = 2^FIFO_addr_size
// 指针多 1 bit（[FIFO_addr_size:0]）用来区分「满」和「空」（绕回一周后地址相同）。
// =============================================================================

module FIFO_async #(
	parameter FIFO_data_size = 6,   // 数据位宽
	parameter FIFO_addr_size = 5    // 地址位宽 → 深度 = 2^FIFO_addr_size
)(
	// -------- 写时钟域 --------
	input                           clk_w,
	input                           rst_w,      // 低有效异步复位
	input                           w_en,
	input  [FIFO_data_size-1:0]     data_in,

	// -------- 读时钟域 --------
	input                           clk_r,
	input                           rst_r,      // 低有效异步复位
	input                           r_en,
	output [FIFO_data_size-1:0]     data_out,

	// -------- 状态（各自时钟域产生，使用时注意 CDC）--------
	output wire                     empty,
	output wire                     full
);

	// --- 跨域后的 Gray 指针（命名：xxx_sync = 已同步到「使用它」的那一侧）---
	wire [FIFO_addr_size:0] r_pointer_gray_sync; // 读指针 Gray → 同步到写时钟，给 full 用
	wire [FIFO_addr_size:0] w_pointer_gray_sync; // 写指针 Gray → 同步到读时钟，给 empty 用

	// --- 本域产生的 Gray 指针 ---
	wire [FIFO_addr_size:0] r_pointer_gray;
	wire [FIFO_addr_size:0] w_pointer_gray;

	// --- 实际访问 RAM 的地址（指针低 FIFO_addr_size 位）---
	wire [FIFO_addr_size-1:0] w_addr;
	wire [FIFO_addr_size-1:0] r_addr;

	// -------------------------------------------------------------------------
	// 双口 RAM：写口跟 clk_w，读口跟 clk_r
	// -------------------------------------------------------------------------
	RAM #(
		.FIFO_data_size(FIFO_data_size),
		.FIFO_addr_size(FIFO_addr_size)
	) inst_RAM (
		.clk_w    (clk_w),
		.rst_w    (rst_w),
		.clk_r    (clk_r),
		.rst_r    (rst_r),
		.full     (full),
		.empty    (empty),
		.w_en     (w_en),
		.r_en     (r_en),
		.r_addr   (r_addr),
		.w_addr   (w_addr),
		.data_in  (data_in),
		.data_out (data_out)
	);

	// -------------------------------------------------------------------------
	// 写侧：推进写指针、产生 full
	// -------------------------------------------------------------------------
	write_full #(
		.FIFO_addr_size(FIFO_addr_size)
	) inst_write_full (
		.clk_w               (clk_w),
		.rst_w               (rst_w),
		.w_en                (w_en),
		.r_pointer_gray_sync (r_pointer_gray_sync),
		.w_pointer_gray      (w_pointer_gray),
		.w_addr              (w_addr),
		.full                (full)
	);

	// -------------------------------------------------------------------------
	// 读侧：推进读指针、产生 empty
	// -------------------------------------------------------------------------
	read_empty #(
		.FIFO_addr_size(FIFO_addr_size)
	) inst_read_empty (
		.clk_r               (clk_r),
		.rst_r               (rst_r),
		.r_en                (r_en),
		.w_pointer_gray_sync (w_pointer_gray_sync),
		.r_pointer_gray      (r_pointer_gray),
		.r_addr              (r_addr),
		.empty               (empty)
	);

	// -------------------------------------------------------------------------
	// 【原 bug】两路同步器的 din / 时钟域接反了！
	//
	// 正确做法（指针必须「离开自己的时钟域、进入对方」）：
	//   - 读指针 Gray  → 用写时钟打两拍 → r_pointer_gray_sync（写侧判 full）
	//   - 写指针 Gray  → 用读时钟打两拍 → w_pointer_gray_sync（读侧判 empty）
	//
	// 原代码把读指针用读时钟同步、写指针用写时钟同步，等于没有跨域，full/empty 会错。
	// -------------------------------------------------------------------------

	// 读 Gray → 写时钟域
	synchronization #(
		.FIFO_addr_size(FIFO_addr_size)
	) sync_r2w (
		.clk  (clk_w),
		.rst  (rst_w),
		.din  (r_pointer_gray),
		.dout (r_pointer_gray_sync)
	);

	// 写 Gray → 读时钟域
	synchronization #(
		.FIFO_addr_size(FIFO_addr_size)
	) sync_w2r (
		.clk  (clk_r),
		.rst  (rst_r),
		.din  (w_pointer_gray),
		.dout (w_pointer_gray_sync)
	);

endmodule


// =============================================================================
// 双口 RAM
// =============================================================================
module RAM #(
	parameter FIFO_data_size = 3,
	parameter FIFO_addr_size = 2
)(
	input                       clk_w,
	input                       rst_w,
	input                       clk_r,
	input                       rst_r,
	input                       full,
	input                       empty,
	input                       w_en,
	input                       r_en,
	input  [FIFO_addr_size-1:0] w_addr,
	input  [FIFO_addr_size-1:0] r_addr,
	input  [FIFO_data_size-1:0] data_in,
	output reg [FIFO_data_size-1:0] data_out
);

	// 深度 = 2^FIFO_addr_size；下标 0 .. DEPTH-1
	localparam integer DEPTH = 1 << FIFO_addr_size;

	reg [FIFO_data_size-1:0] mem [0:DEPTH-1];
	integer i;

	// -------- 写端口 --------
	// 【原 bug1】复位循环写成了 i <= FIFO_data_size（按数据位宽清），
	//            地址更深时（如 addr_size=5 → 32 深）只清了前几个单元。
	// 【原 bug2】else 分支把 mem[w_addr] 清零 —— 不写就擦数据，FIFO 必坏。
	//            正确：只在「使能且未满」时写；其它时间保持。
	always @(posedge clk_w or negedge rst_w) begin
		if (~rst_w) begin
			for (i = 0; i < DEPTH; i = i + 1)
				mem[i] <= {FIFO_data_size{1'b0}};
		end else if (w_en && !full) begin
			mem[w_addr] <= data_in;
		end
		// else: 保持 mem 不变（不要清零）
	end

	// -------- 读端口（同步读）--------
	// 【原写法】不读就把 data_out 清 0，仿真难看且丢「上次读出值」。
	// 改为：有效读才更新；否则保持。
	always @(posedge clk_r or negedge rst_r) begin
		if (~rst_r) begin
			data_out <= {FIFO_data_size{1'b0}};
		end else if (r_en && !empty) begin
			data_out <= mem[r_addr];
		end
	end

endmodule


// =============================================================================
// 写侧：二进制写指针 + Gray + full
// =============================================================================
module write_full #(
	parameter FIFO_addr_size = 2
)(
	input                           clk_w,
	input                           rst_w,
	input                           w_en,
	input      [FIFO_addr_size:0]   r_pointer_gray_sync, // 已同步到写域的读指针 Gray
	output                          full,
	output wire [FIFO_addr_size-1:0] w_addr,
	output wire [FIFO_addr_size:0]  w_pointer_gray
);

	reg  [FIFO_addr_size:0] w_pointer_bin;
	wire                    flag_wr;

	// 写成功条件：使能且当前未满
	assign flag_wr = w_en && !full;

	always @(posedge clk_w or negedge rst_w) begin
		if (~rst_w)
			w_pointer_bin <= {(FIFO_addr_size+1){1'b0}};
		else if (flag_wr)
			w_pointer_bin <= w_pointer_bin + 1'b1;
		// else 保持
	end

	// 二进制 → Gray：G = (B >> 1) ^ B
	assign w_pointer_gray = (w_pointer_bin >> 1) ^ w_pointer_bin;

	// RAM 地址取指针低位
	assign w_addr = w_pointer_bin[FIFO_addr_size-1:0];

	// full：写 Gray 与「读 Gray 的高 2 位取反、其余相同」时判满
	// （等价于：多出来的那 1 bit 说明写比读多绕了一圈，地址低位相同 → 满）
	assign full = (w_pointer_gray ==
		{~r_pointer_gray_sync[FIFO_addr_size:FIFO_addr_size-1],
		  r_pointer_gray_sync[FIFO_addr_size-2:0]});

endmodule


// =============================================================================
// 读侧：二进制读指针 + Gray + empty
// =============================================================================
module read_empty #(
	parameter FIFO_addr_size = 2
)(
	input                           clk_r,
	input                           rst_r,
	input                           r_en,
	input      [FIFO_addr_size:0]   w_pointer_gray_sync, // 已同步到读域的写指针 Gray
	output wire                     empty,
	output wire [FIFO_addr_size-1:0] r_addr,
	output wire [FIFO_addr_size:0]  r_pointer_gray
);

	reg [FIFO_addr_size:0] r_pointer_bin;

	always @(posedge clk_r or negedge rst_r) begin
		if (~rst_r)
			// 【原 bug】宽度写成 FIFO_addr_size，少了指针多出来的那 1 bit
			r_pointer_bin <= {(FIFO_addr_size+1){1'b0}};
		else if (r_en && !empty)
			r_pointer_bin <= r_pointer_bin + 1'b1;
	end

	assign r_pointer_gray = (r_pointer_bin >> 1) ^ r_pointer_bin;
	assign r_addr         = r_pointer_bin[FIFO_addr_size-1:0];

	// empty：读写 Gray 完全相等 → 没有未读数据
	assign empty = (r_pointer_gray == w_pointer_gray_sync);

endmodule


// =============================================================================
// 两级同步器（两拍）：缓解亚稳态，把 din 安全采到本 clk 域
// 注意：只能同步「单 bit 翻转」的信号（故指针必须先 Gray 编码）
// =============================================================================
module synchronization #(
	parameter FIFO_addr_size = 2
)(
	input                       clk,
	input                       rst,
	input  [FIFO_addr_size:0]   din,
	output reg [FIFO_addr_size:0] dout
);

	reg [FIFO_addr_size:0] dout_t; // 第一级

	always @(posedge clk or negedge rst) begin
		if (~rst) begin
			// 【原 bug】复位宽度写成 FIFO_addr_size，少 1 bit
			dout_t <= {(FIFO_addr_size+1){1'b0}};
			dout   <= {(FIFO_addr_size+1){1'b0}};
		end else begin
			dout_t <= din;    // 第 1 拍
			dout   <= dout_t; // 第 2 拍（输出）
		end
	end

endmodule
