# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Reader 実装 (`src/reader/reader.zig`)
  - 基本構造: Tokenizer → Form 変換
  - リテラル: 整数（10進/16進/8進/基数）、浮動小数点、有理数、文字列
  - シンボル、キーワード（名前空間対応）
  - コレクション: リスト `()`、ベクター `[]`
  - マクロ文字: quote, deref, syntax-quote, unquote, unquote-splicing
  - ディスパッチ: #\_ (discard), #() (fn), ##Inf/##NaN

---

## 次回タスク

### Phase 2: Runtime 基盤

1. **Value 型** (`src/runtime/value.zig`)
   - Form と似ているが実行時の値表現
   - nil, boolean, int, float, string, symbol, keyword
   - コレクション: list, vector, map, set
   - 関数: IFn インターフェース（将来）

2. **Var 型** (`src/runtime/var.zig`)
   - 名前空間修飾シンボルに束縛
   - root binding, thread-local binding（将来）

3. **Namespace 型** (`src/runtime/namespace.zig`)
   - シンボル → Var のマッピング
   - alias, refer の管理

4. **Env 型** (`src/runtime/env.zig`)
   - グローバル環境
   - Namespace のレジストリ

### 今後の検討事項

- マップ `{}` / セット `#{}` のデータ構造選択
  - HashMap vs 永続データ構造（HAMT）
- 文字リテラル `\a`, `\newline` の Value 表現

---

## 申し送り (解消したら削除)

- 有理数は現在 float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
