//! Env: グローバル環境
//!
//! 全ての Namespace を管理するグローバルな環境。
//! data readers、features なども保持。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md
//!
//! TODO: 評価器実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const form = @import("../reader/form.zig");
// const Symbol = form.Symbol;
// const namespace = @import("namespace.zig");
// const Namespace = namespace.Namespace;

/// Env: グローバル環境
/// TODO: 実装時にコメント解除・拡張
pub const Env = struct {
    // === 名前空間管理 ===
    // namespaces: SymbolNsMap,  // Symbol → *Namespace

    // === Reader 設定 ===
    // features: FeatureSet,      // :clj, :cljs, etc. (#? 用)
    // data_readers: TagReaderMap, // #uuid, #inst, etc.
    // default_data_reader: ?*Fn, // *default-data-reader-fn*

    // === コンパイラ設定（将来）===
    // allow: ?Set(Symbol),      // 許可シンボル（サンドボックス用）
    // deny: ?Set(Symbol),       // 拒否シンボル

    // プレースホルダー
    placeholder: void,

    // === メソッド ===

    // /// Namespace を取得（なければ作成）
    // pub fn findOrCreateNs(self: *Env, sym: Symbol) *Namespace {
    //     if (self.namespaces.get(sym)) |ns| {
    //         return ns;
    //     }
    //     const new_ns = allocator.create(Namespace);
    //     new_ns.name = sym;
    //     self.namespaces.put(sym, new_ns);
    //     return new_ns;
    // }

    // /// Namespace を取得（なければ null）
    // pub fn findNs(self: *Env, sym: Symbol) ?*Namespace {
    //     return self.namespaces.get(sym);
    // }

    // /// 初期化（clojure.core 等の組み込み NS 作成）
    // pub fn init(allocator: Allocator) *Env {
    //     const env = allocator.create(Env);
    //     // clojure.core を作成
    //     const core = env.findOrCreateNs(Symbol.init("clojure.core"));
    //     // 組み込み関数を登録
    //     registerBuiltins(core);
    //     return env;
    // }
};

// === 型エイリアス（将来）===
//
// const SymbolNsMap = std.HashMap(Symbol, *Namespace, ...);
// const FeatureSet = std.HashMap(Symbol, void, ...);
// const TagReaderMap = std.HashMap(Symbol, *Fn, ...);

// === テスト ===

test "placeholder" {
    const e: Env = .{ .placeholder = {} };
    _ = e;
}
