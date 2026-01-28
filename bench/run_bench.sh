#!/bin/bash
# 全言語・全ベンチマーク計測スクリプト
# 使い方: bash bench/run_bench.sh [--yaml]
#   --yaml: YAML フォーマットで出力 (status/bench.yaml への転記用)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNS=3
YAML_MODE=false

[[ "${1:-}" == "--yaml" ]] && YAML_MODE=true

# --- ヘルパー関数 ---

median() {
    echo "$@" | tr ' ' '\n' | sort -n | sed -n '2p'
}

measure() {
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
    echo "scale=1; $mem_bytes / 1048576" | bc
}

# --- ビルド ---

build_c() {
    local bench=$1
    local src="$SCRIPT_DIR/$bench/${bench%30}.c"
    [[ "$bench" == "fib30" ]] && src="$SCRIPT_DIR/$bench/fib.c"
    local out="$SCRIPT_DIR/$bench/bench_c"
    cc -O3 -o "$out" "$src" 2>/dev/null
    echo "$out"
}

build_cpp() {
    local bench=$1
    local src="$SCRIPT_DIR/$bench/${bench%30}.cpp"
    [[ "$bench" == "fib30" ]] && src="$SCRIPT_DIR/$bench/fib.cpp"
    local out="$SCRIPT_DIR/$bench/bench_cpp"
    c++ -O3 -o "$out" "$src" 2>/dev/null
    echo "$out"
}

build_zig() {
    local bench=$1
    local src="$SCRIPT_DIR/$bench/${bench%30}.zig"
    [[ "$bench" == "fib30" ]] && src="$SCRIPT_DIR/$bench/fib.zig"
    local out="$SCRIPT_DIR/$bench/bench_zig"
    (cd "$SCRIPT_DIR/$bench" && zig build-exe -OReleaseFast "$(basename "$src")" -femit-bin=bench_zig 2>/dev/null)
    echo "$out"
}

build_java() {
    local bench=$1
    local class_name
    case "$bench" in
        fib30) class_name="Fib" ;;
        sum_range) class_name="SumRange" ;;
        map_filter) class_name="MapFilter" ;;
        string_ops) class_name="StringOps" ;;
        data_transform) class_name="DataTransform" ;;
    esac
    javac "$SCRIPT_DIR/$bench/$class_name.java" 2>/dev/null
    echo "java -cp $SCRIPT_DIR/$bench $class_name"
}

run_py() {
    local bench=$1
    local src="$SCRIPT_DIR/$bench/${bench%30}.py"
    [[ "$bench" == "fib30" ]] && src="$SCRIPT_DIR/$bench/fib.py"
    echo "python3 $src"
}

run_rb() {
    local bench=$1
    local src="$SCRIPT_DIR/$bench/${bench%30}.rb"
    [[ "$bench" == "fib30" ]] && src="$SCRIPT_DIR/$bench/fib.rb"
    echo "ruby --yjit $src"
}

run_clj() {
    local bench=$1
    local src="$SCRIPT_DIR/$bench/${bench%30}.clj"
    [[ "$bench" == "fib30" ]] && src="$SCRIPT_DIR/$bench/fib.clj"
    echo "$PROJECT_DIR/zig-out/bin/ClojureWasmBeta $src"
}

# --- メイン ---

BENCHMARKS=(fib30 sum_range map_filter string_ops data_transform)
LANGUAGES=(c cpp zig java ruby python clojurewasmbeta)

if ! $YAML_MODE; then
    echo "=========================================="
    echo " 全言語ベンチマーク ($RUNS runs 中央値)"
    echo "=========================================="
    echo ""
    echo "環境: $(uname -m), $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    echo "日付: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
fi

# 結果格納用連想配列
declare -A RESULTS_TIME RESULTS_MEM

for bench in "${BENCHMARKS[@]}"; do
    if ! $YAML_MODE; then
        echo "--- $bench ---"
    fi

    # ビルド (C/C++/Zig/Java)
    C_BIN=$(build_c "$bench")
    CPP_BIN=$(build_cpp "$bench")
    ZIG_BIN=$(build_zig "$bench")
    JAVA_CMD=$(build_java "$bench")
    PY_CMD=$(run_py "$bench")
    RB_CMD=$(run_rb "$bench")
    CLJ_CMD=$(run_clj "$bench")

    # 計測
    for lang in "${LANGUAGES[@]}"; do
        case "$lang" in
            c) cmd="$C_BIN" ;;
            cpp) cmd="$CPP_BIN" ;;
            zig) cmd="$ZIG_BIN" ;;
            java) cmd="$JAVA_CMD" ;;
            python) cmd="$PY_CMD" ;;
            ruby) cmd="$RB_CMD" ;;
            clojurewasmbeta) cmd="$CLJ_CMD" ;;
        esac

        t=$(measure "$cmd")
        m=$(measure_mem "$cmd")
        RESULTS_TIME["${bench}_${lang}"]=$t
        RESULTS_MEM["${bench}_${lang}"]=$m

        if ! $YAML_MODE; then
            printf "  %-16s %6ss / %7s MB\n" "$lang" "$t" "$m"
        fi
    done

    # クリーンアップ
    rm -f "$SCRIPT_DIR/$bench/bench_c" "$SCRIPT_DIR/$bench/bench_cpp" "$SCRIPT_DIR/$bench/bench_zig"
    rm -f "$SCRIPT_DIR/$bench"/*.class
    rm -rf "$SCRIPT_DIR/$bench/.zig-cache" "$SCRIPT_DIR/$bench/bench_zig.o"
done

# YAML 出力
if $YAML_MODE; then
    echo "# 計測日: $(date '+%Y-%m-%d')"
    echo ""
    echo "baseline:"
    echo "  date: $(date '+%Y-%m-%d')"
    echo "  languages:"
    for lang in c cpp zig java ruby python; do
        echo "    $lang:"
        for bench in "${BENCHMARKS[@]}"; do
            t=${RESULTS_TIME["${bench}_${lang}"]}
            m=${RESULTS_MEM["${bench}_${lang}"]}
            echo "      $bench: { time_s: $t, mem_mb: $m }"
        done
    done
    echo ""
    echo "# ClojureWasmBeta"
    echo "history:"
    echo "  - date: $(date '+%Y-%m-%d')"
    echo "    version: \"TODO\""
    echo "    build: ReleaseFast"
    echo "    results:"
    for bench in "${BENCHMARKS[@]}"; do
        t=${RESULTS_TIME["${bench}_clojurewasmbeta"]}
        m=${RESULTS_MEM["${bench}_clojurewasmbeta"]}
        echo "      $bench: { time_s: $t, mem_mb: $m }"
    done
fi
