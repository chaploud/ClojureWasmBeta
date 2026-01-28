# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**ポスト実装フェーズ — リファクタリング・高速化・安定化**

全機能実装フェーズ (Phase 1 〜 LAST) が完了。
次のロードマップは `docs/roadmap.md` を参照。

### R1: core.zig ファイル分割 — 完了

11,095行の `src/lib/core.zig` を 18 ドメイン別サブモジュール + facade に分割。
全テスト (760 pass) 回帰なし。

| ファイル            | 行数  | 内容                               |
|---------------------|-------|------------------------------------|
| core.zig (facade)   | 181   | re-export + threadlocal アクセサ   |
| core/defs.zig       | 104   | 型定義, threadlocal, モジュール状態 |
| core/helpers.zig    | 532   | 共通ユーティリティ                 |
| core/lazy.zig       | 544   | LazySeq force/transform            |
| core/arithmetic.zig | 1039  | 算術+比較+bit-ops                  |
| core/predicates.zig | 892   | 型述語                             |
| core/collections.zig| 1941  | コレクション操作                   |
| core/sequences.zig  | 1328  | シーケンス HOF                     |
| core/strings.zig    | 968   | 文字列+regex                       |
| core/io.zig         | 230   | I/O                                |
| core/meta.zig       | 140   | メタデータ                         |
| core/concurrency.zig| 532   | Atom/Delay/Promise/Volatile        |
| core/interop.zig    | 652   | 階層+型操作                        |
| core/transducers.zig| 576   | Transient/Transduce                |
| core/namespaces.zig | 939   | NS操作+require/use                 |
| core/eval.zig       | 357   | eval/read-string/sorted            |
| core/misc.zig       | 390   | gensym/UUID/tap/ex-info            |
| core/wasm.zig       | 191   | wasm/* 関数                        |
| core/registry.zig   | 243   | comptime テーブル集約+登録         |

注意: Zig 0.15.2 では `pub usingnamespace` が廃止されたため、
threadlocal 変数は inline アクセサ関数 (get/set) で提供。
外部 3 ファイル (evaluator.zig, vm.zig, host_functions.zig) に軽微な変更あり。

### P1: ベンチマーク基盤整備 — 完了

- `time` マクロを実装 (スタブ → 実タイミング計測)
  - `__time-start` / `__time-end` builtin を `src/lib/core/io.zig` に追加
  - `expandTime` in `analyze.zig` を let/do 展開に書き換え
  - stderr に `"Elapsed time: X.YYY msecs"` を出力、式の値を返す
- `test/bench/basic.clj` を 10 ベンチマークに拡充 (全て `time` マクロ使用)
- `test/bench/run_bench.sh` を新規作成
  - 両バックエンド自動実行、表形式出力
  - `--save` でベースライン保存、`--compare` で差分比較 (±5% 閾値)
  - `--backend=vm` / `--backend=tree_walk` でバックエンド指定可能

### U1: REPL readline/履歴 — 完了

- `src/repl/line_editor.zig` を新規作成 (自前 readline 実装、外部依存なし)
  - raw ターミナルモード (termios)
  - 左右矢印カーソル移動、Home/End
  - Ctrl-A/E/B/F/K/U/W/D/H/L
  - Backspace/Delete
  - 上下矢印で履歴ナビゲーション (最大 500 エントリ)
  - 履歴ファイル保存/読み込み (`~/.clj_wasm_history`)
  - 非 TTY 時は dumb モードにフォールバック
- `src/main.zig` の `runRepl` を LineEditor に統合
  - 複数行入力 (括弧バランス) は従来通り動作

### R2: value.zig 分割 — 完了

1,308 行の `src/runtime/value.zig` を facade + 3 サブモジュールに分割。
外部ファイルの変更不要 (facade が全型を re-export)。
全テスト (760 pass) 回帰なし。

| ファイル               | 行数 | 内容                                    |
|------------------------|------|-----------------------------------------|
| value.zig (facade)     | 726  | Value union + eql/format/deepClone + テスト |
| value/types.zig        | 349  | Symbol, Keyword, String, 関数型, 参照型 |
| value/collections.zig  | 172  | 永続コレクション 4 型                   |
| value/lazy_seq.zig     | 121  | LazySeq + Transform + Generator         |

### P2: VM 最適化 — 完了 (構造改善、速度効果なし)

ベンチマーク計測に基づく段階的最適化。

**P2a: 低侵襲最適化** (types.zig, vm.zig)
- findArity: 単一アリティ fast path (大多数の関数が 1 アリティ)
- callValueWithExceptionHandling: handler_count == 0 fast path
- recur: スタックバッファ (16 要素まで heap 不要)
- 結果: 計測誤差内で変化なし (ボトルネックは execute 再帰ではない)

**P2b: フレームインライン化** (vm.zig)
- CallFrame に code/constants フィールド追加
- execute() 内でローカル code/constants 変数を使用、フレーム切替時に更新
- tryInlineCall(): fn_val (ユーザー定義) / fn_proto をフレーム積みのみで処理
  (execute 再帰を排除。builtin/partial/comp 等は従来の callValue パス)
- ret opcode: 親フレームの code/constants に切替 + `sp = ret_base - 1`
- call/call_0-3/tail_call: tryInlineCall 経由に変更
- 結果: 全テスト維持 (760/1, zig 270/274)、速度効果なし
- 分析: per-call overhead (フレーム構築・スタック操作) が支配的で、
  execute 再帰のコスト自体は小さかった

**ベンチマーク結果** (変化なし):
| ベンチマーク           | TreeWalk    | VM          |
|------------------------|-------------|-------------|
| fib(25)                | 7,002 ms    | 6,976 ms    |
| sum-to(10000)          | 134 ms      | 133 ms      |
| get-from-map(200x100)  | 815 ms      | 824 ms      |

### P2c: PersistentMap ハッシュインデックス — 完了

O(n) リニアスキャン → O(log n) バイナリサーチ (ハッシュインデックス付き)。

- Value.valueHash(): 全型対応のハッシュ関数 (Wyhash ベース)
  - int/float 互換 (整数の float は同じハッシュ)
  - list/vector 互換 (sequential equality に合わせたハッシュ)
  - map/set は XOR 結合 (順序非依存)
- PersistentMap に hash_values/hash_index フィールド追加
  - entries は挿入順を保持 (イテレーション互換性)
  - hash_values (ソート済み) + hash_index で O(log n) ルックアップ
  - ハッシュ未構築の場合はリニアスキャンにフォールバック
  - assoc/dissoc でインデックスを維持
  - fromUnsortedEntries / buildIndex でインデックス構築
- hash-map 関数で fromUnsortedEntries を使用
- 全テスト維持 (760/1 compat, 270/274 zig)
- ベンチマーク: map lookup で ~7% 改善

### R3a: builtin レジストリ comptime 検証 — 完了

- registry.zig に `validateNoDuplicates` comptime 関数追加
- 重複 2 件を発見・修正: `atom?`, `realized?`
- `realized?` の predicates 版を concurrency 版の実装に更新 (delay/promise 対応)

### R3b: @branchHint 適用 — 完了

hot path のエラー分岐に `@branchHint(.cold)` を適用。
コンパイラに「正常パスの命令配置を優先」するヒントを提供。

- **vm.zig** (主要ターゲット):
  - execute ループ: コード終端チェック、未実装 opcode
  - push/pop/peek: StackOverflow/Underflow
  - callValue: ArityError, StackOverflow, TypeError (else分岐)
  - tryInlineCall: 同上のエラーパス
  - handleThrow/internalErrorToValue/handleThrowFromError: 例外処理全体
  - recur: heap 割り当てフォールバック (> 16 引数)
- **evaluator.zig**:
  - callWithArgs: builtin エラーパス、ArityError、TypeError (else分岐)
  - runThrow/internalErrorToValue
- **core/arithmetic.zig**:
  - add/sub: TypeError (非数値引数)
  - inc/dec: ArityError + TypeError
  - eq/lt/gt/lte/gte: ArityError
- **core/helpers.zig**:
  - compareNumbers: TypeError (非数値引数)

全テスト維持 (760/1 compat, 270/274 zig)。

### R4: テスト整理 — 完了

- `q1a_first_class.clj` → `first_class_functions.clj` (機能名ベース命名規約に統一)
- `run_tests.sh` に `-v/--verbose` オプション追加 (クラッシュ時の出力全体表示)
- `.clj-kondo/config.edn` 追加 (test_runner マクロの unresolved-symbol 抑制)

### R5: 不要ファイル・死コードクリーンアップ — 完了

スタブファイル 4 件を削除 (-185 行):
- `gc/arena.zig`: GcAllocator に置き換え済み
- `compiler/optimize.zig`: 未実装プレースホルダー
- `vm/ops.zig`: vm.zig にインライン実装済み
- `vm/stack.zig`: vm.zig にインライン実装済み

wasm/types.zig の未使用関数 (wasmI64ToValue, wasmF32ToValue, wasmF64ToValue) は
将来の Wasm 型拡張で必要になるため残留。

### R6: Wasm ローダー重複排除 — 完了

- loader.zig に `loadModuleCore()` 共通ヘルパー抽出 (PreInstantiateFn フック付き)
- wasi.zig は `loader.loadModuleCore()` に委譲 (~50 行の重複削減)
- 全テスト維持 (760/1 compat, wasm 4 テスト全 pass)

### U2a: エラーメッセージ改善 — babashka 風フォーマット — 完了

babashka / SandboxClojureWasm の実際の出力を調査し、フォーマットを参考に実装。

- main.zig: `reportError()` で babashka 風フォーマット出力
  - base/error.zig の `last_error` に Info あれば整形表示、なければ従来の Zig error 名
- base/error.zig: `setArityError` / `setTypeError` / `setDivisionByZero` / `setEvalErrorFmt` 追加
  - threadlocal `msg_buf` (512 bytes) でフォーマット済みメッセージ格納
  - `parseErrorFmt` も追加 (analyzer 向け)
- arithmetic.zig: +/-/*/÷/inc/dec/=/</>/<=/>= の全エラー箇所にメッセージ設定
- evaluator.zig: callWithArgs のユーザー関数アリティ・非関数呼び出し等にメッセージ設定
- helpers.zig: compareNumbers の TypeError にメッセージ設定
- analyze.zig: UndefinedSymbol にシンボル名を含める
- 全テスト維持 (760/1 compat, 270/274 zig)

