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

| メソッド                  | ファイル                               | 目的                |
|---------------------------|----------------------------------------|---------------------|
| `valueHash()`             | `src/runtime/value.zig`                | ハッシュ計算        |
| `eql()`                   | `src/runtime/value.zig`                | 等価性判定          |
| `printValue()`            | `src/runtime/value/printing.zig`       | 文字列表現          |
| `deepClone()`             | `src/runtime/value/collections.zig`    | ディープコピー      |
| GC mark/sweep             | `src/gc/gc.zig`, `src/gc/tracing.zig`  | GC 対応             |

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

| 項目                 | ルール                           |
|----------------------|----------------------------------|
| コメント             | 日本語                           |
| コミットメッセージ   | 日本語                           |
| 識別子               | 英語                             |
| 構造体               | 小さく (Token: 8-16 バイト以内)  |
| comptime             | テーブル類はコンパイル時構築     |
| メモリ管理           | ArenaAllocator (フェーズ単位)    |
| 参照方式             | 配列 > ポインタ (NodeId = u32)   |

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

## 参照ドキュメント

| ドキュメント                     | 内容                              |
|----------------------------------|-----------------------------------|
| `docs/reference/architecture.md` | 全体設計・ディレクトリ構成        |
| `docs/reference/type_design.md`  | 3フェーズ型設計                   |
| `docs/reference/vm_design.md`    | VM スタック・クロージャ契約       |
| `docs/reference/gc_design.md`    | GC 設計                           |
| `docs/reference/zig_guide.md`    | Zig 0.15.2 落とし穴              |
| `plan/notes.md`                  | 技術ノート                        |
| `status/vars.yaml`               | 実装状況 (yq で照会)             |
