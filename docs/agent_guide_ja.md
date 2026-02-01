# ClojureWasm 正式版: コーディングエージェント開発ガイド

> ClojureWasm Beta の知見を基に、Claude Code 等のコーディングエージェントで
> 正式版をフルスクラッチ実装するための参照資料・プロンプト設計・管理体制。
>
> 関連: [future.md](./future.md) (正式版設計構想)

---

## 0. 前提

- エージェント: **Claude Code** (claude-code CLI)
- ホスト言語: **Zig 0.15.2+**
- 参照実装: **ClojureWasmBeta** (本リポジトリ)
- 開発方式: **TDD (t-wada 方式 Red-Green-Refactor)** + Plan Mode

---

## 1. 参照ディレクトリ (`add-dir`)

Claude Code の `add-dir` で追加すべきディレクトリ群。
フェーズによって必要な参照が変わるため、段階的に追加する。

### 常時参照 (全フェーズ)

| ディレクトリ                 | 理由                          |
|------------------------------|-------------------------------|
| `<ClojureWasmBeta のパス>`   | Beta 実装 (主参照)            |
| `<clojure のパス>`           | 本家 Clojure (振る舞いの真実) |
| `<zig stdlib のパス>`        | Zig 標準ライブラリ            |

> パスは環境依存。Beta の CLAUDE.md を参照して実際のパスに読み替えること。

### Phase 1-2 (Reader + Analyzer)

| ディレクトリ                 | 理由                         |
|------------------------------|------------------------------|
| `<tools.reader のパス>`      | Clojure Reader 参照実装      |
| `<clojurescript のパス>`     | CLJS の reader/analyzer 参照 |

### Phase 3+ (Builtin + テスト)

| ディレクトリ                 | 理由                         |
|------------------------------|------------------------------|
| `<sci のパス>`               | SCI の builtin 実装パターン  |
| `<babashka のパス>`          | Babashka のテスト体系        |

### 選択的参照 (必要時のみ)

| ディレクトリ                 | 理由                        |
|------------------------------|-----------------------------|
| `<nrepl のパス>`             | nREPL プロトコル実装        |
| `<cider-nrepl のパス>`       | CIDER nREPL middleware      |
| `<babashka.nrepl のパス>`    | Babashka の nREPL 実装      |

---

## 2. プロジェクト構成と管理ファイル

### 2.1 ディレクトリ構成

```
clojurewasm/
├── .claude/                       # Claude Code
│   ├── CLAUDE.md                  # エージェント指示 (本体)
│   ├── settings.json              # 権限・フック設定
│   ├── skills/                    # カスタムスキル (Anthropic Skills 形式)
│   │   ├── tdd/
│   │   │   ├── SKILL.md
│   │   │   └── references/tdd-patterns.md
│   │   ├── phase-check/
│   │   │   └── SKILL.md
│   │   └── compat-test/
│   │       ├── SKILL.md
│   │       └── references/edge-cases.md
│   └── agents/                    # カスタムサブエージェント
│       ├── security-reviewer.md
│       ├── compat-checker.md
│       ├── test-runner.md
│       ├── codebase-explorer.md
│       └── debugger.md
├── .dev/                          # 開発内部 (git 管理)
│   ├── plan/                      # セッション計画・ログ
│   │   ├── memo.md                # 現在地点のみ (常に小さく保つ)
│   │   ├── active/                # 今のフェーズの計画+ログ (1セットだけ)
│   │   │   ├── plan_0003_vm_bytecode.md
│   │   │   └── log_0003_vm_bytecode.md
│   │   └── archive/              # 完了フェーズの計画+ログ (対で保存)
│   │       ├── plan_0001_tokenizer_reader.md
│   │       ├── log_0001_tokenizer_reader.md
│   │       ├── plan_0002_analyzer.md
│   │       └── log_0002_analyzer.md
│   ├── status/                    # 内部進捗追跡
│   │   ├── vars.yaml              # Var 実装状況
│   │   ├── bench.yaml             # ベンチマーク
│   │   └── namespaces.yaml        # 名前空間対応状況
│   └── notes/                     # 技術メモ・思考ノート
├── flake.nix                      # ツールチェーン定義
├── flake.lock
├── build.zig
├── build.zig.zon
├── src/
│   ├── api/                       # 公開 API (§17)
│   ├── common/                    # 共有コード
│   ├── native/                    # native 路線固有
│   ├── wasm_rt/                   # wasm_rt 路線固有
│   └── wasm/                      # Wasm InterOp (両路線共通)
│       ├── loader.zig             # .wasm ロード
│       ├── runtime.zig            # 関数呼び出し
│       ├── interop.zig            # メモリ操作・マーシャリング
│       ├── wit_parser.zig         # WIT パーサー (Phase 2)
│       └── wit_types.zig          # WIT 型定義 (Phase 2)
├── clj/                           # Clojure ソース (AOT → @embedFile)
│   └── core.clj                   # AOT コンパイル対象 (§9.6)
├── test/
│   ├── unit/
│   ├── e2e/
│   └── upstream/                  # upstream テスト変換 (§10)
├── docs/                          # 外向きドキュメント
│   ├── developer/                 # 開発者向け実践ガイド
│   ├── compatibility.md           # 互換性ステータス (自動生成)
│   ├── differences.md             # 本家 Clojure との差異
│   └── examples/                  # サンプルコード集
├── bench/                         # ベンチマークスイート
├── scripts/                       # CI/品質ゲートスクリプト
├── LICENSE
└── README.md
```