残作業 (U2c 以降): スタックトレース、try/catch の ex-info マップへの反映

### U2b: ソース位置表示 — 完了

エラーメッセージに file:line:column を表示。全レイヤーでソース位置を伝播。

- **Reader**: `source_file` フィールド追加、`readLocated()` メソッド追加 (Form + 位置情報を返す)
- **Analyzer**: `source_file`/`source_line`/`source_column` フィールド追加
  - `currentSourceInfo()` → 全 Node の `.stack` に自動設定 (31 箇所)
  - `analysisError()` / `analysisErrorFmt()` ラッパーで全エラー報告に位置付与 (157+ 箇所)
- **Evaluator**: `setSourceLocationFromNode()` で runCall エラー時に Node.stack を伝播
- **error.zig**: `setErrorLocation()` / `parseErrorFmtLoc()` 追加
- **helpers.zig**: `loadFileContentWithPath()` 追加 — ファイルパスをReader/Analyzerに伝播
- **namespaces.zig**: `loadFileFn`/`tryLoadFile` がファイルパスを伝播
- **main.zig**: `readLocated()` 使用に更新 (runWithBackend/runCompare/evalForRepl)
- エラー表示例:
  ```
  ----- Error --------------------------------------------------------------------
  Type:     type_error
  Message:  Expected number, got string
  Location: /tmp/example.clj:3:0
  ```
- 全テスト維持 (760/1 compat, 270/274 zig)

### U4a: map/set/symbol を関数として呼び出し — 完了

map, set, symbol を Clojure 同様に関数として呼び出し可能に。

