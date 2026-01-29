# エラー設計（sci/babashka参考）

sci と babashka のエラー処理パターンを参考に、Zig実装向けのエラー設計を整理。

## エラーのフェーズ

| フェーズ      | 説明                | 例                            |
|---------------|---------------------|-------------------------------|
| `parse`       | Reader/パーサー段階 | 構文エラー、EOF、不正リテラル |
| `analysis`    | 解析/コンパイル段階 | 未定義変数、型エラー          |
| `macroexpand` | マクロ展開段階      | マクロ内エラー                |
| `eval`        | 実行時              | ゼロ除算、アリティ不一致      |

## エラー構造（sci参考）

sci の `ex-info` で使われるデータ構造:

```clojure
{:type     :sci/error          ; または :sci.error/parse
 :message  "Human readable msg"
 :file     "source.clj"        ; または "NO_SOURCE_PATH"
 :line     42                  ; 1-based
 :column   10                  ; 0-based
 :phase    "parse"             ; parse/analysis/macroexpand
 :data     {...}}              ; 追加情報
```

## Zig での設計案

### エラーフェーズ

```zig
pub const ErrorPhase = enum {
    parse,
    analysis,
    macroexpand,
    eval,
};
```

### エラー種別

```zig
pub const ErrorKind = enum {
    // Parse phase
    unexpected_eof,
    invalid_token,
    unmatched_delimiter,
    invalid_number,
    invalid_character,
    invalid_string,
    invalid_regex,

    // Analysis phase
    undefined_symbol,
    invalid_arity,
    invalid_binding,
    duplicate_key,

    // Macroexpand phase
    macro_error,

    // Eval phase
    division_by_zero,
    index_out_of_bounds,
    type_error,
    assertion_error,

    // General
    internal_error,
};
```

### ソース位置

```zig
pub const SourceLocation = struct {
    file: ?[]const u8,   // null = unknown
    line: u32,           // 1-based, 0 = unknown
    column: u32,         // 0-based

    pub const unknown = SourceLocation{
        .file = null,
        .line = 0,
        .column = 0,
    };
};
```

### エラー情報

```zig
pub const ErrorInfo = struct {
    kind: ErrorKind,
    phase: ErrorPhase,
    message: []const u8,
    location: SourceLocation,

    // スタックトレース（評価時のみ）
    callstack: ?[]const StackFrame = null,

    // 原因となったエラー（ラップ時）
    cause: ?*const ErrorInfo = null,
};

pub const StackFrame = struct {
    name: []const u8,       // 関数名
    ns: ?[]const u8,        // 名前空間
    location: SourceLocation,
    is_builtin: bool,
};
```

### Zigエラー型との統合

```zig
pub const EvalError = error{
    // Parse
    UnexpectedEof,
    InvalidToken,
    UnmatchedDelimiter,
    InvalidNumber,
    InvalidCharacter,
    InvalidString,

    // Analysis
    UndefinedSymbol,
    InvalidArity,
    InvalidBinding,

    // Eval
    DivisionByZero,
    IndexOutOfBounds,
    TypeError,

    // Memory
    OutOfMemory,
};

// エラー詳細はスレッドローカルまたはコンテキストに格納
pub threadlocal var last_error: ?ErrorInfo = null;

pub fn setError(info: ErrorInfo) EvalError {
    last_error = info;
    return switch (info.kind) {
        .unexpected_eof => error.UnexpectedEof,
        .invalid_token => error.InvalidToken,
        // ...
    };
}
```

## エラーメッセージ例（sci/babashka参考）

### Parse phase

```
EOF while reading
Unmatched delimiter: )
Invalid number: 123abc
Invalid character literal: \invalid
Invalid regex literal
```

### Analysis phase

```
Unable to resolve symbol: foo in this context
Parameter declaration missing
Parameter declaration should be a vector
Can't have more than 1 variadic overload
```

### Eval phase

```
Divide by zero
Wrong number of args (2) passed to: core/+
Index 5 out of bounds for length 3
```

## エラー表示フォーマット（babashka参考）

```
----- Error ------------------------------
Type:     :sci.error/parse
Message:  EOF while reading string
Phase:    parse
Location: src/example.clj:42:10

  40 | (defn foo []
  41 |   (let [x "hello
  42 |         world]
       ^--- error here
  43 |     x))

----- Stack ------------------------------
user/foo          - src/example.clj:40:1
user/main         - src/main.clj:10:3
```

## 実装優先度

以下は全て実装済み (Phase U2a-U2d で完了):

1. ~~**Phase 1**: ErrorKind, SourceLocation, 基本メッセージ~~ ○
2. ~~**Phase 2**: スタックトレース収集~~ ○
3. ~~**Phase 3**: コンテキスト表示（周辺ソースコード）~~ ○

## 参考ファイル

- `~/Documents/OSS/sci/src/sci/impl/utils.cljc` - エラー生成
- `~/Documents/OSS/sci/src/sci/impl/callstack.cljc` - スタックトレース
- `~/Documents/OSS/babashka/src/babashka/impl/error_handler.clj` - 表示フォーマット
