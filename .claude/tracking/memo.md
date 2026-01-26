# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 現在地点

**Phase 8.3 分配束縛 完了** - シーケンシャル分配・マップ分配の両方が動作。

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

### 組み込み関数

```
算術: +, -, *, /, inc, dec
比較: =, <, >, <=, >=
論理: not
述語: nil?, number?, integer?, float?, string?, keyword?,
      symbol?, fn?, coll?, list?, vector?, map?, set?, empty?, contains?
コレクション: first, rest, cons, conj, count, nth, get, list, vector
マップ: hash-map, assoc, dissoc, keys, vals
文字列: str
出力: println, pr-str
```

### 特殊形式

```
制御: if, do, let, loop, recur
関数: fn, def, defmacro, quote
高階: apply, partial, comp, reduce
```

### 分配束縛（8.3 で追加）

```clojure
;; シーケンシャル分配
(let [[a b c] [1 2 3]] (+ a b c))      ; => 6
(let [[x & rest] [1 2 3 4]] rest)      ; => (2 3 4)
(let [[a b :as all] [1 2]] all)        ; => [1 2]
(let [[a [b c]] [1 [2 3]]] (+ a b c))  ; => 6 (ネスト)

;; マップ分配
(let [{:keys [name age]} {:name "Alice" :age 30}] name) ; => "Alice"
(let [{x :x y :y} {:x 1 :y 2}] (+ x y))               ; => 3
(let [{:keys [a] :or {a 0}} {}] a)                      ; => 0
(let [{:keys [a b] :as m} {:a 1 :b 2}] m)               ; => {:a 1 :b 2}
(let [{:strs [name]} {"name" "Bob"}] name)              ; => "Bob"

;; fn 引数での分配（ベクター・マップ両対応）
((fn [[a b]] (+ a b)) [1 2])             ; => 3
((fn [{:keys [x y]}] (+ x y)) {:x 3 :y 4}) ; => 7

;; 順次バインディング（後続が前のバインディングを参照）
(let [x 1 y x] y)                      ; => 1
```

---

## 次回タスク

### Phase 8.4: 遅延シーケンス (LazySeq)

map, filter, take に必須。

---

## 将来のフェーズ（優先順）

| Phase | 内容 | 依存 |
|-------|------|------|
| 8.4 | 遅延シーケンス (LazySeq) | map/filter/take に必須 |
| 8.5 | プロトコル | 型の拡張性に必須 |
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