### 2.2 .dev/plan/ の運用フロー

```
フェーズ開始時:
  1. .dev/plan/active/ に plan_NNNN_タイトル.md を作成 (ゴール・タスクリスト)
  2. memo.md を更新 (現在のフェーズ番号・active ファイル名)

実装中:
  3. エージェントがタスク完了ごとに log_NNNN_タイトル.md に追記
  4. 計画変更があれば plan にも反映し、変更理由を log に記録
  5. memo.md の「次のタスク」を更新

フェーズ完了時:
  6. plan + log を .dev/plan/archive/ に移動
  7. 次のフェーズの plan を .dev/plan/active/ に作成
  8. memo.md を更新
```

**命名規則**: `plan_NNNN_short_title.md` / `log_NNNN_short_title.md`
- タイトルは英語スネークケース (言語ポリシーに従う)
- 4桁連番 (差し込み問題を回避。Beta では S, G, P... と乱立した)
- 番号は作成順。途中に差し込みが発生しても次の番号を使うだけ
- active/ には常に1セット (plan + log) だけ存在する

### 2.3 memo.md の構造

memo.md は **現在地点のみ** を記録する。小さく保つこと。
タスク詳細は .dev/plan/active/ の plan ファイルに書く。

```markdown
# ClojureWasm 開発メモ

## 現在地点

- 現在のフェーズ: .dev/plan/active/plan_0003_vm_bytecode.md
- 直近の完了: Analyzer の基本ノード生成
- 次のタスク: OpCode 定義とスタックマシン基盤
- ブロッカー: なし

## 完了フェーズ

| #    | タイトル           | 期間              | テスト数 |
|------|--------------------|-------------------|----------|
| 0001 | tokenizer_reader   | 2026-02 〜 2026-03 | 312      |
| 0002 | analyzer           | 2026-03 〜 2026-04 | 198      |
```

### 2.4 plan ファイルの構造

```markdown
# plan_0003_vm_bytecode.md

## ゴール
BytecodeVM の基盤を構築し、定数・算術・比較の opcode が動作する状態にする。

## 参照
- Beta: src/compiler/emit.zig, src/vm/vm.zig, src/compiler/bytecode.zig
- Beta 教訓: docs/reference/vm_design.md (スタック契約の重要性)
- 設計: docs/future.md §9.1 (コンパイラ-VM 間契約)

## タスクリスト

| # | タスク                                | 状態   | 備考                     |
|---|---------------------------------------|--------|--------------------------|
| 1 | OpCode enum 定義                      | 完了   |                          |
| 2 | Chunk (バイトコード列) 構造体         | 完了   |                          |
| 3 | VM スタックマシン基盤                 | 作業中 | Beta の stack_top 方式   |
| 4 | 定数ロード (op_const)                 | 未着手 |                          |
| 5 | 算術 opcode (+, -, *, /)              | 未着手 | NaN boxing 前提          |

## 設計メモ
- Beta との差異: VM をインスタンス化 (threadlocal 排除)
- NaN boxing は Phase 0003 で導入する (Beta の tagged union ではなく)
```

### 2.5 log ファイルの構造

```markdown
# log_0003_vm_bytecode.md

## 2026-04-10
- OpCode enum を定義 (24 opcodes)
- Beta では u8 だったが、正式版では enum(u8) にした (型安全性)

## 2026-04-11
- Chunk 構造体を実装。Beta と同じ ArrayList(u8) ベース
- ★ 計画変更: 定数テーブルを Chunk 内に持つ方式に変更
  (Beta では外部テーブルだったが、VM インスタンス化との相性が悪い)
  → plan のタスク4 を修正

## 2026-04-12
- VM スタックマシン基盤: 10 テスト pass
- 発見: Beta の stack_top ポインタ方式は NaN boxing と相性が良い
- 教訓: スタックオーバーフローチェックを最初から入れるべきだった
  (Beta では後から追加して3箇所バグが出た)
```

---

## 3. CLAUDE.md テンプレート

プロジェクトルートに配置する CLAUDE.md。
**Claude Code Best Practice に従い、簡潔に保つこと**。
Claude が自力で推測できる内容は書かない。

````markdown
# ClojureWasm

Zig で Clojure 処理系をフルスクラッチ実装。動作互換 (ブラックボックス) を目指す。

参照実装: <Beta のパス> (add-dir 済み)

現在の状態は .dev/plan/memo.md を参照。
設計の詳細は docs/future.md を参照。

## 言語ポリシー

- **コード内は全て英語**: 識別子、コメント、docstring、コミットメッセージ、PR 説明
- ソースコードおよびバージョン管理履歴に非英語テキストを含めない
- Zig 0.15.2 の作法に従う (docs/reference/zig_guide.md 参照)
- エージェントの応答言語は個人設定 — `~/.claude/CLAUDE.md` で指定する

> **コントリビューター向け**: エージェントの応答を英語以外で受け取りたい場合、
> 個人の `~/.claude/CLAUDE.md` (リポジトリにコミットされない) に指示を追加する。
> 例: `応答は日本語でお願いします。` / `Respond in Korean.`
> プロジェクトは言語中立に保ちつつ、個人の好みを尊重する。

