#!/bin/bash
# audit_sci_coverage.sh — sci 関数カバレッジ監査
# sci の clojure.core 関数と ClojureWasmBeta の vars.yaml を照合し差分を出力

set -euo pipefail
cd "$(dirname "$0")/.."

SCI_NS="/Users/shota.508/Documents/OSS/sci/src/sci/impl/namespaces.cljc"
VARS_YAML="status/vars.yaml"

echo "=== sci 関数カバレッジ監査 ==="
echo ""

# sci から関数名抽出 (clojure-core def 内の 'symbol-name パターン)
# macOS grep は -P 非対応なので sed で抽出
sed -n "1135,1776p" "$SCI_NS" \
  | sed -n "s/.*'\\([a-zA-Z*!?<>=+/][a-zA-Z0-9*!?<>=+_./'~&@-]*\\).*/\\1/p" \
  | sort -u > /tmp/sci_funcs.txt

# vars.yaml から done 関数抽出
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | .[].key' "$VARS_YAML" \
  | sort -u > /tmp/wasm_done.txt

# vars.yaml から skip 関数抽出
yq '.vars.clojure_core | to_entries | map(select(.value.status == "skip")) | .[].key' "$VARS_YAML" \
  | sort -u > /tmp/wasm_skip.txt

# 全 vars.yaml 関数
cat /tmp/wasm_done.txt /tmp/wasm_skip.txt | sort -u > /tmp/wasm_all.txt

SCI_COUNT=$(wc -l < /tmp/sci_funcs.txt | tr -d ' ')
WASM_DONE=$(wc -l < /tmp/wasm_done.txt | tr -d ' ')
WASM_SKIP=$(wc -l < /tmp/wasm_skip.txt | tr -d ' ')

echo "sci 関数数:          $SCI_COUNT"
echo "ClojureWasm done:    $WASM_DONE"
echo "ClojureWasm skip:    $WASM_SKIP"
echo ""

# sci にあって ClojureWasm にない関数
comm -23 /tmp/sci_funcs.txt /tmp/wasm_all.txt > /tmp/missing.txt
MISSING=$(wc -l < /tmp/missing.txt | tr -d ' ')
echo "=== sci にあって ClojureWasm にない関数: $MISSING ==="
if [ "$MISSING" -gt 0 ]; then
  cat /tmp/missing.txt
fi

echo ""

# ClojureWasm にあって sci にない関数
comm -13 /tmp/sci_funcs.txt /tmp/wasm_done.txt > /tmp/extra.txt
EXTRA=$(wc -l < /tmp/extra.txt | tr -d ' ')
echo "=== ClojureWasm 独自実装: $EXTRA ==="
if [ "$EXTRA" -gt 0 ] && [ "$EXTRA" -le 50 ]; then
  cat /tmp/extra.txt
fi

echo ""

# 共通関数
comm -12 /tmp/sci_funcs.txt /tmp/wasm_done.txt > /tmp/common.txt
COMMON=$(wc -l < /tmp/common.txt | tr -d ' ')
echo "=== 共通 (done): $COMMON ==="
echo "カバレッジ率: $(echo "scale=1; $COMMON * 100 / $SCI_COUNT" | bc)%"
