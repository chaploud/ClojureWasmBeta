//! ClojureWasmBeta - Clojure処理系のZig実装
//!
//! Clojure互換（ブラックボックス）を目指す。

const std = @import("std");

// モジュールエクスポート
pub const Value = @import("value.zig").Value;
pub const Symbol = @import("value.zig").Symbol;
pub const err = @import("error.zig");
pub const tokenizer = @import("reader/tokenizer.zig");

pub const Tokenizer = tokenizer.Tokenizer;
pub const Token = tokenizer.Token;
pub const TokenKind = tokenizer.TokenKind;

// テスト
test {
    std.testing.refAllDecls(@This());
}
