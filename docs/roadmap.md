# ロードマップ — ポスト実装フェーズ

> Phase LAST (Wasm 連携) 完了後の改善ロードマップ。
> 機能追加フェーズからリファクタリング・高速化・安定化フェーズへ移行。
>
> 作成: 2026-01-28
> 参照: `.claude/tracking/remaining_tasks.md` (着想メモ)

---

## 現在のプロジェクト指標

| 指標                     | 値                             |
|--------------------------|--------------------------------|
| Zig ソースコード         | ~32,000 行 (src/ 以下)         |
| clojure.core 対応状況    | 545 done / 169 skip / 714 total |
| テスト                   | 815 pass / 1 fail(意図的)      |
| 最大ファイル             | core/sequences.zig 1,328 行    |
| デュアルバックエンド     | TreeWalk + BytecodeVM          |
| GC                       | 式境界 Mark-Sweep              |
| Wasm                     | zware (10 API 関数)            |

---

## フェーズ概要

```
Phase R: リファクタリング     — コード品質・保守性の向上
Phase P: 高速化               — ベンチマーク駆動のパフォーマンス改善
Phase G: GC・メモリ管理       — 世代別GCへの段階的移行
Phase U: UX改善               — REPL体験・エラーメッセージの向上
Phase S: セルフホスト         — pure Clojure 関数の .clj 移行 (長期)
Phase D: ドキュメント         — 利用者/開発者/発表用の3系統整備
```

### 依存関係と推奨順序

```
R1 (core.zig分割) ─────────────────────────────────┐
R2 (value.zig分割)                                  │
R3 (Zigイディオム再点検)                            │
R4 (テスト整理)                                     │
                                                     ↓
P1 (ベンチマーク基盤) ←───── R完了は必須ではないが望ましい
P2 (Zigレベル最適化)
P3 (VM最適化)
                                                     ↓
G1 (MemoryPool導入) ←──── P1完了が前提 (効果測定のため)
G2 (世代別GC)
                                                     ↓
U1 (REPL readline)        ←── 独立して着手可能
U2 (エラーメッセージ改善) ←── 独立して着手可能
U3 (doc/dir/apropos)
                                                     ↓
S1 (pure関数の.clj移行)   ←── P1完了が前提 (性能トレードオフ計測)
                                                     ↓
D1-D3 (ドキュメント)      ←── 各フェーズ完了後に随時
```

---

## Phase R: リファクタリング

> 目的: 変更の意図が追える、壊れにくい、読みやすい構造へ段階的に改善

### R1: core.zig ファイル分割 — ✅ 完了

11,095 行の core.zig を 18 ドメイン別サブモジュール + 181 行 facade に分割完了。
全テスト 760 pass 維持。Zig 0.15.2 では `pub usingnamespace` が廃止されたため、
threadlocal 変数は inline アクセサ関数 (get/set) で外部に提供。

### R2: value.zig の分割 — ✅ 完了

1,308 行の value.zig を facade + 3 サブモジュールに分割完了。
外部ファイルの import 変更不要 (facade が全型を re-export)。
全テスト 760 pass 維持。

| 分割先ファイル             | 行数 | 内容                                     |
|----------------------------|------|------------------------------------------|
| `runtime/value.zig`        | 726  | Value union + eql/format/deepClone (facade) |
| `runtime/value/types.zig`  | 349  | Symbol, Keyword, String, 関数型, 参照型  |
| `runtime/value/collections.zig` | 172 | PersistentList/Vector/Map/Set           |
| `runtime/value/lazy_seq.zig` | 121 | LazySeq + Transform + Generator         |

### R3: Zig 0.15.2 イディオム再点検

**対象**: プロジェクト横断で以下を再点検し、zig_guide.md も更新。

- ~~`MultiArrayList` の適用可能箇所~~ → 評価済み・見送り
  - FnArity (1-3 要素) が最有力候補だが配列が極小でキャッシュ改善効果限定的
  - PersistentMap は P2c で改善済み、Bytecode はリスク対効果不釣り合い
- ~~`MemoryPool` の適用~~ → 評価済み・見送り
  - Value サイズ可変 (16-40 bytes) で固定 slab 不適、Arena GC が既にほぼ最適
- ✅ `@branchHint(.cold)` の hot path 適用 (R3b)
  - vm.zig: execute ループ、push/pop/peek、callValue、tryInlineCall のエラーパス
  - evaluator.zig: callWithArgs のエラーパス、throw/internalErrorToValue
  - core/arithmetic.zig: add/sub/inc/dec/eq/lt/gt/lte/gte のアリティ・型エラー
  - core/helpers.zig: compareNumbers の型エラー
