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

| ディレクトリ                                          | 理由                             |
|-------------------------------------------------------|----------------------------------|
| `~/Documents/MyProducts/ClojureWasmBeta`              | Beta 実装 (主参照)               |
| `~/Documents/OSS/clojure`                             | 本家 Clojure (振る舞いの真実)    |
| `/opt/homebrew/Cellar/zig/0.15.2/lib`                 | Zig 標準ライブラリ               |

### Phase 1-2 (Reader + Analyzer)

| ディレクトリ                                          | 理由                             |
|-------------------------------------------------------|----------------------------------|
| `~/Documents/OSS/tools.reader`                        | Clojure Reader 参照実装          |
| `~/Documents/OSS/clojurescript`                       | CLJS の reader/analyzer 参照     |

### Phase 3+ (Builtin + テスト)

| ディレクトリ                                          | 理由                             |
|-------------------------------------------------------|----------------------------------|
| `~/Documents/OSS/sci`                                 | SCI の builtin 実装パターン      |
| `~/Documents/OSS/babashka`                            | Babashka のテスト体系            |

### 選択的参照 (必要時のみ)

| ディレクトリ                                          | 理由                             |
|-------------------------------------------------------|----------------------------------|
| `~/Documents/OSS/nrepl`                               | nREPL プロトコル実装             |
| `~/Documents/OSS/cider-nrepl`                         | CIDER nREPL middleware           |
| `~/Documents/OSS/babashka.nrepl`                      | Babashka の nREPL 実装           |

---

## 2. プロジェクト構成と管理ファイル

### 2.1 ディレクトリ構成

```
clojurewasm/
├── CLAUDE.md                    # エージェント指示 (本体)
├── CLAUDE.local.md              # ローカル固有設定 (.gitignore)
├── .claude/
│   ├── settings.json            # 権限・フック設定
│   ├── skills/                  # カスタムスキル
│   │   ├── tdd/SKILL.md
│   │   ├── phase-check/SKILL.md
│   │   └── compat-test/SKILL.md
│   └── agents/                  # カスタムサブエージェント
│       ├── security-reviewer.md
│       └── compat-checker.md
├── flake.nix                    # ツールチェーン定義
├── flake.lock
├── build.zig
├── build.zig.zon
├── src/
│   ├── api/                     # 公開 API (§17)
│   ├── common/                  # 共有コード
│   ├── native/                  # native 路線固有
│   └── wasm_rt/                 # wasm_rt 路線固有
├── core/
│   └── core.clj                 # AOT コンパイル対象 (§9.6)
├── test/
│   ├── unit/
│   ├── e2e/
│   └── imported/                # upstream テスト (§10)
├── plan/
│   ├── memo.md                  # 現在地点・実行計画
│   ├── roadmap.md               # タスク詳細
│   └── notes.md                 # 技術メモ
├── status/
│   ├── vars.yaml                # Var 実装状況
│   ├── bench.yaml               # ベンチマーク
│   └── namespaces.yaml          # 名前空間対応状況
├── doc/
│   └── adr/                     # Architecture Decision Records
├── book/                        # mdBook ドキュメント
├── bench/                       # ベンチマークスイート
└── examples/
```

### 2.2 plan/memo.md の構造

```markdown
# ClojureWasm 開発メモ

## 現在地点

- Phase: 1 (Reader + Analyzer)
- 直近の完了: Tokenizer 基本型
- 次のタスク: Reader の list/vector パース
- ブロッカー: なし

## 実行計画

| # | タスク                          | 状態     | 備考               |
|---|--------------------------------|----------|--------------------|
| 1 | Tokenizer                      | 完了     |                    |
| 2 | Reader: atom (数値, 文字列)    | 完了     |                    |
| 3 | Reader: list, vector           | 作業中   | Beta src/reader 参照 |
| 4 | Reader: map, set               | 未着手   |                    |
| 5 | Reader: quote, deref 等        | 未着手   |                    |
| ...                                                               |

## セッションログ

### 2026-02-01
- Tokenizer 実装完了 (178 テスト pass)
- 数値パースは Beta の教訓を反映 (NaN/Infinity 対応)
```

---

## 3. CLAUDE.md テンプレート

プロジェクトルートに配置する CLAUDE.md。
**Claude Code Best Practice に従い、簡潔に保つこと**。
Claude が自力で推測できる内容は書かない。

