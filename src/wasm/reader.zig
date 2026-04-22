//! Byte-slice cursor used by every decoder in this sub-library.
//!
//! The reader never owns memory; it only tracks a position inside an
//! externally-owned `[]const u8`. All returned slices alias that buffer.

const std = @import("std");
const errors = @import("errors.zig");

pub const Reader = struct {
    bytes: []const u8,
    pos: usize,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes, .pos = 0 };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.pos;
    }

    pub fn eof(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    pub fn readByte(self: *Reader) errors.ParseError!u8 {
        if (self.pos >= self.bytes.len) return error.UnexpectedEof;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn peekByte(self: *const Reader) errors.ParseError!u8 {
        if (self.pos >= self.bytes.len) return error.UnexpectedEof;
        return self.bytes[self.pos];
    }

    pub fn readBytes(self: *Reader, n: usize) errors.ParseError![]const u8 {
        if (self.remaining() < n) return error.UnexpectedEof;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// Carve out a sub-reader whose window is the next `n` bytes. Useful for
    /// size-prefixed payloads: construct a sub-reader, decode, then require
    /// `sub.eof()` to assert the declared size matched actual consumption.
    pub fn sub(self: *Reader, n: usize) errors.ParseError!Reader {
        const slice = try self.readBytes(n);
        return Reader.init(slice);
    }
};

test "reader readByte advances cursor" {
    var r = Reader.init(&[_]u8{ 0x01, 0x02, 0x03 });
    try std.testing.expectEqual(@as(u8, 0x01), try r.readByte());
    try std.testing.expectEqual(@as(u8, 0x02), try r.readByte());
    try std.testing.expectEqual(@as(usize, 1), r.remaining());
}

test "reader readBytes advances cursor" {
    var r = Reader.init(&[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD });
    const s = try r.readBytes(3);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, s);
    try std.testing.expectEqual(@as(usize, 1), r.remaining());
}

test "reader underflow -> error.UnexpectedEof" {
    var r = Reader.init(&[_]u8{0x00});
    _ = try r.readByte();
    try std.testing.expectError(error.UnexpectedEof, r.readByte());
}

test "reader readBytes underflow" {
    var r = Reader.init(&[_]u8{ 0x00, 0x01 });
    try std.testing.expectError(error.UnexpectedEof, r.readBytes(3));
}

test "reader peek does not advance" {
    var r = Reader.init(&[_]u8{ 0xAB, 0xCD });
    try std.testing.expectEqual(@as(u8, 0xAB), try r.peekByte());
    try std.testing.expectEqual(@as(u8, 0xAB), try r.peekByte());
    try std.testing.expectEqual(@as(usize, 2), r.remaining());
}

test "reader sub carves a window of exact size" {
    var r = Reader.init(&[_]u8{ 1, 2, 3, 4, 5 });
    var s = try r.sub(3);
    try std.testing.expectEqual(@as(usize, 3), s.bytes.len);
    try std.testing.expectEqual(@as(u8, 1), try s.readByte());
    try std.testing.expectEqual(@as(usize, 2), r.remaining());
}
