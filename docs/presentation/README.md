# 発表資料 — Shibuya.lisp #117

## スライド・ノート

| ファイル              | 内容                                        |
|-----------------------|---------------------------------------------|
| `index_15min.md`      | 15分発表用スライド                          |
| `index_full.md`       | 完全版 (参照資料、Q&A対応用)                |
| `speaker_15min.md`    | スピーカーノート (操作手順・チェックリスト) |
| `rehearsal_script.md` | 通し練習台本 (声に出して読む用)             |
| `qa_cheatsheet.md`    | Q&A 緊急リファレンス + ソースコード参照     |

## デモファイル

| ファイル                   | 内容                        |
|----------------------------|-----------------------------|
| `demo/01_basics.clj`       | REPL基本 + 遅延シーケンス   |
| `demo/02_protocols.clj`    | プロトコル + マルチメソッド |
| `demo/03_macros_atoms.clj` | マクロ + アトム             |
| `demo/04_wasm.clj`         | Wasm 基本連携               |
| `demo/05_wasm_host.clj`    | ホスト関数注入              |
| `demo/06_go_wasm.clj`      | Go → Wasm 連携 (TinyGo)     |

## Go Wasm ソース

| ファイル                             | 内容                         |
|--------------------------------------|------------------------------|
| `test/wasm/src/go_math.go`           | Go ソース (add/multiply/fib) |
| `test/wasm/fixtures/08_go_math.wasm` | TinyGo コンパイル済み (20KB) |
