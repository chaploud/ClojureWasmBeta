# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 現在地点

**Phase 8.4 シーケンス操作 完了** - map, filter, take, drop, range 等が動作。

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

### 組み込み関数

```
算術: +, -, *, /, inc, dec
比較: =, <, >, <=, >=
論理: not
述語: nil?, number?, integer?, float?, string?, keyword?,
      symbol?, fn?, coll?, list?, vector?, map?, set?, empty?, contains?
コレクション: first, rest, cons, conj, count, nth, get, list, vector
マップ: hash-map, assoc, dissoc, keys, vals
シーケンス: take, drop, range, concat, into, reverse, seq, vec,
           repeat, distinct, flatten
文字列: str
出力: println, pr-str
```

### 特殊形式

```
制御: if, do, let, loop, recur
関数: fn, def, defmacro, quote
高階: apply, partial, comp, reduce, map, filter
```

### シーケンス操作（8.4 で追加）

```clojure
;; map / filter（特殊ノード: ユーザー関数を呼び出し）
(map inc [1 2 3])                        ; => (2 3 4)
(filter (fn [x] (> x 2)) [1 2 3 4 5])   ; => (3 4 5)

;; 組み込みシーケンス関数
(take 3 (range 10))                      ; => (0 1 2)
(drop 2 [1 2 3 4 5])                     ; => (3 4 5)
(range 5)                                ; => (0 1 2 3 4)
(range 2 8)                              ; => (2 3 4 5 6 7)
(range 0 10 3)                           ; => (0 3 6 9)
(concat [1 2] [3 4])                     ; => (1 2 3 4)
(into [] (list 1 2 3))                   ; => [1 2 3]
(reverse [1 2 3])                        ; => (3 2 1)
(seq [1 2 3])                            ; => (1 2 3) / (seq []) => nil
(vec (list 1 2 3))                       ; => [1 2 3]
(repeat 3 :x)                           ; => (:x :x :x)
(distinct [1 2 1 3])                     ; => (1 2 3)
(flatten [[1 2] [3 [4 5]]])             ; => (1 2 3 4 5)

;; 複合パイプライン
(reduce + 0 (take 3 (map inc (range 10))))               ; => 6
(reduce + 0 (filter (fn [x] (> x 5)) (range 10)))        ; => 30
```

**注意**: map/filter は現在 Eager 実装（即座にリスト全体を生成）。
真の LazySeq（無限シーケンス対応）は将来のフェーズで実装。

---

## 次回タスク

### Phase 8.5: プロトコル or その他機能拡充

候補:
- プロトコル (defprotocol, extend-type)
- try/catch/finally (例外処理)
- Atom (状態管理)
- cond, when, when-not, if-let, when-let (制御フロー)
- threading macro (->, ->>)

---

## 将来のフェーズ（優先順）

| Phase | 内容 | 依存 |
|-------|------|------|
| 8.5 | プロトコル or 機能拡充 | - |
| 8.6 | LazySeq（真の遅延シーケンス）| 無限シーケンスに必要 |
| 9 | GC | LazySeq導入後に必須 |
| 10 | Wasm連携 | 言語機能充実後 |

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
- **メモリリーク（Phase 9 GC で対応予定）**:
  - evaluator.zig の args 配列（バインディングスタック改善で対応）
  - Value 所有権（Var 破棄時に内部 Fn が解放されない）
  - context.withBinding の配列（バインディング毎に新配列を確保）

### VM
- createClosure: frame.base > 0 のみキャプチャ（トップレベルクロージャバグ修正済み）

### シーケンス操作
- map/filter は Eager 実装（リスト全体を即座に生成）
- LazySeq が必要な場合（無限シーケンス、遅延実行）は別途実装が必要
- `(range)` 引数なし（無限シーケンス）は未サポート

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
