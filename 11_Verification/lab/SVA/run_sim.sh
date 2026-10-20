#!/usr/bin/env bash
set -euo pipefail
source /root/oss-cad-suite/environment
cd "$(dirname "$0")"
mkdir -p build
work=$(mktemp -d /tmp/ch11_sva.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp ../Handshake/elastic_alu.v channel_properties.sv tb_sva.sv "$work/"
(cd "$work"; verilator --binary -j 2 --timing --assert --trace --top-module tb_sva \
  --Mdir obj elastic_alu.v channel_properties.sv tb_sva.sv) > build/compile.log 2>&1
cp "$work/obj/Vtb_sva" build/
(cd build; ./Vtb_sva) | tee build/run.log
