# 教訓集 — バグから学んだ設計知見

> 実際に遭遇したバグの根本原因、発見の経緯、修正方法、
> そして今後同種の問題を防ぐための指針。

---

## U4e: クロージャが中間式をキャプチャする

### 症状

```clojure
(for [x [1 2] y [:a :b]] (list x y))
;; TreeWalk: 正常
;; VM: y が map 関数に化ける
```

### 根本原因

`createClosure` が `stack[frame.base]` から `sp` までの全値をキャプチャしていた。
`(map (fn [z] z) coll)` のように HOF を呼ぶ場合、スタック上に:

```
[closure_bindings..., params..., locals..., map_fn_value, ...]
                                            ↑ 中間式の値
```

`map` 関数がスタックに push された状態で内側の `fn` の closure が作られると、
`map` もキャプチャ対象に含まれてしまう。

### 発見方法

1. `--compare` で MISMATCH を検出
2. 最小再現ケースに絞り込み: `(fn [x] (map (fn [z] z) [:a]))`
3. `local_load` opcode に stderr トレースを挿入:
   ```
   local_load slot=0 → #<fn map>  ← ここでおかしいと気付く
   ```
4. `createClosure` でキャプチャされた値を全ダンプして確認

### 修正

`sp - frame.base` 全部ではなく、`proto.capture_count` / `proto.capture_offset` に基づき
正確にキャプチャ。

### 教訓

- **「全部取る」は安全に見えて危険**。必要最小限のキャプチャが正しい
- **中間式がスタックに残るタイミング** を意識する。特に HOF 呼出し中の closure 生成
- **TreeWalk との比較** (--compare) がなければ発見は極めて困難だった

---

## U4f: 多段ネストの inherited_captures 不足

### 症状

U4e の修正後、2段ネストは正常だが 3段以上で壊れる:

```clojure
((fn [x]
   (mapv (fn [y]
           (mapv (fn [z] [x y z])
                 [100 200]))
         [10 20]))
 1)
;; 期待: [[1 10 100] [1 10 200] [1 20 100] [1 20 200]]
;; VM:   [[10 100 100] [10 100 200] ...]
```

### 根本原因

コンパイラの `capture_count = self.locals.items.len` は直接の親のローカル数のみ。
祖先からの継承分を含んでいない。

Level 3 の fn の場合:
```
locals.items.len = 1 (親の y のみ)
本来必要:        2 (祖父の x + 親の y)
```

`capture_count=1` なので `x` がキャプチャされず、`y` のスロットが `x` に割り当てられ、
`z` のスロットが `y` に割り当てられる → 値がずれる。

### 修正

```zig
inherited_captures: u16  // 新フィールド
capture_count = self.inherited_captures + @as(u16, @intCast(self.locals.items.len))
```

子コンパイラ作成時に `fn_compiler.inherited_captures = capture_count` を設定。

### 教訓

- **2段で通ったから正しいとは限らない**。ネスト深度を変えたテストが必須
- **「コンパイラが出す数値の意味」と「VMが解釈する意味」が一致しているか** を
  明文化すべき。U4e では「取りすぎ」、U4f では「取り不足」という正反対のバグ
- **`inherited_captures` のような伝播値** は暗黙の依存関係を作る。
  ドキュメント化しないと後で必ず壊れる

---

## G1c: fixup 漏れによる use-after-free

### 症状 (仮想例)

セミスペース GC 後にランダムなクラッシュ、または正しくない値が返る。
再現が不安定で、GC が走るタイミングに依存する。

### 根本原因

旧 Arena のオブジェクトを新 Arena にコピーした後、
旧アドレスを指しているポインタの更新 (fixup) を漏らすと、
旧 Arena の `deinit()` 後に解放済みメモリにアクセスする。

### 特に漏れやすい箇所

1. **PersistentMap の内部配列**: `hash_values` と `hash_index` は Value のスライス。
   Map の Value だけ fixup して内部配列を忘れると壊れる
2. **LazySeq の cons_tail**: cons_head は fixup したが cons_tail を忘れる
3. **グローバル状態**: GcGlobals の hierarchy など、ルートツリー外のポインタ
4. **closure_bindings**: Fn のクロージャバインディング配列内の各 Value

### 対策

- `fixupValue` 関数で Value union の全タグを switch で列挙
- `else => {}` は使わない。新しいタグを追加したら必ずコンパイルエラーで気付く
- テスト実行順序を変えて GC タイミングを変動させる

### 教訓

- **Arena 一括解放は速いが、ポインタ fixup の網羅性が生命線**
- **「即座にクラッシュしない」のが最も危険**。解放済みメモリが偶然まだ有効な内容を
  保持していると、しばらく動いてから壊れる
