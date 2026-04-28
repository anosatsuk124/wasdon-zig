//! Minimal constant-expression evaluator for data/element segment offsets
//! and immutable-global inits.
//!
//! Supports exactly two MVP-const forms:
//!
//!   * `[i32.const N]` — the single-instruction literal form
//!   * `[global.get G]` where `G`'s own init expression is an `i32.const`
//!
//! Anything else (arithmetic, floats, multi-instruction bodies) is rejected
//! with `NonConstInitExpr`. The translator never executes WASM, so this is
//! sufficient: per spec, segment offsets must be a constant expression, and
//! the translator only needs to evaluate a single i32-typed result.

const std = @import("std");
const errors = @import("errors.zig");
const module = @import("module.zig");
const Module = module.Module;
const Instruction = @import("instruction.zig").Instruction;

pub fn countImportedFuncs(mod: Module) u32 {
    var n: u32 = 0;
    for (mod.imports) |imp| switch (imp.desc) {
        .func => n += 1,
        else => {},
    };
    return n;
}

pub fn countImportedGlobals(mod: Module) u32 {
    var n: u32 = 0;
    for (mod.imports) |imp| switch (imp.desc) {
        .global => n += 1,
        else => {},
    };
    return n;
}

/// Follow a single `global.get` hop and require the target global's init to
/// be a plain `i32.const`. Returns `NonConstInitExpr` for anything more
/// elaborate (including chained `global.get` calls).
fn evalGlobalInitI32(mod: Module, globalidx: u32) errors.ParseError!i32 {
    const num_imported = countImportedGlobals(mod);
    if (globalidx < num_imported) return error.NonConstInitExpr;
    const idx = globalidx - num_imported;
    if (idx >= mod.globals.len) return error.NonConstInitExpr;
    const init = mod.globals[idx].init;
    if (init.len != 1) return error.NonConstInitExpr;
    return switch (init[0]) {
        .i32_const => |v| v,
        else => error.NonConstInitExpr,
    };
}

/// Evaluate a single-instruction expression as an i32. Used for data-segment
/// offsets, element-segment offsets, and inline `i32.const` immutable-global
/// inits.
pub fn evalConstI32(mod: Module, expr: []const Instruction) errors.ParseError!i32 {
    if (expr.len != 1) return error.NonConstInitExpr;
    return switch (expr[0]) {
        .i32_const => |v| v,
        .global_get => |g| try evalGlobalInitI32(mod, g),
        else => error.NonConstInitExpr,
    };
}

// ---------------- tests ----------------

test "evalConstI32 on [i32.const 42]" {
    const mod: Module = .{};
    const expr = [_]Instruction{.{ .i32_const = 42 }};
    try std.testing.expectEqual(@as(i32, 42), try evalConstI32(mod, &expr));
}

test "evalConstI32 rejects multi-instruction expression" {
    const mod: Module = .{};
    const expr = [_]Instruction{ .{ .i32_const = 1 }, .{ .i32_const = 2 } };
    try std.testing.expectError(error.NonConstInitExpr, evalConstI32(mod, &expr));
}

test "evalConstI32 rejects non-const opcode" {
    const mod: Module = .{};
    const expr = [_]Instruction{.i32_add};
    try std.testing.expectError(error.NonConstInitExpr, evalConstI32(mod, &expr));
}

test "evalConstI32 follows a global.get hop" {
    const gi = [_]Instruction{.{ .i32_const = 99 }};
    const globals = [_]module.Global{.{ .ty = .{ .valtype = .i32, .mut = .immutable }, .init = &gi }};
    const mod: Module = .{ .globals = &globals };
    const expr = [_]Instruction{.{ .global_get = 0 }};
    try std.testing.expectEqual(@as(i32, 99), try evalConstI32(mod, &expr));
}

test "evalConstI32 rejects global.get targeting imported global" {
    const imports = [_]module.Import{.{ .module = "env", .name = "g", .desc = .{ .global = .{ .valtype = .i32, .mut = .immutable } } }};
    const mod: Module = .{ .imports = &imports };
    const expr = [_]Instruction{.{ .global_get = 0 }};
    try std.testing.expectError(error.NonConstInitExpr, evalConstI32(mod, &expr));
}
