# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase 26 完了 — Reader Conditionals + 外部ライブラリ統合テスト**

### 完了フェーズ

| Phase | 内容                                                                                          |
|-------|-----------------------------------------------------------------------------------------------|
| 1-4   | Reader, Runtime基盤, Analyzer, TreeWalk評価器                                                 |
| 5     | ユーザー定義関数 (fn, クロージャ)                                                             |
| 6     | マクロシステム (defmacro)                                                                     |
| 7     | CLI (-e, 複数式, 状態保持)                                                                    |
| 8.0   | VM基盤 (Bytecode, Compiler, VM, --compare)                                                    |
| 8.1   | クロージャ完成, 複数アリティfn, 可変長引数                                                    |
| 8.2   | 高階関数 (apply, partial, comp, reduce)                                                       |
| 8.3   | 分配束縛 (シーケンシャル・マップ)                                                             |
| 8.4   | シーケンス操作 (map, filter, take, drop, range 等)                                            |
| 8.5   | 制御フローマクロ・スレッディングマクロ                                                        |
| 8.6   | try/catch/finally 例外処理                                                                    |
| 8.7   | Atom 状態管理 (atom, deref, reset!, swap!)                                                    |
| 8.8   | 文字列操作拡充                                                                                |
| 8.9   | defn・dotimes・doseq・if-not・comment                                                         |
| 8.10  | condp・case・some->・some->>・as->・mapv・filterv                                             |
| 8.11  | キーワードを関数として使用                                                                    |
| 8.12  | every?/some/not-every?/not-any?                                                               |
| 8.13  | バグ修正・安定化                                                                              |
| 8.14  | マルチメソッド (defmulti, defmethod)                                                          |
| 8.15  | プロトコル (defprotocol, extend-type, extend-protocol)                                        |
| 8.16  | ユーティリティ関数・HOF・マクロ拡充                                                           |
| 8.17  | VM let-closure バグ修正                                                                       |
| 8.18  | letfn（相互再帰ローカル関数）                                                                 |
| 8.19  | 実用関数・マクロ大量追加（~83関数/マクロ）                                                    |
| 8.20  | 動的コレクションリテラル（変数を含む [x y], {:a x} 等）                                       |
| 9     | LazySeq — 真の遅延シーケンス（無限シーケンス対応）                                            |
| 9.1   | Lazy map/filter/concat — 遅延変換・連結                                                       |
| 9.2   | iterate/repeat/cycle/range()/mapcat — 遅延ジェネレータ・lazy mapcat                           |
| 11    | PURE述語(23)+コレクション/ユーティリティ(17)+ビット演算等(17) = +57関数                       |
| 12    | PURE残り: 述語(15)+型キャスト(6)+算術(5)+出力(4)+ハッシュ(4)+MM拡張(6)+HOF(6)+他(7) = +53関数 |
| 13    | DESIGN: delay/force(3)+volatile(4)+reduced(4) = 新型3種+11関数、deref拡張                     |
| 14    | DESIGN: transient(7)+transduce基盤(6) = Transient型+13関数                                    |
| 15    | DESIGN: Atom拡張(7)+Var操作(6)+メタデータ(3) = +16関数                                        |
| 17    | DESIGN: 階層システム(7) = make-hierarchy/derive/underive/isa?等                               |
| 18    | DESIGN: promise/deliver + ユーティリティ(10) = Promise型+UUID+他                              |
| 18b   | DESIGN: partitionv/splitv-at/tap/parse-uuid 等(9) = 追加ユーティリティ                        |
| 19a   | DESIGN: class/struct/accessor/xml-seq等(9) = struct操作+ユーティリティ                        |
| 19b   | DESIGN: eval/read-string/sorted/dynamic-vars(18+14dynvar) = eval基盤+ソートcol+動的Var        |
| 19c   | DESIGN: NS操作/Reader/定義マクロ等(27+2dynvar) = 名前空間スタブ+load+definline                |
| 20    | FINAL: 残り59一括実装 — binding/chunk/regex/IO/NS/defrecord/deftype/動的Var                   |
| 21    | GC: Mark-Sweep at Expression Boundary (GcAllocator + tracing + 式境界GC)                      |
| 22    | 正規表現エンジン（フルスクラッチ Zig 実装）                                                   |
| 23    | 動的バインディング（本格実装）                                                                |
| 24    | 名前空間（本格実装）                                                                          |
| 25    | REPL (対話型シェル)                                                                           |
| 26    | Reader Conditionals + 外部ライブラリ統合テスト (medley v1.4.0)                                |

