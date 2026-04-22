//! Generic LEB128 decoders used throughout the WASM binary format.
//!
//! One implementation services every width the spec asks for:
//!   u32 / u64 (indices, sizes, vector lengths), i32 / i64 (numeric immediates),
//!   i33 (blocktype). Width and signedness are read from `@typeInfo(T)` so
//!   a single function body covers all of them.
//!
//! Malformed conditions per docs/w3c_wasm_binary_format_note.md:
//!   * Continuation never terminates     → LebTooLong
//!   * Exceeds ceil(N / 7) bytes          → LebTooLong
//!   * Unused high bits in final byte     → LebUnusedBitsNotZero
//!   * (Width overflow is subsumed by the above two for an N-bit target.)

const std = @import("std");
const errors = @import("errors.zig");
const Reader = @import("reader.zig").Reader;

fn lowBitsMaskU8(n: u16) u8 {
    // n in 1..8; 7 is the only value we hand it in practice.
    std.debug.assert(n >= 1 and n <= 8);
    if (n == 8) return 0xFF;
    return @intCast((@as(u32, 1) << @as(u5, @intCast(n))) - 1);
}

pub fn readULEB128(comptime T: type, r: *Reader) errors.ParseError!T {
    const info = @typeInfo(T).int;
    comptime std.debug.assert(info.signedness == .unsigned);
    const N: u16 = info.bits;
    const max_bytes: usize = (@as(usize, N) + 6) / 7;

    const ShiftT = std.math.Log2Int(T);
    var result: T = 0;
    var shift: u16 = 0;
    var i: usize = 0;
    while (i < max_bytes) : (i += 1) {
        const b = try r.readByte();
        const cont = (b & 0x80) != 0;
        const payload: u8 = b & 0x7F;
        const is_last_allowed = i == max_bytes - 1;
        const used_bits: u16 = if (is_last_allowed) N - shift else 7;

        if (is_last_allowed) {
            if (cont) return error.LebTooLong;
            if (used_bits < 7) {
                const keep_mask = lowBitsMaskU8(used_bits);
                const unused_mask: u8 = 0x7F ^ keep_mask;
                if ((payload & unused_mask) != 0) return error.LebUnusedBitsNotZero;
            }
        }

        const contrib_mask: u8 = if (used_bits == 7) 0x7F else lowBitsMaskU8(used_bits);
        const contrib: u8 = payload & contrib_mask;
        result |= @as(T, contrib) << @as(ShiftT, @intCast(shift));
        shift += used_bits;

        if (!cont) return result;
    }
    unreachable;
}

pub fn readSLEB128(comptime T: type, r: *Reader) errors.ParseError!T {
    const info = @typeInfo(T).int;
    comptime std.debug.assert(info.signedness == .signed);
    const N: u16 = info.bits;
    const max_bytes: usize = (@as(usize, N) + 6) / 7;

    const U = std.meta.Int(.unsigned, N);
    const ShiftT = std.math.Log2Int(U);

    var result: U = 0;
    var shift: u16 = 0;
    var i: usize = 0;
    while (i < max_bytes) : (i += 1) {
        const b = try r.readByte();
        const cont = (b & 0x80) != 0;
        const payload: u8 = b & 0x7F;
        const is_last_allowed = i == max_bytes - 1;
        const used_bits: u16 = if (is_last_allowed) N - shift else 7;

        if (is_last_allowed) {
            if (cont) return error.LebTooLong;
            if (used_bits < 7) {
                const keep_mask = lowBitsMaskU8(used_bits);
                const unused_mask: u8 = 0x7F ^ keep_mask;
                const msb_mask: u8 = @as(u8, 1) << @as(u3, @intCast(used_bits - 1));
                const value_sign = (payload & msb_mask) != 0;
                const unused_bits = payload & unused_mask;
                const expected: u8 = if (value_sign) unused_mask else 0;
                if (unused_bits != expected) return error.LebUnusedBitsNotZero;
            }
        }

        const contrib_mask: u8 = if (used_bits == 7) 0x7F else lowBitsMaskU8(used_bits);
        const contrib: u8 = payload & contrib_mask;
        result |= @as(U, contrib) << @as(ShiftT, @intCast(shift));
        shift += used_bits;

        if (!cont) {
            // Sign-extend from bit (shift - 1) up to N.
            const top_bit_mask: u8 = @as(u8, 1) << @as(u3, @intCast(used_bits - 1));
            const high_bit_set = (contrib & top_bit_mask) != 0;
            if (shift < N and high_bit_set) {
                const ext_mask: U = ~(@as(U, 0)) << @as(ShiftT, @intCast(shift));
                result |= ext_mask;
            }
            return @bitCast(result);
        }
    }
    unreachable;
}

