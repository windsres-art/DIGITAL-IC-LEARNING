`default_nettype none
// Wallace 风格的行压缩：每层把独立的三行压成两行，余行直接送下层。
// 模 2^PW 运算；乘法器的非负部分积总和本身不超出 PW 位。
module csa_reduce #(parameter PW=16,ROWS=8) (
    input wire [PW*ROWS-1:0] rows,
    output wire [PW-1:0] total
);
    localparam TRIPLES=ROWS/3;
    localparam NEXT=2*TRIPLES+ROWS%3;
    genvar i;
    generate
        if(ROWS==1) begin : g_one
            assign total=rows;
        end else if(ROWS==2) begin : g_two
            // 只在末尾做一次全宽进位传播。
            assign total=rows[0 +: PW]+rows[PW +: PW];
        end else begin : g_level
            wire [PW*NEXT-1:0] reduced;
            for(i=0;i<TRIPLES;i=i+1) begin : g_compress
                wire [PW-1:0] x,y,z;
                assign x=rows[(3*i)*PW +: PW];
                assign y=rows[(3*i+1)*PW +: PW];
                assign z=rows[(3*i+2)*PW +: PW];
                assign reduced[(2*i)*PW +: PW]=x^y^z;
                assign reduced[(2*i+1)*PW +: PW]=((x&y)|(x&z)|(y&z))<<1;
            end
            for(i=0;i<ROWS%3;i=i+1) begin : g_tail
                assign reduced[(2*TRIPLES+i)*PW +: PW]=rows[(3*TRIPLES+i)*PW +: PW];
            end
            csa_reduce #(.PW(PW),.ROWS(NEXT)) next_level(.rows(reduced),.total(total));
        end
    endgenerate
endmodule
`default_nettype wire
