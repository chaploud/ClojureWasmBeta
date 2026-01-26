# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 現在地点

**Phase 8.2 完了** - 評価器の骨格が完成した段階。
「Clojureらしさ」を支えるデータ抽象層（分配束縛、遅延シーケンス、プロトコル）はまだない。

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

### 組み込み関数

```
算術: +, -, *, /
比較: =, <, >, <=, >=
述語: nil?, number?, integer?, float?, string?, keyword?,
      symbol?, fn?, coll?, list?, vector?, map?, set?, empty?
コレクション: first, rest, cons, conj, count, nth, list, vector
出力: println, pr-str
```

### 特殊形式

```
制御: if, do, let, loop, recur
関数: fn, def, defmacro, quote
高階: apply, partial, comp, reduce
```

---

## 次回タスク

### Phase 8.3: 分配束縛 (Destructuring) ← 最優先

これがないと実用的なClojureコードが書けない。

**実装対象**:
```clojure
;; ベクター分配
(let [[a b c] [1 2 3]] (+ a b c))
(let [[x & rest] [1 2 3 4]] rest)
(let [[a b :as all] [1 2]] all)

;; マップ分配
(let [{:keys [name age]} {:name "Alice" :age 30}] name)
(let [{x :x y :y} {:x 1 :y 2}] (+ x y))
(let [{:keys [a] :or {a 0}} {}] a)

;; fn 引数での分配
(fn [[x y]] (+ x y))
(fn [{:keys [x y]}] (+ x y))
```

**必要な変更**:
1. Analyzer: 分配パターンの解析
2. 新ノード or 既存LetNode拡張
3. Evaluator: 分配バインディング処理
4. VM: 対応するバイトコード

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
- マップ/セットは Reader で nil を返す仮実装

### Value/Runtime
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
- char_val は Form に対応していない（valueToForm でエラー）

### メモリ管理
- **メモリリーク（Phase 9 GC で対応予定）**:
  - evaluator.zig の args 配列（バインディングスタック改善で対応）
  - Value 所有権（Var 破棄時に内部 Fn が解放されない）

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