// ---------------- tests ----------------

fn mk(bytes: []const u8) Reader {
    return Reader.init(bytes);
}

test "readULEB128 u32 basic" {
    // 624485 = 0x0009_8765 in u32 → LEB128: E5 8E 26
    var r = mk(&[_]u8{ 0xE5, 0x8E, 0x26 });
    try std.testing.expectEqual(@as(u32, 624485), try readULEB128(u32, &r));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "readULEB128 u32 single-byte zero" {
    var r = mk(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u32, 0), try readULEB128(u32, &r));
}

test "readULEB128 u32 single-byte max-7bit" {
    var r = mk(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(u32, 127), try readULEB128(u32, &r));
}

test "readULEB128 u32 max value" {
    // 0xFFFF_FFFF → FF FF FF FF 0F (5 bytes)
    var r = mk(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F });
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try readULEB128(u32, &r));
}

test "readULEB128 u32 too long rejected" {
    // 6-byte continuation → LebTooLong.
    var r = mk(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try std.testing.expectError(error.LebTooLong, readULEB128(u32, &r));
}

test "readULEB128 u32 unused-bits must be zero" {
    // 5th byte has bits above bit 3 set (4 bits used of the final 7).
    var r = mk(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x10 });
    try std.testing.expectError(error.LebUnusedBitsNotZero, readULEB128(u32, &r));
}

test "readULEB128 u64 across multiple bytes" {
    // 0x1_0000_0000 → 80 80 80 80 10
    var r = mk(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x10 });
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), try readULEB128(u64, &r));
}

test "readULEB128 unexpected eof" {
    var r = mk(&[_]u8{0x80});
    try std.testing.expectError(error.UnexpectedEof, readULEB128(u32, &r));
}

test "readSLEB128 i32 zero" {
    var r = mk(&[_]u8{0x00});
    try std.testing.expectEqual(@as(i32, 0), try readSLEB128(i32, &r));
}

test "readSLEB128 i32 -1 (single byte 0x7F)" {
    var r = mk(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(i32, -1), try readSLEB128(i32, &r));
}

test "readSLEB128 i32 positive 0x7F (expand to two bytes)" {
    // 127 is encoded as FF 00 (two bytes) because single byte 7F means -1.
    var r = mk(&[_]u8{ 0xFF, 0x00 });
    try std.testing.expectEqual(@as(i32, 127), try readSLEB128(i32, &r));
}

test "readSLEB128 i32 -123456" {
    // Canonical SLEB128 of -123456: C0 BB 78.
    var r = mk(&[_]u8{ 0xC0, 0xBB, 0x78 });
    try std.testing.expectEqual(@as(i32, -123456), try readSLEB128(i32, &r));
}

test "readSLEB128 i32 123456" {
    var r = mk(&[_]u8{ 0xC0, 0xC4, 0x07 });
    try std.testing.expectEqual(@as(i32, 123456), try readSLEB128(i32, &r));
}

test "readSLEB128 i32 INT_MIN" {
    // i32.min = -2147483648. Encoding: 80 80 80 80 78
    var r = mk(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x78 });
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), try readSLEB128(i32, &r));
}

test "readSLEB128 i32 INT_MAX" {
    // i32.max = 2147483647. Encoding: FF FF FF FF 07
    var r = mk(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x07 });
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), try readSLEB128(i32, &r));
}

test "readSLEB128 i32 too long rejected" {
    var r = mk(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try std.testing.expectError(error.LebTooLong, readSLEB128(i32, &r));
}

test "readSLEB128 i32 bad sign extension in final byte" {
    // Final byte has only 4 usable bits (for i32); bits above must all match
    // the sign bit (bit 3 of payload). Here bit 3 = 0, but bit 4 = 1 → invalid.
    var r = mk(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x10 });
    try std.testing.expectError(error.LebUnusedBitsNotZero, readSLEB128(i32, &r));
}

test "readSLEB128 i64 sign-extension across many bytes" {
    // -1 encoded maximally (10 bytes, each 0xFF except last 0x7F).
    var r = mk(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
    try std.testing.expectEqual(@as(i64, -1), try readSLEB128(i64, &r));
}

test "readSLEB128 i33 blocktype negative" {
    // i33 (s33) used by blocktype. `-64` is single byte 0x40.
    var r = mk(&[_]u8{0x40});
    try std.testing.expectEqual(@as(i33, -64), try readSLEB128(i33, &r));
}

test "readSLEB128 i33 blocktype positive typeidx" {
    // 0x7F alone is -1 in s33. To encode +0x7F (127) we need FF 00.
    var r = mk(&[_]u8{ 0xFF, 0x00 });
    try std.testing.expectEqual(@as(i33, 127), try readSLEB128(i33, &r));
}
