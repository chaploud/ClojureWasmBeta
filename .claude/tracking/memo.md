# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase 23 完了 — 動的バインディング（本格実装）**

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

### 実装状況

549 done / 169 skip / 0 todo (概算)

照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## Phase 23 実装詳細

### サブフェーズ

| Sub   | 内容                                                                          |
|-------|-------------------------------------------------------------------------------|
| 23a   | Var バインディングフレーム基盤 (BindingEntry/Frame + push/pop/get/set)        |
| 23b   | core.zig スタブ本格化 (push/pop/set!/thread-bound?/get-bindings/with-redefs) |
| 23c   | Analyzer マクロ展開修正 + Reader ^: メタ対応 + (var sym) 特殊形式            |
| 23d   | Compiler emitVarRef dynamic対応 (var_load_dynamic)                           |
| 23e   | dynamic フラグ設定 (registerDynamicVars) + GC トレース                       |
| 23f   | E2E テスト (binding/nested/set!/with-redefs/thread-bound?)                   |

### 変更ファイル

| ファイル                       | 変更内容                                                       |
|--------------------------------|----------------------------------------------------------------|
| `src/runtime/var.zig`          | BindingEntry/Frame + push/pop/get/set + deref dynamic対応      |
| `src/lib/core.zig`             | 6スタブ本格化 + registerDynamicVars に .dynamic = true          |
| `src/reader/reader.zig`        | readMeta() — ^:keyword / ^{map} / ^Type メタデータ対応         |
| `src/analyzer/node.zig`        | DefNode に is_dynamic フィールド追加                           |
| `src/analyzer/analyze.zig`     | expandBinding 書換 + analyzeVarSpecial + expandSetBang 等      |
| `src/compiler/emit.zig`        | emitVarRef: dynamic Var → var_load_dynamic                     |
| `src/vm/vm.zig`                | var_load_dynamic の TODO コメント更新                          |
| `src/runtime/evaluator.zig`    | runDef: is_dynamic → v.dynamic = true                          |
| `src/gc/tracing.zig`           | markRoots にバインディングフレームトレース追加                 |
| `src/test_e2e.zig`             | Phase 23 E2E テスト 5件追加                                    |

### 設計ポイント

- **マクロ展開方式**: `(binding [...] body)` → `push-thread-bindings` + `try/finally` + `pop-thread-bindings`
- **グローバルフレームスタック**: シングルスレッド前提 (Wasm ターゲット)
- **`(var sym)` 特殊形式**: Analyzer で Var オブジェクトを constantNode として返す
- **with-redefs**: root 直接差替 + finally 復元 (TreeWalk のみ完全動作、VM は制限あり)
- **GC**: バインディングフレーム内の Value をトレース
- **Reader メタデータ**: `^:dynamic` → `(with-meta sym {:dynamic true})` 展開

### 既知の制限

- VM での `with-redefs` 後のユーザー関数呼び出しが signal 6 でクラッシュする
  (VM のユーザー関数呼び出しに関する既存の問題の可能性)

---

## ロードマップ

### 次のフェーズ（品質向上・新機能）

```
Phase 24: 名前空間（本格実装）
  └ 現在の ns/require/use はスタブ
  └ ファイルロード、refer フィルタリング、alias

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
