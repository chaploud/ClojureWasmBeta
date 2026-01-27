# 技術ノート

> コンポーネント別の注意点・回避策。関連作業時に参照。

---

## Reader/Form

- 有理数は float で近似（Ratio 型は将来実装）

## Value/Runtime

- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
- char_val は Form に対応していない（valueToForm でエラー）

## メモリ管理

- **Deep Clone による scratch→persistent 安全化**:
  - `runDef`: def'd 値を deepClone してから bindRoot（scratch 上のコレクション参照を排除）
  - `runFn`: fn body ノードを deepClone（scratch 上の Node ツリーを persistent にコピー）
  - `runSwap` / `resetBang`: atom 更新前に値を deepClone
  - `Chunk.addConstant`: VM bytecode 定数を deepClone
  - `Value.deepClone`: Atom の内部値も再帰的にクローン
- **メモリリーク（Phase 10 GC で対応予定）**:
  - deepClone により古い値が孤立する（GC で回収予定）
  - evaluator.zig の args 配列（バインディングスタック改善で対応）
  - Value 所有権（Var 破棄時に内部 Fn が解放されない）
  - context.withBinding の配列（バインディング毎に新配列を確保）

## Analyzer

- `analyzeDef` で Var を init 式解析前に intern（再帰的 defn の自己参照を可能に）

## VM

- createClosure: frame.base > 0 のみキャプチャ（トップレベルクロージャバグ修正済み）
- **sp_depth コンパイル時スタック追跡**: ローカル変数のスロット位置を正確に計算
  - `Local.slot`: frame.base からの実際のスタック位置
  - `Compiler.sp_depth`: コンパイル時のスタック深度追跡（全 emit 関数で更新）
  - `scope_exit` 命令: let/loop スコープ終了時にローカルを除去し結果を保持
  - `loop_locals_base`: sp_depth ベースで正確なオフセットを計算（recur が正しいスロットに書き込む）
  - これにより `(+ 1 (let [x 2] x))` や `(not (loop ...))` 等のネストが正常動作

## compare モード

- Var スナップショット機構: 各バックエンドが独自の Var 状態を維持
  - `VarSnapshot` 構造体: Var roots の保存・復元
  - TreeWalk 実行後に tw_state 保存 → vm_snapshot 復元 → VM 実行後に vm_snapshot 保存 → tw_state 復元
  - Atom はスナップショット対象外（別インスタンスが作られる）

## シーケンス操作

- map/filter は Eager 版と Lazy 版の両方が存在（Phase 9.1 で遅延版を追加）
- **LazySeq 実装済み**: `(lazy-seq body)` 特殊形式、cons 形式の遅延保持
- `(range)` 引数なし（無限シーケンス）対応済み（Phase 9.2 で遅延 range を実装）

## LazySeq（Phase 9 で追加）

- **LazySeq 構造**: サンク形式（body_fn）と cons 形式（cons_head + cons_tail）の2種類
  - サンク形式: `(lazy-seq body)` → body を `(fn [] body)` に変換して保持
  - cons 形式: `(cons x lazy-tail)` → head + tail をそのまま保持（tail を force しない）
- **force メカニズム**: threadlocal コールバック（ForceFn 型）
  - TreeWalk: `treeWalkForce` + `current_env` threadlocal
  - VM: `vmForce` + `current_vm` threadlocal（callValue が再帰的に execute を呼ぶため同期的）
- **インクリメンタル操作**: first/rest/take/drop は lazy-seq を一要素ずつ force
  - `lazyFirst`: 一段だけ force して head を返す
  - `lazyRest`: 一段だけ force して tail を返す
  - `forceLazySeqOneStep`: サンク → cons/具体値に一段変換
- **完全 force**: `forceLazySeq` は全要素を収集（無限シーケンスでは無限ループ）
  - `ensureRealized`, `doall`, `count` が使用
