# clojure.java.* 名前空間の機能一覧

本ドキュメントは、Clojure の `clojure.java.*` 名前空間の機能をリストアップし、
Zig実装での対応方針を検討するための資料。

## 概要

| 名前空間 | 機能 | Zig対応方針 |
|---------|------|------------|
| clojure.java.io | ファイル・ストリームI/O | 必要（優先度高） |
| clojure.java.shell | サブプロセス実行（旧API） | 検討 |
| clojure.java.process | サブプロセス実行（新API 1.12+） | 検討 |
| clojure.java.browse | ブラウザ起動 | スキップ |
| clojure.java.javadoc | Javadocブラウズ | スキップ |
| clojure.java.basis | deps.edn/CLI情報 | スキップ |

---

## clojure.java.io（優先度: 高）

I/O操作の中核。Zigのstd.fsとstd.ioで大部分を代替可能。

### プロトコル

| 名前 | 説明 | Zig対応案 |
|-----|------|----------|
| `Coercions` | as-file, as-url への変換 | パス文字列の正規化で対応 |
| `IOFactory` | Reader/Writer/Stream生成 | Zig std.fs.File で代替 |

### 公開関数

| 関数 | 説明 | Zig対応案 |
|-----|------|----------|
| `reader` | BufferedReader取得 | std.io.bufferedReader |
| `writer` | BufferedWriter取得 | std.io.bufferedWriter |
| `input-stream` | BufferedInputStream取得 | std.fs.File.reader |
| `output-stream` | BufferedOutputStream取得 | std.fs.File.writer |
| `copy` | 入力→出力コピー | 手動実装 |
| `file` | File オブジェクト生成 | パス文字列で代替 |
| `delete-file` | ファイル削除 | std.fs.deleteFile |
| `make-parents` | 親ディレクトリ作成 | std.fs.makePath |
| `as-file` | Fileへ変換 | パス正規化 |
| `as-url` | URLへ変換 | URL非対応（ファイルパスのみ） |
| `as-relative-path` | 相対パス取得 | パス操作 |
| `resource` | クラスパスリソース取得 | 別途検討（組み込みリソース？） |

### オプション

- `:encoding` - 文字エンコーディング（UTF-8デフォルト）
- `:append` - 追記モード
- `:buffer-size` - バッファサイズ

### 備考

- Java固有のURL/URI処理は非対応
- Socket I/Oは検討対象外（ネットワークは別途）

---

## clojure.java.shell（優先度: 中）

サブプロセス実行。`sh` 関数が中核。

### 公開関数・マクロ

| 名前 | 種別 | 説明 | Zig対応案 |
|-----|------|------|----------|
| `sh` | fn | コマンド実行、stdout/stderr/exit取得 | std.process.Child |
| `with-sh-dir` | macro | 作業ディレクトリ設定 | 実行時にcwd指定 |
| `with-sh-env` | macro | 環境変数設定 | 実行時にenv指定 |

### sh オプション

- `:in` - 標準入力（String, byte[], Readerなど）
- `:in-enc` - 入力エンコーディング
- `:out-enc` - 出力エンコーディング（`:bytes` で byte[]）
- `:env` - 環境変数マップ
- `:dir` - 作業ディレクトリ

### 戻り値

```clojure
{:exit 0        ;; 終了コード
 :out "..."     ;; stdout
 :err "..."}    ;; stderr
```

---

## clojure.java.process（優先度: 中）

Clojure 1.12+ の新しいプロセスAPI。より柔軟な制御が可能。

### 公開関数

| 名前 | 説明 | Zig対応案 |
|-----|------|----------|
| `start` | プロセス起動、Process返却 | std.process.Child.spawn |
| `exec` | 起動→完了待ち→stdout返却 | spawn + wait + read |
| `stdin` | プロセスの標準入力取得 | child.stdin |
| `stdout` | プロセスの標準出力取得 | child.stdout |
| `stderr` | プロセスの標準エラー取得 | child.stderr |
| `exit-ref` | 終了待ちの参照（deref可能） | wait + 終了コード |
| `to-file` | リダイレクト先ファイル指定 | ファイルへ出力 |
| `from-file` | リダイレクト元ファイル指定 | ファイルから入力 |

### start オプション

- `:in` - `:pipe`, `:inherit`, または Redirect
- `:out` - `:pipe`, `:inherit`, `:discard`, または Redirect
- `:err` - `:pipe`, `:inherit`, `:discard`, `:stdout`, または Redirect
- `:dir` - 作業ディレクトリ
- `:env` - 環境変数マップ
- `:clear-env` - 継承環境変数クリア

---

## clojure.java.browse（優先度: スキップ）

デスクトップブラウザを開く機能。REPL/開発ツール向け。

| 名前 | 説明 |
|-----|------|
| `browse-url` | URLをデフォルトブラウザで開く |

**スキップ理由**: Wasm環境での利用シーン無し。

---

## clojure.java.javadoc（優先度: スキップ）

Javadocをブラウザで開く機能。

| 名前 | 説明 |
|-----|------|
| `javadoc` | クラスのJavadocをブラウザで表示 |
| `add-local-javadoc` | ローカルJavadocパス追加 |
| `add-remote-javadoc` | リモートJavadocURL追加 |

**スキップ理由**: Java固有。

---

## clojure.java.basis（優先度: スキップ）

Clojure CLIのdeps.edn情報を取得。

| 名前 | 説明 |
|-----|------|
| `initial-basis` | 起動時のbasis情報 |
| `current-basis` | 現在のbasis情報 |

**スキップ理由**: Clojure CLI/tools.deps固有。

---

## clojure.reflect（優先度: スキップ）

### 概要

Javaクラスのリフレクション情報をClojureデータとして取得する機能。

### 主要関数

| 名前 | 説明 |
|-----|------|
| `reflect` | オブジェクト/クラスのリフレクション情報取得 |
| `type-reflect` | 型参照からリフレクション情報取得 |

### 戻り値の構造

```clojure
{:bases #{親クラス/インターフェース...}
 :flags #{:public :final ...}
 :members #{{:name メソッド名
             :declaring-class クラス名
             :parameter-types [引数型...]
             :return-type 戻り型
             :flags #{:public ...}}
            ...}}
```

### スキップ理由

1. **Javaランタイム依存**: `java.lang.Class` のメソッド情報などを取得
2. **使用シーンが限定的**: 主にマクロ生成やREPLでのイントロスペクション
3. **代替困難**: Zig実装のデータ構造には「リフレクション」概念がない
4. **Alpha状態**: 公式にも "Alpha - subject to change" と明記

---

## 実装優先度まとめ

### Phase 1（初期実装）

**clojure.java.io の基本機能**:
- `slurp` / `spit`（clojure.coreにある）
- `reader` / `writer`
- `input-stream` / `output-stream`
- `file` / `delete-file` / `make-parents`
- `copy`

### Phase 2（拡張）

**clojure.java.shell または clojure.java.process**:
- `sh` または `exec` + `start`
- サブプロセス制御

### スキップ

- clojure.java.browse
- clojure.java.javadoc
- clojure.java.basis
- clojure.reflect

---

## Zig実装時の注意点

1. **エンコーディング**: Zigは基本UTF-8。他エンコーディングは手動変換が必要
2. **バッファリング**: std.io.bufferedReader/Writer を使用
3. **エラー処理**: Zigのerror unionでClojureの例外を表現
4. **パス正規化**: std.fs.path を使用
5. **クロスプラットフォーム**: Windowsパス区切りなどに注意
