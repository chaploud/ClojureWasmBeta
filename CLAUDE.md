# ClojureWasmBeta

ZigでClojure処理系をフルスクラッチ実装。動作互換（ブラックボックス）を目指す。

現在の状態は `plan/memo.md` を参照。
実装状況は `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml` で照会。

## 実装方針

- **全てをZigで実装**（Tokenizer, Reader, Analyzer, Evaluator, VM, 組み込み関数）
- **JavaInterop再実装は行わない**（無限地獄を避ける）
- 本家.cljを「そのまま」読む方針は取らない
- Java依存を排除した形でcore機能を再実装

## セッションの進め方

### 開始時
1. **`CLAUDE.md` を再確認**（長時間実行時のドリフト防止）
2. `plan/memo.md` を確認
3. 「実行計画」テーブルで未完了の最初のタスクを特定
4. タスク詳細が必要なら `plan/roadmap.md` を参照

### 開発中
1. **TreeWalk で正しい振る舞いを実装**
2. **VM を同期**（同じ結果を返すように）
3. **`--compare` で回帰検出**
4. テスト追加 → コミット

### タスク完了時
1. memo.md の該当タスクを「完了」に更新
2. **パフォーマンス改善時はベンチマーク記録** (後述)
3. 意味のある単位で `git commit`
4. **次の未完了タスクへ自動的に進む**（実行計画を参照）

## 自律実行モード

ユーザーが不在でも以下のルールで継続実行する。

### 継続条件
- タスク完了後は `plan/memo.md` の実行計画で次の未完了タスクを選び、自動的に着手
- 各イテレーション開始時に `CLAUDE.md` を再確認してドリフトを防止

### 停止条件（以下の場合のみ停止）
1. **実行計画の全タスク完了**
2. **解決不能なブロッカー**: 3回以上の異なるアプローチを試しても解決できない場合のみ
   - ビルドエラー・テスト失敗は原因を調査して修正を試みる
   - 設計判断が必要な場合は `plan/notes.md` に選択肢を記録し、最も妥当な方を選んで進む

### 停止時の記録
停止する場合は `plan/memo.md` に以下を記録:
- 停止理由
- 試したアプローチ
- 次回セッションへの引き継ぎ事項

## ドキュメント構成

| パス                                | 内容                                 | 参照タイミング         |
|-------------------------------------|--------------------------------------|------------------------|
| `plan/memo.md`                      | 現在地点・実行計画テーブル           | 毎セッション（必須）   |
| `plan/notes.md`                     | 技術ノート・回避策・注意点           | 関連サブシステム作業時 |
| `plan/roadmap.md`                   | タスク詳細・スコープ外項目           | 詳細確認時             |
| `docs/reference/architecture.md`    | 全体設計・ディレクトリ構成           | 設計確認時             |
| `docs/reference/type_design.md`     | 3フェーズ型設計 (Form→Node→Value)    | 必要時のみ             |
| `docs/reference/zig_guide.md`       | Zig 0.15.2 の落とし穴・パターン      | 必要時のみ             |
| `docs/reference/vm_design.md`       | VM設計・スタック・クロージャ契約     | VM/コンパイラ変更時    |
| `docs/reference/gc_design.md`       | GC設計・セミスペース・fixup          | GC/メモリ変更時        |
| `docs/reference/lessons_learned.md` | バグ教訓集・横断的設計知見           | 設計判断時             |
| `docs/changelog.md`                 | 完了フェーズ履歴                     | 参照用（普段読まない） |
| `status/vars.yaml`                  | 実装状況（yq で照会）                | 関数追加時             |
| `status/bench.yaml`                 | ベンチマーク履歴（自動追記）         | パフォーマンス改善時   |
| `status/README.md`                  | status/ のスキーマ定義               | status/ 編集時         |

## コーディング規約

- **日本語コメント**: ソースコード内は日本語
- **コミットメッセージ**: 日本語
- **識別子**: 英語

## CLI 使い方

```bash
# 式を評価
clj-wasm -e "(+ 1 2)"

# スクリプトファイルを直接実行
clj-wasm script.clj

# バイトコードダンプ (デバッグ用)
clj-wasm --dump-bytecode -e "(defn f [x] (+ x 1))"

# 両バックエンドで評価して比較
clj-wasm --compare -e "(+ 1 2)"

# GC 統計表示
clj-wasm --gc-stats -e '(dotimes [_ 1000] (vec (range 100)))'

# REPL 起動 (引数なし)
clj-wasm
```

### CLI テスト時の注意