- **Value に新しいポインタ型を追加するたびに fixup を更新する** というルールが必要

---

## Phase 24: テスト期待値のドリフト

### 症状

274 テスト中 4 つが失敗。コード変更なしで突然壊れた (ように見える)。

### 根本原因

- NS カウントテスト: `all-ns` が 2 を期待するが、wasm NS 追加で 3 になった
- `identical?` キーワード: false を期待するが、keyword は intern されるため true が正しい

### 教訓

- **具体的な数値をテスト期待値にハードコードすると、無関係な変更で壊れる**
- `(>= (count (all-ns)) 2)` のような「最低限」アサーションの方が堅牢
- ただし、数値の変化に気付けるのはハードコードの利点でもある。
  「何が変わったか」を検出するための regression test と、
  「正しく動いているか」を検証する correctness test を区別する

---

## mapcat lazy: for マクロの展開と VM の相互作用

### 症状

```clojure
(for [x [1 2] y [:a :b]] (list x y))
;; VM で MISMATCH
```

### 根本原因

`for` マクロはネストした `mapcat` + `map` に展開される。
内側の `fn` がクロージャとして生成される際に U4e のバグが発動。

### 教訓

- **マクロ展開の結果を人間が予測するのは困難**。展開結果のバイトコードを
  確認する手段 (ディスアセンブラ) があると良い
- **マクロが生成するコード** は手書きより複雑になりがち。
  手書きでは起きない「中間式 + クロージャ」の組み合わせが自然に発生する
- **テストは展開前のマクロ形式で書く** (ユーザーが書く形式)。
  展開後の形式でテストしても、実際のバグは見つからない

---

## letfn: fn 名による余分なローカルスロット

### 症状

```clojure
(letfn [(f [x] (g x)) (g [x] x)] (f 5))
;; → UndefinedSymbol
```

### 根本原因

`analyzeFn` に名前付き fn を渡すと、自己参照用のローカルインデックスが
1つ追加される。letfn ではスコープが既に全関数名を提供しているため、
この自己参照ローカルは不要かつ有害 (パラメータインデックスがずれる)。

### 教訓

- **analyzer の「便利機能」が別のコンテキストで害になる** ケース
- letfn の fn は通常の fn と同じ `analyzeFn` を通るが、
  スコープの前提が異なる。コンテキストに応じた振る舞いの分岐が必要
- **ローカルインデックスのずれ** は「1 個ずれて隣の値が見える」ため
  クラッシュせず静かに壊れる (VM の「静かに壊れる」パターン)

---

## 横断的な教訓

### 1. 暗黙の契約を明文化する

コンパイラが emit する値 (capture_count, slot 番号, scope_exit の引数) と
VM が解釈する値が同じ意味でなければならない。
この契約が暗黙的だと、一方を変更したときに他方を更新し忘れる。

**対策**: `vm_design.md` の「コンパイラ-VM 間の契約」セクションを維持する。

### 2. 「静かに壊れる」バグを早期検出する

VM のバグは大抵クラッシュではなく「間違った値を返す」形で現れる。
検出手段:
- `--compare` (TreeWalk との突き合わせ) — 最も有効
- 多段ネスト・HOF・マクロ展開を組み合わせたテスト
- 値レベルのアサーション (`test-eq`)

### 3. 最小再現ケースを作る技術

大きなテストケースが失敗したとき、以下の手順で絞り込む:
1. 失敗するテストの中から最小の式を特定
2. 外側の構造を剥がしていく (for → mapcat+map → map+fn → fn)
3. 引数の数を減らす ([1 2 3] → [1])
4. 各ステップで「まだ壊れるか」を確認

### 4. GC は「全部正しい」か「どこかで壊れる」

部分的に正しい GC は存在しない。fixup を 1箇所漏らすだけで全体が壊れる。
新しい Value 型を追加するたびに、以下を全て更新:
- `traceValue` (mark フェーズ)
- `fixupValue` (fixup フェーズ)
- `deepClone` (scratch → persistent コピー)
- `format` / `prStr` (デバッグ出力)
- `eql` (等価比較)

### 5. 双方向の変更を忘れない

| 変更箇所         | 影響を受ける箇所                               |
|------------------|------------------------------------------------|
| Value に新タグ   | traceValue, fixupValue, deepClone, format, eql |
| 新 opcode 追加   | emit.zig (emit側) + vm.zig (execute側)         |
| FnProto 変更     | emit.zig (設定側) + vm.zig (読取側)            |
| ローカル追加方式 | emit.zig (addLocal) + vm.zig (local_load/store) |
| 新 Node 型追加   | node.zig + analyze.zig + evaluator.zig + emit.zig + vm.zig |