## 開発方式: TDD (t-wada 方式)

IMPORTANT: t-wada (和田卓人) の推奨するテスト駆動開発の進め方に厳密に従うこと。

1. **Red**: まず失敗するテストを1つだけ書く
2. **Green**: そのテストを通す最小限のコードを書く
3. **Refactor**: テストが通る状態を維持しながらリファクタリング

- テストを書く前にプロダクションコードを書かない
- 一度に複数のテストを追加しない (1テスト→1実装→確認のサイクル)
- テストが Red になることを必ず確認してから Green に進む
- 「仮実装」→「三角測量」→「明白な実装」の順で進める
- リファクタリングでは振る舞いを変えない (テストが壊れたら即戻す)

## セッションの進め方

### 開始時
1. .dev/plan/memo.md を確認 (現在のフェーズと次のタスクを把握)
2. .dev/plan/active/ の plan ファイルでタスク詳細を確認

### 開発中
1. TDD サイクルで実装 (上記)
2. Beta のコードを参照するが、コピペではなく理解して再設計
3. テストが通ったらこまめにコミット
4. タスク完了・発見・計画変更は .dev/plan/active/ の log ファイルに追記

### タスク完了時
1. .dev/plan/active/ の plan ファイルの該当タスクを「完了」に更新
2. memo.md の「次のタスク」を更新
3. 意味のある単位で git commit
4. 次の未完了タスクへ自動的に進む

### フェーズ完了時
1. plan + log を .dev/plan/archive/ に移動
2. memo.md の「完了フェーズ」テーブルに追記
3. 次のフェーズの plan を .dev/plan/active/ に作成 (Plan Mode で)

## ビルドとテスト

```bash
# Enter dev shell (all tools on PATH)
nix develop

# Build
zig build

# Run tests
zig build test

# Specific test only
zig build test -- "Reader basics"

# Benchmark
bash bench/run_bench.sh --quick
```

## Beta との差異

正式版は Beta のフルスクラッチ再設計。以下を変更:
- VM をインスタンス化 (threadlocal 排除) → future.md §15.5
- GcStrategy trait でGC抽象化 → future.md §5
- BuiltinDef にメタデータ (doc, arglists, added) → future.md §10
- core.clj AOT コンパイル → future.md §9.6
- 設計判断は docs/adr/ に ADR として記録
````

---

## 4. スキル定義

> Skills ガイド (Anthropic) に基づく構成:
> - **YAML frontmatter**: `name` + `description` (トリガー条件を含む) + `metadata`
> - **Progressive Disclosure**: SKILL.md は簡潔に、詳細は `references/` に分離
> - **フォルダ構造**: `skills/<name>/SKILL.md` + `scripts/` + `references/`

### 4.1 TDD スキル

ファイル構成:

```
.claude/skills/tdd/
├── SKILL.md
└── references/
    └── tdd-patterns.md    # 仮実装・三角測量・明白な実装の詳細解説
```

SKILL.md の内容 (実際のデプロイ版は英語、ここでは日本語で説明):

```markdown
---
name: tdd
description: >
  t-wada 方式の TDD サイクル (Red-Green-Refactor) で関数やモジュールを実装する。
  「TDD で実装」「テスト駆動で」「write tests first」「Red-Green-Refactor」
  またはテスト付きで関数を実装する依頼の際に使用。
  既存コードにテストを追加するだけの場合は使用しない (完全な TDD サイクル以外は対象外)。
compatibility: Claude Code 専用。zig build test が必要。
metadata:
  author: clojurewasm
  version: 1.0.0
---
# TDD スキル

t-wada (和田卓人) の厳密な TDD サイクルに従い $ARGUMENTS を実装する。

## 手順

1. **テストリスト作成**: 実装すべき振る舞いをテストリストとして列挙
2. **最も単純なケースを選択**: テストリストから最も単純なものを1つ選ぶ
3. **Red**: 失敗するテストを書く。`zig build test` で失敗を確認
4. **Green**: テストを通す最小限のコードを書く。仮実装 (定数を返す等) でよい
5. **成功確認**: `zig build test`
6. **Refactor**: 重複を除去し、コードを整理する。テストは壊さない
7. **成功確認**: `zig build test`
8. **コミット**: `git commit` (テストが通っている状態のみ)
9. **次へ**: テストリストに戻り、次のケースを選ぶ (2へ)

## 主要パターン

詳細は `references/tdd-patterns.md` を参照:
- 仮実装: 最初のテストはハードコード定数で通す
- 三角測量: 2つ目のテストで一般化を強制する
- 明白な実装: パターンが明確になったら直接実装する

## ルール

- 一度に2つ以上のテストを追加しない
- テストが Red であることを確認せずに Green のコードを書かない
- リファクタリング中にテストを追加しない
- Beta のコードは参照するが、テストなしにコードを持ち込まない
```

references/tdd-patterns.md の内容:

