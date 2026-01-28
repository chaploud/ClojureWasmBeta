#!/bin/bash
# run_bench.sh — ベンチマークランナー
#
# 使い方:
#   bash test/bench/run_bench.sh              # 通常実行 (両バックエンド)
#   bash test/bench/run_bench.sh --save       # 結果をベースラインとして保存
#   bash test/bench/run_bench.sh --compare    # 前回ベースラインと比較
#   bash test/bench/run_bench.sh --backend=vm # 特定バックエンドのみ
#
# time マクロの出力 ("Elapsed time: X.YYY msecs") を解析して集計

set -uo pipefail
cd "$(dirname "$0")/../.."

BIN="./zig-out/bin/ClojureWasmBeta"
BENCH_FILE="test/bench/basic.clj"
BASELINE_DIR="test/bench/.baseline"
SAVE=false
COMPARE=false
BACKENDS=("tree_walk" "vm")

# オプション解析
for arg in "$@"; do
  case "$arg" in
    --save)    SAVE=true ;;
    --compare) COMPARE=true ;;
    --backend=tree_walk) BACKENDS=("tree_walk") ;;
    --backend=vm)        BACKENDS=("vm") ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# ビルド確認
if [ ! -f "$BIN" ]; then
  echo "=== ビルド中... ==="
  zig build 2>&1
  if [ $? -ne 0 ]; then
    echo "ERROR: ビルド失敗"
    exit 1
  fi
fi

# ベンチマーク名 (basic.clj の print 行から順番に対応)
BENCH_NAMES=(
  "fib(25)"
  "fib-iter(40)"
  "map/filter/reduce(1000)"
  "str-concat(500)"
  "atom-inc(1000)"
  "sum-to(10000)"
  "reduce-sum(10000)"
  "nested-map(500)"
  "assoc-build(500)"
  "get-from-map(200x100)"
)

run_bench() {
  local backend="$1"
  local backend_flag=""
  if [ "$backend" = "vm" ]; then
    backend_flag="--backend=vm"
  fi

  # 2>&1 で結合し、"Elapsed time: X.YYY msecs" 行を抽出
  local output
  output=$($BIN $backend_flag -e "(load-file \"$BENCH_FILE\")" 2>&1)

  # "Elapsed time: X.YYY msecs" から数値を抽出
  local i=0
  while IFS= read -r time_val; do
    if [ $i -lt ${#BENCH_NAMES[@]} ]; then
      printf "%s\t%s\t%s\n" "${BENCH_NAMES[$i]}" "$time_val" "$backend"
    fi
    i=$((i + 1))
  done < <(echo "$output" | sed -n 's/.*"Elapsed time: \([0-9.]*\) msecs".*/\1/p')
}

echo ""
echo "=== ClojureWasmBeta Benchmark ==="
echo ""

# 結果を一時ファイルに蓄積
RESULTS=$(mktemp)

for backend in "${BACKENDS[@]}"; do
  echo "Running: $backend ..."
  run_bench "$backend" >> "$RESULTS"
done

echo ""

# 表形式で出力
if [ "${#BACKENDS[@]}" -eq 2 ]; then
  printf "%-30s %14s %14s\n" "Benchmark" "tree_walk" "vm"
  printf "%-30s %14s %14s\n" "------------------------------" "--------------" "--------------"
  for name in "${BENCH_NAMES[@]}"; do
    tw_time=$(grep "^${name}	" "$RESULTS" | grep "tree_walk" | cut -f2)
    vm_time=$(grep "^${name}	" "$RESULTS" | grep "vm" | cut -f2)
    printf "%-30s %12s ms %12s ms\n" "$name" "${tw_time:-N/A}" "${vm_time:-N/A}"
  done
else
  backend="${BACKENDS[0]}"
  printf "%-30s %14s\n" "Benchmark" "$backend"
  printf "%-30s %14s\n" "------------------------------" "--------------"
  for name in "${BENCH_NAMES[@]}"; do
    time_val=$(grep "^${name}	" "$RESULTS" | cut -f2)
    printf "%-30s %12s ms\n" "$name" "${time_val:-N/A}"
  done
fi

echo ""

# ベースライン保存
if $SAVE; then
  mkdir -p "$BASELINE_DIR"
  date_str=$(date +%Y%m%d_%H%M%S)
  cp "$RESULTS" "$BASELINE_DIR/bench_${date_str}.tsv"
  cp "$RESULTS" "$BASELINE_DIR/latest.tsv"
  echo "=== ベースライン保存: $BASELINE_DIR/bench_${date_str}.tsv ==="
fi

# ベースライン比較
if $COMPARE; then
  if [ ! -f "$BASELINE_DIR/latest.tsv" ]; then
    echo "=== ベースラインなし (--save で保存してください) ==="
  else
    echo "=== ベースライン比較 ==="
    printf "%-30s %12s %12s %8s\n" "Benchmark" "Baseline" "Current" "Change"
    printf "%-30s %12s %12s %8s\n" "------------------------------" "------------" "------------" "--------"

    while IFS=$'\t' read -r name cur_time backend; do
      prev_time=$(grep "^${name}	" "$BASELINE_DIR/latest.tsv" | grep "${backend}$" | cut -f2)
      if [ -n "$prev_time" ] && [ "$prev_time" != "N/A" ] && [ "$cur_time" != "N/A" ]; then
        change=$(awk "BEGIN { printf \"%.1f\", (($cur_time - $prev_time) / $prev_time) * 100 }")
        if [ "$(echo "$change > 5" | bc -l 2>/dev/null)" = "1" ]; then
          marker="SLOWER"
        elif [ "$(echo "$change < -5" | bc -l 2>/dev/null)" = "1" ]; then
          marker="FASTER"
        else
          marker="~"
        fi
        printf "%-30s %10s ms %10s ms %7s%% %s\n" "$name ($backend)" "$prev_time" "$cur_time" "$change" "$marker"
      fi
    done < "$RESULTS"
    echo ""
  fi
fi

rm -f "$RESULTS"
echo "=== Done ==="