- ✅ `comptime` 検証強化 — builtin テーブルの名前重複チェック (R3a)
- switch exhaustiveness の統合 (新型追加時の更新箇所を減らす)
- エラー伝播の改善 (`catch { return error.X }` → `try` 活用)
- `anyopaque` キャスト削減 (wasm 周りで zware 型を直接使える箇所)

### R4: テスト整理 — ✅ 完了

- ✅ テストファイルの命名規約統一 (q1a_first_class → first_class_functions)
- compat/ と sci/ の境界は既に明確 (sci/ は compat/ のサブディレクトリ)
- bench/ と compat/ は既に分離済み
- ✅ テスト実行スクリプト (`run_tests.sh`) のエラーレポート改善 (-v/--verbose)
- ✅ clj-kondo 警告への対応 (.clj-kondo/config.edn で unresolved-symbol 抑制)

### R5: 不要ファイル・死コードクリーンアップ — ✅ 完了

- ✅ スタブファイル 4 件削除 (arena.zig, optimize.zig, ops.zig, stack.zig = -185 行)
- wasm/types.zig の未使用変換関数は将来の Wasm 型拡張で必要なため残留

### R6: Wasm ローダー重複排除 — ✅ 完了

- loader.zig に `loadModuleCore()` (PreInstantiateFn フック付き) を抽出
- wasi.zig は loader.loadModuleCore() に委譲 (~50 行の重複コード削減)
- テスト: wasm_basic/wasm_memory/wasm_host/wasm_wasi 全 pass

---

## Phase P: 高速化

> 方針: ベンチマークを先に置き、「前後差分」で進める。効果が測定できない最適化はやらない。

### P1: ベンチマーク基盤整備 — ✅ 完了

- `time` マクロを実装 (スタブ → `std.time.nanoTimestamp` による実タイミング計測)
- `test/bench/basic.clj`: 10 ベンチマーク (fib, recur, reduce, str, atom, loop, map, assoc)
- `test/bench/run_bench.sh`: 両バックエンド自動実行, 表形式出力, `--save`/`--compare` 対応

### P2: VM 最適化 — ✅ 完了 (構造改善、速度効果なし)

ベンチマーク P1 の結果に基づき、fib(25) の ~242k 再帰呼び出しをターゲットに最適化。

**P2a: 低侵襲最適化** (types.zig, vm.zig)
- findArity 単一アリティ fast path、例外ハンドラ分離、recur スタックバッファ
- 結果: 計測誤差内で変化なし

**P2b: フレームインライン化** (vm.zig, +179/-24 行)
- CallFrame に code/constants フィールド追加
- tryInlineCall(): fn_val/fn_proto をフレーム積みのみで処理 (execute 再帰排除)
- ret opcode: 親フレームの code/constants に切替
- 結果: 全テスト維持、速度効果なし
- 分析: per-instruction overhead が支配的で execute 再帰のコストは微小

**P2c: PersistentMap ハッシュインデックス** (collections.zig, value.zig)
- PersistentMap に hash_values/hash_index 追加 (entries は挿入順保持)
- Value.valueHash() で全型対応ハッシュ (eql 互換不変条件を維持)
- get: バイナリサーチ O(log n)、未構築時はリニアスキャンにフォールバック
- 結果: map lookup で ~7% 改善 (per-call overhead が支配的なため限定的)

**残る高インパクト候補**:

| 最適化                    | 期待効果 | 難易度 | 備考                      |
|---------------------------|----------|--------|---------------------------|
| NaN boxing                | 高       | 高     | Value サイズ縮小          |
| 定数畳み込み              | 中       | 中     | Compiler 側               |
| inline caching            | 高       | 高     | 関数呼び出し高速化        |

**tail call dispatch について**:
- Zig 0.15.2 の `@call(.always_tail, dispatch_fn, .{args})` で computed goto 相当
- opcode ごとに関数を分離し、次の opcode ハンドラへ tail call
- 分岐予測ミスの削減が期待できる
- 注意: 関数ポインタとの組み合わせで ABI 不一致エラーが出る場合あり

**NaN boxing について**:
- 現状: `Value = union(enum)` (tagged union)。32バイト程度
- NaN boxing: 64-bit double の NaN 空間にポインタ・整数・特殊値を埋め込む
  - メモリ使用量半減、キャッシュ効率大幅改善
  - ただし Value 型の全面的な書き換えが必要 (侵襲度: 高)
  - Zig では tagged union が既にコンパイラ最適化されるため、効果は要検証