- **evaluator.zig**: `callWithArgs` に `.map`, `.set`, `.symbol` ケース追加
  - map-as-fn: `({:a 1} :a)` → `1`, `({:a 1} :c :default)` → `:default`
  - set-as-fn: `(#{:a :b} :a)` → `:a`, `(#{:a :b} :c)` → `nil`
  - symbol-as-fn: `('k {'k 1})` → `1`, `('k {} :d)` → `:d`
- **vm.zig**: `callValue` に同一ロジック追加 (スタック操作版)
- 全て 2-arity (デフォルト値) 対応
- `--compare` モードで両バックエンド一致確認
- 全テスト維持 (760/1 compat, 270/274 zig)

### U2c: スタックトレース表示 — 完了

エラー時にコールスタックを表示。TreeWalk と VM の両バックエンドで動作。

- **error.zig**: `callstack_buf` (threadlocal、最大32フレーム) + `setCallstack()` ヘルパー
- **evaluator.zig**: threadlocal callstack (push/pop) でコールスタック追跡
  - エラー時はフレームを残し `attachCallstack()` で一括収集・リセット
  - `try/catch` でのエラー回復時に `callstack_depth` をリセット (リーク防止)
- **vm.zig**: `collectCallstack()` — `self.frames` 配列から `proto.name` を収集
  - `run()` のエラーキャッチで自動収集
- **main.zig**: `reportError` にスタックトレースセクション追加
- 表示例:
  ```
  ----- Stack Trace --------------------------------------------------------------
    + (builtin)
    inner
    middle
    outer
  ```
- 全テスト維持 (760/1 compat, 270/274 zig)

### U2d: 周辺ソースコード表示 — 完了

エラー発生時にソースコードの前後2行を表示。babashka 風フォーマット。

- **error.zig**: `source_text` threadlocal + `setSourceText()`/`getSourceText()` 追加
  - `-e` 引数や REPL 入力のソーステキストを保持
- **main.zig**: `showSourceContext()` 関数追加
  - ファイルパスがあればファイルを読み込み (最大 64KB)
  - なければ threadlocal のソーステキストをフォールバック使用
  - エラー行の前後2行を行番号付きで表示
  - エラーカラム位置に `^--- error here` ポインタ表示
- **main.zig**: `main()`/`runRepl()` でソーステキストを設定・クリア
- 表示例:
  ```
    5 |   (str "Goodbye, " name "!"))
    6 |
    7 | (defn process [x]
        ^--- error here
    8 |   (+ x "world"))
    9 |
  ```
- 全テスト維持 (760/1 compat, 270/274 zig)

### U3: doc/dir/find-doc/apropos — 完了

REPL ドキュメント閲覧機能。

- **Var.doc / Var.arglists**: defn の docstring と引数リストを Var に保存
  - DefNode に doc/arglists フィールド追加
  - Analyzer: expandDefn で抽出、analyzeDef で DefNode に設定
  - evaluator: runDef で Var に設定
  - VM: def_doc opcode (0x48) で Var に doc/arglists を設定
- **`(doc name)`**: マクロ展開 → `(__doc "name")` builtin 呼び出し
  - Var の ns/name, arglists, docstring を stdout に表示
- **`(dir ns-name)`**: マクロ展開 → `(__dir "ns-name")` builtin 呼び出し
  - 名前空間の public var をソートして一覧表示
- **`(find-doc "pattern")`**: builtin 関数
  - 全名前空間の docstring/var名からパターン文字列を検索
- **`(apropos "pattern")`**: builtin 関数
  - 全名前空間の var 名からパターン文字列を検索
- 全テスト維持 (760/1 compat, 270/274 zig)

### U4b: doc/arglists ダングリングポインタ修正 — 完了

`defn` の docstring/arglists が scratch arena に割り当てられ、式境界の
`resetScratch()` でメモリ解放 → 後続の `(doc fn-name)` でセグフォルト。
`ctx.allocator.dupe()` で persistent memory にコピーするよう修正。

### T5: テストカバレッジ拡充 — 完了

3つの新規テストファイルで 55 テスト追加 (815 pass / 1 fail(意図的)):

| テストファイル                  | テスト数 | 対象機能                                                |
|---------------------------------|----------|---------------------------------------------------------|
| `test/compat/protocols.clj`     | 23       | defprotocol, extend-type, extend-protocol, satisfies?, defrecord |
| `test/compat/documentation.clj` | 14       | doc, dir, find-doc, apropos (U3 機能の検証)             |
| `test/compat/namespaces.clj`    | 18       | all-ns, find-ns, create-ns, in-ns, the-ns, ns-publics, ns-resolve, alias, remove-ns |

### U4c: thread-bound? 多引数対応 — 完了

`(thread-bound? #'*x* #'*y*)` で全 Var が thread-bound か検査。
1引数限定 → 多引数対応 (全て bound なら true)。

### U4d: ^:private / defn- メタデータ対応 — 完了

`(defn ^:private name ...)` と `(defn- name ...)` で private Var を定義可能に。
- Analyzer: `(with-meta name {:private true})` パターンを検出し DefNode.is_private に設定
- evaluator: `v.private = true` を設定
- `dir` で private 関数が非表示になることを確認
- `defn-` が実際に private Var を生成するよう修正 (従来は defn と同等だった)

### G1a-b: GC 計測基盤 — 完了

`--gc-stats` CLI フラグで GC 実行ごとの統計と終了時サマリを stderr に出力。

- **GcAllocator**: `total_collections`, `total_freed_bytes`, `total_freed_count`, `total_alloc_count` 累計統計
- **sweep()**: `SweepResult` を返す (回収バイト数/オブジェクト数/前後ヒープサイズ/新閾値)
- **Allocators**: `gc_stats_enabled` フラグ、`printGcSummary()`, `logSweepResult()` 追加
- **main.zig**: `--gc-stats` フラグ解析、`-e` モードと REPL モード両方対応
- 出力例:
  ```
  [GC #1] freed 6412275 bytes, 100660 objects | heap 6451691 -> 39416 bytes | threshold 262144 bytes

  [GC Summary]
    total collections : 1
    total freed       : 6412275 bytes, 100660 objects
    total allocated   : 101114 alloc calls
    final heap        : 39416 bytes, 452 objects
    final threshold   : 262144 bytes
  ```
