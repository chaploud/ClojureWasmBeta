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

- map/filter は Eager 実装（リスト全体を即座に生成）
- LazySeq が必要な場合（無限シーケンス、遅延実行）は別途実装が必要
- `(range)` 引数なし（無限シーケンス）は未サポート

## 例外処理

- throw は任意の Value を投げられる（Clojure 互換）
- 内部エラー（TypeError 等）も catch で捕捉可能（TreeWalk / VM 両方対応）
- thrown_value は threadlocal に `*anyopaque` で格納（レイヤリング維持）
- VM: ExceptionHandler スタックで try/catch の状態を管理、ネスト対応
- Zig 0.15.2 で `catch` + `continue` パターンが LLVM IR エラーを引き起こすため、ラッパー関数で回避

## Atom

- `swap!` は特殊形式（関数呼び出しが必要なため通常の BuiltinFn では不可）
- `atom`, `deref`, `reset!`, `atom?` は通常の組み込み関数

## VM: let-closure バグ（既知）

- `(let [x 0] (fn [] x))` のような let 内で定義した fn が let-local をキャプチャできない
- fn-within-fn パターン `((fn [x] (fn [] x)) 0)` は正常動作
- complement/constantly マクロは fn-within-fn で回避済み

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

## CLI テスト注意

- bash/zsh 環境で `!` はスペース後に `\` が挿入される場合がある
- `swap!`, `reset!` 等を含む式は Write ツールでファイル経由で渡すか、`$(cat file)` で回避