- 判断: P1 のベンチマーク結果を見てから。Value サイズがボトルネックでなければ不要

**TreeWalk について**:
- 教育的価値が主目的のため、最適化対象外
- ただしボトルネックが致命的なら最低限の改善は検討

---

## Phase G: GC・メモリ管理の高度化

> 目的: 長期稼働でも破綻しにくい＆高速な実行環境へ

### G1: アロケータ最適化 (世代別GC の前段)

**現状**: GcAllocator (Mark-Sweep at expression boundary)

| 改善項目                      | 内容                                                   | 状態      |
|-------------------------------|--------------------------------------------------------|-----------|
| アロケーション計測            | GC 呼び出し頻度・回収量をログ出力する仕組み            | ✅ G1a    |
| pause time 計測               | mark/sweep フェーズの所要時間計測                      | ✅ G1b    |
| セミスペース Arena GC         | GPA 個別 free → Arena 一括解放 + ForwardingTable fixup | ✅ G1c    |
|                               | sweep 性能: 1,146ms → 29ms (~40x 高速化)              |           |
| MemoryPool 導入               | Value の頻繁な alloc/free を高速化                     | 未着手    |
|                               | `std.heap.MemoryPool(Value)` — slab/pool 方式          |           |
|                               | destroy 時にメモリを free list に返却 (ヒープ確保不要) |           |
| FixedBufferAllocator 活用     | VM スタックフレーム用に検討                            | 未着手    |

### G2: 世代別 GC

**方式**: Young (bump allocator) + Old (Mark-Sweep)

```
┌──────────────────────────────────────────┐
│ Young Generation (bump allocator)        │
│  - 高速割り当て (ポインタをインクリメント) │
│  - minor GC で生存オブジェクトを Old へ  │
│  - 短命オブジェクトはここで回収           │
└──────────────┬───────────────────────────┘
               │ promote (N回生存)
┌──────────────▼───────────────────────────┐
│ Old Generation (Mark-Sweep: 既存流用)    │
│  - major GC は頻度を下げる               │
│  - 長寿命オブジェクト (Var, Fn, NS)       │
└──────────────────────────────────────────┘
```

**Write Barrier**:
- Old → Young 参照の追跡が必要
- Card marking 方式を推奨 (実装が簡潔、オーバーヘッド ~2%)
  - ヒープを 512B チャンクに分割
  - Old 世代への書き込み時にチャンクを dirty マーク (1バイト書き込み)
  - minor GC 時に dirty チャンクのみスキャン
- 参考: JVM の SerialGC / G1GC、GraalVM SubstrateVM の Serial GC

**段階導入計画**:

| ステップ | 内容                                     | 前提     |
|----------|------------------------------------------|----------|
| G2a      | GC 計測基盤 (alloc 数、GC 頻度、pause)  | G1       |
| G2b      | Young generation bump allocator          | G2a      |
| G2c      | minor GC + promotion                    | G2b      |
| G2d      | write barrier (card marking)             | G2c      |
| G2e      | チューニング (閾値、promote 回数)        | G2d      |

**GC 方式の比較** (参考):

| 方式         | フラグメント | メモリ効率 | 速度   | 実装難度 | 移動 |
|--------------|-------------|-----------|--------|----------|------|
| Mark-Sweep   | あり         | 高         | 中     | 低       | なし |
| Copying       | なし         | 低 (50%)   | 高     | 中       | あり |
| Mark-Compact | なし         | 高         | 低     | 高       | あり |

→ Young: Copying (bump → minor GC でコピー)、Old: Mark-Sweep (既存) が最も現実的。

---

## Phase U: UX 改善

> 目的: REPL 体験とエラー体験を実用レベルに引き上げる

### U1: REPL readline / 履歴 — ✅ 完了

自前実装 (外部依存なし) で readline 風の行編集を実装。
`src/repl/line_editor.zig`: raw ターミナル + 矢印キー + 履歴 + Emacs ショートカット。
履歴ファイル: `~/.clj_wasm_history`。非 TTY 時は dumb モードにフォールバック。

### U2: エラーメッセージ改善

**現状**: `error.TypeError` が多く、情報が不足。

**目標** (babashka/sci 参考):

```
----- Error ------------------------------
Type:     TypeError
Message:  Expected number, got string: "hello"
Phase:    eval
Location: user.clj:42:10

  40 | (defn add-one [x]
  41 |   (+ x 1))
  42 | (add-one "hello")
       ^--- error here

----- Stack ------------------------------
user/add-one  - user.clj:40:1
user/-main    - user.clj:50:3
```

**段階導入**:

