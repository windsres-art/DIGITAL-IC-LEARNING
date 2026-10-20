// 仅供数字仿真：真实 ASIC 应映射工艺库 ICG。
module icg_model(input wire EN,CLK,output wire GCLK);
    reg held_en;
    // 此 latch 有意用于在高电平期间冻结门控使能。
    /* verilator lint_off LATCH */
    always @* if(!CLK) held_en=EN;
    /* verilator lint_on LATCH */
    assign GCLK=CLK & held_en;
endmodule
