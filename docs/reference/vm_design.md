# バイトコードVM設計ノート

> コンパイラ (emit.zig) と VM (vm.zig) 間の「契約」、
> スタックレイアウト、クロージャキャプチャの設計と落とし穴。

---

## スタックフレーム構造

VM はスタックベース。関数呼出しごとにフレームを積み、`frame.base` がローカル領域の先頭。

```
stack[frame.base] →
  ┌──────────────────────────────────────────────────────────┐
  │ inherited_captures  (祖先からのクロージャバインディング) │
  │ parameters          (引数)                               │
  │ let_locals          (let/loop で束縛された変数)          │
  │ intermediates       (式評価の一時値)                     │
  └──────────────────────────────────────────────────────────┘
                                              ← sp (スタックポインタ)
```

### ローカル変数のアドレッシング

- `Local.slot`: `frame.base` からのオフセット
- `local_load slot=N` → `stack[frame.base + N]` を読む
- `local_store slot=N` → `stack[frame.base + N]` に書く
- コンパイラは `sp_depth` で現在のスタック深度を追跡し、`addLocal` で正しい slot を割り当てる

### 重要な不変条件

1. **slot 0 〜 capture_count-1**: クロージャバインディング (createClosure が配置)
2. **slot capture_count 〜 capture_count+param_count-1**: パラメータ (呼出し側が配置)
3. **slot capture_count+param_count 〜**: let/loop ローカル
4. **それ以降**: 中間式の値 (add の途中結果など、ローカルではない)

---

## コンパイラ-VM 間の契約

### FnProto (関数プロトタイプ)

```zig
pub const FnProto = struct {
    arity: u8,          // パラメータ数
    is_variadic: bool,
    body_offset: u32,   // バイトコード開始位置
    capture_count: u16, // キャプチャするスタック値の数
    capture_offset: u16, // frame.base からのオフセット (現在は常に 0)
    // ...
};
```

**契約**: コンパイラが設定する `capture_count` と VM の `createClosure` が読む
`capture_count` は同じ意味でなければならない。

### capture_count の計算 (emit.zig)

```
capture_count = inherited_captures + locals.items.len
```

- `inherited_captures`: 親コンパイラから受け継いだキャプチャ深さ
- `locals.items.len`: 現スコープで宣言されたローカル変数数 (クロージャ生成時点の)

### 暗黙的な契約の危険性

この契約はコード上で明文化されておらず、コンパイラ側の計算と VM 側の解釈が
一致することに依存する。契約違反は「静かに壊れる」(後述) ため発見が困難。

---

## クロージャキャプチャ

### メカニズム

1. コンパイラが `fn` をコンパイルする際、親スコープの変数数を `capture_count` に設定
2. VM が `create_closure` opcode を実行する際、`stack[frame.base + capture_offset]` から
   `capture_count` 個の値をコピーして `closure_bindings` 配列を作成
3. クロージャ呼出し時、VM が `closure_bindings` をフレーム先頭にコピー

### 多段ネストの例

```clojure
(fn [x]                    ;; Level 1: capture_count = 0
  (fn [y]                  ;; Level 2: capture_count = 1 (x)
    (fn [z]                ;; Level 3: capture_count = 2 (x, y)
      [x y z])))
```

Level 3 の関数は Level 1 の `x` と Level 2 の `y` の両方を必要とする。
`inherited_captures` により、Level 3 の `capture_count = 2` (Level 2 の
inherited_captures=1 + Level 2 の locals 中の y=1)。

### createClosure (vm.zig)

```zig
const cap_count = proto.capture_count;
const cap_start = frame.base + proto.capture_offset;
const bindings = allocator.alloc(Value, cap_count);
for (0..cap_count) |i| {
    bindings[i] = stack[cap_start + i];
}
```

### createMultiClosure (多アリティ関数)

多アリティ fn は複数の FnProto を持つが、全アリティで同じ
`closure_bindings` を共有する。`capture_count` は全プロトの最大値。

---

## sp_depth によるコンパイル時スタック追跡

コンパイラは実行時のスタック深度を `sp_depth` フィールドで静的に追跡する。

```
emit開始: sp_depth = capture_count (クロージャバインディング分)
パラメータ追加: sp_depth += param_count
local_load: sp_depth += 1
local_store: sp_depth は変化しない (同じスロットに上書き)
add/sub等: sp_depth -= 1 (2値消費、1値生成)
scope_exit: sp_depth をスコープ開始時の値に戻す
```

**scope_exit 命令**: let/loop ブロック終了時にローカルを除去しつつ、
ブロックの戻り値をスタックトップに維持する。

```
[..., local_a, local_b, result]
    ↓ scope_exit(scope_start=2, num_locals=2)
[..., result]
```

---

## letfn (相互再帰ローカル関数)

### 実装戦略

1. 全関数名に nil プレースホルダを push + addLocal
2. 各 fn をコンパイル → local_store で上書き
3. `letfn_fixup` opcode で既存 closure_bindings を実際の関数値で更新

### 注意: fn 名を渡さない

letfn の Phase 2 で fn に名前を渡すと、`analyzeFn` が自己参照用に余分な
ローカルを追加し、パラメータのインデックスがずれる。letfn スコープが
既に相互参照を提供しているため、fn 名は省略する。

---

## デバッグの難しさ

### 1. 静かに壊れる

TreeWalk はバグで大抵クラッシュするか明らかに間違う。
VM はスタックインデックスが 1 ずれていても、たまたまそこに
値があれば通ってしまう。特定条件でだけ壊れるバグの再現条件を
絞り込むまでが最も時間がかかる。

### 2. デバッグ手段

現状は stderr に一時的なトレースを仕込む方法:

```zig
// 例: local_load のデバッグ
std.debug.print("local_load slot={} value={}\n", .{slot, stack[frame.base + slot]});
```

体系的なバイトコードデバッガはまだない。将来的には:
- バイトコードのディスアセンブル表示
- ステップ実行 (opcode 単位)
- スタック/フレーム状態のダンプ

### 3. --compare による回帰検出

TreeWalk と VM の両方で同じ式を評価し、結果を比較する。
差異があれば MISMATCH を報告。ただし:
- 参照型 (Atom, Promise) は別オブジェクトのため常に MISMATCH
- 実行順序依存の副作用 (println 等) は検出困難
- 遅延シーケンスは force タイミングの差で結果が異なる場合がある

---

## 設計判断の根拠

### なぜデュアルバックエンド？

TreeWalk は実装が簡単で正しさの確認が容易。VM は高速だが正しさの検証が困難。
両方を維持し `--compare` で突き合わせることで、VM のバグを早期に発見できる。
開発コストは倍だが、デバッグ時間の削減で十分元が取れた。

### なぜスタックベース？

レジスタベースより実装が単純。関数呼出し時の引数の受け渡しが自然。
Clojure のセマンティクスでは CPU レジスタの直接利用は困難なため、
スタックベースの方が素直に対応できる。

### なぜ capture_offset を常に 0 に？

初期設計ではスタック途中からのキャプチャを想定していたが、
U4e/U4f の修正で「frame.base から capture_count 分を取る」方式に統一。
コードの単純さと正しさのトレードオフで、単純な方を選択した。
