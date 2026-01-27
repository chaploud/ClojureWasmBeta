# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase 15 完了 — 次は Phase 16 (DESIGN: defrecord・deftype)**

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

### 実装状況

378 done / 170 skip / 166 todo

照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## ロードマップ

### 残タスクの分類

残り 243 todo は以下の 4 層に分かれる:

| 層            | 推定数 | 性質                                                      |
|---------------|--------|-----------------------------------------------------------|
| **PURE**      | ~55    | 既存基盤の組み合わせ。設計不要。述語・HOF・ユーティリティ |
| **DESIGN**    | ~75    | 新しいデータ構造・パターンが要るが、サブシステムは不要    |
| **SUBSYSTEM** | ~100   | 新サブシステムが必要（正規表現、名前空間、I/O、動的Var）  |
| **JVM_ADAPT** | ~10    | JVM 概念を簡略化移植（型変換・型チェック）                |

> Phase 11 で PURE ~60件を一括実装し、バッチ方式の有効性を確認済み。
> 残り PURE を片付けてから DESIGN → SUBSYSTEM へ進む。

### 方針変更メモ

1. **GC を後回し**: 旧計画では Phase 10 だったが、ArenaAllocator でバッチ実行は問題なし。
   GC が必要になるのは長時間 REPL セッション時。言語機能充実を優先し、GC は Phase 20 台へ延期。
2. **PURE → DESIGN → SUBSYSTEM**: 設計不要の PURE を先に片付け、土台を固めてから
   新しい型やサブシステムに着手する順序に変更。
3. **フェーズ番号の整理**: Phase 10 (旧GC) を廃止、Phase 12 から連番で再割り当て。

### フェーズ計画

```
Phase 12: PURE 残り — シーケンス・HOF・ユーティリティ（~55 件）
  └ lazy-cat, tree-seq, partition-by, comparator, replicate
  └ juxt, memoize, trampoline, random-sample, gensym
  └ *', +', -', dec', inc'（オーバーフロー安全算術）
  └ clojure-version, newline, printf, println-str
  └ hash-combine, hash-ordered-coll, hash-unordered-coll, mix-collection-hash
  └ multimethod 拡張: get-method, methods, remove-method, remove-all-methods,
    prefer-method, prefers
  └ 残り述語: bytes?, class?, decimal?, ratio?, rational?, record? 等
  └ find-keyword, parse-uuid, random-uuid, char, byte, short, long, float, num

Phase 13: DESIGN — delay/force, volatile, reduced ✅
  └ delay/delay?/force: サンクラッパー（マクロ展開 + builtin）
  └ volatile!/volatile?/vreset!/vswap!: ミュータブルボックス
  └ reduced/reduced?/unreduced/ensure-reduced: Reduced ラッパー型
  └ deref 拡張（volatile, delay 対応）
  └ 新型3種: Delay, Volatile, Reduced を value.zig に追加

Phase 14: DESIGN — transduce 基盤・transient ✅
  └ completing, transduce, cat, eduction, halt-when
  └ iteration（遅延ステートフルイテレータ）
  └ transient/persistent!/conj!/assoc!/dissoc!/disj!/pop!: 一時的ミュータブルコレクション
  └ Transient 型を value.zig に追加

Phase 15: DESIGN — Atom 拡張・Var 操作・メタデータ ✅
  └ add-watch, remove-watch, get-validator, set-validator!
  └ compare-and-set!, reset-vals!, swap-vals!
  └ var-get, var-set, alter-var-root, find-var, intern, bound?
  └ alter-meta!, reset-meta!, vary-meta
  └ Atom に validator/watches/meta フィールド追加、core.zig に current_env threadlocal

Phase 16: DESIGN — defrecord・deftype
  └ プロトコルと組み合わせた名前付きレコード型
  └ defstruct, create-struct, struct, struct-map, accessor（簡易版）
  └ record?, instance?

Phase 17: DESIGN — 階層システム
  └ make-hierarchy, derive, underive, ancestors, descendants, parents, isa?
  └ マルチメソッドの完全なディスパッチ階層

Phase 18: DESIGN — 動的束縛・sorted コレクション
  └ binding, with-bindings, set!, with-local-vars, bound-fn 等（束縛フレームスタック）
  └ sorted-map, sorted-map-by, sorted-set, sorted-set-by（赤黒木）
  └ promise, deliver

Phase 19: SUBSYSTEM — 正規表現
  └ re-pattern, re-find, re-matches, re-seq, re-matcher, re-groups
  └ Zig で正規表現エンジン実装 or PCRE バインディング

Phase 20: SUBSYSTEM — 名前空間システム
  └ ns, in-ns, require, use, refer, refer-clojure, load, load-file
  └ all-ns, find-ns, create-ns, remove-ns, ns-name, ns-publics, ns-map 等
  └ resolve, ns-resolve, requiring-resolve, alias, ns-aliases
  └ *ns* 動的 Var

Phase 21: SUBSYSTEM — I/O
  └ *in*, *out*, *err*, slurp, spit, read-line, flush
  └ with-open, with-out-str, with-in-str, line-seq, file-seq
  └ print 系動的 Var: *print-length*, *print-level*, *flush-on-newline* 等

Phase 22: SUBSYSTEM — Reader/Eval
  └ read, read-string, read+string, eval, macroexpand, macroexpand-1
  └ load-string, load-reader
  └ *read-eval*, *data-readers*, *default-data-reader-fn*

Phase 23: GC（シンプル版）
  └ mark-and-sweep or arena + 世代管理
  └ 長時間 REPL 対応（言語機能は ArenaAllocator で十分動作済み）

Phase LAST: Wasm 連携
  └ 言語機能充実後
  └ Component Model 対応、.wasm ロード・呼び出し、型マッピング
```

---

## 設計判断の控え

1. **正規表現**: Zig 標準ライブラリにないため外部実装 or 自前が要る。
2. **skip 方針**: 明確に JVM 固有（proxy, agent, STM, Java array, unchecked-*, BigDecimal）のみ skip。
   迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。
   instance?/class は内部タグ検査。深追いせず最小限で。

詳細: `docs/reference/architecture.md`
