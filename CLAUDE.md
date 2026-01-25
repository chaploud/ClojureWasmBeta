# ClojureWasmBeta

ZigでClojure処理系をフルスクラッチ実装するプロジェクト。

## プロジェクト概要

**目標**: 動作互換（ブラックボックス）のClojure処理系をZigで実装し、将来的にWasmで動作させる。

**方針**:
- 本家core.cljを「そのままロード」する方針は取らない
- JavaInterOp再実装はしない
- 同じ入力 → 同じ出力を保証する動作互換
- 初期はZigで全て実装（セルフホスト.cljは後）
- 網羅的・精査的アプローチ

## 設計ドキュメント

| ファイル | 内容 |
|---------|------|
| `plan/001_next_gen_plan.md` | 設計議論ログ（3プロジェクトの反省、設計論点） |
| `plan/002_consolidated_plan.md` | 統合設計プラン（確定方針、開発フェーズ） |
| `plan/003_token_patterns.md` | Clojureトークン完全リスト（本家LispReader調査結果） |

## 過去プロジェクトからの教訓

### SandboxClojureWasm
- **良かった点**: GC実装済み、314テスト、prelude.cljでマクロ動作
- **苦しみ**: 本家互換性の担保が曖昧、テストがあっても本家との差異が発見しづらい

### ClojureWasmPre
- **良かった点**: 「カスタムcore.cljは技術的負債」という強い方針
- **苦しみ**: 学習プロジェクトで終わった

### ClojureWasmAlpha
- **良かった点**: 本家core.cljを986行までロード、Reader/エラー表示充実
- **苦しみ**:
  - JavaInterOp再実装が無限に続く（`(. clojure.lang.RT ...)` 形式）
  - 本家core.cljの変更追従が困難
  - 「JavaInterOp排除」と言いながら実際はZigで再実装している矛盾

### 共通の教訓
1. **互換性検証の仕組みが最重要** - 本家と同じ結果を返すかの自動テスト
2. **網羅的なトークン/構文テスト** - Readerの問題は後で発覚すると大変
3. **対応状況の可視化** - 何ができて何ができないかを常に把握

## コーディング規約

- **日本語コメント優先**: ソースコード内のコメントは日本語で記述
- **ドキュメント**: 日本語で記述
- **識別子**: 英語（関数名、変数名、型名）

## ビルド・テスト

```bash
zig build              # ビルド
zig build test         # テスト
zig build run          # REPL起動
```

## 参照リポジトリ

- 本家Clojure: `~/Documents/OSS/clojure`
- sci: `~/Documents/OSS/sci`
- babashka: `~/Documents/OSS/babashka`
- Zig標準ライブラリ: `/opt/homebrew/Cellar/zig/0.15.2/lib/zig/std/`
- 旧プロジェクト: `~/Documents/MyProducts/ClojureWasmAlpha`
