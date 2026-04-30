//! Decoders for the primitive type encodings of WASM Core 1.
//!
//! Coverage (per docs/w3c_wasm_binary_format_note.md):
//!   * ValType            (§ Value Types)
//!   * ResultType         (§ Result Types)
//!   * FuncType           (§ Function Types)
//!   * Limits             (§ Limits)
//!   * MemType / TableType (§ Memory / Table Types)
//!   * GlobalType         (§ Global Types)
//!   * Name               (§ Names — UTF-8 validated)
//!   * BlockType          (§ blocktype — encoded as s33)
//!
//! Every function leaves the reader's cursor positioned immediately past the
//! decoded value when successful, or at an undefined position on error.

const std = @import("std");
const errors = @import("errors.zig");
const Reader = @import("reader.zig").Reader;
const leb128 = @import("leb128.zig");

pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    /// Post-MVP `reference-types` proposal (`docs/w3c_wasm_binary_format_note.md`
    /// §"Reference-types `funcref` value type"). Decoder-only acceptance:
    /// the translator raises `FuncrefValueTypeNotYetSupported` if a
    /// `funcref` reaches a position that would require materializing a
    /// first-class function reference (param / result / local / global /
    /// stack value). Table elem types still go through their own decoder.
    funcref = 0x70,
};

pub fn decodeValType(r: *Reader) errors.ParseError!ValType {
    const b = try r.readByte();
    return switch (b) {
        0x7F => .i32,
        0x7E => .i64,
        0x7D => .f32,
        0x7C => .f64,
        0x70 => .funcref,
        else => error.InvalidValType,
    };
}

pub fn decodeResultType(allocator: std.mem.Allocator, r: *Reader) errors.ParseError![]ValType {
    const n = try leb128.readULEB128(u32, r);
    const out = try allocator.alloc(ValType, n);
    errdefer allocator.free(out);
    for (out) |*v| v.* = try decodeValType(r);
    return out;
}

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

