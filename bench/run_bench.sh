#!/bin/bash
# ClojureWasmBeta ベンチマークスイート
#
# 使い方:
#   bash bench/run_bench.sh                    # 全言語実行 (コンソール出力のみ)
#   bash bench/run_bench.sh --quick            # ClojureWasmBeta のみ (開発中の回帰チェック)
#   bash bench/run_bench.sh --record           # 結果を status/bench.yaml に追記
#   bash bench/run_bench.sh --version="P3 NaN" # 記録時のバージョン名を指定
#   bash bench/run_bench.sh --hyperfine        # hyperfine で高精度計測
#
# 組み合わせ例:
#   bash bench/run_bench.sh --quick --record                      # CLJ のみ計測して記録
#   bash bench/run_bench.sh --quick --record --version="G2 GC"    # バージョン名付きで記録

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
YAML_FILE="$PROJECT_DIR/status/bench.yaml"

# オプション
QUICK_MODE=false
RECORD_MODE=false
BASELINE_MODE=false
HYPERFINE_MODE=false
VERSION_NAME="dev"
RUNS=3

for arg in "$@"; do
    case "$arg" in
        --quick) QUICK_MODE=true ;;
        --record) RECORD_MODE=true ;;
        --baseline) BASELINE_MODE=true ;;
        --hyperfine) HYPERFINE_MODE=true ;;
        --version=*) VERSION_NAME="${arg#--version=}" ;;
    esac
done

# ツールチェック
if $HYPERFINE_MODE && ! command -v hyperfine &> /dev/null; then
    echo "Error: hyperfine not found. Install with: brew install hyperfine" >&2
    exit 1
fi
if $RECORD_MODE && ! command -v yq &> /dev/null; then
    echo "Error: yq not found. Install with: brew install yq" >&2
    exit 1
fi

# ベンチマーク定義
BENCHMARKS=(fib30 sum_range map_filter string_ops data_transform)
OTHER_LANGS=(c cpp zig java clojure ruby python)

# ═══════════════════════════════════════════════════════════════════
# 計測関数
# ═══════════════════════════════════════════════════════════════════

median() {
    echo "$@" | tr ' ' '\n' | sort -n | sed -n '2p'
}

# 標準計測 (/usr/bin/time)
measure_time() {
    local cmd="$1"
    local times=()
    for _ in $(seq 1 $RUNS); do
        local t
        t=$( { /usr/bin/time -p sh -c "$cmd > /dev/null 2>&1" ; } 2>&1 | grep '^real' | awk '{print $2}' )
        times+=("$t")
    done
    median "${times[@]}"
}

measure_mem() {
    local cmd="$1"
    local mem_bytes
    mem_bytes=$( /usr/bin/time -l sh -c "$cmd > /dev/null 2>&1" 2>&1 | grep 'maximum resident set size' | awk '{print $1}' )
    printf "%.1f" "$(echo "scale=1; $mem_bytes / 1048576" | bc)"
}

# hyperfine 高精度計測
measure_hyperfine() {
    local cmd="$1"
    local tmpfile
    tmpfile=$(mktemp)
    hyperfine --warmup 2 --runs 5 --export-json "$tmpfile" "$cmd" >/dev/null 2>&1
    if command -v jq &> /dev/null; then
        jq -r '.results[0].mean' "$tmpfile"
    else
        grep -o '"mean": *[0-9.e+-]*' "$tmpfile" | head -1 | sed 's/.*: *//'
    fi
    rm -f "$tmpfile"
}

