# nREPL サーバー

ClojureWasmBeta に組み込みの nREPL サーバー。
CIDER / Calva / Conjure から接続して式評価・補完・ドキュメント表示が可能。

## 起動

```bash
# OS がポートを自動割り当て (推奨)
clj-wasm --nrepl-server

# ポート指定
clj-wasm --nrepl-server --port=7888

# VM バックエンド指定
clj-wasm --nrepl-server --port=7888 --backend=vm
```

起動すると:
- `.nrepl-port` ファイルが CWD に作成される (エディタが自動検出)
- stderr にポート情報を出力: `nREPL server started on port N on host 127.0.0.1`
- Ctrl-C で停止

## エディタ接続

### CIDER (Emacs)

```
M-x cider-connect RET localhost RET 7888 RET
```

または `.nrepl-port` が CWD にあれば:

```
M-x cider-connect-clj RET
```

### Calva (VS Code)

1. コマンドパレット → "Calva: Connect to a Running REPL Server"
2. "Generic" プロジェクトタイプを選択
3. `localhost:7888` を入力

### Conjure (Neovim)

`.nrepl-port` ファイルがあれば自動接続。

```vim
:ConjureConnect 7888
```

## サポート ops

| op           | 説明                                       |
|--------------|--------------------------------------------|
| clone        | 新規セッション作成                         |
| close        | セッション削除                             |
| describe     | サーバー情報・サポート ops 一覧            |
| eval         | 式評価 (stdout キャプチャ付き)             |
| load-file    | ファイル内容を eval として実行             |
| completions  | 補完候補 (プレフィックスマッチ)            |
| info/lookup  | シンボル情報 (doc/arglists)                |
| eldoc        | 引数リスト                                 |
| ls-sessions  | アクティブセッション一覧                   |
| ns-list      | 全名前空間一覧                             |

## 動作仕様

- **マルチフォーム**: 1つの eval リクエストに複数式を含められる
- **stdout キャプチャ**: `println` 等の出力は `out` メッセージで返送
- **エラー**: `err`/`ex` メッセージ + `status: ["done", "eval-error"]`
- **名前空間**: セッションごとに現在の NS を保持 (`in-ns` で切替可能)
- **スレッド安全**: eval は mutex で直列化 (複数クライアント同時接続可能)

## 制限事項

- stdin 入力 (`read-line` 等) は未サポート
- デバッガー (CIDER debugger) は未サポート
- スタックトレース inspect は未サポート
- テスト実行 ops (`test`, `test-all`) は未サポート
