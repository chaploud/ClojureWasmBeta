# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Tokenizer 実装完了
- Form 設計完了
- ディレクトリ構造設計（3フェーズアーキテクチャ）
- Claude Code 基盤整備

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

## 注意点

### Zig 0.15.2 落とし穴

CLAUDE.md の「Zig 0.15.2 ガイド」参照:
- stdout はバッファ付き writer 必須
- format メソッド持ち型の `{}` は ambiguous
- tagged union の `==` 比較は switch で