```markdown
# ClojureWasm

Zig で Clojure 処理系をフルスクラッチ実装。動作互換 (ブラックボックス) を目指す。

参照実装: ~/Documents/MyProducts/ClojureWasmBeta (add-dir 済み)

現在の状態は plan/memo.md を参照。

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
1. plan/memo.md を確認
2. 「実行計画」テーブルで未完了の最初のタスクを特定
3. 必要なら plan/roadmap.md でタスク詳細を確認

### 開発中
1. TDD サイクルで実装 (上記)
2. Beta のコードを参照するが、コピペではなく理解して再設計
3. テストが通ったらこまめにコミット

### タスク完了時
1. plan/memo.md の該当タスクを「完了」に更新
2. 意味のある単位で git commit (日本語メッセージ)
3. 次の未完了タスクへ自動的に進む

## ビルドとテスト

```bash
# 開発シェルに入る (全ツールが PATH に載る)
nix develop

# ビルド
zig build

# テスト実行
zig build test

# 特定テストのみ
zig build test -- "Reader 基本"

# ベンチマーク
bash bench/run_bench.sh --quick
```

## コーディング規約

- 日本語コメント・日本語コミットメッセージ (正式版で英訳)
- 識別子は英語
- Zig 0.15.2 の作法に従う (@docs/reference/zig_guide.md)

## Beta との差異

正式版は Beta のフルスクラッチ再設計。以下を変更:
- VM をインスタンス化 (threadlocal 排除) → §15.5 埋め込みモード対応
- GcStrategy trait でGC抽象化 → §5 モジュラー設計
- BuiltinDef にメタデータ (doc, arglists, added) → §10
- core.clj AOT コンパイル → §9.6
- 設計判断は doc/adr/ に ADR として記録

設計の詳細は docs/future.md を参照。
```

---

## 4. スキル定義

### 4.1 TDD スキル

```markdown
# .claude/skills/tdd/SKILL.md
---
name: tdd
description: t-wada 方式の TDD サイクルを実行
---
t-wada (和田卓人) の推奨するテスト駆動開発のサイクルに厳密に従い、
以下のステップで $ARGUMENTS を実装する。

## 手順

1. **テストリスト作成**: 実装すべき振る舞いをテストリストとして列挙する
2. **最も単純なケースを選ぶ**: テストリストから最も単純なものを1つ選ぶ
3. **Red**: 失敗するテストを書く。`zig build test` で失敗を確認する
4. **Green**: テストを通す最小限のコードを書く。仮実装 (定数を返す等) でよい
5. **`zig build test` で成功を確認する**
6. **Refactor**: 重複を除去し、コードを整理する。テストは壊さない
7. **`zig build test` で成功を確認する**
8. **コミット**: `git commit` する (テストが通っている状態のみ)
9. **テストリストに戻り、次のケースを選ぶ** (2へ)

## 仮実装 → 三角測量 → 明白な実装

- 仮実装: 最初のテストはハードコード定数で通す
- 三角測量: 2つ目のテストで一般化を強制する
- 明白な実装: パターンが明確になったら直接実装する

## 注意

- 一度に2つ以上のテストを追加しない
- テストが Red であることを確認せずに Green のコードを書かない
- リファクタリング中にテストを追加しない
- Beta のコードは参照するが、テストなしにコードを持ち込まない
```

### 4.2 Phase チェックスキル

```markdown
# .claude/skills/phase-check/SKILL.md
---
name: phase-check
description: 現在の開発フェーズの進捗を確認
---
現在の開発フェーズの進捗を確認する。

1. plan/memo.md を読み、現在のフェーズとタスクを確認
2. `zig build test` を実行し、テストの pass/fail 数を報告
3. status/vars.yaml の実装状況を集計
4. 未完了タスクの一覧を表示
5. ブロッカーがあれば報告
```

### 4.3 互換性テストスキル

```markdown
# .claude/skills/compat-test/SKILL.md
---
name: compat-test
description: 本家 Clojure との互換性をテスト
---
$ARGUMENTS の関数/マクロについて、本家 Clojure との互換性をテストする。

1. 本家のソースを確認:
   `~/Documents/OSS/clojure/src/clj/clojure/core.clj` で定義を探す
2. 本家の振る舞いを nREPL で確認:
   `clj-nrepl-eval -p <port> "(関数 引数)"` で実際の出力を得る
3. ClojureWasm で同じ式を評価:
   `clj-wasm -e "(関数 引数)"` で出力を比較
4. 差異があれば報告し、テストケースを追加
5. 辺境値 (nil, 空コレクション, 負数等) も確認
```

---

## 5. サブエージェント定義

### 5.1 セキュリティレビュアー

