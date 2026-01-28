#!/bin/bash
# fib(30) ベンチマーク — 全言語比較
# fib(30) は ClojureWasmBeta で 152秒かかるため fib(30) を採用
# 使い方: bash bench/run_bench.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNS=5

echo "=========================================="
echo " fib(30) ベンチマーク"
echo "=========================================="
echo ""
echo "--- 環境情報 ---"
echo "OS:  $(uname -s) $(uname -r) ($(uname -m))"
echo "CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
echo "RAM: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 )) GB"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 中央値を計算 (5個の値からソートして3番目)
median() {
    echo "$@" | tr ' ' '\n' | sort -n | sed -n '3p'
}

# 実行時間計測 (秒, 小数点3桁)
measure_time() {
    local cmd="$1"
    local times=()
    for i in $(seq 1 $RUNS); do
        local t
        t=$( { /usr/bin/time -p sh -c "$cmd > /dev/null 2>&1" ; } 2>&1 | grep '^real' | awk '{print $2}' )
        times+=("$t")
    done
    median "${times[@]}"
}

# メモリ計測 (KB → MB)
measure_memory() {
    local cmd="$1"
    local mem_bytes
    mem_bytes=$( /usr/bin/time -l sh -c "$cmd > /dev/null 2>&1" 2>&1 | grep 'maximum resident set size' | awk '{print $1}' )
    echo "scale=1; $mem_bytes / 1048576" | bc
}

# 結果格納
declare -A LANG_TIME LANG_MEM LANG_VER

echo "--- ビルド ---"

# C
echo -n "C:   ビルド中... "
cc -O3 -o "$SCRIPT_DIR/fib_c" "$SCRIPT_DIR/fib.c"
LANG_VER[C]="$(cc --version 2>&1 | head -1)"
echo "OK"

# C++
echo -n "C++: ビルド中... "
c++ -O3 -o "$SCRIPT_DIR/fib_cpp" "$SCRIPT_DIR/fib.cpp"
LANG_VER[Cpp]="$(c++ --version 2>&1 | head -1)"
echo "OK"

# Java
echo -n "Java: ビルド中... "
javac "$SCRIPT_DIR/Fib.java"
LANG_VER[Java]="$(java --version 2>&1 | head -1)"
echo "OK"

# Zig
echo -n "Zig: ビルド中... "
(cd "$SCRIPT_DIR" && zig build-exe -OReleaseFast fib.zig -femit-bin=fib_zig 2>/dev/null)
LANG_VER[Zig]="Zig $(zig version)"
echo "OK"

# Python
LANG_VER[Python]="$(python3 --version)"

# Ruby
LANG_VER[Ruby]="$(ruby --version | awk '{print $1, $2}')"

# ClojureWasmBeta — ReleaseFast ビルド
echo -n "ClojureWasmBeta: ビルド確認中... "
CLJ_WASM="$PROJECT_DIR/zig-out/bin/ClojureWasmBeta"
if [ ! -f "$CLJ_WASM" ]; then
    echo "バイナリが見つかりません。zig build -Doptimize=ReleaseFast を実行してください。"
    exit 1
fi
LANG_VER[ClojureWasmBeta]="ClojureWasmBeta (Zig $(zig version), VM)"
echo "OK"

echo ""
echo "--- 計測中 ($RUNS 回の中央値) ---"

# C
echo -n "C:   "
LANG_TIME[C]=$(measure_time "$SCRIPT_DIR/fib_c")
LANG_MEM[C]=$(measure_memory "$SCRIPT_DIR/fib_c")
echo "${LANG_TIME[C]}s / ${LANG_MEM[C]} MB"

# C++
echo -n "C++: "
LANG_TIME[Cpp]=$(measure_time "$SCRIPT_DIR/fib_cpp")
LANG_MEM[Cpp]=$(measure_memory "$SCRIPT_DIR/fib_cpp")
echo "${LANG_TIME[Cpp]}s / ${LANG_MEM[Cpp]} MB"

# Zig
echo -n "Zig: "
LANG_TIME[Zig]=$(measure_time "$SCRIPT_DIR/fib_zig")
LANG_MEM[Zig]=$(measure_memory "$SCRIPT_DIR/fib_zig")
echo "${LANG_TIME[Zig]}s / ${LANG_MEM[Zig]} MB"

# Java
echo -n "Java: "
LANG_TIME[Java]=$(measure_time "java -cp $SCRIPT_DIR Fib")
LANG_MEM[Java]=$(measure_memory "java -cp $SCRIPT_DIR Fib")
echo "${LANG_TIME[Java]}s / ${LANG_MEM[Java]} MB"

# Ruby (YJIT)
echo -n "Ruby: "
LANG_TIME[Ruby]=$(measure_time "ruby --yjit $SCRIPT_DIR/fib.rb")
LANG_MEM[Ruby]=$(measure_memory "ruby --yjit $SCRIPT_DIR/fib.rb")
echo "${LANG_TIME[Ruby]}s / ${LANG_MEM[Ruby]} MB"

# ClojureWasmBeta
echo -n "ClojureWasmBeta: "
LANG_TIME[ClojureWasmBeta]=$(measure_time "$CLJ_WASM $SCRIPT_DIR/fib.clj")
LANG_MEM[ClojureWasmBeta]=$(measure_memory "$CLJ_WASM $SCRIPT_DIR/fib.clj")
echo "${LANG_TIME[ClojureWasmBeta]}s / ${LANG_MEM[ClojureWasmBeta]} MB"

# Python (最後 — 遅い)
echo -n "Python: "
LANG_TIME[Python]=$(measure_time "python3 $SCRIPT_DIR/fib.py")
LANG_MEM[Python]=$(measure_memory "python3 $SCRIPT_DIR/fib.py")
echo "${LANG_TIME[Python]}s / ${LANG_MEM[Python]} MB"

echo ""
echo "=========================================="
echo " 結果サマリ: fib(30) — 中央値 ($RUNS runs)"
echo "=========================================="
echo ""
printf "%-20s %-12s %-10s %s\n" "言語" "時間(s)" "メモリ(MB)" "バージョン"
printf "%-20s %-12s %-10s %s\n" "----" "-------" "---------" "----------"
for lang in C Cpp Zig Java Ruby ClojureWasmBeta Python; do
    name="$lang"
    [ "$lang" = "Cpp" ] && name="C++"
    printf "%-20s %-12s %-10s %s\n" "$name" "${LANG_TIME[$lang]}" "${LANG_MEM[$lang]}" "${LANG_VER[$lang]}"
done
echo ""

# クリーンアップ
rm -f "$SCRIPT_DIR/fib_c" "$SCRIPT_DIR/fib_cpp" "$SCRIPT_DIR/fib_zig" "$SCRIPT_DIR/Fib.class"
rm -rf "$SCRIPT_DIR/fib_zig.o" "$SCRIPT_DIR/.zig-cache"

echo "クリーンアップ完了"