# 計測実行 (時間を秒で返す)
measure() {
    local cmd="$1"
    if $HYPERFINE_MODE; then
        measure_hyperfine "$cmd"
    else
        measure_time "$cmd"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# ビルド関数
# ═══════════════════════════════════════════════════════════════════

build_benchmark() {
    local bench="$1"
    local dir="$SCRIPT_DIR/$bench"

    # C
    [[ -f "$dir/fib.c" ]] && cc -O3 -o "$dir/bench_c" "$dir/fib.c" 2>/dev/null
    [[ -f "$dir/sum.c" ]] && cc -O3 -o "$dir/bench_c" "$dir/sum.c" 2>/dev/null
    [[ -f "$dir/main.c" ]] && cc -O3 -o "$dir/bench_c" "$dir/main.c" 2>/dev/null

    # C++
    [[ -f "$dir/fib.cpp" ]] && c++ -O3 -o "$dir/bench_cpp" "$dir/fib.cpp" 2>/dev/null
    [[ -f "$dir/sum.cpp" ]] && c++ -O3 -o "$dir/bench_cpp" "$dir/sum.cpp" 2>/dev/null
    [[ -f "$dir/main.cpp" ]] && c++ -O3 -o "$dir/bench_cpp" "$dir/main.cpp" 2>/dev/null

    # Zig
    for zigfile in "$dir"/*.zig; do
        [[ -f "$zigfile" ]] && zig build-exe -OReleaseFast "$zigfile" -femit-bin="$dir/bench_zig" 2>/dev/null && break
    done

    # Java
    for javafile in "$dir"/*.java; do
        [[ -f "$javafile" ]] && javac -d "$dir" "$javafile" 2>/dev/null && break
    done

    return 0
}

get_cmd() {
    local bench="$1"
    local lang="$2"
    local dir="$SCRIPT_DIR/$bench"

    case "$lang" in
        c) echo "$dir/bench_c" ;;
        cpp) echo "$dir/bench_cpp" ;;
        zig) echo "$dir/bench_zig" ;;
        java)
            local class
            class=$(basename "$dir"/*.java 2>/dev/null | head -1 | sed 's/.java$//')
            echo "java -cp $dir $class"
            ;;
        python)
            local py
            py=$(ls "$dir"/*.py 2>/dev/null | head -1)
            echo "python3 $py"
            ;;
        clojure)
            local clj
            clj=$(ls "$dir"/*.clj 2>/dev/null | head -1)
            echo "clojure -M $clj"
            ;;
        ruby)
            local rb
            rb=$(ls "$dir"/*.rb 2>/dev/null | head -1)
            echo "ruby $rb"
            ;;
        clojurewasmbeta)
            local clj
            clj=$(ls "$dir"/*.clj 2>/dev/null | head -1)
            echo "$PROJECT_DIR/zig-out/bin/ClojureWasmBeta --backend=vm $clj"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
# メイン処理
# ═══════════════════════════════════════════════════════════════════

echo "══════════════════════════════════════════════════════════════"
if $QUICK_MODE; then
    echo " ClojureWasmBeta ベンチマーク (quick mode)"
else
    echo " 全言語ベンチマーク"
fi
if $HYPERFINE_MODE; then
    echo " [hyperfine 高精度]"
else
    echo " [$RUNS runs 中央値]"
fi
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "環境: $(uname -m), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
echo "日付: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 結果格納用
declare -A RESULTS_CLJ_TIME
declare -A RESULTS_CLJ_MEM

for bench in "${BENCHMARKS[@]}"; do
    echo "─── $bench ───"
    build_benchmark "$bench"

    # 他言語 (--quick でなければ)
    if ! $QUICK_MODE; then
        for lang in "${OTHER_LANGS[@]}"; do
            cmd=$(get_cmd "$bench" "$lang")
            if [[ -n "$cmd" ]] && [[ -x "${cmd%% *}" || "$lang" == "python" || "$lang" == "ruby" || "$lang" == "java" || "$lang" == "clojure" ]]; then
                t=$(measure "$cmd")
                m=$(measure_mem "$cmd")
                if $HYPERFINE_MODE; then
                    t_ms=$(printf "%.2f" "$(echo "$t * 1000" | bc -l)")
                    printf "  %-10s %10s ms  %8s MB\n" "$lang" "$t_ms" "$m"
                else
                    printf "  %-10s %10ss  %8s MB\n" "$lang" "$t" "$m"
                fi
            fi
        done
        echo "  ──────────"
    fi

    # ClojureWasmBeta
    cmd=$(get_cmd "$bench" "clojurewasmbeta")
    t=$(measure "$cmd")
    m=$(measure_mem "$cmd")
    RESULTS_CLJ_TIME["$bench"]=$t
    RESULTS_CLJ_MEM["$bench"]=$m

    if $HYPERFINE_MODE; then
        t_ms=$(printf "%.2f" "$(echo "$t * 1000" | bc -l)")
        printf "  %-10s %10s ms  %8s MB  ← ClojureWasmBeta\n" "clj-wasm" "$t_ms" "$m"
    else
        printf "  %-10s %10ss  %8s MB  ← ClojureWasmBeta\n" "clj-wasm" "$t" "$m"
    fi
    echo ""
done

# ═══════════════════════════════════════════════════════════════════
# YAML 記録
# ═══════════════════════════════════════════════════════════════════

if $RECORD_MODE; then
    echo "──────────────────────────────────────────────────────────────"
    echo "結果を $YAML_FILE に追記中..."

    TODAY=$(date '+%Y-%m-%d')

    # 新しい履歴エントリを作成
    NEW_ENTRY=$(cat <<EOF
- date: $TODAY
  version: "$VERSION_NAME"
  build: ReleaseFast
  results:
    fib30: { time_s: ${RESULTS_CLJ_TIME[fib30]}, mem_mb: ${RESULTS_CLJ_MEM[fib30]} }
    sum_range: { time_s: ${RESULTS_CLJ_TIME[sum_range]}, mem_mb: ${RESULTS_CLJ_MEM[sum_range]} }
    map_filter: { time_s: ${RESULTS_CLJ_TIME[map_filter]}, mem_mb: ${RESULTS_CLJ_MEM[map_filter]} }
    string_ops: { time_s: ${RESULTS_CLJ_TIME[string_ops]}, mem_mb: ${RESULTS_CLJ_MEM[string_ops]} }
    data_transform: { time_s: ${RESULTS_CLJ_TIME[data_transform]}, mem_mb: ${RESULTS_CLJ_MEM[data_transform]} }
EOF
)

    # yq で history に追加
    echo "$NEW_ENTRY" | yq -i '.history += load("/dev/stdin")' "$YAML_FILE"

    echo "✓ 記録完了"
    echo ""
fi

# サマリー
echo "══════════════════════════════════════════════════════════════"
echo " ClojureWasmBeta サマリー"
echo "══════════════════════════════════════════════════════════════"
printf "  %-16s %10s  %10s\n" "ベンチマーク" "時間" "メモリ"
printf "  %-16s %10s  %10s\n" "────────────────" "──────────" "──────────"
for bench in "${BENCHMARKS[@]}"; do
    t="${RESULTS_CLJ_TIME[$bench]}"
    m="${RESULTS_CLJ_MEM[$bench]}"
    if $HYPERFINE_MODE; then
        t_disp=$(printf "%.2f ms" "$(echo "$t * 1000" | bc -l)")
    else
        t_disp="${t}s"
    fi
    printf "  %-16s %10s  %8s MB\n" "$bench" "$t_disp" "$m"
done
echo ""
