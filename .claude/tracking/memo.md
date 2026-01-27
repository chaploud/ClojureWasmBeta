# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase 20 完了 — 全 clojure.core 関数実装完了（545 done / 169 skip / 0 todo）**

### 完了フェーズ

| Phase | 内容                                                                    |
|-------|-------------------------------------------------------------------------|
| 1-4   | Reader, Runtime基盤, Analyzer, TreeWalk評価器                           |
| 5     | ユーザー定義関数 (fn, クロージャ)                                       |
| 6     | マクロシステム (defmacro)                                               |
| 7     | CLI (-e, 複数式, 状態保持)                                              |
| 8.0   | VM基盤 (Bytecode, Compiler, VM, --compare)                              |
| 8.1   | クロージャ完成, 複数アリティfn, 可変長引数                              |
| 8.2   | 高階関数 (apply, partial, comp, reduce)                                 |
| 8.3   | 分配束縛 (シーケンシャル・マップ)                                       |
| 8.4   | シーケンス操作 (map, filter, take, drop, range 等)                      |
| 8.5   | 制御フローマクロ・スレッディングマクロ                                  |
| 8.6   | try/catch/finally 例外処理                                              |
| 8.7   | Atom 状態管理 (atom, deref, reset!, swap!)                              |
| 8.8   | 文字列操作拡充                                                          |
| 8.9   | defn・dotimes・doseq・if-not・comment                                   |
| 8.10  | condp・case・some->・some->>・as->・mapv・filterv                       |
| 8.11  | キーワードを関数として使用                                              |
| 8.12  | every?/some/not-every?/not-any?                                         |
| 8.13  | バグ修正・安定化                                                        |
| 8.14  | マルチメソッド (defmulti, defmethod)                                    |
| 8.15  | プロトコル (defprotocol, extend-type, extend-protocol)                  |
| 8.16  | ユーティリティ関数・HOF・マクロ拡充                                     |
| 8.17  | VM let-closure バグ修正                                                 |
| 8.18  | letfn（相互再帰ローカル関数）                                           |
| 8.19  | 実用関数・マクロ大量追加（~83関数/マクロ）                              |
| 8.20  | 動的コレクションリテラル（変数を含む [x y], {:a x} 等）                 |
| 9     | LazySeq — 真の遅延シーケンス（無限シーケンス対応）                      |
| 9.1   | Lazy map/filter/concat — 遅延変換・連結                                 |
| 9.2   | iterate/repeat/cycle/range()/mapcat — 遅延ジェネレータ・lazy mapcat     |
| 11    | PURE述語(23)+コレクション/ユーティリティ(17)+ビット演算等(17) = +57関数 |
| 12    | PURE残り: 述語(15)+型キャスト(6)+算術(5)+出力(4)+ハッシュ(4)+MM拡張(6)+HOF(6)+他(7) = +53関数 |
| 13    | DESIGN: delay/force(3)+volatile(4)+reduced(4) = 新型3種+11関数、deref拡張              |
| 14    | DESIGN: transient(7)+transduce基盤(6) = Transient型+13関数              |
| 15    | DESIGN: Atom拡張(7)+Var操作(6)+メタデータ(3) = +16関数                  |
| 17    | DESIGN: 階層システム(7) = make-hierarchy/derive/underive/isa?等         |
| 18    | DESIGN: promise/deliver + ユーティリティ(10) = Promise型+UUID+他       |
| 18b   | DESIGN: partitionv/splitv-at/tap/parse-uuid 等(9) = 追加ユーティリティ |
| 19a   | DESIGN: class/struct/accessor/xml-seq等(9) = struct操作+ユーティリティ |
| 19b   | DESIGN: eval/read-string/sorted/dynamic-vars(18+14dynvar) = eval基盤+ソートcol+動的Var |
| 19c   | DESIGN: NS操作/Reader/定義マクロ等(27+2dynvar) = 名前空間スタブ+load+definline |
| 20    | FINAL: 残り59一括実装 — binding/chunk/regex/IO/NS/defrecord/deftype/動的Var     |

### 実装状況

545 done / 169 skip / 0 todo

照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## ロードマップ

### clojure.core 実装完了

545 done / 169 skip / 0 todo — **全 clojure.core 関数の実装が完了**。

> 多くはスタブ/簡易実装。本格的な正規表現エンジン、動的バインディング、
> チャンクシーケンス等は将来の品質向上フェーズで改善予定。

### 次のフェーズ（品質向上・新機能）

```
Phase 21: GC（シンプル版）
  └ mark-and-sweep or arena + 世代管理
  └ 長時間 REPL 対応（言語機能は ArenaAllocator で十分動作済み）

Phase 22: 正規表現エンジン（本格実装）
  └ 現在の re-* はスタブ（文字列一致のみ）
  └ Zig で正規表現エンジン実装 or PCRE バインディング

Phase 23: 動的バインディング（本格実装）
  └ 現在の binding/with-redefs は let に展開するスタブ
  └ thread-local binding stack の実装

Phase 24: 名前空間（本格実装）
  └ 現在の ns/require/use はスタブ
  └ ファイルロード、refer フィルタリング、alias

Phase LAST: Wasm 連携
  └ 言語機能充実後
  └ Component Model 対応、.wasm ロード・呼び出し、型マッピング
```

---

## 設計判断の控え

1. **正規表現**: Zig 標準ライブラリにないため外部実装 or 自前が要る。現在はスタブ。
2. **skip 方針**: 明確に JVM 固有（proxy, agent, STM, Java array, unchecked-*, BigDecimal）のみ skip。
   迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。
   instance?/class は内部タグ検査。深追いせず最小限で。

詳細: `docs/reference/architecture.md`
