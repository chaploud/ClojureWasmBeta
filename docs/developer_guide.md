# Developer Guide

ClojureWasmBeta の開発に参加するための技術ガイド。

---

## コード読み順

初めてコードベースを読む場合の推奨順序:

### Level 1: 全体像を掴む

1. **`src/main.zig`** — CLI エントリポイント。引数解析と処理の分岐先がわかる
2. **`docs/reference/architecture.md`** — ディレクトリ構成と処理フロー
3. **`src/runtime/value.zig`** — Value 型 (facade)。全ての型がここに集約

### Level 2: 処理パイプライン

4. **`src/reader/tokenizer.zig`** → **`src/reader/reader.zig`** — Source → Form
5. **`src/analyzer/analyze.zig`** — Form → Node (マクロ展開、シンボル解決)
6. **`src/runtime/evaluator.zig`** — TreeWalk 評価器 (Node → Value)

### Level 3: VM

7. **`src/compiler/bytecode.zig`** — OpCode 定義
8. **`src/compiler/emit.zig`** — Node → Bytecode コンパイラ
9. **`src/vm/vm.zig`** — VM メインループ
10. **`docs/reference/vm_design.md`** — スタックフレーム・クロージャ契約

### Level 4: 基盤

11. **`src/runtime/env.zig`** — グローバル環境
12. **`src/runtime/namespace.zig`** — 名前空間
13. **`src/runtime/var.zig`** — Var (動的バインディング含む)
14. **`src/gc/gc.zig`** — GC (Mark-Sweep)
15. **`src/gc/gc_allocator.zig`** — セミスペース Arena

---

## Value ライフサイクル

```
Form (reader)           ← ソーステキストから構築
  ↓ analyze()
Node (analyzer)         ← マクロ展開・シンボル解決済み
  ↓ evaluate() / compile() + vm.run()
Value (runtime)         ← 実行結果。GC 管理下
  ↓ GC cycle
[alive] or [collected] ← Mark-Sweep で到達不能なら回収
```

### Value の型階層

```
Value (tagged union)
├── プリミティブ: nil, bool, int, float, char
├── 参照型 (ヒープ):
│   ├── string, keyword, symbol
│   ├── list, vector, map, set
│   ├── fn_val, partial_fn, comp_fn, multi_fn
│   ├── protocol, protocol_fn, fn_proto
│   ├── lazy_seq
│   ├── atom, delay, volatile, reduced, transient, promise
│   ├── regex, matcher
│   └── wasm_module
└── 特殊: var_val
```

ヒープに確保された Value は GcAllocator 経由でアロケーションされ、GC の追跡対象になる。

---

## 新しい組み込み関数の追加手順

### 1. サブモジュールに関数を追加

`src/lib/core/` 以下の適切なファイルに関数を追加。

```zig
// src/lib/core/arithmetic.zig (例)
pub fn myNewFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // 実装
    return Value{ .int = 42 };
}
```

シグネチャは常に `fn(std.mem.Allocator, []const Value) anyerror!Value`。

### 2. builtins テーブルに登録

同ファイルの `builtins` 配列に追加:

```zig
pub const builtins = [_]BuiltinDef{
    // ...既存の定義...
    .{ .name = "my-new-fn", .func = myNewFn },
};
```

comptime で自動登録されるため、他に変更は不要。

### 3. テスト追加

`test/` に対応するテストファイルを追加:

```clojure
;; test/test_my_new_fn.clj
(assert (= 42 (my-new-fn :anything)) "my-new-fn returns 42")
```

### 4. status/vars.yaml 更新

```yaml
my-new-fn:
  status: done
  type: fn
```

### 5. ビルド・テスト

```bash
zig build && bash test/run_tests.sh
```

---

## 新しい Value 型の追加手順

Value に新しいバリアントを追加するのは影響範囲が大きい。以下を全て更新する必要がある。

### 1. 型定義

`src/runtime/value/types.zig` に構造体を追加。

### 2. Value union にバリアントを追加

`src/runtime/value.zig` の Value tagged union に追加。

### 3. 必須メソッド更新

以下の switch を全て更新:

