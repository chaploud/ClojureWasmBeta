#!/bin/bash
# ClojureWasmBeta warm benchmark
# nREPL 経由で warm-up 後の純粋な計算時間を計測する。
#
# 前提: ClojureWasmBeta nREPL サーバー (--backend=vm) が指定ポートで起動済み
#
# 使い方:
#   bash bench/cwb_warm_bench.sh [port]
#
# 出力形式 (1行/ベンチ):
#   <bench_name>=<ナノ秒>

set -uo pipefail

PORT="${1:-7891}"

eval_nrepl() {
    clj-nrepl-eval -p "$PORT" --timeout 30000 "$1" 2>/dev/null
}

# nREPL 出力 ("=> 12345\n...") から最初の数値を抽出
extract_ns() {
    grep -oE '^=> [0-9]+' | head -1 | awk '{print $2}'
}

# ── 各ベンチの「定義」と「計測対象式」──
declare -A BENCH_SETUP
declare -A BENCH_EXPR

BENCH_SETUP[fib30]='(defn fib [n] (if (<= n 1) n (+ (fib (- n 1)) (fib (- n 2)))))'
BENCH_EXPR[fib30]='(fib 30)'

BENCH_SETUP[sum_range]=''
BENCH_EXPR[sum_range]='(reduce + (range 1000000))'

BENCH_SETUP[map_filter]=''
BENCH_EXPR[map_filter]='(->> (range 100000) (filter odd?) (map (fn [x] (* x x))) (take 10000) (reduce +))'

BENCH_SETUP[string_ops]='(require (quote [clojure.string :as str]))'
BENCH_EXPR[string_ops]='(count (apply str (map (fn [x] (str/upper-case (str "item-" x))) (range 10000))))'

BENCH_SETUP[data_transform]=''
BENCH_EXPR[data_transform]='(count (map (fn [m] (assoc m :doubled (* 2 (:value m)))) (map (fn [i] {:id i :value i}) (range 10000))))'

BENCHMARKS=(fib30 sum_range map_filter string_ops data_transform)

for bench in "${BENCHMARKS[@]}"; do
    setup="${BENCH_SETUP[$bench]}"
    expr="${BENCH_EXPR[$bench]}"

    # セットアップ (関数定義等)
    if [[ -n "$setup" ]]; then
        eval_nrepl "$setup" >/dev/null || true
    fi

    # warm-up 3回
    for _ in 1 2 3; do
        eval_nrepl "$expr" >/dev/null || true
    done

    # 計測 5回: System/nanoTime でナノ秒差分を取得
    ns_values=()
    for _ in 1 2 3 4 5; do
        ns=$(eval_nrepl "(let [t0 (System/nanoTime)] $expr (- (System/nanoTime) t0))" 2>/dev/null | extract_ns || true)
        [[ -n "$ns" ]] && ns_values+=("$ns")
    done

    # 中央値 (ソートして3番目)
    if [[ ${#ns_values[@]} -ge 5 ]]; then
        median=$(printf '%s\n' "${ns_values[@]}" | sort -n | sed -n '3p')
        echo "${bench}=${median}"
    elif [[ ${#ns_values[@]} -ge 1 ]]; then
        # 一部成功時は最小値
        minval=$(printf '%s\n' "${ns_values[@]}" | sort -n | head -1)
        echo "${bench}=${minval}"
    else
        # System/nanoTime ラッパーでクラッシュする場合: シェル側壁時計で計測
        # (nREPL の通信オーバーヘッド含むので precision は低い)
        ns_wall_values=()
        for _ in 1 2 3 4 5; do
            t0=$(python3 -c 'import time; print(int(time.time_ns()))')
            eval_nrepl "$expr" >/dev/null 2>&1 || true
            t1=$(python3 -c 'import time; print(int(time.time_ns()))')
            ns_wall_values+=("$((t1 - t0))")
        done
        median=$(printf '%s\n' "${ns_wall_values[@]}" | sort -n | sed -n '3p')
        echo "${bench}=${median} (wall-clock)"
    fi
done
