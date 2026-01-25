# 作業メモ

> セッション間で共有すべき申し送り事項
> 古いメモは削除して肥大化を防ぐ

---

## 現在の状態（2025-01-25）

### 完了した設計

- **3フェーズアーキテクチャ**: Form → Node → Value
- **ディレクトリ構造**: base/, reader/, analyzer/, runtime/, lib/ + 将来用 compiler/, vm/, gc/, wasm/
- **Tokenizer**: ほぼ完了（tokens.yaml の partial 項目は Reader で検証）

### 次のタスク: Reader 実装

`src/reader/reader.zig` を作成し、Tokenizer からの Form 構築を実装する。

---

## 設計原則

### 3フェーズアーキテクチャ

```
Source → Tokenizer → Reader → Form
                              ↓
                           Analyzer → Node
                              ↓
                             VM → Value
```

詳細: `docs/reference/architecture.md`

### Zig 0.15.2 の注意点

詳細: `CLAUDE.md` の「落とし穴」セクション

- stdout はバッファ付き writer 必須
- format メソッド持ち型の `{}` は ambiguous
- メソッド名と同名のローカル変数はシャドウイングエラー
- tagged union の `==` 比較は switch で

---

## 技術的負債

（現時点ではなし）

---

## 過去の教訓

- 本家 Clojure / sci / babashka の実装を参照すると設計が明確になる
- Zig 0.15.2 の API は古いドキュメントと異なることがある
