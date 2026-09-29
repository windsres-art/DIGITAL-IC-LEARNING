// =============================================================================
// PWM 与按键消抖 testbench（自检查）
//   pwm_part：两个 pwm（SHADOW=1 / SHADOW=0）接同样的 period / duty
//     T1 静态扫描：若干 period × duty（含 0%、100%），每组 4 个周期，高电平拍数必须精确
//     T2 周期中途随机改 duty（period = 99），2000 个周期以上
//     T3 period 和 duty 都随机改
//     每个 PWM 周期（cnt 从 0 开始到下一次 0）统计：长度、高电平拍数、高电平段数
//     SHADOW=1 必须：长度 = 周期开始时的 period + 1，高电平 = min(duty, 长度)，
//     且只有 1 段（或 0 段）；SHADOW=0 只统计异常周期数
//   deb_part：debounce（N = 64 拍）与"只同步 + 边沿检测"的对照
//     400 次电平变化（200 次按下 + 200 次松开），每次变化带随机抖动；稳定期随机注入
//     毛刺。所有抖动 / 毛刺宽度 < N - 3 拍，时刻与时钟不对齐
//     检查：press / release 各 200 次、不多不少；每次在最后一个抖动边沿之后
//     N+2 ~ N+3 拍输出；最后定向测一个略短于 N 和一个略长于 N 的毛刺
// =============================================================================
`timescale 1ns / 1ps

module pwm_part (output reg done);
    localparam CW = 8;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [CW-1:0] period = 9;
    reg  [CW:0]   duty   = 0;
    wire [CW-1:0] cnt_s, cnt_n;
    wire          pwm_s, pwm_n;

    pwm #(.CW(CW), .SHADOW(1)) u_s (.clk(clk), .rst_n(rst_n), .period(period), .duty(duty),
                                    .cnt_o(cnt_s), .pwm_out(pwm_s));
    pwm #(.CW(CW), .SHADOW(0)) u_n (.clk(clk), .rst_n(rst_n), .period(period), .duty(duty),
                                    .cnt_o(cnt_n), .pwm_out(pwm_n));

    // ---------------- 每个 PWM 周期的统计 ----------------
    integer errors = 0, test = 0;
    // shadow
    integer s_len = 0, s_high = 0, s_seg = 0, s_win = 0, s_bad = 0;
    integer s_exp_len, s_exp_duty;
    reg     s_prev = 0, s_started = 0;
    // naive
    integer n_len = 0, n_high = 0, n_seg = 0, n_win = 0, n_multi = 0, n_odd = 0;
    integer n_d0, n_d1;
    reg     n_prev = 0, n_started = 0;
    reg [CW-1:0] period_prev;
    reg [CW:0]   duty_prev;
    // T1 结果表
    integer t1_high, t1_len;
    integer min_i;

    function integer imin(input integer x, input integer y);
        imin = (x < y) ? x : y;
    endfunction

    always @(posedge clk) if (rst_n) begin
        // ---- SHADOW = 1 ----
        if (cnt_s == 0) begin
            if (s_started && test != 0) begin
                s_win = s_win + 1;
                if (s_len != s_exp_len || s_high != imin(s_exp_duty, s_exp_len) || s_seg > 1) begin
                    if (s_bad < 5) $display("ERROR pwm shadow @%0t len %0d (exp %0d) high %0d (exp %0d) seg %0d",
                                            $time, s_len, s_exp_len, s_high, imin(s_exp_duty, s_exp_len), s_seg);
                    s_bad = s_bad + 1;
                end
                t1_high = s_high; t1_len = s_len;
            end
            // 这个周期用的是上一拍（回绕那拍）装入的 period / duty
            s_exp_len  = period_prev + 1;
            s_exp_duty = duty_prev;
            s_len = 0; s_high = 0; s_seg = 0; s_started = 1;
        end
        s_len = s_len + 1;
        if (pwm_s) begin
            s_high = s_high + 1;
            if (s_len == 1 || !s_prev) s_seg = s_seg + 1;
        end
        s_prev = pwm_s;

        // ---- SHADOW = 0：周期内高电平不止一段，或拍数既不等于开始时也不等于结束时的 duty ----
        if (cnt_n == 0) begin
            if (n_started && test >= 2) begin
                n_win = n_win + 1;
                n_d1  = duty_prev;
                if (n_seg > 1) n_multi = n_multi + 1;
                if (n_high != imin(n_d0, n_len) && n_high != imin(n_d1, n_len)) n_odd = n_odd + 1;
            end
            n_d0 = duty_prev;
            n_len = 0; n_high = 0; n_seg = 0; n_started = 1;
        end
        n_len = n_len + 1;
        if (pwm_n) begin
            n_high = n_high + 1;
            if (n_len == 1 || !n_prev) n_seg = n_seg + 1;
        end
        n_prev = pwm_n;

        period_prev = period;
        duty_prev   = duty;
    end

    // 等 SHADOW 那一路完整走完 k 个周期
    task wait_windows(input integer k);
        integer w0;
        begin
            w0 = s_win;
            wait (s_win >= w0 + k);
        end
    endtask

    integer pi, di, k, n_chg = 0, w_t2;
    integer plist [0:2];
    integer dsel;
    initial begin
        done = 0;
        plist[0] = 9; plist[1] = 99; plist[2] = 255;
        #22 rst_n = 1;
        // ---- T1 静态扫描 ----
        test = 1;
        $display("PWM T1 static (SHADOW=1): period+1 / duty -> measured high / length");
        for (pi = 0; pi < 3; pi = pi + 1) begin
            for (di = 0; di < 6; di = di + 1) begin
                @(negedge clk);
                period = plist[pi];
                case (di)
                    0: dsel = 0;
                    1: dsel = 1;
                    2: dsel = (plist[pi] + 1) / 4;
                    3: dsel = (plist[pi] + 1) / 2;
                    4: dsel = plist[pi] + 1;          // 100%
                    default: dsel = 511;              // 大于周期，也是 100%
                endcase
                duty = dsel;
                wait_windows(4);                      // 第 1 个周期可能还是旧值，取稳定后的
                $display("  period+1 %3d  duty %3d  -> high %3d / %3d  (%5.1f%%)",
                         plist[pi] + 1, dsel, t1_high, t1_len, 100.0 * t1_high / t1_len);
            end
        end
        // ---- T2 周期中途随机改 duty ----
        @(negedge clk); period = 99;
        wait_windows(2);
        test = 2;
        w_t2 = s_win;
        while (s_win < w_t2 + 2000) begin
            repeat (1 + $urandom % 150) @(negedge clk);
            duty = $urandom % 101;
            n_chg = n_chg + 1;
        end
        $display("PWM T2 period 100, duty changed %0d times at random points, %0d periods", n_chg, 2000);
        $display("  SHADOW=1 : bad periods %0d", s_bad);
        $display("  SHADOW=0 : periods with 2 pulses %0d, high count matches neither old nor new duty %0d  (of %0d)",
                 n_multi, n_odd, n_win);
        // ---- T3 period、duty 都随机改 ----
        test = 3;
        for (k = 0; k < 1500; k = k + 1) begin
            repeat (1 + $urandom % 300) @(negedge clk);
            if ($urandom % 2) period = 4 + $urandom % 252;
            else              duty   = $urandom % 260;
        end
        wait_windows(2);
        $display("PWM T3 random period + duty changes: %0d periods checked (SHADOW=1), bad %0d", s_win, s_bad);
        errors = s_bad;
        if (n_multi == 0) begin
            $display("ERROR: 对照组 SHADOW=0 应该出现一个周期两个脉冲"); errors = errors + 1;
        end
        done = 1;
    end
endmodule


module deb_part (output reg done);
    localparam N = 64;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  key = 1'b1;                    // 上拉，按下为 0
    wire level, press, release_p;
    debounce #(.N(N), .IDLE(1'b1)) dut (.clk(clk), .rst_n(rst_n), .key_in(key),
        .key_level(level), .press(press), .release_p(release_p));

    // 对照：只做两级同步 + 下降沿检测
    reg [2:0] nv = 3'b111;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) nv <= 3'b111;
        else        nv <= {nv[1:0], key};
    wire naive_press = nv[2] & ~nv[1];

    integer errors = 0, n_press = 0, n_rel = 0, n_naive = 0, n_level_chg = 0;
    integer exp_press = 0, exp_rel = 0, n_bounce = 0, n_glitch = 0;
    realtime t_last = 0;
    real     lat, lat_min = 1e9, lat_max = 0;
    reg      level_q = 1'b1;
    reg      armed = 0;                 // 在等一次合法的电平变化
    reg      target = 1'b1;

    always @(key) t_last = $realtime;

    always @(posedge clk) if (rst_n) begin
        if (press)       n_press = n_press + 1;
        if (release_p)   n_rel   = n_rel + 1;
        if (naive_press) n_naive = n_naive + 1;
        if (level !== level_q) begin
            n_level_chg = n_level_chg + 1;
            // press / release 必须和电平翻转同一拍（在翻转后的这一拍采到）
            if ((level == 1'b0 && !press) || (level == 1'b1 && !release_p)) begin
                $display("ERROR deb @%0t 电平翻转但事件脉冲不对", $time); errors = errors + 1;
            end
            if (!armed || level !== target) begin
                if (errors < 5) $display("ERROR deb @%0t 多余的电平变化 -> %b", $time, level);
                errors = errors + 1;
            end else begin
                lat = ($realtime - t_last) / 10.0;
                if (lat < lat_min) lat_min = lat;
                if (lat > lat_max) lat_max = lat;
            end
            armed = 0;
        end
        level_q = level;
    end

    // 以 ps 为单位的随机等待：cyc 个时钟周期再加 0~9.999 ns 的零头，保证与时钟不对齐
    task wait_async(input integer cyc);
        begin
            #(cyc * 10.0 + ($urandom % 10000) / 1000.0);
        end
    endtask

    // 电平从 ~lvl 变到 lvl：先抖动 0..8 次（每段 1..N-4 拍），最终停在 lvl
    task transition(input reg lvl);
        integer b, nb;
        begin
            nb = $urandom % 9;
            for (b = 0; b < nb; b = b + 1) begin
                key = ~key;
                wait_async(1 + $urandom % (N - 4));
                n_bounce = n_bounce + 1;
            end
            if (key !== lvl) key = lvl;
            else begin key = ~lvl; wait_async(1 + $urandom % (N - 4)); key = lvl; end
            armed  = 1;
            target = lvl;
        end
    endtask

    // 稳定期：等到输出翻转完成，再保持一段，期间随机插入 0~2 个短毛刺
    task hold_stable(input reg lvl);
        integer g, ng;
        begin
            wait (armed == 0);
            ng = $urandom % 3;
            for (g = 0; g < ng; g = g + 1) begin
                wait_async(N + $urandom % (2 * N));
                key = ~lvl;
                wait_async($urandom % (N - 4));
                key = lvl;
                n_glitch = n_glitch + 1;
            end
            wait_async(N + $urandom % (2 * N));
        end
    endtask

    integer e;
    integer short_ok, long_ok, p0;
    initial begin
        done = 0;
        #22 rst_n = 1;
        wait_async(3 * N);
        for (e = 0; e < 200; e = e + 1) begin
            transition(1'b0); exp_press = exp_press + 1; hold_stable(1'b0);
            transition(1'b1); exp_rel   = exp_rel + 1;   hold_stable(1'b1);
        end
        $display("DEBOUNCE N=%0d cycles: %0d presses + %0d releases, %0d bounce edges, %0d glitches in stable periods",
                 N, exp_press, exp_rel, n_bounce, n_glitch);
        $display("  debounce : press %0d  release %0d  level changes %0d  latency after last edge %.2f ~ %.2f cycles",
                 n_press, n_rel, n_level_chg, lat_min, lat_max);
        $display("  naive (2FF sync + falling edge only): press %0d", n_naive);
        if (n_press != exp_press || n_rel != exp_rel) begin
            $display("ERROR: 事件数不对"); errors = errors + 1;
        end
        if (lat_min < N + 2 - 0.01 || lat_max > N + 3 + 0.01) begin
            $display("ERROR: 延迟超出 N+2 ~ N+3 拍"); errors = errors + 1;
        end
        // ---- 定向：略短于 N 的毛刺被滤掉，略长于 N 的被当成一次按键 ----
        p0 = n_press;
        key = 1'b0; #((N - 3) * 10.0 + 3.3); key = 1'b1; wait_async(3 * N);
        short_ok = (n_press == p0);
        armed = 1; target = 1'b0;
        key = 1'b0; #((N + 3) * 10.0 + 3.3);
        wait (armed == 0);                    // 这时输出已经判定为按下
        key = 1'b1; armed = 1; target = 1'b1;
        wait_async(3 * N);
        long_ok = (n_press == p0 + 1) && (n_rel == exp_rel + 1);
        $display("  glitch %0d cycles: %0s ; glitch %0d cycles: %0s", N - 3,
                 short_ok ? "rejected" : "ACCEPTED (wrong)", N + 3,
                 long_ok ? "accepted as press + release" : "REJECTED (wrong)");
        if (!short_ok || !long_ok) errors = errors + 1;
        done = 1;
    end
endmodule


module tb_pwm_debounce;
    wire [1:0] done;
    pwm_part u_pwm (done[0]);
    deb_part u_deb (done[1]);
    integer errors;
    initial begin
        $dumpfile("pwm_debounce.vcd");
        $dumpvars(0, tb_pwm_debounce);
        wait (&done);
        $display("------------------------------------------------------------------------");
        errors = u_pwm.errors + u_deb.errors;
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