- **bash の `!` 展開に注意**: `-e '(swap! ...)'` のようにシングルクォート内に `!` を含むと、bash の history expansion が発動して予期しないエラーになる
- **対策**: `!` を含む Clojure コードは **ファイル経由** (`clj-wasm file.clj` または `load-file`) で実行する。`-e` での直接実行は避ける
- heredoc (`<< 'EOF'`) でファイルに書き出してから実行するのも有効

## ベンチマークスイート

パフォーマンス改善タスク (P3, G2 等) では**必ずベンチマークを実行**して効果を計測・記録すること。

```bash
# 回帰チェック (ClojureWasmBeta のみ、約4秒)
bash bench/run_bench.sh --quick

# 改善後に履歴記録 (必須)
bash bench/run_bench.sh --quick --record --version="P3 NaN boxing"

# 全言語比較 (ベースライン更新時のみ)
bash bench/run_bench.sh

# 高精度計測 (hyperfine 使用)
bash bench/run_bench.sh --quick --hyperfine
```

### オプション一覧

| オプション         | 効果                                    |
|--------------------|-----------------------------------------|
| (なし)             | 全7言語実行                             |
| `--quick`          | ClojureWasmBeta のみ (開発中推奨)       |
| `--record`         | status/bench.yaml に履歴追記            |
| `--version="名前"` | 記録時のバージョン名 (タスク名を推奨)   |
| `--hyperfine`      | ms 精度計測 (要: brew install hyperfine) |

### 5種類のベンチマーク

| 名前           | 内容                       | 主な計測対象                |
|----------------|----------------------------|-----------------------------|
| fib30          | 再帰 fib(30)               | 関数呼び出しオーバーヘッド  |
| sum_range      | range(1M) + sum            | 数値シーケンス              |
| map_filter     | filter/map/take/sum チェイン | HOF + lazy seq GC 圧力     |
| string_ops     | upper-case + 結合 ×10000   | 文字列処理                  |
| data_transform | マップ作成・変換 ×10000    | データ構造                  |

履歴は `status/bench.yaml` に蓄積される。`yq '.history' status/bench.yaml` で参照可能。

## Zig 0.15.2 ガイド

詳細: `docs/reference/zig_guide.md`

```zig
// ✅ ArrayList（.empty で初期化）
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);

// ✅ HashMap（Unmanaged形式）
var map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
defer map.deinit(allocator);
try map.put(allocator, key, value);

// ✅ stdout（バッファ必須）
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const stdout = &writer.interface;
try stdout.flush();  // 忘れずに

// ✅ tagged union の判定は switch
return switch (self) { .nil => true, else => false };
// ❌ self == .nil は不安定
```

## 設計原則

- **comptime**: テーブル類はコンパイル時構築
- **ArenaAllocator**: フェーズ単位で一括解放
- **配列 > ポインタ**: NodeId = u32 でインデックス参照
- **構造体は小さく**: Token は 8-16 バイト以内

## IDE連携ツール（ZLS / Emacs MCP）

Zig コードの探索・変更時は IDE 連携ツールを**積極的に活用**し、コンテキスト消費を抑えること。

### 使えるツールと用途

| ツール                 | 用途                           | 使い方                               |
|------------------------|--------------------------------|--------------------------------------|
| `imenu-list-symbols`   | ファイル内の関数・構造体を一覧 | ファイルを全文読む前に構造を把握     |
| `xref-find-references` | シンボルの全参照箇所を検索     | 型・関数の変更前に影響範囲を特定     |
| `getDiagnostics`       | コンパイルエラー・警告を取得   | 編集後、`zig build` 前にエラーを検出 |

### 活用パターン

**ファイルの構造把握（Read の前に）:**
```
imenu-list-symbols(file_path: "src/lib/core.zig")
→ 全関数の名前と行番号が返る → 必要な関数だけを Read で読む
```

**リファクタリング前の影響調査:**
```
xref-find-references(identifier: "Value", file_path: "src/runtime/value.zig")
→ Value を使う全ファイル・全行が返る → 変更の影響範囲を把握
```

**編集後の即座のエラー検出:**
```
getDiagnostics(uri: "file:///path/to/edited.zig")
→ コンパイルエラーがあればビルド前に検出
```

### 注意事項

- `xref-find-apropos` と `treesit-info` は Zig では未動作（tags / tree-sitter 未設定）
- `xref-find-references` は大量の結果を返す場合がある（Value 等のコア型）
- ZLS LSP プラグインが有効な場合、go-to-definition 等の追加ツールが使える可能性がある

## 参照

- 本家Clojure: `~/Documents/OSS/clojure`
- tools.reader: `~/Documents/OSS/tools.reader`
- sci / babashka: `~/Documents/OSS/sci`, `~/Documents/OSS/babashka`
- Zig標準ライブラリ: `/opt/homebrew/Cellar/zig/0.15.2/lib/zig/std/`
