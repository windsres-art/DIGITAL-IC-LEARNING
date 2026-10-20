`timescale 1ns/1ps
module tb_cordic;
    parameter ITER=16;
    reg clk=0, rst_n=0, req_valid=0, rsp_ready=0, mode=0;
    reg signed [23:0] x_in=0,y_in=0,angle_in=0;
    wire req_ready,busy,rsp_valid,range_error,zero_vector;
    wire signed [23:0] x_out,y_out,angle_out;
    cordic_iter #(.ITER(ITER)) dut(.*);
    always #5 clk=~clk;
    integer cycles=0, previous=-1, transactions=0, holds=0;
    integer fd,status,mm,xx,yy,aa,bad,zero,i;
    real ex,ey,ez,xtol,ztol;
    real max_rotation=0.0, max_magnitude=0.0, max_phase=0.0, max_tiny_phase=0.0;
    localparam real PI=3.14159265358979323846;
    always @(posedge clk) cycles=cycles+1;
    function real absreal(input real v);
        absreal=(v<0.0)?-v:v;
    endfunction
    task transact(input integer m,xv,yv,av,be,ze,
                  input real xr,yr,zr,tx,tz, input integer stall,stream);
        integer t;
        real dx,dy,dz,rho;
        reg [73:0] saved;
        begin
            @(negedge clk);
            if(req_ready!==1) $fatal(1,"FAIL ready");
            mode=m; x_in=xv; y_in=yv; angle_in=av; req_valid=1; rsp_ready=0;
            @(posedge clk); #1;
            if(stream && previous>=0 && cycles-previous!=ITER+2) $fatal(1,"FAIL interval");
            previous=cycles;
            if(busy!==1 || rsp_valid!==0) $fatal(1,"FAIL acceptance");
            @(negedge clk);
            req_valid=0; mode=!m; x_in=123; y_in=-456; angle_in=789;
            for(t=1;t<=ITER;t=t+1) begin
                @(posedge clk); #1;
                if(rsp_valid !== (t==ITER) || req_ready!==0) $fatal(1,"FAIL latency");
            end
            if((^{x_out,y_out,angle_out,range_error,zero_vector})===1'bx)
                $fatal(1,"FAIL unknown output");
            if(range_error!==be[0] || zero_vector!==ze[0]) $fatal(1,"FAIL flags");
            dx=absreal($itor($signed(x_out))/1048576.0-xr);
            dy=absreal($itor($signed(y_out))/1048576.0-yr);
            dz=absreal($itor($signed(angle_out))/1048576.0-zr);
            // atan2 分支切口附近按模 2pi 比较，而旋转模式比较真实残角。
            if(m && dz>PI) dz=absreal(dz-2.0*PI);
            if(dx>tx || dy>tx || dz>tz)
                $fatal(1,"FAIL numeric ITER=%0d mode=%0d in=(%0d,%0d,%0d) error=(%g,%g,%g) tol=(%g,%g)",
                       ITER,m,xv,yv,av,dx,dy,dz,tx,tz);
            if(!be && !ze) begin
                if(!m) begin
                    if(dx>max_rotation) max_rotation=dx;
                    if(dy>max_rotation) max_rotation=dy;
                end else begin
                    if(dx>max_magnitude) max_magnitude=dx;
                    rho=$sqrt(($itor(xv)/1048576.0)**2+($itor(yv)/1048576.0)**2);
                    if(rho>=0.125) begin if(dz>max_phase) max_phase=dz; end
                    else if(dz>max_tiny_phase) max_tiny_phase=dz;
                end
            end
            if(!m && av==0 && !stream)
                $display("EXAMPLE ITER=%0d sincos(0) x=%0d y=%0d residual=%0d",ITER,x_out,y_out,angle_out);
            if(m && xv==1048576 && yv==1048576)
                $display("EXAMPLE ITER=%0d vector(1,1) scaled_r=%0d residual_y=%0d angle=%0d",ITER,x_out,y_out,angle_out);
            saved={x_out,y_out,angle_out,range_error,zero_vector};
            for(t=0;t<stall;t=t+1) begin
                @(posedge clk); #1;
                if(rsp_valid!==1 || req_ready!==0 ||
                   {x_out,y_out,angle_out,range_error,zero_vector}!==saved)
                    $fatal(1,"FAIL hold");
                holds=holds+1;
            end
            @(negedge clk); rsp_ready=1;
            @(posedge clk); #1;
            if(rsp_valid!==0 || req_ready!==1) $fatal(1,"FAIL retirement");
            transactions=transactions+1;
        end
    endtask
    task abort_case(input integer completed);
        begin
            @(negedge clk); req_valid=1; rsp_ready=0; mode=0; angle_in=0;
            @(posedge clk); #1;
            @(negedge clk); req_valid=0;
            if(completed) repeat(ITER) begin @(posedge clk); #1; end
            #2; rst_n=0; #1;
            if(busy!==0 || rsp_valid!==0 || req_ready!==0) $fatal(1,"FAIL reset");
            @(negedge clk); rst_n=1;
            repeat(ITER+2) begin
                @(posedge clk); #1;
                if(busy!==0 || rsp_valid!==0) $fatal(1,"FAIL ghost");
            end
        end
    endtask
    initial begin
        $dumpfile("cordic.vcd"); $dumpvars(0,tb_cordic);
        #2; rst_n=1; #1; rst_n=0;
        @(negedge clk); rst_n=1;
        fd=$fopen("vectors.txt","r");
        if(!fd) $fatal(1,"FAIL missing vectors");
        status=$fscanf(fd,"%d %d %d %d %d %d %f %f %f %f %f\n",mm,xx,yy,aa,bad,zero,ex,ey,ez,xtol,ztol);
        while(status==11) begin
            transact(mm,xx,yy,aa,bad,zero,ex,ey,ez,xtol,ztol,2,0);
            status=$fscanf(fd,"%d %d %d %d %d %d %f %f %f %f %f\n",mm,xx,yy,aa,bad,zero,ex,ey,ez,xtol,ztol);
        end
        if(!$feof(fd) || transactions==0) $fatal(1,"FAIL malformed vectors");
        $fclose(fd);
        abort_case(0); abort_case(1);
        previous=-1;
        for(i=0;i<8;i=i+1)
            transact(0,0,0,0,0,0,1.0,0.0,0.0,8.0*(ITER+1)/1048576.0+4.0*(2.0**(-ITER)),
                     8.0*(ITER+1)/1048576.0+4.0*(2.0**(-ITER)),0,1);
        $display("ERROR ITER=%0d rotation_xy=%g vector_scaled_r=%g phase_rho_ge_0.125=%g tiny_phase=%g",
                 ITER,max_rotation,max_magnitude,max_phase,max_tiny_phase);
        $display("PASS CORDIC ITER=%0d transactions=%0d latency=%0d interval=%0d hold_cycles=%0d reset_aborts=2",
                 ITER,transactions,ITER,ITER+2,holds);
        $finish;
    end
    initial begin #10000000; $fatal(1,"FAIL timeout"); end
endmodule