```markdown
# .claude/agents/security-reviewer.md
---
name: security-reviewer
description: コードのセキュリティ問題を検出
tools: Read, Grep, Glob
model: sonnet
---
Zig コードのセキュリティ問題を検出する:
- バッファオーバーフロー (境界チェック漏れ)
- use-after-free (GC との相互作用)
- 未検証の外部入力 (Reader への入力)
- 整数オーバーフロー
- @ptrCast / @intToPtr の不正使用
具体的な行番号と修正案を提示すること。
```

### 5.2 互換性チェッカー

```markdown
# .claude/agents/compat-checker.md
---
name: compat-checker
description: 本家 Clojure との振る舞い差異を検出
tools: Read, Grep, Glob, Bash
model: sonnet
---
指定された関数について本家 Clojure との互換性を検証する。
1. 本家 core.clj で定義を確認
2. 本家の docstring, arglists, :added を抽出
3. ClojureWasm の実装と比較
4. テストケースを提案
辺境値 (nil, 空, 大きな値) に特に注意すること。
```

---

## 6. フック定義

```jsonc
// .claude/settings.json (抜粋)
{
  "hooks": {
    "postEdit": [
      {
        "pattern": "src/**/*.zig",
        "command": "zig build test 2>&1 | tail -5",
        "description": "編集後に自動テスト実行"
      }
    ],
    "preCommit": [
      {
        "command": "zig build test",
        "description": "テスト失敗時はコミットをブロック"
      }
    ]
  }
}
```

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

            # === ドキュメント ===
            mdbook                   # mdBook ビルド

            # === 開発補助 ===
            python3                  # スクリプト・テスト生成
            nodePackages.prettier    # Markdown フォーマッタ

            # === VCS ===
            git
            gh                       # GitHub CLI
          ];

          shellHook = ''
            echo "ClojureWasm dev shell (Zig $(zig version))"
            echo "Tools: clojure, wasmtime, hyperfine, yq, mdbook"
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
| mdbook      | ドキュメントビルド・プレビュー             | ドキュメント更新時                |
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
4. CLAUDE.md, plan/memo.md, status/vars.yaml の初期版を作成
5. doc/adr/0001-nan-boxing.md の雛形を作成
6. git init && 初回コミット
```

### Phase 1: Reader + Analyzer

```
plan/memo.md の Phase 1 タスクに従い、TDD で Reader を実装する。

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
plan/memo.md の Phase 2 タスクに従い、TDD で VM を実装する。

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
plan/memo.md の Phase 3 タスクに従い、builtin 関数を実装する。

2つの実装パス:
1. Zig builtin (vm_intrinsic + runtime_fn):
   - TDD でテスト→実装
   - BuiltinDef に doc, arglists, added メタデータを必ず付与
   - 本家 core.clj の docstring をそのまま使う (互換性のため)

2. core.clj AOT (core_fn + core_macro):
   - core/core.clj にClojureで定義
   - ビルド時 AOT パイプラインを構築 (future.md §9.6)
   - 本家のブートストラップ順序を参考にする

互換性テスト:
- 各関数について本家と同じ入出力を返すことをテスト
- clj-nrepl-eval で本家の振る舞いを確認してからテストを書く
- status/vars.yaml に kind, ns, added を記録
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
for file in $(cat test/imported/pending.txt); do
  claude -p "test/imported/$file を ClojureWasm 用に変換して。\
    Tier 1 ルール (future.md §10) に従う。\
    変換できたら test/imported/converted/ に保存" \
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

echo "=== vars.yaml 整合性チェック ==="
# kind フィールドが正しい enum 値か
yq '.vars.clojure_core | to_entries | map(select(.value.kind != null))
    | map(select(.value.kind |
      test("^(special_form|vm_intrinsic|runtime_fn|core_fn|core_macro)$") | not))
    | length' status/vars.yaml | grep -q '^0$'

echo "=== 名前空間対応チェック ==="
# ns フィールドが設定されているか
yq '.vars.clojure_core | to_entries
    | map(select(.value.status == "done" and .value.ns == null))
    | length' status/vars.yaml | grep -q '^0$'

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
# doc/adr/0000-template.md

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
- フックで決定論的な振る舞いを保証 (CLAUDE.md の指示は助言的)
- スキルでドメイン知識を必要時にのみロード
- 並列セッションで Writer/Reviewer パターンを活用

### ソース

- [Claude Code Best Practices (Anthropic 公式)](https://code.claude.com/docs/en/best-practices)
- [t-wada: AIエージェント時代のTDD (Agile Journey)](https://agilejourney.uzabase.com/entry/2025/08/29/103000)
- [Claude 向け人名+テクニック一覧 (t-wada TDD)](https://memory-lovers.blog/entry/2025/06/27/102550)
