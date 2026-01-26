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

## CLI テスト注意

- bash/zsh 環境で `!` はスペース後に `\` が挿入される場合がある
- `swap!`, `reset!` 等を含む式は Write ツールでファイル経由で渡すか、`$(cat file)` で回避
