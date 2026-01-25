# 作業メモ

> セッション間の申し送り + 次回タスク計画
> 古い申し送りは削除して肥大化を防ぐ

---

## 次回タスク

### Reader 実装 (`src/reader/reader.zig`)

1. **基本構造作成**
   - Tokenizer から Form を構築する Reader 構造体
   - `read()` 関数: トークン列 → Form

2. **リテラル対応**
   - 数値（整数、浮動小数点、有理数）
   - 文字列
   - シンボル、キーワード
   - nil, true, false

3. **コレクション対応**
   - リスト `()`
   - ベクター `[]`
   - マップ `{}`（将来）

4. **数値検証**（tokens.yaml の partial 項目）
   - 8進数 `0777` の値解釈
   - 無効な8進数 `08`, `00` のエラー
   - `##Inf`, `##-Inf`, `##NaN` の解釈

---

## 申し送り

### 完了した設計（2025-01-25）

- **3フェーズアーキテクチャ**: Form → Node → Value
- **ディレクトリ構造**: base/, reader/, analyzer/, runtime/, lib/ + 将来用スタブ
- **Tokenizer**: 完了（tokens.yaml の partial 項目は Reader で検証）

### Zig 0.15.2 注意点

CLAUDE.md の「落とし穴」セクション参照:
- stdout はバッファ付き writer 必須
- format メソッド持ち型の `{}` は ambiguous
- tagged union の `==` 比較は switch で

### 技術的負債

（現時点ではなし）

---

## 参照ドキュメント

必要時のみ参照（コンテキスト節約）:
- `ITERATION.md` - バックログ全体
- `docs/reference/architecture.md` - アーキテクチャ詳細
- `docs/reference/type_design.md` - 型設計