### 実装状況

549 done / 169 skip / 0 todo (概算)

照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## Phase 26 実装詳細

### 機能

- **Reader Conditional `#?`**: `:clj` 分岐を選択、`:default` フォールバック対応
- **`.cljc` ファイル対応**: `require` で `.clj` → `.cljc` フォールバック検索
- **`--classpath=path1:path2`**: 複数クラスパスルート指定
- **`instance?` 特殊形式**: Java 型名をシンボル定数として解決
- **名前付き fn 自己再帰**: クロージャスロットで自己参照パッチ
- **`#(...)` fn リテラル**: `%`, `%1`, `%2`, `%&` パラメータスキャン + body ラップ
- **`reduced` 早期終了**: `reduce` / `reduce-kv` で `reduced` 値をアンラップ
- **`'` シンボル文字**: `coll'`, `x'` 等のシンボルを許可
- **Java 互換シンボル**: `clojure.lang.PersistentQueue/EMPTY` 等の名前空間付きシンボル解決

### 変更ファイル

| ファイル                              | 変更内容                                              |
|---------------------------------------|-------------------------------------------------------|
| `src/reader/tokenizer.zig`            | `isSymbolChar` で `'` を許可                          |
| `src/reader/reader.zig`               | `readFnLit` 全面書き直し + `readReaderCond` 追加      |
| `src/analyzer/analyze.zig`            | `instance?` 特殊形式 + 名前付き fn + Java シンボル    |
| `src/runtime/evaluator.zig`           | 名前付き fn 自己参照 + `reduced` ハンドリング         |
| `src/lib/core.zig`                    | `reduceKv` reduced 対応 + `.cljc` + classpath         |
| `src/main.zig`                        | `--classpath` オプション                              |
| `src/test_e2e.zig`                    | Phase 26 E2E テスト 7 件追加                          |
| `test/libs/medley_trimmed/core.cljc`  | medley v1.4.0 トリミング版 (新規)                     |
| `test/libs/medley/core.cljc`          | medley v1.4.0 フルソース (新規)                       |
| `test/integration/test_medley.clj`    | medley 統合テスト (新規)                              |

### medley 統合テスト結果

**medley-trimmed (22関数)**: 全テスト pass
- Tier 1: abs, find-first, assoc-some, dissoc-in, update-existing
- Tier 2: map-keys, map-vals, filter-keys, filter-vals
- Tier 3: boolean?, least, greatest

**フル medley**: form #39 (deref-swap!) で停止 — `compare-and-set!` 未実装

### 既知の制限

- VM で `reduced` 未対応 (TreeWalk のみ)
- sets-as-functions 未対応 (`#{:a :b}` を関数として使用不可)
- フル medley の `compare-and-set!`/`deref-swap!`/`deref-reset!` 未実装
- 文字列表示で `!` がエスケープされる (Phase 25 以前からの問題)
- VM での `with-redefs` 後のユーザー関数呼び出しクラッシュ (Phase 23 由来)

---

## ロードマップ

### 次のフェーズ（品質向上・新機能）

```
Phase LAST: Wasm 連携
  └ 言語機能充実後
  └ Component Model 対応、.wasm ロード・呼び出し、型マッピング
```

---

## 設計判断の控え

1. **正規表現**: Zig フルスクラッチ実装。バックトラッキング方式で Java regex 互換。
2. **skip 方針**: 明確に JVM 固有（proxy, agent, STM, Java array, unchecked-*, BigDecimal）のみ skip。
   迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。
   instance?/class は内部タグ検査。深追いせず最小限で。
4. **GC**: 式境界 Mark-Sweep。GcAllocator で全 persistent alloc を追跡。
   閾値超過時にのみ実行。CLI 用途では十分な性能。
5. **動的バインディング**: マクロ展開方式 (push+try/finally+pop)。
   新 Node/Opcode 不要。既存インフラを最大限活用。

詳細: `docs/reference/architecture.md`