| ステップ | 内容                                          | 前提 | 状態      |
|----------|-----------------------------------------------|------|-----------|
| U2a      | "Expected X, got Y" 形式のエラーメッセージ    | なし | ✅ 完了   |
| U2b      | ソース位置の表示 (SourceInfo 活用)             | U2a  | ✅ 完了   |
| U2c      | スタックトレース (関数名 + ソース位置)         | U2b  | ✅ 完了   |
| U2d      | 周辺ソースコード表示                           | U2c  | ✅ 完了   |

**参考ドキュメント**: `docs/reference/error_design.md` (設計済み、未実装)

### U3: doc / dir / apropos — ✅ 完了

doc / dir / find-doc / apropos を実装。defn の docstring と arglists を Var に保存。
doc/dir はマクロ展開、find-doc/apropos は builtin 関数。

| 本家機能             | 説明                         | 状態      |
|----------------------|------------------------------|-----------|
| `(doc fn-name)`      | docstring 表示               | ✅ 完了   |
| `(dir ns-name)`      | NS の public var 一覧        | ✅ 完了   |
| `(find-doc "pat")`   | docstring パターン検索       | ✅ 完了   |
| `(apropos "pat")`    | 名前パターン Var 検索        | ✅ 完了   |
| `(source fn-name)`   | ソースコード表示             | 未実装    |
| Tab 補完             | NS/Var 名の補完              | 未実装    |

### U4: 既知バグの修正

`memo.md` の「既知の制限」セクションから:

| バグ                          | 優先度 | 難易度 |
|-------------------------------|--------|--------|
| ~~map-as-fn 2-arity~~         | ✅ 完了 (U4a) |        |
| ~~symbol-as-fn~~              | ✅ 完了 (U4a) |        |
| ~~sets-as-functions~~         | ✅ 完了 (U4a) |        |
| ~~with-redefs VM クラッシュ~~ | ✅ 再現不可 (自然修正) |        |
| ^:const 未対応                | 低     | 中     |
| with-local-vars 未実装        | 低     | 中     |
| ~~add-watch on var 未実装~~   | ✅ 完了 (U4g) |        |
| ~~thread-bound? 多引数~~      | ✅ 完了 (U4c) |        |
| ~~^:private / defn- 未対応~~  | ✅ 完了 (U4d) |        |
| defmacro inside defn          | 低     | 高     |

---

## Phase S: セルフホスト化

> 現時点では急がない。ベンチマーク結果を見てから判断。

**前提条件**:
- `load-file` + `require` が動作済み
- P1 (ベンチマーク基盤) 完了

**移行候補** (pure Clojure で実装可能な関数):

| 候補                | 現在の実装      | 移行後の形態       |
|---------------------|-----------------|-------------------|
| `juxt`              | マクロ展開       | .clj 関数          |
| `comp` (多引数)     | builtin          | .clj 関数          |
| `partial` (多引数)  | builtin          | .clj 関数          |
| `keep`              | マクロ展開       | .clj 関数          |
| `keep-indexed`      | マクロ展開       | .clj 関数          |
| `mapcat`            | マクロ展開       | .clj 関数          |
| `for`               | マクロ展開       | .clj マクロ        |
| `tree-seq`          | builtin (eager)  | .clj 関数          |
| `partition-by`      | builtin (eager)  | .clj 関数          |

**性能トレードオフ**:
- Zig builtin → Clojure 関数呼び出しでオーバーヘッド発生
- ベンチマークで「呼び出し頻度 × オーバーヘッド」を測定してから移行判断

### S1 完了サブタスク: 標準名前空間の .clj 提供

| Sub  | 内容                                         | 状態      |
|------|----------------------------------------------|-----------|
| S1a  | clojure.string (19 関数)                     | ✅ 完了   |
| S1b  | clojure.set (11 関数)                        | ✅ 完了   |
| S1c  | clojure.string 完全化 + clojure.walk (7 関数) | ✅ 完了   |
| S1d  | clojure.edn (read-string)                    | ✅ 完了   |
| S1e  | clojure.math (33 数学関数)                   | ✅ 完了   |
| S1f  | clojure.repl (find-doc/apropos/source/pst)   | ✅ 完了   |
| S1g  | clojure.data (diff)                          | ✅ 完了   |
| S1h  | clojure.stacktrace (print-stack-trace 等)    | ✅ 完了   |
| S1i  | clojure.template (apply-template/do-template)| ✅ 完了   |
| S1j  | clojure.zip (zipper ツリー操作)               | ✅ 完了   |

**長期ビジョン**:
- ブートストラップ `.clj` ファイル群を `src/clj/` に配置
- 起動時に `load-file` で自動読み込み
- Zig 側は最小限の primitive に絞る

