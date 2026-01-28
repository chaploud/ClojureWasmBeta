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
| 3   | P3    | NaN boxing           | 保留     | 大規模変更、事前に設計文書が必要           |
| 4   | G2    | 世代別 GC            | 未着手   | Young bump allocator + minor GC           |
| 5   | P3    | inline caching       | 未着手   | 関数呼び出し高速化                         |
| 6   | P3    | 定数畳み込み         | 未着手   | Compiler 側最適化                          |
| 7   | P3    | tail call dispatch   | 未着手   | computed goto 相当                         |

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
