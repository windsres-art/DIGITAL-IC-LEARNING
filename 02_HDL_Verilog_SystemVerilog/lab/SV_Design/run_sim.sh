#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
# 包必须先编译；interface 端口实验用 Verilator，四态反例另外用 Icarus。
sources=(alu_pkg.sv alu_link.sv alu_core.sv alu_device.sv alu_top.sv)
verilator --lint-only -Wall --top-module alu_top "${sources[@]}" > build/lint.log 2>&1
# Verilator 生成的 Makefile 不支持含空格的构建目录；在 WSL 临时目录编译。
scratch=$(mktemp -d /tmp/ch02-sv.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
cp "${sources[@]}" tb_sv_design.sv "$scratch/"
(cd "$scratch"; verilator --binary --timing --trace -j 2 --top-module tb_sv_design \
  -Wno-TIMESCALEMOD --Mdir obj "${sources[@]}" tb_sv_design.sv) > build/compile.log 2>&1
cp "$scratch/obj/Vtb_sv_design" build/sv_sim
(cd build; ./sv_sim) | tee build/result.log
echo "PASS SV_Design: package + enum + struct + interface/modport + always_comb/ff"
