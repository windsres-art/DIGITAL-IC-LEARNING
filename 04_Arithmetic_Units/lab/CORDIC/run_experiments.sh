#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
python3 generate_vectors.py > build/reference.log
python3 check_mutations.py