- **遅延変換 (Phase 9.1)**:
  - `Transform` 構造体: kind (map/filter) + fn_val + source
  - `forceTransformOneStep`: map は first→call→cons、filter は pred 真まで走査→cons
  - `CallFn` threadlocal（evaluator: `treeWalkCall`, VM: `vmCall`）
  - `concat_sources` フィールド: 遅延 concat（複数コレクション連結を lazy に）
  - `forceConcatOneStep`: sources 配列の先頭から要素を取り出して cons 化
- **pr-str/str での自動 realize**: `prStr`, `strFn` が lazy-seq を ensureRealized してから出力
- **深コピー**: cons_head/cons_tail/transform/concat_sources も deepClone 対象
- **compare モード**: engine.zig で各バックエンドの force callback が有効な間に ensureRealized

## 例外処理

- throw は任意の Value を投げられる（Clojure 互換）
- 内部エラー（TypeError 等）も catch で捕捉可能（TreeWalk / VM 両方対応）
- thrown_value は threadlocal に `*anyopaque` で格納（レイヤリング維持）
- VM: ExceptionHandler スタックで try/catch の状態を管理、ネスト対応
- Zig 0.15.2 で `catch` + `continue` パターンが LLVM IR エラーを引き起こすため、ラッパー関数で回避

## Atom

- `swap!` は特殊形式（関数呼び出しが必要なため通常の BuiltinFn では不可）
- `atom`, `deref`, `reset!`, `atom?` は通常の組み込み関数

## VM: let-closure（修正済み）

- FnProto に `capture_count` + `capture_offset` を追加
  - `capture_count`: 親スコープのローカル変数数（コンパイラが設定）
  - `capture_offset`: 最初のローカルのスロット位置（スタック上の先行値をスキップ）
- createClosure: `frame.base > 0` は従来通り全ローカルキャプチャ、
  `frame.base == 0 && capture_count > 0` は `capture_offset` から `capture_count` 分キャプチャ
- `(pr-str (map (let [x 10] (fn [y] (+ x y))) [1 2 3]))` 等のネスト式も正常動作

## letfn（相互再帰ローカル関数）

- LetfnNode: bindings (LetfnBinding[]) + body
- Analyzer: Phase 1 で全関数名をローカルに登録 → Phase 2 で各 fn body を解析（相互参照可能）
- Compiler `emitLetfn`:
  1. 全関数名に nil プレースホルダを push + addLocal
  2. 各 fn をコンパイル → local_store で上書き
  3. `letfn_fixup` opcode で closure_bindings を更新
- VM `letfnFixup`: 既存 closure_bindings 内の letfn スロットを実際の関数値で上書き（@constCast）
- `locals_offset` フィールド: fn_compiler が Analyzer のグローバルインデックスで自スコープ変数を区別
  - `emitLocalRef`: `ref.idx >= locals_offset` なら自スコープ、そうでなければ親スコープ
  - `compileArity`: fn_compiler.locals_offset = 親の locals_offset + 親の locals 数
  - fn_compiler.sp_depth は capture_count 分オフセット（closure_bindings がスタック先頭に配置されるため）

## 組み込みマクロ

- and/or は短絡評価（let + if に展開）
- 合成シンボル名 `__and__`, `__or__`, `__items__`, `__condp__`, `__case__`, `__st__` 等を使用（gensym が理想）
- doseq の recur に `(seq (rest ...))` が必要（空リストは truthy なので nil 変換が必要）
- condp: `(pred test-val expr)` の順で呼び出し（Clojure互換）
- some->/some->>: 再帰的に let+if+nil? チェーンに展開
- as->: 連続 let バインディングに展開

## マルチメソッド

- MultiFn 型: dispatch_fn + methods (PersistentMap) + default_method
- defmulti/defmethod は専用 Node 型 (DefmultiNode, DefmethodNode) + 専用 OpCode (0x44, 0x45)
- :default キーワードのディスパッチ値は default_method フィールドに格納
- compare モードの E2E テストでは defmulti/defmethod と呼び出しを同一 do ブロック内に記述（バックエンド毎に独自の MultiFn が必要なため）

## プロトコル

