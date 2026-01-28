#!/bin/bash
# run_tests.sh — Clojure 互換性テストランナー
# 使い方: bash test/run_tests.sh [オプション] [テストファイル...]
#   引数なし: test/compat/**/*.clj を全実行
#   引数あり: 指定ファイルのみ実行
#   -v, --verbose: クラッシュ時に出力全体を表示
#
# 出力フォーマット対応:
#   test_runner.clj: "PASS: N, FAIL: M, ERROR: K"
#   clojure/test.clj: "N passed, M failed, K errors"

set -uo pipefail
cd "$(dirname "$0")/.."

VERBOSE=0

BIN="./zig-out/bin/ClojureWasmBeta"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_ERROR=0
FAILED_FILES=()

# ビルド確認
if [ ! -f "$BIN" ]; then
  echo "=== ビルド中... ==="
  zig build 2>&1
  if [ $? -ne 0 ]; then
    echo "ERROR: ビルド失敗"
    exit 1
  fi
fi

# オプション解析
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# テストファイル収集
if [ $# -gt 0 ]; then
  TEST_FILES=("$@")
else
  # test/compat/*.clj + test/compat/**/*.clj (サブディレクトリ含む)
  TEST_FILES=()
  while IFS= read -r -d '' f; do
    TEST_FILES+=("$f")
  done < <(find test/compat -name '*.clj' -print0 | sort -z)
fi

echo "=== Clojure 互換性テスト ==="
echo ""

for f in "${TEST_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "SKIP: $f (not found)"
    continue
  fi

  # テスト実行 — 出力からレポート行を抽出
  OUTPUT=$("$BIN" -e "(load-file \"$f\")" 2>&1) || true

  # 表示名: test/compat/ 以下の相対パスから .clj を除去
  NAME=${f#test/compat/}
  NAME=${NAME%.clj}

  # フォーマット1: test_runner.clj — "PASS: N, FAIL: M, ERROR: K"
  REPORT_LINE=$(echo "$OUTPUT" | grep -E "^PASS:" | tail -1 || true)
  # フォーマット2: clojure/test.clj — "N passed, M failed, K errors"
  CT_LINE=$(echo "$OUTPUT" | grep -E "^[0-9]+ passed," | tail -1 || true)

  if [ -n "$REPORT_LINE" ]; then
    PASS=$(echo "$REPORT_LINE" | sed -E 's/PASS: ([0-9]+).*/\1/')
    FAIL=$(echo "$REPORT_LINE" | sed -E 's/.*FAIL: ([0-9]+).*/\1/')
    ERROR=$(echo "$REPORT_LINE" | sed -E 's/.*ERROR: ([0-9]+).*/\1/')

    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    TOTAL_ERROR=$((TOTAL_ERROR + ERROR))

    FILE_TOTAL=$((PASS + FAIL + ERROR))
    echo "  [$NAME] $PASS/$FILE_TOTAL pass ($FAIL fail, $ERROR error)"

    # FAIL 行を表示
    FAIL_LINES=$(echo "$OUTPUT" | grep -E "^  (FAIL|ERROR):" || true)
    if [ -n "$FAIL_LINES" ]; then
      echo "$FAIL_LINES"
      FAILED_FILES+=("$f")
    fi
  elif [ -n "$CT_LINE" ]; then
    # "123 passed, 0 failed, 0 errors"
    PASS=$(echo "$CT_LINE" | sed -E 's/([0-9]+) passed.*/\1/')
    FAIL=$(echo "$CT_LINE" | sed -E 's/.*passed, ([0-9]+) failed.*/\1/')
    ERROR=$(echo "$CT_LINE" | sed -E 's/.*failed, ([0-9]+) errors.*/\1/')

    TOTAL_PASS=$((TOTAL_PASS + PASS))
    TOTAL_FAIL=$((TOTAL_FAIL + FAIL))
    TOTAL_ERROR=$((TOTAL_ERROR + ERROR))

    FILE_TOTAL=$((PASS + FAIL + ERROR))
    echo "  [$NAME] $PASS/$FILE_TOTAL pass ($FAIL fail, $ERROR error)"

    # FAIL 行を表示
    FAIL_LINES=$(echo "$OUTPUT" | grep -E "^  (FAIL|ERROR) in " || true)
    if [ -n "$FAIL_LINES" ]; then
      echo "$FAIL_LINES"
      FAILED_FILES+=("$f")
    fi
  else
    # レポート行なし = クラッシュ
    ERROR_MSG=$(echo "$OUTPUT" | grep -E "^Error:" | head -1 || true)
    echo "  [$NAME] CRASH: ${ERROR_MSG:-unknown error}"
    if [ "$VERBOSE" -eq 1 ]; then
      echo "    --- output ---"
      echo "$OUTPUT" | sed 's/^/    /'
      echo "    --- end ---"
    fi
    TOTAL_ERROR=$((TOTAL_ERROR + 1))
    FAILED_FILES+=("$f")
  fi
done

echo ""
echo "=== 結果 ==="
TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_ERROR))
echo "TOTAL: $TOTAL_PASS pass, $TOTAL_FAIL fail, $TOTAL_ERROR error (total: $TOTAL)"

if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo ""
  echo "失敗ファイル:"
  for f in "${FAILED_FILES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

exit 0
