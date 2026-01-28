# 完了フェーズ履歴

> 各フェーズの完了サマリ。詳細な技術メモは `plan/notes.md` を参照。

---

## 機能実装フェーズ (Phase 1-26)

| Phase    | 内容                                                              |
|----------|-------------------------------------------------------------------|
| 1-4      | Reader, Runtime基盤, Analyzer, TreeWalk評価器                     |
| 5        | ユーザー定義関数 (fn, クロージャ)                                 |
| 6        | マクロシステム (defmacro)                                         |
| 7        | CLI (-e, 複数式, 状態保持)                                        |
| 8.0      | VM基盤 (Bytecode, Compiler, VM, --compare)                        |
| 8.1-8.20 | VM機能拡充 (クロージャ, HOF, 例外, Atom, マルチメソッド, プロトコル等) |
| 9-9.2    | LazySeq — 遅延シーケンス基盤, 遅延 map/filter/concat, 遅延ジェネレータ |
| 11-18b   | 組み込み関数大量追加 (delay/volatile/reduced/transient/transduce/atom拡張/var操作/階層/promise等) |
| 19a-19c  | struct/eval/read-string/sorted/dynamic-vars/NS操作/Reader/定義マクロ |
| 20       | FINAL — binding/chunk/regex/IO/NS/defrecord/deftype/動的Var       |
| 21       | GC — Mark-Sweep at Expression Boundary                            |
| 22       | 正規表現エンジン (フルスクラッチ Zig 実装)                        |
| 23       | 動的バインディング (本格実装)                                     |
| 24       | 名前空間 (本格実装)                                               |
| 25       | REPL (対話型シェル)                                               |
| 26       | Reader Conditionals + 外部ライブラリ統合テスト (medley v1.4.0)    |

## テストフェーズ (Phase T)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| T1    | Assert ベーステストランナー基盤                               |
| T2    | sci 関数カバレッジ監査 + コアテスト (372/390 pass = 95%)      |
| T3    | 最小 clojure.test 実装 (deftest/is/testing/run-tests)         |
| T4    | sci テストスイート移植 (55 テスト, 159 アサーション)           |
| T5    | テストカバレッジ拡充 (+55 テスト: protocols/documentation/namespaces) |

## 品質修正フェーズ (Phase Q)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| Q1a   | Special Form 正規化 eager 7関数 (apply/partial/comp/reduce/sort-by/group-by/swap!) |
| Q1b   | Special Form 正規化 lazy 5関数 (map/filter/take-while/drop-while/map-indexed) |
| Q1c   | 死コード削除 (12 Node/Opcode, -1,400行)                      |
| Q2a   | Map/Set リテラル in マクロ展開修正                            |
| Q2b   | fn-level recur 修正                                           |
| Q3    | Var システム修正 (def返値, #'var呼出, var-set, alter-var-root, defonce) |
| Q4a   | VM reduced 対応                                               |
| Q4b   | letfn 相互再帰修正                                            |
| Q5a   | with-out-str 実装 (threadlocal output capture)                |

## Wasm フェーズ (Phase LAST)

| Sub | 内容                              |
|-----|-----------------------------------|
| La  | zware 導入 + load + invoke (数値) |
| Lb  | メモリ操作 + 文字列 interop       |
| Lc  | ホスト関数注入 (Clojure→Wasm)     |
| Ld  | WASI 基本サポート                 |
| Le  | エラー改善 + wasm/close + ドキュメント |

## リファクタリングフェーズ (Phase R)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| R1    | core.zig ファイル分割 (11,095行 → 18 サブモジュール + facade) |
| R2    | value.zig 分割 (facade + 3 サブモジュール)                    |
| R3a   | builtin レジストリ comptime 検証 (重複2件修正)                |
| R3b   | @branchHint(.cold) 適用 (vm/evaluator/arithmetic のエラーパス) |
| R4    | テスト整理 (命名規約統一, verbose オプション, clj-kondo 設定) |
| R5    | 不要ファイル・死コードクリーンアップ (-185行)                 |
| R6    | Wasm ローダー重複排除 (loadModuleCore 共通ヘルパー)           |

## 高速化フェーズ (Phase P)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| P1    | ベンチマーク基盤整備 (time マクロ, run_bench.sh)              |
| P2a   | VM 低侵襲最適化 (findArity fast path 等, 速度効果なし)        |
| P2b   | VM フレームインライン化 (execute 再帰排除, 速度効果なし)      |
| P2c   | PersistentMap ハッシュインデックス (O(n)→O(log n), ~7%改善)   |
| P3    | 定数畳み込み (算術・比較演算の Analyzer 段階事前計算)         |

## GC フェーズ (Phase G)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| G1a   | GC 計測基盤 (--gc-stats, 累計統計)                            |
| G1b   | mark/sweep 時間計測 (sweep が GC 停止の 99.9%)                |
| G1c   | セミスペース Arena GC (sweep 1,146ms → 29ms, ~40x 高速化)    |
| G2a-c | 世代別 GC 基盤 (Nursery bump allocator + minor GC + promotion) |

## UX フェーズ (Phase U)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| U1    | REPL readline/履歴 (自前実装, Emacs ショートカット対応)        |
| U2a   | エラーメッセージ改善 (babashka 風フォーマット)                 |
| U2b   | ソース位置表示 (file:line:column)                             |
| U2c   | スタックトレース表示 (TreeWalk + VM 両対応)                   |
| U2d   | 周辺ソースコード表示 (エラー行の前後2行 + ポインタ)           |
| U3    | doc/dir/find-doc/apropos                                      |
| U4a   | map/set/symbol を関数として呼び出し                           |
| U4b   | doc/arglists ダングリングポインタ修正                         |
| U4c   | thread-bound? 多引数対応                                      |
| U4d   | ^:private / defn- メタデータ対応                              |
| U4e   | VM クロージャキャプチャ修正                                   |
| U4f   | 多段ネストクロージャの capture_count 修正                     |
| U4g   | add-watch/remove-watch 完全実装 (Atom + Var)                  |
| U5a   | ファイル直接実行オプション                                    |
| U5b   | バイトコードダンプモード                                      |
| U6    | nREPL サーバー (CIDER/Calva/Conjure 互換)                     |

## セルフホストフェーズ (Phase S)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| S1a   | clojure.string (19 関数)                                      |
| S1b   | clojure.set (11 関数)                                         |
| S1c   | clojure.string 完全化 + clojure.walk (7 関数)                 |
| S1d   | clojure.edn (read-string)                                     |
| S1e   | clojure.math (33 数学関数)                                    |
| S1f   | clojure.repl (find-doc/apropos/source/pst)                    |
| S1g   | clojure.data (diff)                                           |
| S1h   | clojure.stacktrace (print-stack-trace 等)                     |
| S1i   | clojure.template (apply-template/do-template)                 |
| S1j   | clojure.zip (zipper ツリー操作)                               |

## リファクタリング追加 (Phase R7)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| R7    | Zig イディオム改善 — WasmModule anyopaque→zware具体型, valueHash switch 改善 |

## ドキュメントフェーズ (Phase D)

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| D1    | presentation.md — shibuya.lisp 発表用 (15分+デモ, ベンチ結果) |
| D2    | getting_started.md — 利用者向け導入ガイド                     |
| D3    | developer_guide.md — 開発者向け技術ガイド                     |

## ベンチマーク基盤

| Phase | 内容                                                          |
|-------|---------------------------------------------------------------|
| Bench | fib(38) 全言語比較基盤 (C/C++/Zig/Java/Python/Ruby/ClojureWasmBeta) |
