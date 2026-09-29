#!/usr/bin/env bash
# 串行回归：遍历 W × SEED，每个组合调用一次 make sim，最后汇总
# 用法：bash regress.sh
#       WIDTHS="4 8" SEEDS="1 2 3" BUG=1 CORNER=1 bash regress.sh
# 退出码：全部通过为 0，否则为 1（CI 靠退出码判断成败）

# 不用 -e：单个用例失败不能中断整个回归
set -uo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment

WIDTHS=${WIDTHS:-"4 8 16"}
SEEDS=${SEEDS:-"1 2 3 4 5"}
BUG=${BUG:-0}
CORNER=${CORNER:-0}

pass=0
fail=0
failed=()
start=$SECONDS

for w in $WIDTHS; do
  for s in $SEEDS; do
    # $( ) 捕获输出；make 的退出码在赋值语句后用 $? 取
    out=$(make -s sim W="$w" SEED="$s" BUG="$BUG" CORNER="$CORNER" 2>&1)
    if [[ $? -eq 0 ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      failed+=("make sim W=$w SEED=$s BUG=$BUG CORNER=$CORNER")
    fi
    echo "  $(grep -E '^(PASS|FAIL)' <<< "$out" || echo "NO RESULT W=$w SEED=$s")"
  done
done

echo "total=$((pass + fail)) pass=$pass fail=$fail  用时 $((SECONDS - start)) s"
if ((fail > 0)); then
  echo "复现失败用例："
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