- G1b: mark/sweep 時間計測追加 (std.time.Timer)
- 計測結果: mark ~0.3ms vs sweep ~9s (1.2M objects) — sweep が GC 停止の 99.9%
- 全テスト維持 (815/1 compat, 270/274 zig)

### S1a: clojure.string 名前空間 — 完了

`(require 'clojure.string)` で標準的な clojure.string 関数名を提供。
実装は全て Zig builtin へのラッパー (.clj にロジックなし)。

- **新規 builtin 5 関数** (strings.zig): capitalize, string-reverse, index-of, last-index-of, escape
- **`src/clj/clojure/string.clj`**: 17 関数のラッパー NS
  - upper-case, lower-case, capitalize, trim, triml, trimr
  - blank?, starts-with?, ends-with?, includes?
  - index-of, last-index-of, replace, replace-first
  - split, join, reverse, escape, re-quote-replacement
- **デフォルト classpath**: `src/clj` を自動追加 (main.zig)
- **テスト**: `test/compat/clojure_string.clj` — 32 assertions
- 全テスト 847 pass / 1 fail (意図的)

### S1b: clojure.set 名前空間 — 完了

`(require 'clojure.set)` で標準的な clojure.set 関数名を提供。

- **新規 builtin 8 関数** (collections.zig): set-union, set-intersection, set-difference,
  set-subset?, set-superset?, set-select, set-rename-keys, set-map-invert
- **`src/clj/clojure/set.clj`**: 11 関数のラッパー NS
  - union, intersection, difference, subset?, superset?, select
  - rename-keys, map-invert, project, rename, index
  - project/rename/index は reduce ベースの pure Clojure 実装
- **バグ修正**: `set` 関数が lazy-seq を受け付けなかった問題を修正
  (getItems → collectToSlice)
- **テスト**: `test/compat/clojure_set.clj` — 24 assertions
- 全テスト 871 pass / 1 fail (意図的)

### S1c: clojure.string 完全化 + clojure.walk 名前空間 — 完了

- **strings.zig**: split-lines, trim-newline 追加 → clojure.string 全 19/19 関数完了
- **sequences.zig**: walk, postwalk, prewalk を Zig builtin 実装
  - postwalkImpl/prewalkImpl: 再帰的データ構造走査 (list/vector/map/set 対応)
- **`src/clj/clojure/walk.clj`**: 7 関数の NS
  - walk, postwalk, prewalk (builtin ラッパー)
  - postwalk-replace, prewalk-replace (postwalk/prewalk ベース)
  - keywordize-keys, stringify-keys (postwalk + reduce-kv ベース)
- **テスト**: clojure_string 37 (+5), clojure_walk 9 assertions
- 全テスト 885 pass / 1 fail (意図的)

### G1c: sweep 高速化 — セミスペース Arena GC — 完了

GPA 個別 free → ArenaAllocator セミスペース方式に置換。

- **gc_allocator.zig**: backing を GPA → ArenaAllocator に変更
  - sweep() が生存オブジェクトを新 Arena にコピー、旧 Arena を一括解放
  - ForwardingTable (old_ptr → new_ptr) を返す
  - gcFree はレジストリ除去のみ (Arena が一括管理)
- **tracing.zig**: fixupRoots/fixupValue/fixupSlice 等を追加
  - sweep 後に全ルート (Env→Namespace→Var→Value) のポインタを更新
  - PersistentMap の hash_values/hash_index も fixup 対象
- **gc.zig**: GcGlobals.hierarchy を `*?Value` に変更 (fixup writeback 用)
- **allocators.zig**: runGc に fixup フェーズ追加
- **registry.zig**: getGcGlobals() で hierarchy ポインタを返す

**性能結果** (240k objects, ~2.4GB):
| フェーズ   | Before (GPA) | After (Arena) | 改善  |
|------------|--------------|---------------|-------|
| mark       | 0.567 ms     | 0.268 ms      | 同等  |
| sweep      | 1,146 ms     | 29 ms         | ~40x  |
| total GC   | 1,147 ms     | 29 ms         | ~40x  |

全テスト維持 (885/1 compat, 270/274 zig — 4失敗は既存)

### U4e: VM クロージャキャプチャ修正 — 完了

VM の `createClosure`/`createMultiClosure` でネストされたクロージャのパラメータが
呼び出し元の関数に解決されるバグを修正。

- **根本原因**: `frame.base > 0` のとき `sp - frame.base` 分全スタック値をキャプチャしていた。
  コンパイラは親スコープの宣言済みローカル数 (`capture_count`) のみ想定。
  中間式 (map 関数など) がスタック上にある状態でクロージャ生成すると、
  キャプチャ数がずれてパラメータのスロットが不正になる。
- **修正**: `capture_count`/`capture_offset` に基づき正確にキャプチャ。
- **テスト修正**: Phase 24 NS カウント (wasm NS 追加分), identical? keyword, mapcat lazy
- **結果**: 274/274 Zig テスト全 pass (4 既存失敗を全修正), 885/886 compat

### U4f: 多段ネストクロージャの capture_count 修正 — 完了

U4e の修正で 2 段ネストは修正されたが、3 段以上のネストで
`inherited_captures` (祖先から継承したキャプチャ数) が考慮されていなかった。

- Compiler に `inherited_captures` フィールド追加
- `capture_count = inherited_captures + locals.items.len` で正確なキャプチャ深さを計算
- `capture_offset = 0` (常に frame.base から)
- 3段ネスト `(fn [x] (mapv (fn [y] (mapv (fn [z] [x y z]) ...)) ...))` が VM で正常動作
- 274/274 Zig, 885/886 compat

### S1d: clojure.edn 名前空間 — 完了

