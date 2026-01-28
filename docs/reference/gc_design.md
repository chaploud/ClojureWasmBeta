# GC 設計ノート

> Mark-Sweep GC の設計判断、セミスペース Arena 方式への移行、
> ポインタ fixup の網羅性確保、式境界 GC の選択理由。

---

## 基本方針: アロケータ分離

```
┌────────────────────────────────────┐
│ GPA (GeneralPurposeAllocator)      │
│   Env, Namespace, Var, HashMap     │
│   → GC 対象外、プロセス寿命       │
└────────────────────────────────────┘
                ↓ 子アロケータ
┌────────────────────────────────────┐
│ GcAllocator                        │
│   Clojure Value (*String, *Vector, │
│   *Fn, *PersistentMap, etc.)       │
│   → GC 追跡対象                   │
└────────────────────────────────────┘
```

### なぜ分離するか

- **インフラ** (Env/Namespace/Var) はプロセス全体で生存。GC で回収する必要がない
- **Clojure 値** は式評価のたびに大量生成され、多くが短命。GC が必須
- 分離により GC の追跡対象が減り、mark フェーズが高速化
- GPA と Arena の使い分けで、それぞれに最適なメモリ戦略を適用可能

---

## 式境界 GC

### タイミング

GC はトップレベル式の評価完了後に実行される (式境界)。

```
式1の評価 → GC チェック → 式2の評価 → GC チェック → ...
```

式の途中では GC を実行しない。

### なぜ式境界なのか

1. **ルートの特定が容易**: 式境界では「生きている値」= Var に格納された値 + 名前空間の値。
   スタック上の中間値を追跡する必要がない
2. **一貫性の保証**: 式の途中で GC が走ると、スタック上の参照が移動する可能性がある。
   式境界なら安全
3. **実装の単純さ**: Zig には自動的にスタック上のポインタを追跡する仕組みがない。
   式境界に限定すれば、ルートは Env ツリーだけで十分

### 制限

- 単一式内で大量のメモリを消費するケース (巨大な遅延シーケンスの force 等) では
  GC が発動せず、メモリが一時的に膨張する
- loop/recur の `recur_buffer` 最適化で部分的に緩和 (毎イテレーションの alloc を排除)

---

## Mark-Sweep アルゴリズム

### Mark フェーズ

ルートから到達可能な全オブジェクトにマークを付ける。

```
ルート
  └→ Env
       └→ Namespace[]
            └→ Var[]
                 └→ Value (root)
                      └→ 再帰的に子 Value を追跡
```

### サイクル検出

`gc.mark()` は `bool` を返す。`true` = 既にマーク済み → スキップ。
`(fn foo [] foo)` のような自己参照 fn で無限ループを防止。

### Sweep フェーズ (初期版: GPA 個別 free)

マークされていないオブジェクトを個別に `gpa.free()` で解放。
**問題**: 240k objects で 1,146ms。オブジェクトごとの free が遅すぎる。

---

## セミスペース Arena GC (G1c)

### 設計

GPA 個別 free を廃止し、ArenaAllocator のセミスペース方式に移行。

```
GC前:
  ┌──────────────────┐
  │ 旧 Arena          │
  │  [live] [dead]    │
  │  [dead] [live]    │
  │  [dead] [dead]    │
  └──────────────────┘

GC後:
  ┌──────────────────┐     ┌──────────────────┐
  │ 旧 Arena (解放)   │     │ 新 Arena          │
  │                   │ →   │  [live (copy)]    │
  │                   │     │  [live (copy)]    │
  └──────────────────┘     └──────────────────┘
```

### sweep() の処理

1. 新 Arena を作成
2. マーク済みオブジェクトを新 Arena にコピー
3. ForwardingTable (old_ptr → new_ptr) を構築
4. 旧 Arena を一括解放 (`arena.deinit()`)
5. ForwardingTable を返す

### fixupRoots() の処理

ForwardingTable を使い、全ルートのポインタを新アドレスに更新。

