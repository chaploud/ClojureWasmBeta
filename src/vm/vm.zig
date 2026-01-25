//! VM: バイトコード仮想マシン
//!
//! コンパイル済みバイトコードを実行する。
//! スタックベースの仮想マシン。
//!
//! 処理フロー:
//!   Form (Reader) → Node (Analyzer) → Bytecode (Compiler) → Value (VM)
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: VM実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const bytecode = @import("../compiler/bytecode.zig");
// const Chunk = bytecode.Chunk;
// const Opcode = bytecode.Opcode;
// const value = @import("../runtime/value.zig");
// const Value = value.Value;
// const gc = @import("../gc/gc.zig");

/// 仮想マシン
/// TODO: 実装時にコメント解除
pub const VM = struct {
    // === 実行状態 ===
    // chunk: *Chunk,
    // ip: [*]u8,           // 命令ポインタ
    // stack: Stack,        // 値スタック
    // frames: CallFrames,  // コールフレーム

    // === 環境 ===
    // globals: GlobalMap,  // グローバル変数
    // open_upvalues: ?*Upvalue,

    // === GC ===
    // gc: *gc.GC,

    placeholder: void,

    // /// バイトコードを実行
    // pub fn run(self: *VM) !Value {
    //     while (true) {
    //         const op = self.readByte();
    //         switch (@as(Opcode, @enumFromInt(op))) {
    //             .push_nil => self.push(.nil),
    //             .push_const => {
    //                 const idx = self.readByte();
    //                 self.push(self.chunk.constants[idx]);
    //             },
    //             .call => try self.callValue(),
    //             .return_val => {
    //                 if (self.frames.len == 0) {
    //                     return self.pop();
    //                 }
    //                 // フレームを戻す
    //             },
    //             // ...
    //         }
    //     }
    // }

    // fn readByte(self: *VM) u8 {
    //     const b = self.ip[0];
    //     self.ip += 1;
    //     return b;
    // }
};

// === テスト ===

test "placeholder" {
    const vm: VM = .{ .placeholder = {} };
    _ = vm;
}
