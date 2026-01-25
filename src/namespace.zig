//! Namespace: 名前空間
//!
//! Symbol → Var のマッピングを管理。
//! alias、refer、import も扱う。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md
//!
//! TODO: 評価器実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const form = @import("form.zig");
// const Symbol = form.Symbol;
// const var_mod = @import("var.zig");
// const Var = var_mod.Var;

/// Namespace: 名前空間
/// TODO: 実装時にコメント解除・拡張
pub const Namespace = struct {
    // === 基本フィールド ===
    // name: Symbol,

    // === マッピング ===
    // mappings: SymbolVarMap,   // Symbol → *Var (この NS で定義)
    // aliases: SymbolNsMap,     // Symbol → *Namespace (alias)
    // refers: SymbolVarMap,     // Symbol → *Var (他 NS から refer)

    // === Java interop（将来）===
    // imports: SymbolClassMap,  // Symbol → Class

    // === メタデータ ===
    // meta: ?*PersistentMap,

    // プレースホルダー
    placeholder: void,

    // === メソッド ===

    // /// この NS に Var を定義（intern）
    // pub fn intern(self: *Namespace, sym: Symbol) *Var {
    //     if (self.mappings.get(sym)) |existing| {
    //         return existing;
    //     }
    //     const new_var = allocator.create(Var);
    //     new_var.sym = sym;
    //     new_var.ns = self;
    //     self.mappings.put(sym, new_var);
    //     return new_var;
    // }

    // /// 他 NS から Var を参照（refer）
    // pub fn refer(self: *Namespace, sym: Symbol, var_ref: *Var) void {
    //     self.refers.put(sym, var_ref);
    // }

    // /// 別 NS へのエイリアス
    // pub fn alias(self: *Namespace, sym: Symbol, ns: *Namespace) void {
    //     self.aliases.put(sym, ns);
    // }

    // /// シンボルを解決
    // /// 優先順位: ローカル定義 > refer > alias経由
    // pub fn resolve(self: *Namespace, sym: Symbol) ?*Var {
    //     // 名前空間修飾されている場合
    //     if (sym.namespace) |ns_name| {
    //         if (self.aliases.get(ns_name)) |aliased_ns| {
    //             return aliased_ns.mappings.get(sym.name);
    //         }
    //         return null;
    //     }
    //     // ローカル定義
    //     if (self.mappings.get(sym.name)) |v| {
    //         return v;
    //     }
    //     // refer
    //     if (self.refers.get(sym.name)) |v| {
    //         return v;
    //     }
    //     return null;
    // }
};

// === 型エイリアス（将来）===
//
// const SymbolVarMap = std.HashMap(Symbol, *Var, ...);
// const SymbolNsMap = std.HashMap(Symbol, *Namespace, ...);
// const SymbolClassMap = std.HashMap(Symbol, *Class, ...);

// === テスト ===

test "placeholder" {
    const ns: Namespace = .{ .placeholder = {} };
    _ = ns;
}
