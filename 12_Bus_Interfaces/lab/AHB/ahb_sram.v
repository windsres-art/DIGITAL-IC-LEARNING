// =============================================================================
// AHB-Lite SRAM 从机（32 bit 数据，小端）
//   - 地址阶段：hsel & hready & htrans[1]（NONSEQ/SEQ）时接收，
//     把 写/读、字地址、字节使能 寄存到数据阶段；IDLE/BUSY 不产生传输
//   - 写：HWDATA 在数据阶段才到，所以在数据阶段最后一拍（hreadyout=1）写入
//   - 读：模仿真实 SRAM 的同步读——地址阶段结束的那个沿就读出，数据阶段零等待给出。
//     代价：写数据阶段和紧跟的读地址阶段在同一个沿完成，读到的是旧值，
//     所以要做写后读旁路（raw）。本模型的存储是触发器阵列（相当于 1R1W），
//     换成单口 SRAM 时同一拍不能又读又写，要改成写缓冲或插等待。
//   - stall：测试用输入，模拟慢速存储；只在本从机的数据阶段起作用
//   - 只支持 HSIZE ≤ 字（byte / half / word），HRESP 恒为 OKAY
// =============================================================================
module ahb_sram #(
    parameter AW = 12                   // 字节地址位宽，容量 2^AW 字节
)(
    input               hclk,
    input               hresetn,
    input               hsel,
    input      [AW-1:0] haddr,
    input      [1:0]    htrans,
    input               hwrite,
    input      [2:0]    hsize,
    input      [31:0]   hwdata,
    input               hready,
    output              hreadyout,
    output              hresp,
    output     [31:0]   hrdata,
    input               stall
);
    localparam WORDS = 1 << (AW - 2);

    reg [31:0] mem [0:WORDS-1];

    // 地址阶段完成：必须看全局 hready（上一笔可能在别的从机上被拉长）
    // htrans[1]=1 即 NONSEQ/SEQ；从机不需要区分两者，也不需要 HBURST
    wire          ap_valid = hsel & hready & htrans[1];
    wire          unused_htrans0 = htrans[0];
    wire [AW-3:0] ap_widx  = haddr[AW-1:2];

    function [3:0] byte_en(input [2:0] size, input [1:0] a);
        case (size)
            3'd0:    byte_en = 4'b0001 << a;
            3'd1:    byte_en = a[1] ? 4'b1100 : 4'b0011;
            default: byte_en = 4'b1111;
        endcase
    endfunction

    // ---------------- 数据阶段寄存器 ----------------
    reg          dp_valid;
    reg          dp_write;
    reg [AW-3:0] dp_widx;
    reg [3:0]    dp_be;
    reg [31:0]   rdata_q;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)    dp_valid <= 1'b0;
        else if (hready) dp_valid <= ap_valid;
    end

    always @(posedge hclk) begin
        if (ap_valid) begin
            dp_write <= hwrite;
            dp_widx  <= ap_widx;
            dp_be    <= byte_en(hsize, haddr[1:0]);
        end
    end

    assign hreadyout = ~(dp_valid & stall);
    assign hresp     = 1'b0;
    assign hrdata    = rdata_q;

    // ---------------- 写 ----------------
    wire        wr_commit = dp_valid & dp_write & hreadyout;
    wire [31:0] wmask     = {{8{dp_be[3]}}, {8{dp_be[2]}}, {8{dp_be[1]}}, {8{dp_be[0]}}};

    always @(posedge hclk) begin
        if (wr_commit) mem[dp_widx] <= (mem[dp_widx] & ~wmask) | (hwdata & wmask);
    end

    // ---------------- 读（同步读 + 写后读旁路）----------------
    wire        raw    = wr_commit & (dp_widx == ap_widx);
    wire [31:0] rd_mem = mem[ap_widx];

    always @(posedge hclk) begin
        if (ap_valid & ~hwrite)
            rdata_q <= raw ? ((rd_mem & ~wmask) | (hwdata & wmask)) : rd_mem;
    end
endmodule