---

## Phase D: ドキュメント

> 読者別に3系統で整備

### D1: 利用者向けドキュメント

| 文書                | 内容                                              |
|---------------------|---------------------------------------------------|
| README.md 改訂      | プロジェクト概要、ビルド方法、クイックスタート     |
| Getting Started      | インストール → CLI → REPL → ファイル実行           |
| 本家との差分一覧     | 未実装機能、挙動差異、skip 済み関数リスト          |
| Wasm チュートリアル  | .wasm ロード → 関数呼出 → メモリ操作 → WASI       |
| FAQ                  | よくある質問と回避策                               |

### D2: 開発者向けドキュメント

| 文書                  | 内容                                              |
|-----------------------|---------------------------------------------------|
| コード読み順ガイド    | reader → analyzer → evaluator → vm の読み方       |
| Value ライフサイクル図 | scratch → persistent, GC root, deepClone          |
| ビルド & テスト手順    | `zig build`, `run_tests.sh`, `--compare` の使い方 |
| 新機能追加ガイド      | builtin 関数追加の手順、vars.yaml 更新            |

### D3: 発表・コミュニティ向けドキュメント (ギーク寄り)

| トピック            | 内容                                              |
|---------------------|---------------------------------------------------|
| 全体構成            | 3フェーズ (Form→Node→Value)、デュアルバックエンド |
| 設計判断            | なぜ Zig、なぜ JVM interop 排除、なぜ zware       |
| 工夫の深掘り        | comptime テーブル、threadlocal callback、式境界 GC |
|                     | LazySeq 段階的 force、recur_buffer 最適化          |
| 数字                | 760 テスト、545 core 関数、32K 行 Zig、10 Wasm API |

---

## 他プロジェクトとの比較 (参考)

| プロジェクト   | 言語    | 方式                 | core 関数 | GC              | 特徴                     |
|----------------|---------|----------------------|-----------|-----------------|--------------------------|
| ClojureWasmBeta | Zig     | TreeWalk + BytecodeVM | 545 done  | Mark-Sweep      | Wasm 連携、デュアルBE    |
| jank           | C++     | LLVM JIT/AOT         | ~57%      | Boehm GC        | C++ interop、LLVM ネイティブ |
| sci            | Clojure | Tree-walking         | ~390      | JVM GC          | 組み込み向け             |
| babashka       | Clojure | sci + GraalVM NI     | sci 準拠  | SubstrateVM GC  | スクリプティング特化     |
| ClojureCLR     | C#      | .NET compiler        | Full      | .NET GC         | 本家互換、AOT 制約あり   |
| Joker          | Go      | Interpreter          | サブセット | Go GC           | Linter 兼用              |

---

## 推奨実行順序 (まとめ)

| 順序 | タスク                           | フェーズ | 理由                                 |
|------|----------------------------------|----------|--------------------------------------|
| 1    | core.zig ファイル分割            | R1       | 開発体験の最大改善、他の全作業を加速 |
| 2    | ベンチマーク基盤整備             | P1       | 全高速化・GC 改善の前提              |
| 3    | REPL readline/履歴               | U1       | 独立して着手可能、実用性直結         |
| 4    | エラーメッセージ改善             | U2       | 独立して着手可能、実用性直結         |
| 5    | value.zig 分割                   | R2       | R1 と並行可能                        |
| 6    | Zig イディオム再点検             | R3       | R1/R2 後に効果大                     |
| 7    | Zig レベル最適化                 | P2       | P1 の結果を見てから                  |
| 8    | VM 最適化                        | P3       | P2 と並行可能                        |
| 9    | アロケータ最適化                 | G1       | P1 の結果を見てから                  |
| 10   | 世代別 GC                        | G2       | G1 完了後                            |
| 11   | doc/dir/apropos                  | U3       | U2 完了後                            |
| 12   | セルフホスト                     | S1       | P1 完了後に判断                      |
| 13   | ドキュメント                     | D1-D3    | 各フェーズ完了後に随時               |

---

## 参照

- 着想メモ: `.claude/tracking/remaining_tasks.md`
- 現在地点: `.claude/tracking/memo.md`
- 技術ノート: `.claude/tracking/notes.md`
- 全体設計: `docs/reference/architecture.md`
- 型設計: `docs/reference/type_design.md`
- Zig ガイド: `docs/reference/zig_guide.md`
- メモリ戦略: `docs/reference/memory_strategy.md`
- エラー設計: `docs/reference/error_design.md`
- 実装状況: `status/vars.yaml`