```markdown
# TDD パターン (t-wada)

## 仮実装 → 三角測量 → 明白な実装

### 仮実装 (Fake It)
最初のテストをハードコード定数で通す。
テストインフラが動くことを確認し、アサーションを先に書くことを強制する。

例:
- テスト: `expect(add(1, 2) == 3)`
- 仮実装: `fn add(a, b) { return 3; }`

### 三角測量 (Triangulate)
仮実装では通らない2つ目のテストケースを追加する。
これにより一般化が強制される。

例:
- テスト2: `expect(add(3, 4) == 7)`
- 一般化: `fn add(a, b) { return a + b; }`

### 明白な実装 (Obvious Implementation)
パターンが最初から明確な場合は仮実装をスキップして直接実装する。
ロジックが自明な場合に使用。

## アンチパターン
- Green の前に複数のテストを書く
- テストが Red の状態でリファクタリングする
- Beta のコードをテストなしに持ち込む
```

### 4.2 Phase チェックスキル

ファイル構成:

```
.claude/skills/phase-check/
└── SKILL.md
```

SKILL.md の内容:

```markdown
---
name: phase-check
description: >
  現在の開発フェーズの進捗、未完了タスク、ブロッカーを確認する。
  「進捗」「ステータス」「次は何」「phase check」と言われた場合、
  またはセッション開始時の現状把握に使用。
  テスト実行だけの場合は使用しない (zig build test を直接使う)。
compatibility: Claude Code 専用。.dev/plan/ ディレクトリ構造が必要。
metadata:
  author: clojurewasm
  version: 1.0.0
---
# Phase チェック

現在の開発フェーズの進捗を確認する。

## 手順

1. `.dev/plan/memo.md` を読む — 現在のフェーズと位置を特定
2. `.dev/plan/active/` の plan ファイルを読む — タスク完了状況を確認
3. `zig build test` を実行 — pass/fail 数を報告
4. `.dev/status/vars.yaml` を集計 — 実装カバレッジ
5. 未完了タスクの一覧と次のアクションを推奨
6. ブロッカーがあれば報告
7. `.dev/plan/active/` の log ファイルの最新エントリを表示

## 出力フォーマット

以下の形式で要約:
- 現在のフェーズ: Phase N — [名前]
- タスク: X/Y 完了
- テスト: N 成功、M 失敗
- 次: [推奨タスク]
- ブロッカー: [あれば]
```

### 4.3 互換性テストスキル

ファイル構成:

```
.claude/skills/compat-test/
├── SKILL.md
└── references/
    └── edge-cases.md      # 辺境値のチェックリスト
```

SKILL.md の内容:

```markdown
---
name: compat-test
description: >
  特定の関数/マクロの本家 Clojure との互換性をテストする。
  「互換性チェック」「Clojure と比較」「upstream と比較」
  または特定の clojure.core 関数名を指定して確認する際に使用。
  一般的なテスト記述には使用しない (代わりに tdd スキルを使う)。
compatibility: Claude Code 専用。本家 Clojure への nREPL 接続が必要。
metadata:
  author: clojurewasm
  version: 1.0.0
---
# 互換性テスト

$ARGUMENTS を本家 Clojure と比較テストする。

## 手順

1. **本家の定義を検索**: 本家 Clojure ソースから探す
   (パスは CLAUDE.md に設定)
2. **本家の振る舞いを確認**: `clj-nrepl-eval -p <port> "(関数 引数)"`
3. **ClojureWasm と比較**: `clj-wasm -e "(関数 引数)"`
4. **差異を報告**し、テストケースを追加
5. **辺境値を確認**: `references/edge-cases.md` 参照
   - nil、空コレクション、負数、大きな値
   - 型変換の境界、アリティのバリエーション

## 出力フォーマット

| 式               | 本家      | ClojureWasm | 一致  |
|------------------|-----------|-------------|-------|
| (関数 引数1)     | 結果      | 結果        | ✅/❌  |
```

references/edge-cases.md の内容:

```markdown
# 辺境値チェックリスト

## 共通辺境値
- nil を引数に渡す
- 空コレクション: (), [], {}, #{}
- 要素1つのコレクション
- 負数、ゼロ、MAX_INT
- 空文字列、非常に長い文字列
- ネストした構造 (深さ3以上)

## 型変換
- int vs float: (fn 1) vs (fn 1.0)
- char vs string: (fn \a) vs (fn "a")
- keyword vs symbol: (fn :a) vs (fn 'a)

## アリティ
- 最小アリティ
- 最大アリティ (可変長引数の場合)
- 不正なアリティ (ArityException がスローされるべき)
```

---

## 5. サブエージェント定義

> サブエージェントは Claude Code 固有の機能 (Skills とは別)。
> 各サブエージェントは独立したコンテキストウィンドウで動作し、完了時にサマリーを返す。
>
> **主な設定フィールド**:
> - `tools` / `disallowedTools`: ツールの許可リスト / 拒否リスト
> - `model`: `haiku` (高速・低コスト) / `sonnet` (バランス) / `opus` / `inherit`
> - `permissionMode`: `default` / `acceptEdits` / `dontAsk` / `bypassPermissions` / `plan`
> - `skills`: 起動時にコンテキストに注入するスキル (親会話のスキルは継承されない)
> - `hooks`: サブエージェント内でのみ有効なライフサイクルフック
>
> **活用パターン** (§5.6 で詳述):
> - 冗長出力の分離 (テスト実行、ログ処理)
> - 並列リサーチ (独立したモジュールの同時調査)
> - サブエージェント連鎖 (レビュー → 修正 の順序実行)
> - 再開 (前回の作業コンテキストを保持して継続)

