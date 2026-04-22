//! Minimal constant-expression evaluator used by __udon_meta discovery.
//!
//! Supports exactly what `docs/spec_udonmeta_conversion.md` needs the
//! translator to understand at lowering time:
//!
//!   * `[i32.const N]` — the single-instruction literal form
//!   * `[global.get G]` where `G`'s own init expression is an `i32.const`
//!
//! Anything else (arithmetic, floats, multi-instruction bodies) is treated as
//! `NonConstMetaLocator`. The Udon translator never needs to execute WASM;
//! meta pointers/lengths are always emitted as constants by producers.

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
/// be a plain `i32.const`. Returns `NonConstMetaLocator` for anything more
/// elaborate (including chained `global.get` calls).
fn evalGlobalInitI32(mod: Module, globalidx: u32) errors.ParseError!i32 {
    const num_imported = countImportedGlobals(mod);
    if (globalidx < num_imported) return error.NonConstMetaLocator;
    const idx = globalidx - num_imported;
    if (idx >= mod.globals.len) return error.NonConstMetaLocator;
    const init = mod.globals[idx].init;
    if (init.len != 1) return error.NonConstMetaLocator;
    return switch (init[0]) {
        .i32_const => |v| v,
        else => error.NonConstMetaLocator,
    };
}

/// Evaluate a single-instruction expression as an i32. Used for data-segment
/// offsets and inline `i32.const` bodies/inits.
pub fn evalConstI32(mod: Module, expr: []const Instruction) errors.ParseError!i32 {
    if (expr.len != 1) return error.NonConstMetaLocator;
    return switch (expr[0]) {
        .i32_const => |v| v,
        .global_get => |g| try evalGlobalInitI32(mod, g),
        else => error.NonConstMetaLocator,
    };
}

/// Evaluate a function body that must act as a nullary `i32`-returning const
/// function. Only supports a single `i32.const` (and, as a convenience, a
/// single `global.get` that folds).
pub fn evalFuncConstI32(mod: Module, funcidx: u32) errors.ParseError!i32 {
    const num_imported = countImportedFuncs(mod);
    if (funcidx < num_imported) return error.NonConstMetaLocator;
    const idx = funcidx - num_imported;
    if (idx >= mod.codes.len) return error.NonConstMetaLocator;
    return evalConstI32(mod, mod.codes[idx].body);
}

/// Resolve an exported name of kind `global` or (nullary, i32) `func` to its
/// constant i32 value. Returns null when no matching export is present.
pub fn evalExportedI32(mod: Module, export_name: []const u8) errors.ParseError!?i32 {
    for (mod.exports) |exp| {
        if (!std.mem.eql(u8, exp.name, export_name)) continue;
        switch (exp.desc) {
            .global => |g| return try evalGlobalInitI32(mod, g),
            .func => |f| return try evalFuncConstI32(mod, f),
            else => return error.NonConstMetaLocator,
        }
    }
    return null;
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
    try std.testing.expectError(error.NonConstMetaLocator, evalConstI32(mod, &expr));
}

test "evalConstI32 rejects non-const opcode" {
    const mod: Module = .{};
    const expr = [_]Instruction{.i32_add};
    try std.testing.expectError(error.NonConstMetaLocator, evalConstI32(mod, &expr));
}

test "evalConstI32 follows a global.get hop" {
    // globals[0].init = [i32.const 99]; expr = [global.get 0]
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
    try std.testing.expectError(error.NonConstMetaLocator, evalConstI32(mod, &expr));
}