pub fn decodeFuncType(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!FuncType {
    const tag = try r.readByte();
    if (tag != 0x60) return error.MalformedFuncType;
    const params = try decodeResultType(allocator, r);
    errdefer allocator.free(params);
    const results = try decodeResultType(allocator, r);
    return .{ .params = params, .results = results };
}

pub const Limits = struct {
    min: u32,
    max: ?u32,
};

pub fn decodeLimits(r: *Reader) errors.ParseError!Limits {
    const tag = try r.readByte();
    switch (tag) {
        0x00 => {
            const min = try leb128.readULEB128(u32, r);
            return .{ .min = min, .max = null };
        },
        0x01 => {
            const min = try leb128.readULEB128(u32, r);
            const max = try leb128.readULEB128(u32, r);
            return .{ .min = min, .max = max };
        },
        else => return error.MalformedLimits,
    }
}

pub const MemType = Limits;

pub fn decodeMemType(r: *Reader) errors.ParseError!MemType {
    return decodeLimits(r);
}

pub const ElemType = enum(u8) {
    funcref = 0x70,
};

pub const TableType = struct {
    elem: ElemType,
    limits: Limits,
};

pub fn decodeTableType(r: *Reader) errors.ParseError!TableType {
    const e = try r.readByte();
    if (e != 0x70) return error.InvalidElemType;
    const limits = try decodeLimits(r);
    return .{ .elem = .funcref, .limits = limits };
}

pub const Mutability = enum(u8) {
    immutable = 0x00,
    mutable = 0x01,
};

pub const GlobalType = struct {
    valtype: ValType,
    mut: Mutability,
};

pub fn decodeGlobalType(r: *Reader) errors.ParseError!GlobalType {
    const vt = try decodeValType(r);
    const mb = try r.readByte();
    const mut: Mutability = switch (mb) {
        0x00 => .immutable,
        0x01 => .mutable,
        else => return error.MalformedMut,
    };
    return .{ .valtype = vt, .mut = mut };
}

/// name := vec(byte); the bytes must be valid UTF-8. Returned slice aliases
/// the reader's underlying buffer — the caller does not own it.
pub fn decodeName(r: *Reader) errors.ParseError![]const u8 {
    const n = try leb128.readULEB128(u32, r);
    const bytes = try r.readBytes(n);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8Name;
    return bytes;
}

pub const BlockType = union(enum) {
    empty,
    value: ValType,
    /// typeidx referring to the type section (Core 1 validation ultimately
    /// restricts this, but the binary format itself allows any non-negative
    /// s33). Stored as u32 to match other indices.
    type_index: u32,
};

pub fn decodeBlockType(r: *Reader) errors.ParseError!BlockType {
    // Core 1 blocktype is encoded as s33: negative values denote the single
    // `empty` marker (0x40 → -64) or a valtype (e.g. 0x7F → -1, ...).
    // Non-negative s33 values are a typeidx in the binary format.
    // We peek the first byte to disambiguate the common short forms quickly.
    const first = try r.peekByte();
    if (first == 0x40) {
        _ = try r.readByte();
        return .empty;
    }
    switch (first) {
        0x7F, 0x7E, 0x7D, 0x7C, 0x70 => {
            const vt = try decodeValType(r);
            return .{ .value = vt };
        },
        else => {},
    }
    // Otherwise: positive s33 typeidx.
    const raw = try leb128.readSLEB128(i33, r);
    if (raw < 0) return error.InvalidBlockType;
    return .{ .type_index = @intCast(raw) };
}

// ---------------- tests ----------------

fn mk(bytes: []const u8) Reader {
    return Reader.init(bytes);
}

test "decodeValType all four" {
    var r1 = mk(&[_]u8{0x7F});
    try std.testing.expectEqual(ValType.i32, try decodeValType(&r1));
    var r2 = mk(&[_]u8{0x7E});
    try std.testing.expectEqual(ValType.i64, try decodeValType(&r2));
    var r3 = mk(&[_]u8{0x7D});
    try std.testing.expectEqual(ValType.f32, try decodeValType(&r3));
    var r4 = mk(&[_]u8{0x7C});
    try std.testing.expectEqual(ValType.f64, try decodeValType(&r4));
}

test "decodeValType rejects unknown byte" {
    var r = mk(&[_]u8{0x6F});
    try std.testing.expectError(error.InvalidValType, decodeValType(&r));
}

test "decodeFuncType empty signature" {
    // 0x60 00 00 → functype with no params and no results
    var r = mk(&[_]u8{ 0x60, 0x00, 0x00 });
    const ft = try decodeFuncType(std.testing.allocator, &r);
    defer std.testing.allocator.free(ft.params);
    defer std.testing.allocator.free(ft.results);
    try std.testing.expectEqual(@as(usize, 0), ft.params.len);
    try std.testing.expectEqual(@as(usize, 0), ft.results.len);
}

test "decodeFuncType (i32 i32) -> (i32)" {
    // 0x60 02 7F 7F 01 7F
    var r = mk(&[_]u8{ 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F });
    const ft = try decodeFuncType(std.testing.allocator, &r);
    defer std.testing.allocator.free(ft.params);
    defer std.testing.allocator.free(ft.results);
    try std.testing.expectEqualSlices(ValType, &[_]ValType{ .i32, .i32 }, ft.params);
    try std.testing.expectEqualSlices(ValType, &[_]ValType{.i32}, ft.results);
}

test "decodeFuncType rejects missing 0x60 tag" {
    var r = mk(&[_]u8{ 0x61, 0x00, 0x00 });
    try std.testing.expectError(error.MalformedFuncType, decodeFuncType(std.testing.allocator, &r));
}

test "decodeLimits min only" {
    var r = mk(&[_]u8{ 0x00, 0x01 });
    const l = try decodeLimits(&r);
    try std.testing.expectEqual(@as(u32, 1), l.min);
    try std.testing.expect(l.max == null);
}

test "decodeLimits min + max" {
    var r = mk(&[_]u8{ 0x01, 0x01, 0x10 });
    const l = try decodeLimits(&r);
    try std.testing.expectEqual(@as(u32, 1), l.min);
    try std.testing.expectEqual(@as(u32, 16), l.max.?);
}

test "decodeLimits rejects bad tag" {
    var r = mk(&[_]u8{ 0x02, 0x01 });
    try std.testing.expectError(error.MalformedLimits, decodeLimits(&r));
}

test "decodeTableType funcref" {
    var r = mk(&[_]u8{ 0x70, 0x00, 0x01 });
    const t = try decodeTableType(&r);
    try std.testing.expectEqual(ElemType.funcref, t.elem);
    try std.testing.expectEqual(@as(u32, 1), t.limits.min);
}

test "decodeTableType rejects non-funcref" {
    var r = mk(&[_]u8{ 0x6F, 0x00, 0x01 });
    try std.testing.expectError(error.InvalidElemType, decodeTableType(&r));
}

test "decodeGlobalType immutable i32" {
    var r = mk(&[_]u8{ 0x7F, 0x00 });
    const g = try decodeGlobalType(&r);
    try std.testing.expectEqual(ValType.i32, g.valtype);
    try std.testing.expectEqual(Mutability.immutable, g.mut);
}

test "decodeGlobalType mutable f64" {
    var r = mk(&[_]u8{ 0x7C, 0x01 });
    const g = try decodeGlobalType(&r);
    try std.testing.expectEqual(ValType.f64, g.valtype);
    try std.testing.expectEqual(Mutability.mutable, g.mut);
}

test "decodeGlobalType rejects bad mut" {
    var r = mk(&[_]u8{ 0x7F, 0x02 });
    try std.testing.expectError(error.MalformedMut, decodeGlobalType(&r));
}

test "decodeName ascii" {
    // 5 'h' 'e' 'l' 'l' 'o'
    var r = mk(&[_]u8{ 0x05, 'h', 'e', 'l', 'l', 'o' });
    const s = try decodeName(&r);
    try std.testing.expectEqualStrings("hello", s);
}

test "decodeName utf8 multibyte" {
    // "日" is E6 97 A5, 3 bytes.
    var r = mk(&[_]u8{ 0x03, 0xE6, 0x97, 0xA5 });
    const s = try decodeName(&r);
    try std.testing.expectEqualStrings("日", s);
}

test "decodeName rejects invalid utf8" {
    // 0xC3 alone is the start of a 2-byte sequence but here it has no
    // continuation byte — invalid UTF-8.
    var r = mk(&[_]u8{ 0x01, 0xC3 });
    try std.testing.expectError(error.InvalidUtf8Name, decodeName(&r));
}

test "decodeBlockType empty (0x40)" {
    var r = mk(&[_]u8{0x40});
    const bt = try decodeBlockType(&r);
    try std.testing.expect(bt == .empty);
}

test "decodeBlockType single valtype" {
    var r = mk(&[_]u8{0x7F});
    const bt = try decodeBlockType(&r);
    switch (bt) {
        .value => |vt| try std.testing.expectEqual(ValType.i32, vt),
        else => try std.testing.expect(false),
    }
}

test "decodeBlockType typeidx positive" {
    // typeidx 3, encoded as positive s33: 0x03 (single byte, fits 6 bits).
    var r = mk(&[_]u8{0x03});
    const bt = try decodeBlockType(&r);
    switch (bt) {
        .type_index => |idx| try std.testing.expectEqual(@as(u32, 3), idx),
        else => try std.testing.expect(false),
    }
}

test "decodeValType funcref (post-MVP reference-types 0x70)" {
    var r = mk(&[_]u8{0x70});
    try std.testing.expectEqual(ValType.funcref, try decodeValType(&r));
}

test "decodeBlockType single funcref valtype (0x70)" {
    // Reference-types extends `valtype` (and thus the single-valtype short
    // form of `blocktype`) with `funcref = 0x70`. The decoder accepts this
    // form so that producer toolchains with reference-types enabled can
    // emit blocks like `(block (result funcref) ...)` or implicit
    // funcref-returning ifs that arise from `select` on funcref values.
    var r = mk(&[_]u8{0x70});
    const bt = try decodeBlockType(&r);
    switch (bt) {
        .value => |vt| try std.testing.expectEqual(ValType.funcref, vt),
        else => try std.testing.expect(false),
    }
}

test "decodeBlockType typeidx multi-byte" {
    // typeidx 128 → positive s33 encoding: 80 01
    var r = mk(&[_]u8{ 0x80, 0x01 });
    const bt = try decodeBlockType(&r);
    switch (bt) {
        .type_index => |idx| try std.testing.expectEqual(@as(u32, 128), idx),
        else => try std.testing.expect(false),
    }
}