- Protocol 型: name (Symbol) + method_sigs + impls (PersistentMap: type_keyword → method_map)
- ProtocolFn 型: protocol 参照 + method_name（ディスパッチ用）
- defprotocol/extend-type は専用 Node 型 + 専用 OpCode (0x46, 0x47)
- extend-protocol は組み込みマクロ（複数 extend-type に展開）
- 型名マッピング: "String"→"string", "Integer"→"integer" 等（mapUserTypeName 関数）
- compare モードのテストでは defprotocol/extend-type と呼び出しを同一 do ブロック内に記述

## Phase 8.19: 実用関数・マクロ大量追加

- **~70 builtin 関数**: core.zig に追加、`builtins` comptime 配列に登録
- **~20 組み込みマクロ**: analyze.zig の `expandBuiltinMacro` に追加
- **sort-by / group-by**: HOF ノードパイプライン（Node → Analyzer → Evaluator → Compiler → VM）
  - `SortByNode`, `GroupByNode` を node.zig に追加
  - Evaluator: insertion sort（安定ソート）+ `valueCompare` ヘルパー
  - VM: `sort_by_seq`(0x99), `group_by_seq`(0x9A) opcodes
  - `vmValueCompare`: vm.zig にファイルレベル関数として定義
- **マクロ展開パターン**:
  - `keep`/`keep-indexed`/`mapcat`: 既存プリミティブの合成（`(filter some? (map f coll))` 等）
  - `for`: 単一 → `(map ...)`, ネスト → `(mapcat (fn [x] (for [...] body)) coll)`
  - `cond->` / `cond->>`: 逆順構築で let-if チェーンに展開
  - `while`: `(loop [] (when test body... (recur)))`

## 動的コレクションリテラル（Phase 8.20 で修正済み）

- `(let [x 1] [x])` 等、変数を含むベクター/マップ/セットリテラルが使用可能
- Analyzer が非定数要素を検出 → `(vector ...)` / `(hash-map ...)` / `(set (vector ...))` 呼び出しに変換
- 全要素が定数の場合は従来通り即値コレクションを構築

## Phase 12: PURE 残り

- `collectToSlice` ヘルパー追加（コレクション→スライス変換、core.zig）
- `gensym` は `var gensym_counter: u64 = 0` のファイルレベル変数でカウント（threadlocal 不要）
- `memoize` は暫定的に identity 展開（atom + hash-map キャッシュは Phase 15 の Atom 拡張後）
- `juxt` はマクロ展開: `(fn [& args] (vector (apply f1 args) ...))`
- `lazy-cat` はマクロ展開: `(concat (lazy-seq (seq c1)) (lazy-seq (seq c2)) ...)`
- `tree-seq` は eager 実装（スタックベース深さ優先走査）
- `partition-by` は eager 実装（グループ分割）
- `trampoline` は `call_fn` threadlocal を利用したループ実装
- `==` (数値等価) は `numToFloat` で統一比較
- マルチメソッド拡張: `prefer-method`/`prefers` は no-op（階層システムは Phase 17）
- 述語の多くは常に false を返す stub（bytes?, class?, decimal?, ratio?, record? 等）
  - 将来の型実装に合わせて有効化

## Phase 13: Delay / Volatile / Reduced

- **新型3種を value.zig に追加**: Delay, Volatile, Reduced 構造体 + Value union タグ
- **delay マクロ**: `(delay expr)` → `(__delay-create (fn [] expr))` に展開（analyze.zig）
  - `__delay-create` builtin が fn_val を受けて Delay 構造体を生成
- **force**: delay_val なら fn_val を call_fn threadlocal で呼び出し、結果をキャッシュ
  - 非 delay 値は素通し（Clojure 互換）
- **deref 拡張**: atom に加えて volatile_val, delay_val にも対応
  - delay_val の deref は force と同等
- **vswap!**: call_fn threadlocal を使って `(f @vol args...)` を実行し volatile を更新
- **ensure-reduced**: 既に reduced_val ならそのまま、それ以外は reduced で包む
- switch exhaustiveness: value.zig (typeKeyword, deepClone, format), core.zig (typeFn), main.zig (printValue), analyze.zig (valueToForm) を全て更新

## Phase 14: Transient / Transduce