```
fixup 対象:
  Env → Namespace[] → Var[] → Value (root)
    ↓ 再帰的に
  Value 内の子ポインタ:
    *String → 新アドレス
    *Vector → 新アドレス + items[] 内の各 Value
    *PersistentMap → 新アドレス + hash_values[] + hash_index[]
    *Fn → 新アドレス + closure_bindings[]
    *LazySeq → 新アドレス + cons_head/cons_tail
    ...
```

### 性能改善

| フェーズ | GPA 個別 free | Arena 一括解放 | 改善  |
|----------|---------------|----------------|-------|
| mark     | 0.567 ms      | 0.268 ms       | 同等  |
| sweep    | 1,146 ms      | 29 ms          | ~40x  |
| total    | 1,147 ms      | 29 ms          | ~40x  |

(240k objects, ~2.4GB)

---

## fixup の網羅性: 最も危険なポイント

### 問題

1箇所でも fixup を漏らすと、旧 Arena の解放済みメモリへのポインタが残る。
即座にクラッシュせず、Arena メモリが再利用されるまで動いてしまうことがある。
再現困難なバグになりやすい。

### 対策

1. **Value union の全タグを網羅**: switch 文で全ケースを列挙し、
   ポインタを含むタグ (string, vector, map, fn, etc.) を漏れなく fixup
2. **PersistentMap の内部配列**: `hash_values` と `hash_index` は
   Value のスライスへのポインタ。これも fixup 対象
3. **GcGlobals**: hierarchy 等のグローバル状態も fixup 対象。
   `hierarchy` を `*?Value` (ポインタのポインタ) にすることで、
   fixup が writeback できるようにした

### fixup 漏れの検出方法

現状は「テストを全部通す」以外の検出方法がない。将来的には:
- Arena 解放後にメモリを 0xDEAD で埋めてクラッシュを早期化
- fixup 対象のポインタを全列挙する自動テスト

---

## deepClone: scratch → persistent の安全化

### 問題

scratch アロケータの値を persistent に格納すると、
`resetScratch()` 後にダンリングポインタになる。

### パターン

| 場面                | 関数                     | 説明                                         |
|---------------------|--------------------------|----------------------------------------------|
| `def` で Var に格納 | `runDef` → `deepClone`  | Var.root がスクラッチ値を指さないように       |
| `fn` 定義           | `runFn` → `deepClone`   | fn body ノードの persistent コピー            |
| `swap!`/`reset!`    | → `deepClone`           | Atom 内部値の persistent コピー               |
| VM 定数             | `addConstant` → `deepClone` | バイトコード内の定数テーブル                |
| 階層システム         | `derive` → `deepClone`  | hierarchy に格納する keyword                  |

### deepClone のコスト

再帰的にコレクション全体をコピーするため、大きなデータ構造ではコストが高い。
しかしメモリ安全性のためには必須。

---

## 設計判断の根拠

### なぜ Mark-Sweep で、参照カウントではないのか

- Clojure の永続データ構造はツリー構造で共有が多い。参照カウントだとサイクルが問題になる
  (実際に `(fn foo [] foo)` のような自己参照がある)
- Mark-Sweep はサイクルを自然に処理できる
- 式境界で一括処理するため、参照カウントの更新コストが不要

### なぜ世代別 GC ではないのか (現時点)

- 式境界 GC では全ルートを走査するコストが支配的
- 世代別にすると write barrier が必要になり、全代入箇所に検査コードを入れる必要がある
- 現状の性能 (29ms/GC) で実用上十分
- ベンチマークで世代別の効果が確認できてから検討する

### なぜ Arena セミスペースにしたのか

- GPA の `free()` は個別オブジェクトごとにメタデータ操作が必要で遅い
- Arena は `deinit()` 一発で全メモリ解放。O(1)
- コピー GC のコストは生存オブジェクト数に比例。短命オブジェクトが多い
  Clojure の特性と相性が良い
- ポインタ fixup のコストはあるが、sweep の 40x 高速化で十分にペイする

### hierarchy を `*?Value` にした理由

fixup では「ポインタの指す先」を書き換える必要がある。
`?Value` (値型) だと書き換えが fixup 関数のローカル変数にしか反映されない。
`*?Value` (ポインタ型) にすることで、fixup 関数が元の格納場所を直接更新できる。
