//! Low-level section framing.
//!
//! A WASM binary is a stream of `section := id:byte size:u32 payload:size
//! bytes`. This module only cares about that envelope (id + size-delimited
//! payload slice) and the ordering/duplication rules; payload decoding lives
//! in `module.zig`.

const std = @import("std");
const errors = @import("errors.zig");
const Reader = @import("reader.zig").Reader;
const leb128 = @import("leb128.zig");

pub const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
};

pub fn sectionIdFromByte(b: u8) errors.ParseError!SectionId {
    if (b > 11) return error.UnknownSectionId;
    return @enumFromInt(b);
}

pub const RawSection = struct {
    id: SectionId,
    payload: []const u8,
};

/// Read one section header + payload slice. Advances `r` past the whole
/// section. The returned `payload` aliases the underlying buffer.
pub fn readSection(r: *Reader) errors.ParseError!RawSection {
    const id_byte = try r.readByte();
    const id = try sectionIdFromByte(id_byte);
    const size = try leb128.readULEB128(u32, r);
    const payload = try r.readBytes(size);
    return .{ .id = id, .payload = payload };
}

// ---------------- tests ----------------

fn mk(bytes: []const u8) Reader {
    return Reader.init(bytes);
}

test "sectionIdFromByte maps all ids" {
    try std.testing.expectEqual(SectionId.custom, try sectionIdFromByte(0));
    try std.testing.expectEqual(SectionId.type, try sectionIdFromByte(1));
    try std.testing.expectEqual(SectionId.data, try sectionIdFromByte(11));
}

test "sectionIdFromByte rejects unknown" {
    try std.testing.expectError(error.UnknownSectionId, sectionIdFromByte(12));
    try std.testing.expectError(error.UnknownSectionId, sectionIdFromByte(0xFF));
}

test "readSection returns id + slice" {
    // id=1, size=3, payload=[0xAA, 0xBB, 0xCC]
    var r = mk(&[_]u8{ 0x01, 0x03, 0xAA, 0xBB, 0xCC });
    const s = try readSection(&r);
    try std.testing.expectEqual(SectionId.type, s.id);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, s.payload);
    try std.testing.expect(r.eof());
}

test "readSection EOF mid-payload" {
    var r = mk(&[_]u8{ 0x01, 0x05, 0xAA });
    try std.testing.expectError(error.UnexpectedEof, readSection(&r));
}
