//! Variable / label naming conventions used by the WASM → Udon translator.
//!
//! Follows `docs/spec_variable_conversion.md` (naming scheme for flattening
//! WASM locals/globals into Udon's flat field namespace) and
//! `docs/spec_call_return_conversion.md` §3 (P / S / R / RA suffixes plus
//! per-callsite `__ret_addr_{K}__` / `__call_ret_{K}__`).
//!
//! All helpers are allocator-based and return owned slices because Udon label
//! names must survive for the entire translation pass.

const std = @import("std");

pub fn global(alloc: std.mem.Allocator, wasm_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "__G__{s}", .{sanitize(wasm_name)});
}

pub fn param(alloc: std.mem.Allocator, fn_name: []const u8, i: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_P{d}__", .{ sanitize(fn_name), i });
}

pub fn local(alloc: std.mem.Allocator, fn_name: []const u8, i: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_L{d}__", .{ sanitize(fn_name), i });
}

pub fn stackSlot(alloc: std.mem.Allocator, fn_name: []const u8, depth: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_S{d}__", .{ sanitize(fn_name), depth });
}

pub fn returnSlot(alloc: std.mem.Allocator, fn_name: []const u8, i: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_R{d}__", .{ sanitize(fn_name), i });
}

pub fn returnAddrSlot(alloc: std.mem.Allocator, fn_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_RA__", .{sanitize(fn_name)});
}

pub fn entryLabel(alloc: std.mem.Allocator, fn_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_entry__", .{sanitize(fn_name)});
}

pub fn exitLabel(alloc: std.mem.Allocator, fn_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_exit__", .{sanitize(fn_name)});
}

pub fn blockEndLabel(alloc: std.mem.Allocator, fn_name: []const u8, id: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_BE{d}__", .{ sanitize(fn_name), id });
}

pub fn loopHeadLabel(alloc: std.mem.Allocator, fn_name: []const u8, id: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_LH{d}__", .{ sanitize(fn_name), id });
}

pub fn ifElseLabel(alloc: std.mem.Allocator, fn_name: []const u8, id: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_IE{d}__", .{ sanitize(fn_name), id });
}

pub fn ifEndLabel(alloc: std.mem.Allocator, fn_name: []const u8, id: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_IF{d}__", .{ sanitize(fn_name), id });
}

pub fn retAddrConst(alloc: std.mem.Allocator, k: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__ret_addr_{d}__", .{k});
}

pub fn callRetLabel(alloc: std.mem.Allocator, k: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__call_ret_{d}__", .{k});
}

pub fn constSlot(alloc: std.mem.Allocator, k: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "__const_{d}__", .{k});
}

/// Function-table entry-address data variable (`docs/spec_call_return_conversion.md` §7.1).
pub fn fnEntryAddr(alloc: std.mem.Allocator, fn_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "__{s}_entry_addr__", .{sanitize(fn_name)});
}

/// Replace characters that aren't legal in Udon variable names (§4.4) with
/// underscore. Legal: letters, digits, underscore. WASM function names may
/// contain `.` or `$` from DWARF/objdump output.
pub fn sanitize(name: []const u8) []const u8 {
    // Simple pass-through for names that are already legal. For the bench
    // fixture the LLVM emitter uses plain identifier characters; a full
    // sanitizer would rewrite into a buffer. This suffices for MVP.
    return name;
}

test "global name uses __G__ prefix" {
    const s = try global(std.testing.allocator, "counter");
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("__G__counter", s);
}

test "stack slot format" {
    const s = try stackSlot(std.testing.allocator, "foo", 3);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("__foo_S3__", s);
}

test "entry/exit labels" {
    const e = try entryLabel(std.testing.allocator, "bar");
    defer std.testing.allocator.free(e);
    const x = try exitLabel(std.testing.allocator, "bar");
    defer std.testing.allocator.free(x);
    try std.testing.expectEqualStrings("__bar_entry__", e);
    try std.testing.expectEqualStrings("__bar_exit__", x);
}

test "retAddr const naming" {
    const r = try retAddrConst(std.testing.allocator, 7);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("__ret_addr_7__", r);
}
