#!/usr/bin/env bash
set -euo pipefail
source /root/oss-cad-suite/environment
cd "$(dirname "$0")"
mkdir -p build
work=$(mktemp -d /tmp/ch11_objects.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp ../Handshake/elastic_alu.v tb_objects.sv "$work/"
(cd "$work"; verilator --binary -j 2 --timing --assert --trace --coverage-user \
  --top-module tb_objects --Mdir obj elastic_alu.v tb_objects.sv) > build/compile.log 2>&1
cp "$work/obj/Vtb_objects" build/
for seed in 1 17 2026; do
  (cd build; ./Vtb_objects +verilator+seed+"$seed") | tee "build/run_${seed}.log"
done
