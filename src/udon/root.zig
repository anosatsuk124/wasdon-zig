//! Udon Assembly construction primitives (WASM-independent).
//!
//! Surface:
//!   * `type_name` — encode .NET type names per `docs/udon_specs.md` §3.
//!   * `asm` — build and render a Udon Assembly program, including bytecode
//!     address layout (Pass A) and text rendering (Pass C).

const std = @import("std");

pub const type_name = @import("type_name.zig");
pub const asm_ = @import("asm.zig");

pub const TypeName = type_name.TypeName;
pub const Asm = asm_.Asm;
pub const Literal = asm_.Literal;
pub const DataDecl = asm_.DataDecl;

test {
    std.testing.refAllDecls(@This());
    _ = type_name;
    _ = asm_;
}
