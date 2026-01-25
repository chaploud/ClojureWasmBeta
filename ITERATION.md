# イテレーション管理

**開始時**: このファイルを確認し、次のアクションから着手
**終了時**: このファイルを更新し、コミット

---

## 次のアクション

1. **Reader** - S式の構築
   - `src/reader/reader.zig`
   - トークン列から Form を構築（3フェーズの Phase 1）
   - tokens.yaml の partial 項目（数値検証、文字名前解決等）を含む

---

## 完了

- [x] **zig init** - プロジェクト初期化
- [x] **Form設計** - `src/form.zig`（旧Value設計、Reader出力）
- [x] **Error設計** - `src/error.zig`
- [x] **Tokenizer（完了）** - `src/reader/tokenizer.zig`
  - ホワイトスペース（カンマ含む）、区切り文字
  - 整数/浮動小数点/有理数/16進/基数
  - 文字列、シンボル、キーワード
  - マクロ文字（quote, deref, meta, syntax-quote, unquote）
  - ディスパッチ（#_, #', #(, #{, ##, #?, #:, #^, #<）
  - tokens.yaml ほぼ done（partial は Reader 検証待ち）
- [x] **3フェーズアーキテクチャ設計** - `docs/reference/type_design.md`
  - Form (Reader) → Node (Analyzer) → Value (Runtime)
  - スタブ: node.zig, value.zig, var.zig, namespace.zig, env.zig, context.zig
- [x] **ディレクトリ構造設計** - `docs/reference/architecture.md`
  - base/, reader/, analyzer/, runtime/, lib/ を整理
  - 将来用スタブ: compiler/, vm/, gc/, wasm/

---

## 後回し

- **互換性テスト基盤** - 本家Clojureとの入出力比較
- **GC実装** - 初期は ArenaAllocator で代用

---

## 将来TODO（バックログ）

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

---

## イテレーション終了チェックリスト

- [ ] このファイルを更新した
- [ ] 実装したら `status/*.yaml` を更新した（todo → wip → done）
- [ ] CLAUDE.md の変更があれば更新した
- [ ] `git add` → `git commit` した（意味のある単位で）
- [ ] `yamllint status/*.yaml` でエラーなし確認