### 5.1 セキュリティレビュアー

```markdown
# .claude/agents/security-reviewer.md
---
name: security-reviewer
description: >
  Zig コードのセキュリティ問題を検出する読み取り専用エージェント。
  新モジュールのレビュー時、unsafe 操作の実装後、フェーズ完了前に
  プロアクティブに使用。メモリ安全性、GC 相互作用、入力バリデーションに焦点。
  コード修正は行わない — 問題の検出と報告のみ。
tools: Read, Grep, Glob, Bash
disallowedTools: Edit, Write
model: sonnet
permissionMode: plan
---
Zig コードのセキュリティ問題を検出する:

## チェックカテゴリ

1. **メモリ安全性**
   - バッファオーバーフロー (境界チェック漏れ)
   - use-after-free (GC 相互作用 — コレクション中に値が移動)
   - 二重解放
2. **入力バリデーション**
   - 未検証の外部入力 (Reader 入力、ファイル I/O)
   - 無制限の再帰 (深くネストされたフォーム)
3. **unsafe 操作**
   - @ptrCast / @intToPtr の誤用
   - 算術演算での整数オーバーフロー
   - NaN boxing のビット操作エラー
4. **GC 正確性**
   - アロケーション前にルートが登録されていない
   - GC セーフポイントをまたいでポインタを保持

## 出力

検出された各問題について以下を提示:
- ファイルパスと行番号
- 重大度: Critical / High / Medium / Low
- 脆弱性の説明
- 修正案
```

### 5.2 互換性チェッカー

```markdown
# .claude/agents/compat-checker.md
---
name: compat-checker
description: >
  本家 Clojure との振る舞い差異を検出する。新しい builtin の追加時、
  一括実装の後、名前空間の監査時にプロアクティブに使用。
  docstring、arglists、ランタイム動作を比較する。
  一般的なテスト記述には使わない (代わりに tdd スキルを使う)。
tools: Read, Grep, Glob, Bash
model: sonnet
skills:
  - compat-test
---
指定された関数について本家 Clojure との互換性を検証する。

> compat-test スキルのコンテンツ (edge-cases.md 含む) が自動注入される。

## 手順

1. 本家 `core.clj` で定義を検索 (パスは CLAUDE.md から)
2. 抽出: docstring、arglists、:added メタデータ
3. ClojureWasm の実装と比較
4. 本家は nREPL 経由、ClojureWasm は CLI 経由で実行
5. 差異があればテストケースを提案

## 重点チェック領域

- アリティ処理 (特に可変長引数)
- 返り値の型の一貫性
- エラーメッセージと例外型
- nil 伝播の振る舞い
- 遅延評価 vs 先行評価の差異

## 出力

関数ごとの互換性ステータスのサマリーテーブル、
続いて ❌ 項目に対するテストケース案。
```

### 5.3 テストランナー

冗長なテスト出力をメインコンテキストから分離する。
サブエージェントの最も効果的なパターンの1つ: 大量出力の操作を分離し、
関連するサマリーのみをメイン会話に返す。

```markdown
# .claude/agents/test-runner.md
---
name: test-runner
description: >
  テストスイートを実行し、結果のサマリーのみを返すエージェント。
  テスト実行時、「テストを走らせて」「テスト結果を確認」と言われた際に
  プロアクティブに使用。冗長なテスト出力をメインコンテキストから分離する。
  個別のテストデバッグには debugger サブエージェントを使う。
tools: Bash, Read, Grep, Glob
disallowedTools: Edit, Write
model: haiku
permissionMode: dontAsk
---
テストスイートを実行し、結果を簡潔に要約する。

## 手順

1. `zig build test` を実行
2. 出力を解析: pass/fail 数、失敗テスト名、エラーメッセージを抽出
3. 冗長なスタックトレースやコンパイル出力は省略し、要点のみ報告
4. 失敗がある場合は失敗テストのリストとエラーの要約を返す

## 出力フォーマット

- テスト結果: N pass / M fail
- 失敗テスト一覧 (あれば):
  - テスト名: エラーメッセージ (1行)
- 推奨アクション: [修正が必要なファイルの特定 / 全て成功]
```

### 5.4 コードベースエクスプローラー

Haiku モデルで高速・低コストにコードベースを探索する読み取り専用エージェント。
並列リサーチで複数モジュールを同時に調査する際に特に有効。

```markdown
# .claude/agents/codebase-explorer.md
---
name: codebase-explorer
description: >
  コードベースの構造やパターンを調査する読み取り専用エージェント。
  「〜の仕組みを調べて」「〜がどこで使われているか」「〜の構造を把握して」
  と言われた際に使用。複数の調査を並列で実行できる。
  コード変更は行わない — 調査と報告のみ。
tools: Read, Grep, Glob
disallowedTools: Edit, Write, Bash
model: haiku
permissionMode: plan
---
コードベースを探索し、構造・パターン・依存関係を調査する。

## 用途

- モジュール間の依存関係の把握
- 特定の型・関数の使用箇所の調査
- Beta と正式版の構造比較
- ファイル構成やディレクトリパターンの分析

## 出力フォーマット

- 調査対象のサマリー (何を調べたか)
- 発見事項の箇条書き (ファイルパス:行番号 付き)
- 関連ファイルの一覧
- 推奨事項 (あれば)
```