- **Transient 型を value.zig に追加**: ArrayList ベースのミュータブルコレクションラッパー
  - kind (vector/map/set) + items/entries (ArrayList) + persisted フラグ
  - persistent! 済みの transient への操作は TypeError
- **transient 操作**: conj!, assoc!, dissoc!, disj!, pop! はすべてインプレース操作
  - conj! は vector/map/set それぞれに対応（map は [k v] ベクターを受け取る）
  - assoc! は map と vector（インデックス指定）の両方に対応
- **transduce**: xform を f に適用 → reduce ループ → 完了ステップの3段階
  - 完了ステップ (1-arity) で ArityError が出た場合は acc をそのまま返す
  - reduced_val チェックで早期終了対応
- **cat**: PartialFn ベースのトランスデューサ
  - catFn(rf) → PartialFn(__cat-step, [rf])
  - catStep(rf, result, input): input がコレクションなら各要素を rf に渡す
- **halt-when**: 2段 PartialFn チェーン
  - haltWhenFn(pred) → PartialFn(__halt-when-xform, [pred])
  - haltWhenXform(pred, rf) → PartialFn(__halt-when-step, [pred, rf])
  - haltWhenStep(pred, rf, result, input): pred(input) が真なら reduced(result)
- **eduction**: 即座評価版（xform + conj で reduce して結果リスト化）
- **iteration**: seed からステップ関数を繰り返し適用（nil で停止、安全上限 1000）
- switch exhaustiveness: Phase 13 と同様、全 switch 文を更新

## Phase 15: Atom 拡張・Var 操作・メタデータ

- **Atom 拡張**: validator, watches, meta フィールドを Atom 構造体に追加
  - `add-watch`: watches 配列 [key, fn, key, fn, ...] に追加（通知は未実装、登録のみ）
  - `remove-watch`: stub（watches 配列から削除する仕組みのみ）
  - `set-validator!`/`get-validator`: validator を設定・取得
  - `compare-and-set!`: eql で比較して一致した場合のみ更新
  - `reset-vals!`/`swap-vals!`: [old new] ベクターを返す
- **Var 操作**: var_val は `*anyopaque` → `@ptrCast(@alignCast)` で `*Var` にキャスト
  - `var-get`/`var-set`: root 値の取得・設定
  - `alter-var-root`: call_fn threadlocal で関数適用
  - `find-var`: current_env threadlocal から名前空間検索
  - `intern`: current_env から NS を取得して Var を作成
  - `bound?`: deref() が nil でなければ true
- **メタデータ**: alter-meta!/reset-meta!/vary-meta
  - Atom と Var の meta フィールドを操作
  - Var の meta は `?*const Value`、Atom の meta は `?Value`
- **current_env threadlocal**: core.zig に追加、evaluator.zig と vm.zig で設定

## Phase 17: 階層システム

- **parents ベース動的計算方式**: derive は parents マップのみ更新、ancestors/descendants は parents から再帰計算
  - `isa?`: `isaTransitive` で parents を再帰走査（depth limit 100）
  - `ancestors`: `collectAncestors` で parents を再帰収集 → セットで返す
  - `descendants`: parents マップ全エントリを走査し、`isaTransitive` で各候補をチェック
- **deepClone 必須**: 引数 (child, parent) はスクラッチアロケータの Keyword ポインタを含むため、
  persistent アロケータに deepClone してから hierarchy に格納する必要がある
  - スクラッチメモリは式間で `allocs.resetScratch()` でリセットされる
  - deepClone なしだと2回目の derive で segfault（解放済み Keyword ポインタへのアクセス）
- **global_hierarchy**: ファイルレベル `var` で保持。derive/underive で更新
- **underive**: parents マップから指定 parent を除去するだけ（dissoc or assoc with reduced set）
- **buildHierarchy**: parents/ancestors/descendants の3つの `*PersistentMap` からマップ構築
  - ancestors/descendants は動的計算のためダミー空マップで可

## CLI テスト注意

- bash/zsh 環境で `!` はスペース後に `\` が挿入される場合がある
- `swap!`, `reset!` 等を含む式は Write ツールでファイル経由で渡すか、`$(cat file)` で回避
