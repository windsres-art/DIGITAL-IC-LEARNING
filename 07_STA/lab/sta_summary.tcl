# 精简版：只看每组最差路径与 WNS/TNS，用于对比实验
read_liberty build/lib.lib
read_verilog build/fifo_netlist.v
link_design  FIFO_async
read_sdc     fifo.sdc

report_checks -path_delay max -group_count 3 -endpoint_count 1 -format end -digits 3
report_checks -path_delay min -group_count 3 -endpoint_count 1 -format end -digits 3
report_wns
report_tns