- **`src/clj/clojure/edn.clj`**: `read-string` のラッパー NS
  - clojure.core/read-string をそのまま委譲 (#= 評価リーダー未実装のため既に EDN 安全)
- **テスト**: `test/compat/clojure_edn.clj` — 9 assertions (map/vector/list/set/string/number/keyword/true/nil)
- TreeWalk / VM / --compare 全 PASS

### U4g: add-watch/remove-watch 完全実装 — 完了

- Atom: reset!/swap!/reset-vals!/swap-vals! でウォッチャーコールバック発火
  (以前は登録のみで通知未実装だった)
- Var: watches フィールド追加、alter-var-root で通知
- add-watch/remove-watch が Atom と Var の両方を受け付けるよう拡張
- remove-watch を配列再構築方式に改善
- GC: Var.watches の mark + fixup 対応
- **テスト**: `test/compat/watches.clj` — 12 assertions (TreeWalk/VM/--compare 全 PASS)

### R3 残項目: MultiArrayList / MemoryPool 評価 — 見送り

調査結果:
- **MultiArrayList**: FnArity (1-3 要素) が最有力候補だが、配列が極小のため
  キャッシュ局所性の改善効果は限定的。PersistentMap hash lookup は P2c で
  既に改善済み。Bytecode はリスク対効果が不釣り合い。
- **MemoryPool**: Value サイズが可変 (16-40 bytes) のため固定サイズ slab 不適。
  Arena セミスペース GC が既にほぼ最適。
- **判断**: 現段階では投入コスト対効果が見合わない。ベンチマークで
  ボトルネックが判明した場合に再検討。

### S1e: clojure.math 名前空間 — 完了

- **`src/lib/core/math_fns.zig`**: 33 builtin 数学関数 (comptime ジェネリックラッパー)
  - 三角: sin, cos, tan, asin, acos, atan, atan2
  - 双曲線: sinh, cosh, tanh
  - 指数/対数: exp, expm1, log, log10, log1p, pow
  - 冪根: sqrt, cbrt, hypot
  - 丸め: ceil, floor, rint, round
  - 符号: signum, copy-sign, abs
  - 整数: floor-div, floor-mod
  - その他: IEEE-remainder, to-degrees, to-radians, random
- **`src/clj/clojure/math.clj`**: E, PI 定数 + 33 defn ラッパー
- **テスト**: `test/compat/clojure_math.clj` — 41 assertions (TreeWalk/VM/--compare 全 PASS)

### S1f: clojure.repl 名前空間 — 完了

- **`src/clj/clojure/repl.clj`**: REPL ユーティリティ NS
  - find-doc, apropos: clojure.core の委譲ラッパー
  - source/source-fn: スタブ (ソーステキスト保持未実装)
  - pst: 最新例外表示 (多引数 defn)
  - demunge: スタブ (Java 固有)
  - root-cause: 引数をそのまま返す
- **テスト**: `test/compat/clojure_repl.clj` — 9 assertions (TreeWalk/VM/--compare 全 PASS)
- **注意**: syntax-quote (`) は非 core NS の defmacro 内で使用不可。list 形式で展開。

### S1g: clojure.data 名前空間 — 完了

- **`src/clj/clojure/data.clj`**: diff 関数で map/set/sequential の再帰的差分
  - [only-in-a only-in-b in-both] を返す
  - pure Clojure 実装 (clojure.set 依存、declare による前方参照)
- **テスト**: `test/compat/clojure_data.clj` — 25 assertions

### S1h: clojure.stacktrace 名前空間 — 完了

- **`src/clj/clojure/stacktrace.clj`**: スタックトレースユーティリティ
  - root-cause, print-throwable, print-stack-trace, print-cause-trace, e
  - JVM StackTraceElement 固有部分はスタブ
- **テスト**: `test/compat/clojure_stacktrace.clj` — 11 assertions

### S1i: clojure.template 名前空間 — 完了

- **`src/clj/clojure/template.clj`**: テンプレート展開ユーティリティ
  - apply-template: clojure.walk/prewalk でシンボル置換
  - do-template: 関数版 (マクロ可変長引数の制限を回避)
- **テスト**: `test/compat/clojure_template.clj` — 10 assertions
- **注意**: マクロ可変長引数 (`& rest`) が1要素のみキャプチャする制限あり

### S1j: clojure.zip 名前空間 — 完了

- **`src/clj/clojure/zip.clj`**: 関数的階層 zipper
  - zipper, seq-zip, vector-zip, xml-zip: zipper コンストラクタ
  - node, branch?, children, make-node: ノード操作
  - down, up, left, right, leftmost, rightmost: ナビゲーション
  - root, path, lefts, rights: 位置情報
  - insert-left, insert-right, insert-child, append-child: 挿入
  - replace, edit, remove: 変更
  - next, prev, end?: 深さ優先走査
- **テスト**: `test/compat/clojure_zip.clj` — 34 assertions
- **付随修正**:
  - **vector-as-fn**: `([1 2 3] idx)` → ベクターを関数として呼び出し (evaluator.zig + vm.zig)
  - **with-meta nil 対応**: `(with-meta obj nil)` でメタデータクリア (meta.zig)
  - **deepClone メタデータ保持**: list/vector/map/set の deepClone でメタデータを複製 (value.zig)

### U5a: ファイル直接実行オプション — 完了

- `clj-wasm file.clj` でスクリプトファイルを直接実行可能に
- 非オプション引数をスクリプトファイルとして認識
- 内部で `(load-file "path")` 式に変換して評価
- `-e` との併用も可能 (スクリプト後に追加式を実行)

### U5b: バイトコードダンプモード — 完了

- `--dump-bytecode` フラグで式のバイトコードをダンプ
- dumpChunk: 定数テーブル + 命令リストを表示
- dumpFnProto: 関数プロトタイプの再帰的ダンプ
- dumpInstruction: オペコード名 + オペランド詳細
- dumpValue: 定数の簡易表示
- 出力例:
  ```
  === Bytecode Dump ===
  --- Constants ---
    [  0] <var>
    [  1] 1
    [  2] 2
  --- Instructions ---
       0: var_load             #0  ; <var>
       1: const_load           #1  ; 1
       2: const_load           #2  ; 2
       3: call                 2
       4: ret
  (5 instructions, 3 constants)
  ```

### 推奨次回タスク

1. **U4 残項目**: 既知バグ修正 (^:const, with-local-vars 等)
2. **P3**: VM 最適化 (ベンチマーク駆動)
3. **新規 S1 候補**: clojure.pprint 等

### 前フェーズ: Phase LAST 完了 — Wasm 連携 (zware)

### Phase LAST サブフェーズ

| Sub   | 内容                              | 状態         |
|-------|-----------------------------------|--------------|
| La    | zware 導入 + load + invoke (数値) | ✅ 完了      |
| Lb    | メモリ操作 + 文字列 interop       | ✅ 完了      |
| Lc    | ホスト関数注入 (Clojure→Wasm)     | ✅ 完了      |
| Ld    | WASI 基本サポート                 | ✅ 完了      |
| Le    | エラー改善 + GC + ドキュメント    | ✅ 完了      |

### 完了フェーズ

| Phase | 内容                                                                                          |
|-------|-----------------------------------------------------------------------------------------------|
| 1-4   | Reader, Runtime基盤, Analyzer, TreeWalk評価器                                                 |
| 5     | ユーザー定義関数 (fn, クロージャ)                                                             |
| 6     | マクロシステム (defmacro)                                                                     |
| 7     | CLI (-e, 複数式, 状態保持)                                                                    |
| 8.0   | VM基盤 (Bytecode, Compiler, VM, --compare)                                                    |
| 8.1   | クロージャ完成, 複数アリティfn, 可変長引数                                                    |
| 8.2   | 高階関数 (apply, partial, comp, reduce)                                                       |
| 8.3   | 分配束縛 (シーケンシャル・マップ)                                                             |
| 8.4   | シーケンス操作 (map, filter, take, drop, range 等)                                            |
| 8.5   | 制御フローマクロ・スレッディングマクロ                                                        |
| 8.6   | try/catch/finally 例外処理                                                                    |
| 8.7   | Atom 状態管理 (atom, deref, reset!, swap!)                                                    |
| 8.8   | 文字列操作拡充                                                                                |
| 8.9   | defn・dotimes・doseq・if-not・comment                                                         |
| 8.10  | condp・case・some->・some->>・as->・mapv・filterv                                             |
| 8.11  | キーワードを関数として使用                                                                    |
| 8.12  | every?/some/not-every?/not-any?                                                               |
| 8.13  | バグ修正・安定化                                                                              |
| 8.14  | マルチメソッド (defmulti, defmethod)                                                          |
| 8.15  | プロトコル (defprotocol, extend-type, extend-protocol)                                        |
| 8.16  | ユーティリティ関数・HOF・マクロ拡充                                                           |
| 8.17  | VM let-closure バグ修正                                                                       |
| 8.18  | letfn（相互再帰ローカル関数）                                                                 |
| 8.19  | 実用関数・マクロ大量追加（~83関数/マクロ）                                                    |
| 8.20  | 動的コレクションリテラル（変数を含む [x y], {:a x} 等）                                       |
| 9     | LazySeq — 真の遅延シーケンス（無限シーケンス対応）                                            |
| 9.1   | Lazy map/filter/concat — 遅延変換・連結                                                       |
| 9.2   | iterate/repeat/cycle/range()/mapcat — 遅延ジェネレータ・lazy mapcat                           |
| 11    | PURE述語(23)+コレクション/ユーティリティ(17)+ビット演算等(17) = +57関数                       |
| 12    | PURE残り: 述語(15)+型キャスト(6)+算術(5)+出力(4)+ハッシュ(4)+MM拡張(6)+HOF(6)+他(7) = +53関数 |
| 13    | DESIGN: delay/force(3)+volatile(4)+reduced(4) = 新型3種+11関数、deref拡張                     |
| 14    | DESIGN: transient(7)+transduce基盤(6) = Transient型+13関数                                    |
| 15    | DESIGN: Atom拡張(7)+Var操作(6)+メタデータ(3) = +16関数                                        |
| 17    | DESIGN: 階層システム(7) = make-hierarchy/derive/underive/isa?等                               |
| 18    | DESIGN: promise/deliver + ユーティリティ(10) = Promise型+UUID+他                              |
| 18b   | DESIGN: partitionv/splitv-at/tap/parse-uuid 等(9) = 追加ユーティリティ                        |
| 19a   | DESIGN: class/struct/accessor/xml-seq等(9) = struct操作+ユーティリティ                        |
| 19b   | DESIGN: eval/read-string/sorted/dynamic-vars(18+14dynvar) = eval基盤+ソートcol+動的Var        |
| 19c   | DESIGN: NS操作/Reader/定義マクロ等(27+2dynvar) = 名前空間スタブ+load+definline                |
| 20    | FINAL: 残り59一括実装 — binding/chunk/regex/IO/NS/defrecord/deftype/動的Var                   |
| 21    | GC: Mark-Sweep at Expression Boundary (GcAllocator + tracing + 式境界GC)                      |
| 22    | 正規表現エンジン（フルスクラッチ Zig 実装）                                                   |
| 23    | 動的バインディング（本格実装）                                                                |
| 24    | 名前空間（本格実装）                                                                          |
| 25    | REPL (対話型シェル)                                                                           |
| 26    | Reader Conditionals + 外部ライブラリ統合テスト (medley v1.4.0)                                |
| T1    | Assert ベーステストランナー (基盤)                                                            |
| T2    | sci 関数カバレッジ監査 + コアテスト (372/390 pass = 95%)                                      |
| T3    | 最小 clojure.test 実装 (deftest/is/testing/run-tests)                                         |
| T4    | sci テストスイート移植                                                                        |
| Q3    | Var システム修正 (def返値, #'var呼出, var-set, alter-var-root, defonce)                       |
| Q4a   | VM reduced 対応                                                                               |
| Q2b   | fn-level recur 修正                                                                           |
| Q1a   | Special Form 正規化 eager 7関数 (apply/partial/comp/reduce/sort-by/group-by/swap!)            |
| Q1b   | Special Form 正規化 lazy 5関数 (map/filter/take-while/drop-while/map-indexed)                 |
| Q1c   | 死コード削除 (12 Node/Opcode, -1,400行)                                                      |
| Q2a   | Map/Set リテラル in マクロ展開修正 (valueToForm に map/set 追加)                              |
| Q4b   | letfn 相互再帰修正 (fn名省略でインデックスずれ解消)                                          |
| Q5a   | with-out-str 実装 (threadlocal output capture)                                               |

### 実装状況

549 done / 169 skip / 0 todo (概算)

照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## Phase T4 実装詳細

### テスト全体結果

**1036 pass, 1 fail(意図的), 0 error** (total: 1037)

### sci テストスイート移植

| テストファイル                           | テスト | アサーション | 状態 |
|------------------------------------------|--------|--------------|------|
| `test/compat/sci/core_test.clj`          | 33     | 123          | PASS |
| `test/compat/sci/vars_test.clj`          | 7      | 15           | PASS |
| `test/compat/sci/hierarchies_test.clj`   | 5      | 5            | PASS |
| `test/compat/sci/multimethods_test.clj`  | 4      | 4            | PASS |
| `test/compat/sci/error_test.clj`         | 6      | 12           | PASS |
| **sci 合計**                             | **55** | **159**      |      |

### compat テスト

| テストファイル                           | アサーション | 状態 |
|------------------------------------------|--------------|------|
| `test/compat/atoms.clj`                  | 33           | PASS |
| `test/compat/collections.clj`            | 76           | PASS |
| `test/compat/control_flow.clj`           | 53           | PASS |
| `test/compat/core_basic.clj`             | 54           | PASS |
| `test/compat/dynamic_binding.clj`        | 15           | PASS |
| `test/compat/higher_order.clj`           | 33           | PASS |
| `test/compat/lazy_seq.clj`               | 39           | PASS |
| `test/compat/multimethods.clj`           | 17           | PASS |
| `test/compat/predicates.clj`             | 91           | PASS |
| `test/compat/regex.clj`                  | 17           | PASS |
| `test/compat/sequences.clj`              | 48           | PASS |
| `test/compat/strings.clj`                | 54           | PASS |
| `test/compat/test_framework_test.clj`    | 8+1 fail     | PASS(意図的1fail) |
| `test/compat/var_system.clj`             | 13           | PASS |
| `test/compat/wasm_basic.clj`             | 15           | PASS |
| `test/compat/wasm_memory.clj`            | 7            | PASS |
| `test/compat/wasm_host.clj`              | 5            | PASS |
| `test/compat/wasm_wasi.clj`              | 4            | PASS |
| `test/compat/clojure_string.clj`         | 37           | PASS |
| `test/compat/clojure_set.clj`            | 24           | PASS |
| `test/compat/clojure_walk.clj`           | 9            | PASS |
| `test/compat/clojure_edn.clj`            | 9            | PASS |
| `test/compat/watches.clj`               | 12           | PASS |
| `test/compat/clojure_math.clj`          | 41           | PASS |
| `test/compat/clojure_repl.clj`          | 9            | PASS |
| `test/compat/clojure_data.clj`          | 25           | PASS |
| `test/compat/clojure_stacktrace.clj`    | 11           | PASS |
| `test/compat/clojure_template.clj`      | 10           | PASS |
| `test/compat/clojure_zip.clj`           | 34           | PASS |
| **compat 合計**                          | **785**      |      |

### テスト基盤

| ファイル                    | 内容                                      |
|-----------------------------|-------------------------------------------|
| `src/clj/clojure/test.clj` | 最小 clojure.test (deftest/is/run-tests)  |
| `test/lib/test_runner.clj`  | Assert ベーステストランナー               |
| `test/run_tests.sh`         | シェルテストランナー (T2+sci 両対応)      |

### テスト移植時の制限回避ルール

deftest body 内 (= defn body 内) で使えない構文:
- ~~マップリテラル `{...}`~~ → Q2a で修正済み
- ~~セットリテラル `#{...}`~~ → Q2a で修正済み
- マップ分配束縛 `{:keys [...]}` → 外部ヘルパー関数
- `def ^:dynamic` / `defmacro` → 外部ヘルパー関数
- `(def name "docstring" value)` (3-arg def) → スキップ

### 新規発見バグ一覧

| バグ                                   | 影響         | 回避策                            | 修正Phase |
|----------------------------------------|--------------|-----------------------------------|-----------|
| map/set リテラル in macro body         | load-file 時 | hash-map/hash-set                 | Q2a ✅    |
| fn-level recur returns nil             | defn+recur   | loop+recur を使用                 | Q2b ✅    |
| vector-list equality broken            | = [1] '(1)   | 修正済み (eql で sequential 比較) | 済        |
| map-as-fn 2-arity                      | ({:a 1} k d) | get with default                  | U4a ✅    |
| symbol-as-fn                           | ('a map)     | get                               | U4a ✅    |
| defonce not preventing redef           | defonce      | スキップ                          | Q3e ✅    |
| letfn mutual recursion                 | letfn f→g    | スキップ                          | Q4b ✅    |
| #'var as callable                      | (#'foo)      | スキップ                          | Q3b ✅    |
| (str (def x 1)) returns ""             | def-returns  | スキップ                          | Q3a ✅    |
| ^:const not respected                  | const        | スキップ                          | —         |
| var-set no effect                      | var-set      | スキップ                          | Q3c ✅    |
| alter-var-root uses thread-local       | avr+binding  | スキップ                          | Q3d ✅    |
| with-local-vars not implemented        | wlv          | スキップ                          | —         |
| add-watch on var not implemented       | add-watch    | 修正済み                          | U4g ✅    |
| thread-bound? 1-arity only             | thread-bound | 既に多引数対応済み                | 済 ✅     |
| defmacro inside defn → Undefined       | defmacro     | トップレベルで定義                | —         |
| with-out-str 未実装 (出力未キャプチャ) | io           | str(do body) に展開、空文字列     | Q5a ✅    |
| VM reduced 未対応                      | reduce early | TreeWalk のみ                     | Q4a ✅    |

### 本セッションで実装した機能

- **Q3**: Var システム修正 (def返値→Var, #'var呼出, var-set thread binding, alter-var-root root, defonce)
- **Q4a**: VM reduced 対応 (executeReduce に reduced_val チェック追加)
- **Q2b**: fn-level recur (callWithArgs にリカーループ追加)
- **Q1a**: Special Form 正規化 eager 7関数 → builtin 移行 (apply/partial/comp/reduce/sort-by/group-by/swap!)
  - analyzeList の 7 分岐削除、core.zig に 7 builtin 関数追加
- **Q1b**: Special Form 正規化 lazy 5関数 → builtin 移行 (map/filter/take-while/drop-while/map-indexed)
  - TransformKind 拡張 (take_while/drop_while/map_indexed)
  - forceTransformOneStep の nil要素バグ修正 (isSourceExhausted 導入)
  - reverse の lazy-seq 対応修正
  - 第一級関数テスト 19 assertions
  - 全テスト 710 pass 維持
- **Q1c**: 死コード削除 (-1,400行)
  - node.zig: 12 struct定義 + 12 union variant + switch cases 削除
  - emit.zig: 12 emitXxx 関数 + dispatch cases 削除
  - bytecode.zig: 12 opcode 削除 (apply/partial/comp/reduce/map_seq/filter_seq 等)
  - vm.zig: executeXxx 関数 + WithExceptionHandling ラッパー + vmValueCompare 削除
  - analyze.zig: 12 analyzeXxx 関数削除
- **Q2a**: Map/Set リテラル in マクロ展開修正
  - valueToForm() に .map/.set ケース追加 (formToValue と対称化)
  - deftest body 内で {:a 1}, #{x} が使用可能に
- **Q4b**: letfn 相互再帰修正
  - 根本原因: analyzeLetfn で fn に名前を渡すと analyzeFn が自己参照ローカルを追加し、
    ローカルインデックスがずれる (余分なスロット → パラメータが範囲外に)
  - 修正: letfn Phase 2 で fn 名を省略 (自己参照は letfn スコープで提供済み)
  - evaluator で Fn.name をセット (デバッグ表示用)
  - letfn テスト 10 assertions 追加 (基本/自己再帰/相互再帰/前方参照/3-way 等)
  - 全テスト 720 pass 維持
- **Q5a**: with-out-str 実装
  - threadlocal output_capture バッファによる stdout キャプチャ
  - 全 print 系関数 (println/print/pr/prn/newline/printf) を output_capture 対応に修正
  - __begin-capture / __end-capture builtin 関数追加
  - with-out-str マクロ展開を let + do + capture に変更
  - ネスト対応 (内側キャプチャが外側に漏れない)
  - with-out-str テスト 9 assertions 追加
  - 全テスト 729 pass 維持

前セッション:
- keyword 2-arity / lazy-seq 等価比較 / memoize 本実装 / identical? キーワード

### 既知の制限 (Phase 26 から引き継ぎ)

- ~~sets-as-functions 未対応~~ → U4a で修正済み (map/set/symbol を関数として呼び出し可能)
- フル medley の `compare-and-set!`/`deref-swap!`/`deref-reset!` 未実装
- ~~文字列表示で `!` がエスケープされる~~ → シェル環境の問題 (コードバグではない)
- ~~VM での `with-redefs` 後のユーザー関数呼び出しクラッシュ~~ → 再現不可、既に修正済みと推定

---

## ロードマップ

### Phase Q: Wasm 前品質修正 — 完了

```
  Q3  ✅ Var システム修正
  Q4a ✅ VM reduced 対応
  Q2b ✅ fn-level recur 修正
  Q1a ✅ Special Form 正規化 (eager 7関数)
  Q1b ✅ Special Form 正規化 (lazy 5関数)
  Q2a ✅ Map/Set リテラル in マクロ展開修正
  Q4b ✅ letfn 相互再帰修正
  Q1c ✅ 死コード削除 (12 Node/Opcode, -1400行)
  Q5a ✅ with-out-str 実装 (threadlocal output capture)
  Q6  ✅ ドキュメント整備
```

### Phase LAST: Wasm 連携 — 完了

```
Phase LAST: Wasm 連携 (zware pure Zig runtime) — 完了
  La ✅ zware 導入 + load + invoke (数値のみ)
  Lb ✅ メモリ操作 + 文字列 interop
  Lc ✅ ホスト関数注入 (Clojure→Wasm)
  Ld ✅ WASI 基本サポート
  Le ✅ エラー改善 + wasm/close + ドキュメント
```

### ポスト実装ロードマップ → `docs/roadmap.md`

```
Phase R: リファクタリング (core.zig 分割、Zig イディオム再点検)
Phase P: 高速化 (ベンチマーク基盤、VM 最適化)
Phase G: GC・メモリ管理 (世代別 GC)
Phase U: UX 改善 (REPL readline、エラー改善)
Phase S: セルフホスト (.clj 移行)
Phase D: ドキュメント (3系統整備)
```

---

## 設計判断の控え

1. **正規表現**: Zig フルスクラッチ実装。バックトラッキング方式で Java regex 互換。
2. **skip 方針**: 明確に JVM 固有（proxy, agent, STM, Java array, unchecked-*, BigDecimal）のみ skip。
   迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。
   instance?/class は内部タグ検査。深追いせず最小限で。
4. **GC**: 式境界 Mark-Sweep。GcAllocator で Clojure Value のみ追跡。
   インフラ (Env/Namespace/Var/HashMap) は GPA 直接管理で GC 対象外。
   閾値超過時にのみ実行。サイクル検出付き (自己参照 fn 等に対応)。
   loop/recur は recur_buffer で in-place 更新 (GC 負荷を大幅削減)。
5. **動的バインディング**: マクロ展開方式 (push+try/finally+pop)。
   新 Node/Opcode 不要。既存インフラを最大限活用。

詳細: `docs/reference/architecture.md`
