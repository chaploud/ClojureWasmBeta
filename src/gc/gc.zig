//! GC: ガベージコレクション統合
//!
//! GcAllocator と tracing を統合し、
//! collectGarbage / shouldCollect の高レベル API を提供。
//!
//! 使い方:
//!   var gc = GC.init(&gc_alloc);
//!   if (gc.shouldCollect()) {
//!       gc.collectGarbage(&env, globals);
//!   }

const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
pub const GcAllocator = @import("gc_allocator.zig").GcAllocator;
const tracing = @import("tracing.zig");

/// GC ルート用グローバル参照
pub const GcGlobals = struct {
    /// グローバル階層 (make-hierarchy)
    hierarchy: ?Value,
    /// グローバル taps (add-tap)
    taps: ?[]const Value,
};

/// GC 統合インターフェース
pub const GC = struct {
    gc_alloc: *GcAllocator,

    pub fn init(gc_alloc: *GcAllocator) GC {
        return .{ .gc_alloc = gc_alloc };
    }

    /// GC を実行（mark-sweep）
    pub fn collectGarbage(self: *GC, env: *Env, globals: GcGlobals) GcAllocator.SweepResult {
        tracing.markRoots(self.gc_alloc, env, globals);
        return self.gc_alloc.sweep();
    }

    /// GC を実行すべきかどうか
    pub fn shouldCollect(self: *const GC) bool {
        return self.gc_alloc.shouldCollect();
    }

    /// 統計情報
    pub fn stats(self: *const GC) GcAllocator.Stats {
        return self.gc_alloc.stats();
    }
};

// === テスト ===

test "GC 基本構造" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc_alloc = GcAllocator.init(gpa.allocator());
    defer gc_alloc.deinit();

    var gc = GC.init(&gc_alloc);
    try std.testing.expect(!gc.shouldCollect());

    const s = gc.stats();
    try std.testing.expectEqual(@as(usize, 0), s.bytes_allocated);
}
