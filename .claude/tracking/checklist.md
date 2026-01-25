# 進捗チェックリスト

> 最終更新: 2025-01-25
> 現在: **Phase 1: Reader**

---

## 進め方

1つずつタスクを完了させる:
1. 実装
2. テスト (`zig build test`)
3. 記録更新
4. コミット
5. 次へ

---

## 現在のフェーズ: Reader 実装

### 次のタスク

- [ ] `src/reader/reader.zig` - S式構築の基本構造
  - Tokenizer から Form を構築
  - リスト `()` のパース
  - ベクター `[]` のパース
  - 数値リテラル（整数、浮動小数点）

- [ ] 数値検証（tokens.yaml の partial 項目）
  - 8進数 `0777`
  - 無効な8進数 `08`, `00` のエラー
  - ##Inf, ##-Inf, ##NaN の解釈

- [ ] 文字リテラル検証
  - 名前付き文字: `\newline`, `\space`, `\tab` 等
  - Unicode: `\uXXXX`
  - 8進: `\oXXX`

### 完了

- [x] Tokenizer 基本実装
- [x] Form 型設計
- [x] ディレクトリ構造設計

---

## バックログ

詳細は `ITERATION.md` 参照:

- Phase 1-2: Reader, Runtime, 簡易評価器
- Phase 3-4: Analyzer, マクロ, clojure.core
- Phase 5-6: Compiler, VM, GC
- Phase 7: Wasm Component Model

---

## 追加した機能ログ

| 日付 | 機能 | ファイル |
|------|------|----------|
| 2025-01-25 | Tokenizer | src/reader/tokenizer.zig |
| 2025-01-25 | Form 型 | src/reader/form.zig |
| 2025-01-25 | 3フェーズスタブ | src/analyzer/, src/runtime/ |
| 2025-01-25 | 将来スタブ | src/compiler/, src/vm/, src/gc/, src/wasm/ |
