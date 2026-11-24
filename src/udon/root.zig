//! Udon Assembly construction primitives (WASM-independent).
//!
//! Surface:
//!   * `asm_` — build, lay out and write an Udon Assembly program.
//!   * `program` — read Udon Assembly text back.
//!   * `check` — validate a program against the spec and the node list.
//!   * `vm` / `externs` / `value` — execute a program (emulator).
//!   * `nodes` — the Udon node list and extern-signature parsing.

const std = @import("std");

pub const asm_ = @import("asm.zig");
pub const program = @import("program.zig");
pub const nodes = @import("nodes.zig");
pub const value = @import("value.zig");
pub const vm = @import("vm.zig");
pub const externs = @import("externs.zig");
pub const check = @import("check.zig");

pub const Asm = asm_.Asm;

test {
    std.testing.refAllDecls(@This());
    _ = asm_;
    _ = program;
    _ = nodes;
    _ = value;
    _ = vm;
    _ = externs;
    _ = check;
}