### 5.5 デバッガー

テスト失敗やビルドエラーの根本原因を分析し、修正まで行うエージェント。
security-reviewer (読み取り専用) とは異なり、Edit アクセスを持つ。

```markdown
# .claude/agents/debugger.md
---
name: debugger
description: >
  テスト失敗やビルドエラーの根本原因を分析し修正する。
  「テストが失敗する」「ビルドエラーが出る」「バグを直して」の際に
  プロアクティブに使用。エラーメッセージの分析からコード修正まで一貫して行う。
  セキュリティレビューには security-reviewer を使う。
tools: Read, Edit, Bash, Grep, Glob
model: inherit
permissionMode: acceptEdits
---
テスト失敗やビルドエラーの根本原因を分析し、修正する。

## 手順

1. エラーメッセージとスタックトレースを取得
2. 再現手順を特定
3. 障害箇所を分離
4. 最小限の修正を実装
5. 修正の動作を検証 (`zig build test`)

## デバッグプロセス

- エラーメッセージとログを分析
- 最近のコード変更を確認 (`git diff`)
- 仮説を立てて検証
- 必要に応じてデバッグ用ログを挿入
- 変数の状態を確認

## 出力

各問題について:
- 根本原因の説明
- 診断を裏付けるエビデンス
- 具体的なコード修正
- テストアプローチ
- 再発防止の推奨事項

症状ではなく、根本原因を修正することに集中する。
```

### 5.6 サブエージェント活用パターン

サブエージェントガイド (Anthropic) に基づく活用パターン。

#### メイン会話 vs サブエージェントの使い分け

| 状況                                       | 推奨          |
|--------------------------------------------|---------------|
| 頻繁なやり取りや反復的な改良が必要         | メイン会話    |
| 複数フェーズが重要なコンテキストを共有     | メイン会話    |
| 迅速で的を絞った変更                       | メイン会話    |
| 冗長な出力を生成するタスク (テスト実行等)  | サブエージェント |
| 特定のツール制限を強制したいタスク         | サブエージェント |
| 自己完結的でサマリーを返せるタスク         | サブエージェント |
| 独立した調査を複数並行したいとき           | サブエージェント (並列) |

#### パターン 1: 冗長出力の分離

テスト実行やログ処理を test-runner に委譲し、メインコンテキストを汚染しない。

```
テストを走らせて結果だけ教えて
→ test-runner サブエージェントが zig build test を実行
→ メイン会話には "42 pass / 1 fail: test_lazy_seq_gc - assertion error" のみ返る
```

#### パターン 2: 並列リサーチ

独立したモジュールの調査を同時に実行。各サブエージェントが独立して探索し、
Claude が結果を統合する。

```
Reader、VM、GC モジュールをそれぞれ並列でサブエージェントで調査して
→ 3つの codebase-explorer が同時起動
→ 各モジュールのサマリーが返り、Claude が統合レポートを生成
```

#### パターン 3: サブエージェント連鎖

順序のあるワークフローで、前のサブエージェントの結果を次に渡す。

```
security-reviewer でセキュリティ問題を見つけて、次に debugger で修正して
→ security-reviewer が問題リストを返す
→ Claude が問題リストを debugger に渡して修正を依頼
```

#### パターン 4: 再開 (Resume)

サブエージェントは完了後もコンテキストを保持しており、再開できる。
前回の調査結果を踏まえた追加作業に有効。

```
[compat-checker で map, filter, reduce を確認]
→ 完了

さっきの互換性チェックを再開して、take と drop も追加で確認して
→ 前回のコンテキスト (map, filter, reduce の結果) を保持したまま再開
```

> **注意**: サブエージェントは他のサブエージェントを生成できない。
> ネストが必要な場合はメイン会話からの連鎖で対応する。

---

## 6. フック定義

```jsonc
// .claude/settings.json (抜粋)
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "zig build test 2>&1 | tail -5"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'editing...'"
          }
        ]
      }
    ]
  }
}
```

