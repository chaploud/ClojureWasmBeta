# セッションメモ

> 現在地点・次回タスク。技術ノートは `plan/notes.md`、完了履歴は `docs/changelog.md` を参照。

---

## 現在地点

**ポスト実装フェーズ — リファクタリング・高速化・安定化**

全機能実装フェーズ (Phase 1-LAST) + ポスト実装フェーズ (R/P/G/U/S) が完了。

### プロジェクト指標

| 指標                  | 値                                     |
|-----------------------|----------------------------------------|
| テスト                | 1036 pass / 1 fail (意図的)            |
| clojure.core 実装状況 | 545 done / 169 skip                    |
| Zig ソースコード      | ~38,000 行 (src/ 以下)                 |
| デュアルバックエンド  | TreeWalk + BytecodeVM                  |
| GC                    | セミスペース Arena Mark-Sweep (式境界) |
| Wasm                  | zware (10 API 関数)                    |
| 標準 NS               | string/set/walk/edn/math/repl/data/stacktrace/template/zip/test/pprint |
| nREPL                 | CIDER/Calva/Conjure 互換              |

### 直近の完了

- **Java Interop**: System/nanoTime, System/currentTimeMillis 実装 + tryJavaInterop namespace 対応修正
- **clojure.string**: Zig builtin を clojure.string NS に直接登録 (core から移動、nREPL バグ修正)
- **Bench**: cwb_warm_bench.sh — nREPL 経由 warm ベンチマーク追加
- **P1c**: fused reduce — map_filter 27GB→2MB, sum_range 401MB→2MB, ジェネレータ直接ルーティング
- **P1c**: VM ベンチ標準化 — run_bench.sh で --backend=vm をデフォルト化
- **P1b**: 遅延 take/reduce — lazy-seq の遅延イテレーション実装 (collectToSlice 回避)
- **BUG**: load-file バックエンド — defs.current_backend でバックエンド統一
- **P1a**: Safe Point GC — recur/call で GC チェック (VM 実行中)
- **P3**: 定数畳み込み — Analyzer で算術・比較演算の定数畳み込み
- **G2a-c**: 世代別 GC 基盤 — Nursery bump allocator + minor GC + promotion 実装
- **S1**: clojure.pprint — pprint, print-table, cl-format (最小限) 実装
- **U4**: 既知バグ修正 — `^:const` インライン化, `with-local-vars` 実装, `defmacro in defn` エラーメッセージ改善
- **R7**: Zig イディオム改善 — WasmModule anyopaque → zware 具体型, valueHash switch 改善
- **D1-D3**: ドキュメント — presentation.md, getting_started.md, developer_guide.md
- **Bench**: 7言語×5ベンチマーク比較基盤 (`bash bench/run_bench.sh --quick --record`)

---

## 実行計画 (対応順)

以下の順序でタスクを実行する。セッション開始時はここを参照し、未完了の最初のタスクから着手すること。

**パフォーマンス系タスク (P3, G2) では必ずベンチマーク計測:**
```bash
# タスク開始前 — ベースライン確認
bash bench/run_bench.sh --quick

# タスク完了後 — 効果を記録 (必須)
bash bench/run_bench.sh --quick --record --version="P3 NaN boxing"
```

| #   | Phase | タスク                | 状態     | 備考                                      |
|-----|-------|----------------------|----------|-------------------------------------------|
| 1   | U4    | 既知バグ修正         | 完了     | ^:const, with-local-vars, defmacro in defn |
| 2   | S1    | clojure.pprint       | 完了     | pprint, print-table, cl-format (最小限)    |
| 3   | P0a   | TW vs VM 比較        | 完了     | 同等速度。両者のボトルネックが同じ (builtin call) |
| 4   | P0b   | --profile フラグ     | 完了     | Reader/Analyzer/Engine/Realize の時間計測可能 |
| 5   | P3    | TW 高速算術          | 完了     | fib30: 1.66s→0.92s (45% 改善)             |
| 6   | P3    | VM 算術 opcode 化    | 完了     | VM: fib30 65ms (TW 811ms の 12倍高速)     |
| 7   | BUG   | VM defn 再帰バグ     | 修正済   | closure作成時に自己参照をbindingsに追加    |
| 8   | BUG   | named fn スロット不整合 | 修正済  | let+named fn のキャプチャスロット計算修正  |
| 9   | BUG   | テストVM検証漏れ     | 修正済   | strict_vm_check=true で厳格検証            |
| 10  | BUG   | load-file バックエンド | 修正済   | defs.current_backend でバックエンド統一   |
| 11  | P1a   | Safe Point GC        | 完了     | recur/call で GC チェック、lazy seq は別対応 |
| 12  | P3    | NaN boxing           | 保留     | 大規模変更、事前に設計文書が必要           |
| 7   | G2a-c | 世代別 GC 基盤       | 完了     | Nursery bump allocator + minor GC + promotion |
| 8   | G2d-e | 世代別 GC 統合       | 保留     | 式境界GCでは効果限定的、ベンチ確認後に検討 |
| 9   | P3    | inline caching       | 保留     | VM 既に最適化済み (tryInlineCall)、効果限定 |
| 10  | P3    | 定数畳み込み         | 完了     | Analyzer で算術・比較演算の定数畳み込み    |
| 11  | P3    | tail call dispatch   | 保留     | Zig では実現困難、効果限定的               |
| 12  | P1b   | 遅延 take/reduce     | 完了     | LazySeq.Take 追加、遅延イテレーション実装  |
| 13  | P1c   | fused reduce         | 完了     | map_filter 27GB→2MB、sum_range 401MB→2MB   |
| 14  | P1c   | VM ベンチ標準化      | 完了     | run_bench.sh を --backend=vm に変更        |

### スコープ外 (将来検討)

- **S2**: セルフホスト化 (pure 関数の .clj 移行)
- **S1**: clojure.core.protocols, clojure.java.io サブセット

---

## 設計判断の控え

1. **正規表現**: Zig フルスクラッチ実装。バックトラッキング方式で Java regex 互換。
2. **skip 方針**: 明確に JVM 固有 (proxy, agent, STM, Java array, unchecked-*, BigDecimal) のみ skip。迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。instance?/class は内部タグ検査。
4. **GC**: セミスペース Arena Mark-Sweep。GcAllocator で Clojure Value のみ追跡。インフラ (Env/Namespace/Var/HashMap) は GPA 直接管理で GC 対象外。
5. **動的バインディング**: マクロ展開方式 (push+try/finally+pop)。新 Node/Opcode 不要。

---

## 既知の制限

- defmacro inside defn → エラー (トップレベルで定義が必要、明確なエラーメッセージあり)
- フル medley の `compare-and-set!`/`deref-swap!`/`deref-reset!` 未実装
- **map_filter 27GB メモリ**: → fused reduce で解決済み (2MB)。ジェネレータ直接ルーティング + スタック引数バッファ
- **Safe Point GC は recur のみ**: call 時の GC は builtin 関数の Zig ローカル変数が GC ルート外のため SIGSEGV。詳細は `plan/notes.md`
- **string_ops**: ベンチを `(reduce str ...)` → `(apply str ...)` に変更済み (508MB → 14MB)。他言語が StringBuilder/join を使っていたため公平化
