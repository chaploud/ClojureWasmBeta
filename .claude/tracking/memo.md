# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 現在地点

**Phase 8.6 try/catch/finally 例外処理 完了**

### 完了した機能

| Phase | 内容 |
|-------|------|
| 1-4 | Reader, Runtime基盤, Analyzer, TreeWalk評価器 |
| 5 | ユーザー定義関数 (fn, クロージャ) |
| 6 | マクロシステム (defmacro) |
| 7 | CLI (-e, 複数式, 状態保持) |
| 8.0 | VM基盤 (Bytecode, Compiler, VM, --compare) |
| 8.1 | クロージャ完成, 複数アリティfn, 可変長引数 |
| 8.2 | 高階関数 (apply, partial, comp, reduce) |
| 8.3 | 分配束縛（シーケンシャル `[a b]`、マップ `{:keys [a]}`) |
| 8.4 | シーケンス操作 (map, filter, take, drop, range 等) |
| 8.5 | 制御フローマクロ・スレッディングマクロ・ユーティリティ関数 |
| 8.6 | try/catch/finally 例外処理 + ex-info/ex-message/ex-data |

### 組み込み関数

```
算術: +, -, *, /, inc, dec
比較: =, <, >, <=, >=, not=
論理: not, and, or
述語: nil?, number?, integer?, float?, string?, keyword?,
      symbol?, fn?, coll?, list?, vector?, map?, set?, empty?, contains?,
      some?, zero?, pos?, neg?, even?, odd?
コレクション: first, rest, cons, conj, count, nth, get, list, vector
マップ: hash-map, assoc, dissoc, keys, vals
シーケンス: take, drop, range, concat, into, reverse, seq, vec,
           repeat, distinct, flatten
数値: max, min, abs, mod
文字列: str
出力: println, pr-str
例外: ex-info, ex-message, ex-data
ユーティリティ: identity
```

### 特殊形式

```
制御: if, do, let, loop, recur
関数: fn, def, defmacro, quote
高階: apply, partial, comp, reduce, map, filter
例外: try, throw
```

### 組み込みマクロ（8.5 で追加）

```
制御フロー: cond, when, when-not, if-let, when-let, and, or
スレッディング: ->, ->>
```

実装方式: Analyzer 内で Form→Form 変換（マクロ展開）後に再帰解析。
新しい Node 型は不要（既存の if, let, do 等に展開）。

---

## 次回タスク

### Phase 8.7 以降の候補

候補:
- Atom (状態管理)
- プロトコル (defprotocol, extend-type)
- LazySeq（真の遅延シーケンス）
- 文字列操作拡充 (subs, str/join, etc.)
- 正規表現

---

## 将来のフェーズ（優先順）

| Phase | 内容 | 依存 |
|-------|------|------|
| 8.7+ | 機能拡充 (Atom, プロトコル等) | - |
| 9 | LazySeq（真の遅延シーケンス）| 無限シーケンスに必要 |
| 10 | GC | LazySeq導入後に必須 |
| 11 | Wasm連携 | 言語機能充実後 |

詳細: `docs/reference/architecture.md`

---

## 申し送り (解消したら削除)

### Reader/Form
- 有理数は float で近似（Ratio 型は将来実装）

### Value/Runtime
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
- char_val は Form に対応していない（valueToForm でエラー）

### メモリ管理
- **メモリリーク（Phase 10 GC で対応予定）**:
  - evaluator.zig の args 配列（バインディングスタック改善で対応）
  - Value 所有権（Var 破棄時に内部 Fn が解放されない）
  - context.withBinding の配列（バインディング毎に新配列を確保）

### VM
- createClosure: frame.base > 0 のみキャプチャ（トップレベルクロージャバグ修正済み）

### シーケンス操作
- map/filter は Eager 実装（リスト全体を即座に生成）
- LazySeq が必要な場合（無限シーケンス、遅延実行）は別途実装が必要
- `(range)` 引数なし（無限シーケンス）は未サポート

### 例外処理
- throw は任意の Value を投げられる（Clojure 互換）
- 内部エラー（TypeError 等）も catch で捕捉可能（TreeWalk のみ、VM は UserException のみ）
- thrown_value は threadlocal に `*anyopaque` で格納（レイヤリング維持）
- VM: ExceptionHandler スタックで try/catch の状態を管理、ネスト対応
- Zig 0.15.2 で `catch` + `continue` パターンが LLVM IR エラーを引き起こすため、ラッパー関数で回避

### 組み込みマクロ
- and/or は短絡評価（let + if に展開）
- 合成シンボル名 `__and__`, `__or__` を使用（衝突の可能性は低いが gensym が理想）

---

## 開発ワークフロー

1. **TreeWalk で正しい振る舞いを実装**
2. **VM を同期（同じ結果を返すように）**
3. **`--compare` で回帰検出**
4. **テスト追加 → コミット**

```bash
# 開発時の確認コマンド
zig build                                    # ビルド
zig build test                              # 全テスト
./zig-out/bin/ClojureWasmBeta -e "(+ 1 2)"  # 式評価
./zig-out/bin/ClojureWasmBeta --compare -e "(+ 1 2)"  # 両バックエンド比較
```
