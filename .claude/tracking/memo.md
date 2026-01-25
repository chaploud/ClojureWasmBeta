# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Phase 4: ツリーウォーク評価器
  - Context: ローカルバインディング管理、recur機能
  - Evaluator: Node → Value 評価
  - clojure.core 組み込み関数
    - 算術: +, -, *, /
    - 比較: =, <, >, <=, >=
    - 述語: nil?, number?, integer?, float?, string?, keyword?, symbol?, fn?, coll?, list?, vector?, map?, set?, empty?
    - コレクション: first, rest, cons, conj, count, nth
    - 出力: println, pr-str

---

## 次回タスク

### Phase 5: E2E テスト

1. **統合テスト**
   - Reader → Analyzer → Evaluator の一連の流れをテスト
   - `(+ 1 2 3)` → `6` のような式を文字列から評価

2. **ユーザー定義関数**
   - fn のクロージャ完全実装
   - 関数呼び出しでのローカルバインディング

3. **def された関数の呼び出し**
   - `(def inc (fn [x] (+ x 1)))` → `(inc 5)` → `6`

### Phase 6: マクロシステム（後回し可）

- defmacro
- macroexpand
- Analyzer 拡張（マクロ展開）

### Phase 7: CLI

- `-e` オプション（式評価）
- 複数式の連続評価
- 状態保持（def の値を次の -e で使用可能）

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- 複数アリティ fn は未実装
- fn のクロージャは仮実装（nil を返す）
