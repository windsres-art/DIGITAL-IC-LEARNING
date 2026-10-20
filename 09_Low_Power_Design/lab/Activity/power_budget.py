"""教学参数计算，不读取工艺库，结果不是芯片功耗报告。"""
alpha, capacitance, voltage, frequency=0.12,20e-12,0.8,500e6
dynamic=alpha*capacitance*voltage**2*frequency
ratio=(0.7/0.8)**2*(300/500)
print(f"MODEL switching={dynamic*1e3:.3f} mW; DVFS power_ratio={ratio:.6f}")
# 同样周期数的计算，降频使执行时间增加，动态能量比只剩 V² 比。
print(f"MODEL fixed_cycles dynamic_energy_ratio={(0.7/0.8)**2:.6f}")
transition_energy=2e-6
saved_power=5e-3-0.2e-3
breakeven=transition_energy/saved_power
assert abs(dynamic-0.000768)<1e-12
assert abs(breakeven-1/2400)<1e-12
print(f"MODEL poweroff_break_even={breakeven*1e6:.3f} us (excluding wake deadline)")
