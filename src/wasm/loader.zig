//! Loader: Wasmモジュールローダー
//!
//! .wasm ファイルを読み込み、Component Model に従ってインスタンス化。
//!
//! Wasm Component Model:
//!   - コンポーネント = 自己完結型モジュール
//!   - WIT (WebAssembly Interface Types) でインターフェース定義
//!   - 型安全な相互運用
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: Wasm連携実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const component = @import("component.zig");
// const Component = component.Component;

/// Wasmローダー
/// TODO: 実装時にコメント解除
pub const Loader = struct {
    // allocator: std.mem.Allocator,
    // cache: ComponentCache,  // ロード済みコンポーネントのキャッシュ

    placeholder: void,

    // /// .wasm ファイルをロード
    // pub fn load(self: *Loader, path: []const u8) !*Component {
    //     // 1. ファイル読み込み
    //     // 2. Wasm バイナリをパース
    //     // 3. Component Model セクションを解析
    //     // 4. インスタンス化
    // }

    // /// バイト列からロード
    // pub fn loadFromBytes(self: *Loader, bytes: []const u8) !*Component {
    //     // ...
    // }

    // /// インポートを解決
    // fn resolveImports(self: *Loader, module: *WasmModule) !void {
    //     // Clojure 関数を Wasm インポートとして提供
    // }
};

// === テスト ===

test "placeholder" {
    const l: Loader = .{ .placeholder = {} };
    _ = l;
}
