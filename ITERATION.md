# バックログ

> 将来TODO・完了履歴
> ワークフローは `/continue` スキル参照

---

## 完了

- [x] **zig init** - プロジェクト初期化
- [x] **Form設計** - `src/reader/form.zig`
- [x] **Error設計** - `src/base/error.zig`
- [x] **Tokenizer** - `src/reader/tokenizer.zig`
- [x] **3フェーズアーキテクチャ設計** - `docs/reference/type_design.md`
- [x] **ディレクトリ構造設計** - `docs/reference/architecture.md`
- [x] **Claude Code基盤** - `.claude/skills/continue/`

---

## 後回し

- **互換性テスト基盤** - 本家Clojureとの入出力比較
- **GC実装** - 初期は ArenaAllocator で代用

---

## 将来TODO

詳細: `docs/reference/architecture.md`

### Phase 1-2: 基盤

- [ ] Reader（S式構築）
- [ ] Runtime（value, var, namespace 実装）
- [ ] 簡易評価器（インタプリタ）

### Phase 3-4: 言語機能

- [ ] Analyzer（node, analyze, macroexpand）
- [ ] マクロシステム
- [ ] clojure.core 関数群
- [ ] clojure.string, clojure.set 等
- [ ] REPL

### Phase 5-6: 高速化

- [ ] Compiler（bytecode, emit, optimize）
- [ ] VM（バイトコード実行）
- [ ] GC（Mark-Sweep）

### Phase 7: Wasm連携

- [ ] Wasm Component Model 対応
- [ ] .wasm ロード・呼び出し
- [ ] 型マッピング（Clojure ↔ Wasm）