| メソッド       | ファイル                              | 目的           |
|----------------|---------------------------------------|----------------|
| `valueHash()`  | `src/runtime/value.zig`               | ハッシュ計算   |
| `eql()`        | `src/runtime/value.zig`               | 等価性判定     |
| `printValue()` | `src/runtime/value/printing.zig`      | 文字列表現     |
| `deepClone()`  | `src/runtime/value/collections.zig`   | ディープコピー |
| GC mark/sweep  | `src/gc/gc.zig`, `src/gc/tracing.zig` | GC 対応        |

### 4. Analyzer / Compiler / VM 更新

型に対応する新しい構文が必要な場合:
- `src/analyzer/node.zig` — Node バリアント追加
- `src/analyzer/analyze.zig` — 解析ロジック
- `src/compiler/emit.zig` — バイトコード生成
- `src/vm/vm.zig` — VM 実行ロジック

---

## テスト

### テスト実行

```bash
# 全テスト
bash test/run_tests.sh

# 特定テスト
zig-out/bin/ClojureWasmBeta test/test_arithmetic.clj

# verbose モード
VERBOSE=1 bash test/run_tests.sh
```

### テスト構成

```
test/
├── run_tests.sh            # テストランナー
├── test_*.clj              # 機能テスト (assert ベース)
├── compat/                 # 互換性テスト
├── clojure_test/           # clojure.test ベース
└── wasm/                   # Wasm テスト
```

### テストの書き方

```clojure
;; assert ベース (基本)
(assert (= 3 (+ 1 2)) "addition works")

;; clojure.test ベース
(ns my-test (:require [clojure.test :refer [deftest is testing]]))
(deftest my-test
  (testing "addition"
    (is (= 3 (+ 1 2)))))
```

---

## デバッグ

### バイトコードダンプ

```bash
clj-wasm --dump-bytecode -e "(defn f [x] (+ x 1))"
```

生成されるバイトコードの OpCode と operand を表示。

### --compare モード

```bash
clj-wasm --compare -e "(map inc [1 2 3])"
```

TreeWalk と VM の結果を比較。不一致があればバグ。

### GC 統計

```bash
clj-wasm --gc-stats -e '(dotimes [_ 100] (vec (range 100)))'
```

GC 回数、pause 時間、アロケーション数を表示。

### nREPL デバッグ

CIDER 等のエディタから接続して対話的にデバッグ可能。

```bash
clj-wasm --nrepl-server --port=7888
```

---

## コーディング規約

| 項目               | ルール                          |
|--------------------|---------------------------------|
| コメント           | 日本語                          |
| コミットメッセージ | 日本語                          |
| 識別子             | 英語                            |
| 構造体             | 小さく (Token: 8-16 バイト以内) |
| comptime           | テーブル類はコンパイル時構築    |
| メモリ管理         | ArenaAllocator (フェーズ単位)   |
| 参照方式           | 配列 > ポインタ (NodeId = u32)  |

---

## Zig 0.15.2 の注意点

詳細は `docs/reference/zig_guide.md` を参照。

```zig
// ArrayList (empty 初期化)
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);

// stdout (バッファ必須)
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const stdout = &writer.interface;

// tagged union 判定は switch
return switch (self) { .nil => true, else => false };
```

---

## パフォーマンス最適化

ClojureWasmBeta に施された最適化の全体像。変更時は `bash bench/run_bench.sh --quick` で回帰チェック。

### VM 算術 opcode 化 (P3)

`+`, `-`, `<`, `>` 等の算術・比較演算を汎用 `call` 命令ではなく専用 opcode で実行。
関数ルックアップと引数配列作成をスキップする。

- コンパイラ (`emit.zig`) が `(+ a b)` を `add` opcode に変換
- VM が opcode を直接ディスパッチ
- 対象ファイル: `src/compiler/emit.zig`, `src/vm/vm.zig`, `src/vm/opcodes.zig`

### 定数畳み込み (P3)

Analyzer 段階で `(+ 1 2)` → `3` のように定数式を事前計算。

- 対象ファイル: `src/analyzer/analyze.zig`

### Safe Point GC (P1a)

式境界でしか動かなかった GC を、VM の `recur` opcode 実行時にもチェック。
長い再帰ループ中のメモリ膨張を抑制する。

- 対象ファイル: `src/vm/vm.zig` (recur ハンドラ), `src/runtime/allocators.zig`

