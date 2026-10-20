#!/usr/bin/env bash
set -euo pipefail
source /root/oss-cad-suite/environment
cd "$(dirname "$0")"
mkdir -p build
yosys -Q -T -p 'read_verilog ../Handshake/elastic_alu.v; synth -top elastic_alu; check -assert; write_verilog -noattr build/netlist.v' > build/synth.log
iverilog -g2012 -DNETLIST -s tb_channel -o build/gls build/netlist.v ../Handshake/tb_channel.sv
(cd build; vvp gls +SEED=2026) | tee build/gls.log
iverilog -g2012 -gspecify -Ttyp -s tb_delay -o build/delay delay_cell.v tb_delay.sv
(cd build; vvp delay) | tee build/delay.log
iverilog -g2012 -s tb_x -o build/x tb_x.sv
(cd build; vvp x) | tee build/x.log
