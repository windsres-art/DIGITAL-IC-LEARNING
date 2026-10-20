#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
for w in 1 8; do
  for n in 1 3 8; do
    for pipe in 0 1; do
      tag="w${w}_n${n}_p${pipe}"
      mkdir -p "build/$tag"
      # 纯组合配置保留统一接口，clk/rst_n 必然不使用；只对此配置豁免该告警。
      lint_options=()
      if [[ $pipe == 0 ]]; then lint_options+=(-Wno-UNUSEDSIGNAL); fi
      verilator --lint-only -Wall "${lint_options[@]}" -GW="$w" -GN="$n" -GPIPE="$pipe" param_mux.v > "build/$tag/lint.log" 2>&1
      if [[ $pipe == 1 ]]; then cell_check="select -assert-count $n t:\$adff"; else cell_check='select -assert-none t:$adff'; fi
      yosys -Q -T -p "read_verilog param_mux.v; chparam -set W $w -set N $n -set PIPE $pipe param_mux; hierarchy -check -top param_mux; proc; opt; check -assert; select -assert-none t:\$dlatch; $cell_check" > "build/$tag/synth.log"
      iverilog -g2012 -gstrict-expr-width -s tb_param_mux \
        -Ptb_param_mux.W="$w" -Ptb_param_mux.N="$n" -Ptb_param_mux.PIPE="$pipe" \
        -o "build/$tag/sim" param_mux.v tb_param_mux.sv
      (cd "build/$tag"; vvp -n sim) | tee "build/$tag/result.log"
    done
  done
done
for config in W=0 N=0 PIPE=2; do
  if iverilog -g2012 -s param_mux "-Pparam_mux.$config" -o build/invalid param_mux.v > build/invalid.log 2>&1; then
    echo "FAIL invalid parameter accepted: $config"; exit 1
  fi
  grep -q PARAMETER_ERROR_W_N_PIPE build/invalid.log
  echo "PASS rejected invalid $config at elaboration"
done
echo "PASS Generate: 12 configurations + 3 invalid parameters"