**重要な制約**: `call` 時の GC は実装できない。builtin 関数のローカル変数
(Zig スタック上の `Value`) は GC ルートとして追跡されないため、GC がオブジェクトを
移動するとローカル変数が dangling pointer になり SIGSEGV を引き起こす。
`recur` は VM フレームのスタック上にのみ値が存在するため安全。
詳細は `plan/notes.md` の「Safe Point GC の制約」を参照。

### Fused Reduce (P1c)

`(reduce + (take N (map f (filter pred (range M)))))` のようなパターンで、
lazy-seq チェーンを解析して単一ループに展開する。

仕組み:
1. `reduceLazy` が lazy-seq のネスト構造を走査 (take → map/filter → source)
2. `reduceFused` が base source を直接イテレーション
3. transform (map/filter) をインラインで適用
4. 中間 LazySeq 構造体を一切作成しない

- 対象ファイル: `src/lib/core/sequences.zig` (reduceLazy, reduceFused)

### ジェネレータ直接ルーティング (P1c)

`(reduce + (range 1000000))` のように transform も take もない素のジェネレータも
`reduceFused` で処理。`reduceIterative` (毎ステップ LazySeq 生成) を回避。

- 対象ファイル: `src/lib/core/sequences.zig` (reduceLazy の条件分岐)

### スタック引数バッファ (P1c)

reduce ループ内の `call(fn, args)` で毎回 `allocator.alloc(Value, 2)` していたのを
スタック変数 `var call_args_buf: [2]Value` で再利用。

- 対象ファイル: `src/lib/core/sequences.zig` (reduceSlice, reduceFused, reduceIterative)

### 遅延 Take / 遅延 Range (P1b)

- `(take N lazy-seq)` が具体化せず `LazySeq.Take` を返す
- `(range N)` が N > 256 で `LazySeq.initRangeFinite` (遅延ジェネレータ) を返す
- Fused Reduce と組み合わせて中間コレクション生成を排除

- 対象ファイル: `src/lib/core/sequences.zig`, `src/runtime/value/lazy_seq.zig`, `src/lib/core/lazy.zig`

### TreeWalk 高速算術 (P3)

TreeWalk 評価器にも算術のファストパスを追加。`+`, `-`, `*` の2引数 int 同士の場合に
汎用関数呼び出しを回避。

- 対象ファイル: `src/runtime/evaluator.zig`

### ベンチマーク結果

VM バックエンドでの最終結果 (Apple M4 Pro):

| ベンチマーク   | 初期値        | 最終値 (hyperfine) | 改善           |
|----------------|---------------|--------------------|----------------|
| fib30          | 1.90s / 1.5GB | 69ms / 2.1MB       | 27x速          |
| sum_range      | 0.07s / 133MB | 13ms / 2.1MB       | 5x速           |
| map_filter     | 1.75s / 27GB  | 1.8ms / 2.1MB      | 12857x省メモリ |
| string_ops     | 0.09s / 1.3GB | 6.6ms / 14MB       | 14x速          |
| data_transform | 0.06s / 782MB | 10ms / 22.5MB      | 6x速           |

### 保留中の最適化

| 最適化             | 保留理由                                          |
|--------------------|---------------------------------------------------|
| NaN boxing         | Value 24B→8B。全ファイル影響の大規模変更          |
| 世代別 GC 統合     | 基盤は G2a-c で実装済み。式境界 GC では効果限定的 |
| Inline caching     | tryInlineCall で既に実装済み、追加効果小          |
| Tail call dispatch | Zig では computed goto 不可、効果限定的           |

---

## 参照ドキュメント

| ドキュメント                     | 内容                        |
|----------------------------------|-----------------------------|
| `docs/reference/architecture.md` | 全体設計・ディレクトリ構成  |
| `docs/reference/type_design.md`  | 3フェーズ型設計             |
| `docs/reference/vm_design.md`    | VM スタック・クロージャ契約 |
| `docs/reference/gc_design.md`    | GC 設計                     |
| `docs/reference/zig_guide.md`    | Zig 0.15.2 落とし穴         |
| `plan/notes.md`                  | 技術ノート                  |
| `status/vars.yaml`               | 実装状況 (yq で照会)        |
