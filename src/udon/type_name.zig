//! Udon type-name encoder.
//!
//! Implements `docs/udon_specs.md` §3: C# fully-qualified type names are
//! concatenated with no dots, nested types with no `+`, generic type args
//! appended recursively, arrays get the `Array` suffix.
//!
//! The translator only needs a small, fixed set of primitive / runtime
//! types — the table below is exhaustive for what `bench.wasm` exercises.

const std = @import("std");

/// Primitive .NET types used by the WASM → Udon translation.
pub const Prim = enum {
    int32,
    int64,
    uint32,
    uint64,
    single,
    double,
    boolean,
    string,
    void_,
    object,
};

pub fn primName(p: Prim) []const u8 {
    return switch (p) {
        .int32 => "SystemInt32",
        .int64 => "SystemInt64",
        .uint32 => "SystemUInt32",
        .uint64 => "SystemUInt64",
        .single => "SystemSingle",
        .double => "SystemDouble",
        .boolean => "SystemBoolean",
        .string => "SystemString",
        .void_ => "SystemVoid",
        .object => "SystemObject",
    };
}

/// An encoded Udon type (primitive, or Array-of-primitive). For the minimal
/// surface needed by the translator, this is enough; nested generics can be
/// added later if required.
pub const TypeName = struct {
    prim: Prim,
    is_array: bool = false,

    pub fn write(self: TypeName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(primName(self.prim));
        if (self.is_array) try writer.writeAll("Array");
    }

    pub fn eql(a: TypeName, b: TypeName) bool {
        return a.prim == b.prim and a.is_array == b.is_array;
    }
};

pub const int32: TypeName = .{ .prim = .int32 };
pub const int64: TypeName = .{ .prim = .int64 };
pub const uint32: TypeName = .{ .prim = .uint32 };
pub const uint64: TypeName = .{ .prim = .uint64 };
pub const single: TypeName = .{ .prim = .single };
pub const double: TypeName = .{ .prim = .double };
pub const boolean: TypeName = .{ .prim = .boolean };
pub const string: TypeName = .{ .prim = .string };
pub const void_: TypeName = .{ .prim = .void_ };
pub const object: TypeName = .{ .prim = .object };
pub const object_array: TypeName = .{ .prim = .object, .is_array = true };
pub const uint32_array: TypeName = .{ .prim = .uint32, .is_array = true };
pub const byte_array: TypeName = .{ .prim = .object, .is_array = true }; // not used, see u8 array fallback

/// Allocate a formatted Udon type name string. Caller owns memory.
pub fn format(allocator: std.mem.Allocator, t: TypeName) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try t.write(&buf.writer);
    return try buf.toOwnedSlice();
}

// ------------------ tests ------------------

test "primitive names" {
    try std.testing.expectEqualStrings("SystemInt32", primName(.int32));
    try std.testing.expectEqualStrings("SystemUInt32", primName(.uint32));
    try std.testing.expectEqualStrings("SystemVoid", primName(.void_));
    try std.testing.expectEqualStrings("SystemString", primName(.string));
}

test "TypeName.write primitive" {
    const alloc = std.testing.allocator;
    const s = try format(alloc, int32);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("SystemInt32", s);
}

test "TypeName.write array" {
    const alloc = std.testing.allocator;
    const s = try format(alloc, uint32_array);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("SystemUInt32Array", s);
}

test "TypeName.eql" {
    try std.testing.expect(int32.eql(int32));
    try std.testing.expect(!int32.eql(int64));
    try std.testing.expect(!int32.eql(TypeName{ .prim = .int32, .is_array = true }));
}
