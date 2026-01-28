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
| テスト                   | 760 pass / 1 fail(意図的)      |
| 最大ファイル             | core.zig 11,095 行             |
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

### R1: core.zig ファイル分割

**現状**: core.zig が 11,095 行で単一ファイル最大。変更時の認知負荷が高い。

**方針**: ドメイン別に分割し、comptime テーブルは維持。

| 分割先ファイル          | 責務                                              | 目安行数 |
|-------------------------|---------------------------------------------------|----------|
| `core/arithmetic.zig`   | +, -, *, /, mod, rem, quot, inc, dec, 比較演算     | ~800     |
| `core/collections.zig`  | conj, assoc, dissoc, get, nth, count, keys, vals   | ~1500    |
| `core/sequences.zig`    | map, filter, reduce, take, drop, range, lazy系     | ~2000    |
| `core/strings.zig`      | str, subs, clojure.string/*, format, regex         | ~1000    |
| `core/predicates.zig`   | nil?, number?, string?, every?, some 等            | ~500     |
| `core/io.zig`           | println, pr, prn, slurp, spit, printf              | ~400     |
| `core/wasm.zig`         | wasm/load-module, invoke, memory-*, close 等       | ~600     |
| `core/meta.zig`         | with-meta, meta, alter-meta!, vary-meta            | ~300     |
| `core/concurrency.zig`  | atom, swap!, reset!, deref, promise, volatile      | ~600     |
| `core/interop.zig`      | type, class, instance?, ancestors, hierarchy       | ~500     |
| `core/registry.zig`     | builtins comptime テーブル、ルックアップ           | ~500     |

**完了基準**: 全テスト 760 pass 維持。`zig build` 成功。

### R2: value.zig の分割

**現状**: 1,308 行。PersistentMap/PersistentVector/LazySeq 等が混在。

**方針**: 型ごとにファイル分割。

| 分割先ファイル               | 内容                                     |
|------------------------------|------------------------------------------|
| `runtime/value.zig`          | Value union 本体 + 基本メソッド (残留)   |
| `runtime/persistent_map.zig` | PersistentMap 実装                       |
| `runtime/persistent_vec.zig` | PersistentVector 実装                    |
| `runtime/lazy_seq.zig`       | LazySeq + Transform + force 系           |
| `runtime/types.zig`          | Atom, Delay, Volatile, Reduced 等の構造体 |

### R3: Zig 0.15.2 イディオム再点検

**対象**: プロジェクト横断で以下を再点検し、zig_guide.md も更新。

- `MultiArrayList` の適用可能箇所 (Node 配列、VM スタック等)
  - Zig コンパイラ自身がほぼ全ての構造体を MultiArrayList で格納
  - キャッシュ局所性とメモリ効率の大幅改善が期待できる
- `MemoryPool` の適用 (同一型の頻繁な alloc/free: Value, Node 等)
- `@branch(.likely, ...)` / `@branch(.unlikely, ...)` の hot path 適用
- `comptime` 検証強化 (builtin テーブルの名前重複チェック等)
- switch exhaustiveness の統合 (新型追加時の更新箇所を減らす)
- エラー伝播の改善 (`catch { return error.X }` → `try` 活用)
- `anyopaque` キャスト削減 (wasm 周りで zware 型を直接使える箇所)

### R4: テスト整理

- テストファイルの命名規約統一
- compat/ と sci/ の境界明確化
- ベンチマーク用テストと回帰テストの分離
- テスト実行スクリプト (`run_tests.sh`) のエラーレポート改善
- clj-kondo 警告への対応 (unresolved-symbol 等は設定ファイルで対応)

### R5: 不要ファイル・死コードクリーンアップ

- 未使用の実験ファイル削除
- 未参照のエクスポート関数の特定・削除
- `getDiagnostics` + `xref-find-references` で未使用シンボル検出

### R6: Wasm ローダー重複排除

- `loadModule` / `loadModuleWithImports` / `loadWasiModule` の共通部分をヘルパーに抽出
- テスト: wasm_basic/wasm_memory/wasm_host/wasm_wasi が全 pass

---

## Phase P: 高速化

> 方針: ベンチマークを先に置き、「前後差分」で進める。効果が測定できない最適化はやらない。

### P1: ベンチマーク基盤整備

**現状**: `test/bench/basic.clj` が存在するが、計測が `time` コマンドのみ。

**整備内容**:

| 項目                   | 内容                                                   |
|------------------------|--------------------------------------------------------|
| ベンチマークスイート   | fib(30), fib-iter(40), reduce(100k), str-concat(1k),  |
|                        | atom-inc(10k), sort(10k), map-filter-reduce(100k)      |
| 計測方法               | Clojure 側 `(time ...)` + Zig 側 `std.time` 内部計測   |
| 出力形式               | JSON/TSV で baseline 記録、diff 比較スクリプト          |
| 実行モード             | `--backend=treewalk` と `--backend=vm` の両方           |
| ビルドモード           | Debug, ReleaseSafe, ReleaseFast の3モード比較           |

**Zig ビルドモード比較** (参考):

| モード        | 安全チェック | 最適化レベル | 用途           |
|---------------|-------------|-------------|----------------|
| Debug         | 全有効       | なし         | 開発中         |
| ReleaseSafe   | 全有効       | O2相当       | テスト・計測   |
| ReleaseFast   | 無効         | O3相当       | 性能測定・本番 |
| ReleaseSmall  | 無効         | サイズ最適化 | 組み込み向け   |

### P2: Zig レベル最適化

ベンチマーク P1 の結果を見てから優先度を決定。候補:

| 最適化                    | 期待効果 | 難易度 | 前提条件     |
|---------------------------|----------|--------|--------------|
| Allocator 呼び出し頻度削減 | 中       | 低     | プロファイル |
| スタックバッファ活用       | 中       | 低     | なし         |
| PersistentMap 改善         | 高       | 高     | R2完了       |
|   (線形走査→HAMT or sorted) |        |        |              |
| MultiArrayList 適用        | 中       | 中     | R3完了       |
| MemoryPool 適用            | 中       | 中     | R3完了       |

**PersistentMap について**:
- 現状: 配列ベースの簡易実装 (O(n) ルックアップ)
- 選択肢:
  - HAMT (Hash Array Mapped Trie): Clojure 本家の方式。O(log32 n)。実装が複雑
  - Sorted Array + Binary Search: O(log n)。実装が簡潔。小マップで有効
  - 判断基準: ベンチマークで map ルックアップがボトルネックかどうか

### P3: VM 最適化

| 最適化                         | 期待効果 | 難易度 | 侵襲度 |
|--------------------------------|----------|--------|--------|
| tail call dispatch             | 高       | 中     | 低     |
|   (`@call(.always_tail, ...)`) |          |        |        |
| 定数畳み込み (Compiler 側)     | 中       | 中     | 低     |
| NaN boxing 検討                | 高       | 高     | 高     |
| inline caching                 | 高       | 高     | 高     |

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

| 改善項目                      | 内容                                                   |
|-------------------------------|--------------------------------------------------------|
| MemoryPool 導入               | Value の頻繁な alloc/free を高速化                     |
|                               | `std.heap.MemoryPool(Value)` — slab/pool 方式          |
|                               | destroy 時にメモリを free list に返却 (ヒープ確保不要) |
| FixedBufferAllocator 活用     | VM スタックフレーム用に検討                            |
| アロケーション計測            | GC 呼び出し頻度・回収量をログ出力する仕組み            |

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

### U1: REPL readline / 履歴

**現状**: 基本的な REPL は Phase 25 で実装済み。ただし readline/履歴なし。

**選択肢**:

| 方式                | 説明                                    | 難易度 |
|---------------------|-----------------------------------------|--------|
| linenoise (C lib)   | 軽量 readline 互換。~1,200 行。Zig 組込可 | 中     |
| 自前実装            | 最低限の行編集 + 履歴。外部依存なし     | 中     |
| Zig ecosystem lib   | ziglang コミュニティの readline 実装     | 要調査 |

**最低限の機能**:
- 上下キーによる履歴呼び出し
- 左右キーによるカーソル移動
- Home/End キー
- Ctrl-A/E/K/U (Emacs 風ショートカット)
- 履歴ファイル保存/読み込み (`~/.clojure_wasm_history`)

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

| ステップ | 内容                                          | 前提 |
|----------|-----------------------------------------------|------|
| U2a      | "Expected X, got Y" 形式のエラーメッセージ    | なし |
| U2b      | ソース位置の表示 (SourceInfo 活用)             | U2a  |
| U2c      | スタックトレース (関数名 + ソース位置)         | U2b  |
| U2d      | 周辺ソースコード表示                           | U2c  |

**参考ドキュメント**: `docs/reference/error_design.md` (設計済み、未実装)

### U3: doc / dir / apropos

**本家 clj CLI 機能との対応**:

| 本家機能             | 説明                         | 優先度 |
|----------------------|------------------------------|--------|
| `(doc fn-name)`      | docstring 表示               | 高     |
| `(dir ns-name)`      | NS の public var 一覧        | 高     |
| `(find-doc "pat")`   | docstring パターン検索       | 中     |
| `(apropos "pat")`    | 名前パターン Var 検索        | 中     |
| `(source fn-name)`   | ソースコード表示             | 低     |
| Tab 補完             | NS/Var 名の補完              | 低     |

**実装方針**:
- `doc`: Var の meta に :doc を格納。`(doc fn)` で表示
  - 現状 `def` の 3-arg (docstring) 形式が未完全対応 → 先に修正
- `dir`: `ns-publics` は実装済み。表示用ラッパー追加
- `find-doc` / `apropos`: 全 NS の Var を走査 + パターンマッチ

### U4: 既知バグの修正

`memo.md` の「既知の制限」セクションから:

| バグ                          | 優先度 | 難易度 |
|-------------------------------|--------|--------|
| map-as-fn 2-arity             | 中     | 低     |
| symbol-as-fn                  | 中     | 低     |
| sets-as-functions             | 中     | 中     |
| with-redefs VM クラッシュ     | 高     | 高     |
| ^:const 未対応                | 低     | 中     |
| with-local-vars 未実装        | 低     | 中     |
| add-watch on var 未実装       | 低     | 中     |
| thread-bound? 多引数          | 低     | 低     |
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