> **注意**: Claude Code のフックは `PreToolUse`, `PostToolUse`, `Stop` の3種類。
> `matcher` でツール名をフィルタする。`postEdit`/`preCommit` は存在しない。
> 詳細: [Claude Code Hooks](https://code.claude.com/docs/en/hooks)

---

## 7. ツールチェーン要求 (Nix Flake)

```nix
# flake.nix
{
  description = "ClojureWasm development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # === コンパイラ ===
            zigpkgs."0.15.2"        # Zig コンパイラ (バージョン固定)

            # === Wasm ランタイム ===
            wasmtime                 # Wasm 実行・テスト用

            # === Clojure (互換性テスト用) ===
            clojure                  # 本家 Clojure (振る舞い参照)
            jdk21                    # Clojure 実行に必要
            babashka                 # スクリプティング

            # === ベンチマーク・計測 ===
            hyperfine                # コマンドラインベンチマーク
            valgrind                 # メモリプロファイリング (Linux)

            # === データ処理 ===
            yq-go                    # YAML 処理 (vars.yaml 等)
            jq                       # JSON 処理

            # === 開発補助 ===
            python3                  # スクリプト・テスト生成
            nodePackages.prettier    # Markdown フォーマッタ

            # === VCS ===
            git
            gh                       # GitHub CLI
          ];

          shellHook = ''
            echo "ClojureWasm dev shell (Zig $(zig version))"
            echo "Tools: clojure, wasmtime, hyperfine, yq"
          '';
        };
      });
}
```

### ツールの役割

| ツール      | 用途                                       | Claude Code での利用場面          |
|-------------|--------------------------------------------|-----------------------------------|
| zig         | コンパイル・テスト・ビルド                 | 常時                              |
| wasmtime    | Wasm バイナリの実行テスト                  | wasm_rt 路線テスト時              |
| clojure     | 本家の振る舞い確認                         | 互換性テスト時 (`clj-nrepl-eval`) |
| babashka    | テスト生成スクリプト                       | upstream テスト変換時             |
| hyperfine   | ベンチマーク精密計測                       | パフォーマンス改善時              |
| yq          | vars.yaml / bench.yaml の照会・更新        | ステータス確認時                  |
| gh          | Issue/PR 作成、CI ステータス確認           | PR 作成時                         |

---

## 8. フェーズ別エージェント指示

各フェーズでの Claude Code への指示パターン。
CLAUDE.md は全フェーズ共通で簡潔に保ち、
フェーズ固有の指示は **Plan Mode のプロンプト** で与える。

### Phase 0: プロジェクト初期化

```
Plan Mode で以下を実行:

1. flake.nix でツールチェーンを構築 (nix develop で確認)
2. build.zig の雛形を作成 (zig build / zig build test が通る状態)
3. src/ 以下のディレクトリ構造を docs/future.md §17 に従って作成
4. CLAUDE.md, .dev/plan/memo.md, .dev/status/vars.yaml の初期版を作成
5. docs/adr/0001-nan-boxing.md の雛形を作成
6. git init && 初回コミット
```

### Phase 1: Reader + Analyzer

```
.dev/plan/memo.md の Phase 1 タスクに従い、TDD で Reader を実装する。

参照:
- Beta の src/reader/reader.zig (構造を参考にするが、コピーではなく再設計)
- 本家 tools.reader: ~/Documents/OSS/tools.reader
- Zig 標準ライブラリの std.fmt, std.unicode

注意:
- Beta の Reader は 1 ファイル 2,800 行で肥大化した。正式版では分割する
- 数値パースの NaN/Infinity 対応は Beta の教訓 (docs/reference/lessons_learned.md)
- エラーメッセージは行番号・列番号を含めること
- Reader の入力検証 (深さ制限、サイズ制限) は §14 セキュリティ設計に従う
```

### Phase 2: Native 路線 VM

```
.dev/plan/memo.md の Phase 2 タスクに従い、TDD で VM を実装する。

参照:
- Beta の src/runtime/ (value.zig, evaluator.zig, vm/vm.zig)
- Beta の docs/reference/vm_design.md (スタック契約)
- Beta の docs/reference/gc_design.md (セミスペース GC)

設計変更点 (Beta との差異):
- Value は NaN Boxing を採用 (future.md §5)
- VM はインスタンス化する (threadlocal 排除、future.md §15.5)
- GcStrategy trait でGCを抽象化 (future.md §5)
- コンパイラ-VM 間の契約を型で表現 (future.md §9.1)

テスト戦略:
- 各 opcode に対して最低 3 テスト (正常系, 辺境値, エラー系)
- Beta の --compare パターンを再実装 (TreeWalk 参照実装 vs VM)
```

### Phase 3: Builtin 関数 + core.clj AOT

```
.dev/plan/memo.md の Phase 3 タスクに従い、builtin 関数を実装する。

2つの実装パス:
1. Zig builtin (vm_intrinsic + runtime_fn):
   - TDD でテスト→実装
   - BuiltinDef に doc, arglists, added メタデータを必ず付与
   - 本家 core.clj の docstring をそのまま使う (互換性のため)

2. core.clj AOT (core_fn + core_macro):
   - clj/core.clj にClojureで定義
   - ビルド時 AOT パイプラインを構築 (future.md §9.6)
   - 本家のブートストラップ順序を参考にする

互換性テスト:
- 各関数について本家と同じ入出力を返すことをテスト
- clj-nrepl-eval で本家の振る舞いを確認してからテストを書く
- .dev/status/vars.yaml に kind, ns, added を記録
```

### Phase 4+: 最適化・テスト拡充

```
パフォーマンス改善は必ずベンチマークで計測してから行う。

手順:
1. bench/run_bench.sh --quick でベースライン計測
2. プロファイリングでボトルネック特定
3. 最適化実装 (TDD: テストが壊れないことを確認)
4. bench/run_bench.sh --quick --record --version="最適化名"
5. 改善が確認できたらコミット、できなければリバート

upstream テスト取り込み:
- SCI テスト → Tier 1 変換 (future.md §10)
- ClojureScript テスト → Tier 1 変換
- 本家テスト → Tier 2/3 変換
```

---

## 9. セッション運用パターン

Claude Code Best Practice に基づくセッション管理。

### 9.1 コンテキスト管理

```
- タスク間で /clear を実行 (コンテキスト汚染防止)
- 1セッション = 1タスク (memo.md の1行) を原則とする
- 長時間セッションでは /compact "実装済みの関数リストとテスト結果を保持" を使う
- 調査はサブエージェントに委譲 ("サブエージェントで Reader の構造を調査して")
- テスト実行は test-runner に委譲 (冗長出力をメインコンテキストから分離)
- 複数モジュールの調査は codebase-explorer を並列起動
- Ctrl+B で実行中のタスクをバックグラウンドに移動可能
```

### 9.2 Writer/Reviewer パターン

```
大きな変更では2セッションに分ける:

セッション A (Writer):
  "Phase 2 の Value 型を TDD で実装して"

セッション B (Reviewer):
  "src/runtime/value.zig をレビューして。
   辺境値、GC との相互作用、Beta との設計差異に注目"
```

サブエージェント連鎖で1セッション内に収めることも可能:

```
"Value 型を TDD で実装して。完了したら
 security-reviewer で GC 相互作用をチェックして"
→ メイン会話で実装 → security-reviewer に自動委譲 → 結果をメインに返す
```

### 9.3 エラーからの回復

```
- テストが2回連続で失敗したら、/rewind でチェックポイントに戻す
- 同じ修正を2回試して失敗したら、/clear して新しいアプローチを試す
- ビルドエラーが解消しない場合:
  1. getDiagnostics で LSP エラーを確認
  2. Beta の同等コードを参照
  3. docs/reference/zig_guide.md の落とし穴を確認
```

### 9.4 並列セッション活用

```bash
# ファンアウト: upstream テストの一括変換
for file in $(cat test/upstream/pending.txt); do
  claude -p "test/upstream/$file を ClojureWasm 用に変換して。\
    Tier 1 ルール (future.md §10) に従う。\
    変換できたら test/upstream/converted/ に保存" \
    --allowedTools "Read,Write,Bash(zig build test *)"
done
```

---

## 10. 品質ゲートと CI

### 10.1 ローカル品質ゲート (コミット前)

```bash
#!/bin/bash
# scripts/pre-commit-check.sh
set -e

echo "=== zig build test ==="
zig build test

echo "=== vars.yaml consistency check ==="
# Verify kind field contains valid enum values
yq '.vars.clojure_core | to_entries | map(select(.value.kind != null))
    | map(select(.value.kind |
      test("^(special_form|vm_intrinsic|runtime_fn|core_fn|core_macro)$") | not))
    | length' .dev/status/vars.yaml | grep -q '^0$'

echo "=== namespace correspondence check ==="
# Verify ns field is set for all done vars
yq '.vars.clojure_core | to_entries
    | map(select(.value.status == "done" and .value.ns == null))
    | length' .dev/status/vars.yaml | grep -q '^0$'

echo "All checks passed."
```

### 10.2 CI パイプライン (GitHub Actions)

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command zig build test

  compat:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command bash scripts/compat-check.sh

  bench:
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix develop --command bash bench/run_bench.sh --quick
```

---

## 11. ADR テンプレート

```markdown
# docs/adr/0000-template.md

# ADR-NNNN: タイトル

## ステータス
提案 / 承認 / 非推奨 / 置換 (ADR-XXXX)

## コンテキスト
なぜこの決定が必要か。背景・制約。

## 決定
何を決定したか。

## 根拠
なぜこの選択肢を選んだか。検討した代替案。

## 結果
この決定により何が変わるか。トレードオフ。

## Beta での教訓
(該当する場合) Beta で学んだことがどう影響したか。
```

---

## 12. 参考資料

### TDD

- 和田卓人 (t-wada): テスト駆動開発の第一人者
  - Kent Beck『テスト駆動開発』翻訳者
  - Red-Green-Refactor サイクルの厳密な実践を推奨
  - 「仮実装」→「三角測量」→「明白な実装」の段階的一般化
  - AI エージェント時代において TDD は「ガードレール」として再評価されている
- t-wada の名前を Claude への指示に含めると、汎用的な「TDD」指示より
  厳密なサイクルに従う傾向がある (意味の拡散を防ぐアンカー効果)

### Claude Code Best Practice

- CLAUDE.md は簡潔に保つ (Claude が自力で推測できる内容は書かない)
- テスト・検証手段を提供することが最も効果の高い施策
- Plan Mode で調査→計画→実装→コミットの4フェーズに分ける
- コンテキストウィンドウが最も重要なリソース。/clear を積極的に使う
- サブエージェントで調査を委譲し、メインコンテキストを汚染しない
  - 冗長出力の分離 (テスト実行) が最も効果的なパターン
  - Haiku モデルで高速・低コストに探索系を処理
  - `skills` フィールドでスキルコンテンツをサブエージェントに事前注入
  - サブエージェントは再開可能 (前回のコンテキストを保持)
- フックで決定論的な振る舞いを保証 (CLAUDE.md の指示は助言的)
- スキルでドメイン知識を必要時にのみロード
- 並列セッションで Writer/Reviewer パターンを活用

### ソース

- [Claude Code Best Practices (Anthropic 公式)](https://code.claude.com/docs/en/best-practices)
- [t-wada: AIエージェント時代のTDD (Agile Journey)](https://agilejourney.uzabase.com/entry/2025/08/29/103000)
- [Claude 向け人名+テクニック一覧 (t-wada TDD)](https://memory-lovers.blog/entry/2025/06/27/102550)
