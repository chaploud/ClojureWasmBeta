//! Emit: コード生成
//!
//! Node からバイトコードを生成する。
//!
//! 処理フロー:
//!   Form (Reader) → Node (Analyzer) → Bytecode (Compiler) → Value (VM)
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: VM実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const bytecode = @import("bytecode.zig");
// const Chunk = bytecode.Chunk;
// const Opcode = bytecode.Opcode;
// const node = @import("../analyzer/node.zig");
// const Node = node.Node;

/// コンパイラ状態
/// TODO: 実装時にコメント解除
pub const Compiler = struct {
    // chunk: *Chunk,
    // locals: LocalArray,
    // scope_depth: u32,
    // enclosing: ?*Compiler,  // ネストした関数用

    placeholder: void,

    // /// Node をコンパイル
    // pub fn compile(self: *Compiler, n: Node) !void {
    //     switch (n) {
    //         .constant => |v| try self.emitConstant(v),
    //         .var_ref => |vr| try self.emitVarRef(vr),
    //         .call_node => |c| try self.emitCall(c),
    //         .if_node => |i| try self.emitIf(i),
    //         // ...
    //     }
    // }

    // /// 定数をプッシュ
    // fn emitConstant(self: *Compiler, v: Value) !void {
    //     const idx = try self.chunk.addConstant(v);
    //     try self.emitOp(.push_const);
    //     try self.emitByte(@intCast(idx));
    // }
};

// === テスト ===

test "placeholder" {
    const c: Compiler = .{ .placeholder = {} };
    _ = c;
}
