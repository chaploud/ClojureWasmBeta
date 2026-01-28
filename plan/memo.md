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
| clojure.core 実装状況 | 663 done / 191 skip                    |
| Zig ソースコード      | ~32,000 行 (src/ 以下)                 |
| デュアルバックエンド  | TreeWalk + BytecodeVM                  |
| GC                    | セミスペース Arena Mark-Sweep (式境界) |
| Wasm                  | zware (10 API 関数)                    |
| 標準 NS               | string/set/walk/edn/math/repl/data/stacktrace/template/zip |
| nREPL                 | CIDER/Calva/Conjure 互換              |

### 推奨次回タスク

1. **U4 残項目**: 既知バグ修正 (^:const, with-local-vars 等)
2. **P3**: VM 最適化 (ベンチマーク駆動)
3. **新規 S1 候補**: clojure.pprint 等

---

## 設計判断の控え

1. **正規表現**: Zig フルスクラッチ実装。バックトラッキング方式で Java regex 互換。
2. **skip 方針**: 明確に JVM 固有 (proxy, agent, STM, Java array, unchecked-*, BigDecimal) のみ skip。迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。instance?/class は内部タグ検査。
4. **GC**: セミスペース Arena Mark-Sweep。GcAllocator で Clojure Value のみ追跡。インフラ (Env/Namespace/Var/HashMap) は GPA 直接管理で GC 対象外。
5. **動的バインディング**: マクロ展開方式 (push+try/finally+pop)。新 Node/Opcode 不要。

---

## 既知の制限

- ^:const 未対応
- with-local-vars 未実装
- defmacro inside defn → Undefined (トップレベルで定義が必要)
- フル medley の `compare-and-set!`/`deref-swap!`/`deref-reset!` 未実装
