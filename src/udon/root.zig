//! Udon Assembly toolkit (WASM-independent).
//!
//!   * `asm`   — program builder and text writer.
//!   * `sig`   — extern signature parser.
//!   * `text`  — Udon Assembly text parser.
//!   * `check` — static conformance checker against `docs/udon_specs.md`.
//!   * `vm`    — strict Udon VM emulator.

const std = @import("std");

pub const asm_ = @import("asm.zig");
pub const sig = @import("sig.zig");
pub const text = @import("text.zig");
pub const check = @import("check.zig");
pub const vm = @import("vm.zig");

pub const Program = asm_.Program;
pub const Vm = vm.Vm;

test {
    std.testing.refAllDecls(@This());
}
