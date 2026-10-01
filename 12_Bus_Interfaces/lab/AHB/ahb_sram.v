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
    input               hresetn,            // 低有效复位
    input               hsel,               // 地址阶段：译码器选中本从机
    input      [AW-1:0] haddr,              // 字节地址
    input      [1:0]    htrans,             // 00 IDLE，01 BUSY，10 NONSEQ，11 SEQ。只看 bit 1
    input               hwrite,             // 地址阶段的方向：1 写，0 读
    input      [2:0]    hsize,              // 0 字节，1 半字，2 字
    input      [31:0]   hwdata,             // 写数据。比地址晚一拍，在数据阶段才有效
    input               hready,             // 全局：上一笔数据阶段结束才为 1，地址才往前走
    output              hreadyout,          // 本从机：数据阶段结束为 1。为 0 时整条总线停住
    output              hresp,              // 0 = OKAY。本模块不报错，恒为 0
    output     [31:0]   hrdata,             // 读数据，数据阶段有效
    input               stall               // 测试用。本从机数据阶段为 1 时强制再等一拍
);
    localparam WORDS = 1 << (AW - 2);   // 字数。地址按字节计，存储按 32 位一字

    reg [31:0] mem [0:WORDS-1];

    // 地址阶段这一拍有效：被选中、总线没被上一笔拉住、而且是 NONSEQ 或 SEQ
    // htrans[1]=1 即这两种；从机不区分，也不看 HBURST
    wire          ap_valid = hsel & hready & htrans[1];
    wire          unused_htrans0 = htrans[0];   // SEQ/NONSEQ 的最低位。从机不用，接出来免得 lint 报未读
    wire [AW-3:0] ap_widx  = haddr[AW-1:2];     // 字地址，低 2 位用来算字节使能

    // 由 HSIZE 和地址低 2 位得到 4 位字节使能。bit 0 对应最低字节
    function [3:0] byte_en(input [2:0] size, input [1:0] a);
        case (size)
            3'd0:    byte_en = 4'b0001 << a;             // 字节：只打开 a 指向的那一字节
            3'd1:    byte_en = a[1] ? 4'b1100 : 4'b0011; // 半字：高半或低半
            default: byte_en = 4'b1111;                 // 字：四字节全开
        endcase
    endfunction

    // 数据阶段：地址阶段结束的那个沿，把这一笔的控制锁进来。HWDATA 下一拍才到
    reg          dp_valid;       // 数据阶段有一笔待处理的传输
    reg          dp_write;       // 这是写
    reg [AW-3:0] dp_widx;        // 写/读的字地址
    reg [3:0]    dp_be;          // 这一笔的字节使能
    reg [31:0]   rdata_q;        // 读出的字，数据阶段从这里送到 HRDATA

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

    assign hreadyout = ~(dp_valid & stall);   // stall 只拉长正在进行的数据阶段
    assign hresp     = 1'b0;
    assign hrdata    = rdata_q;

    // 写在数据阶段最后一拍（hreadyout=1）提交。等待拍里不重复写
    wire        wr_commit = dp_valid & dp_write & hreadyout;
    wire [31:0] wmask     = {{8{dp_be[3]}}, {8{dp_be[2]}}, {8{dp_be[1]}}, {8{dp_be[0]}}};

    always @(posedge hclk) begin
        if (wr_commit) mem[dp_widx] <= (mem[dp_widx] & ~wmask) | (hwdata & wmask);
    end

    // 读在地址阶段结束的沿就从 mem 取出。若同一沿正在提交写、且字地址相同，
    // 存储里还是旧值，用正在写入的字节拼出来（写后读旁路）
    wire        raw    = wr_commit & (dp_widx == ap_widx);
    wire [31:0] rd_mem = mem[ap_widx];

    always @(posedge hclk) begin
        if (ap_valid & ~hwrite)
            rdata_q <= raw ? ((rd_mem & ~wmask) | (hwdata & wmask)) : rd_mem;
    end
endmodule
