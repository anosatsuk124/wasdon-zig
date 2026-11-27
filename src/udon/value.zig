//! Values held in the emulated Udon heap.
//!
//! The real heap stores one `StrongBox<T>` per slot and type-checks every
//! typed read (`GetHeapVariable<T>`); the emulator keeps the same strictness
//! by tagging each value with its .NET type and refusing mismatched reads.

const std = @import("std");

pub const VecKind = enum { vector2, vector3, vector4, quaternion, color };

pub const Vec = struct {
    kind: VecKind,
    v: [4]f32 = .{ 0, 0, 0, 0 },

    pub fn typeName(self: Vec) []const u8 {
        return switch (self.kind) {
            .vector2 => "UnityEngineVector2",
            .vector3 => "UnityEngineVector3",
            .vector4 => "UnityEngineVector4",
            .quaternion => "UnityEngineQuaternion",
            .color => "UnityEngineColor",
        };
    }
};

pub const ElemKind = enum {
    boolean,
    byte,
    sbyte,
    int16,
    uint16,
    char,
    int32,
    uint32,
    int64,
    uint64,
    single,
    double,
    /// Reference types and structs: one `Value` per element.
    value,

    pub fn size(k: ElemKind) u32 {
        return switch (k) {
            .boolean, .byte, .sbyte => 1,
            .int16, .uint16, .char => 2,
            .int32, .uint32, .single => 4,
            .int64, .uint64, .double => 8,
            .value => 0,
        };
    }
};

/// A .NET array. Primitive arrays keep their elements as raw little-endian
/// bytes so `Buffer.BlockCopy` and `BitConverter` see exactly what the CLR
/// would.
pub const Array = struct {
    /// Udon type name of the array itself, e.g. `SystemByteArray`.
    type_name: []const u8,
    kind: ElemKind,
    len: u32,
    bytes: []u8 = &.{},
    values: []Value = &.{},

    pub fn elemTypeName(self: *const Array) []const u8 {
        return self.type_name[0 .. self.type_name.len - "Array".len];
    }
};

/// A host object the emulator does not model in detail: Unity components,
/// players, encodings. Property getters/setters read and write `props`.
pub const Object = struct {
    type_name: []const u8,
    name: []const u8 = "",
    props: std.StringArrayHashMapUnmanaged(Value) = .empty,
    children: std.ArrayList(*Object) = .empty,

    pub fn get(self: *const Object, key: []const u8) ?Value {
        return self.props.get(key);
    }

    pub fn put(self: *Object, a: std.mem.Allocator, key: []const u8, v: Value) !void {
        try self.props.put(a, key, v);
    }
};

pub const Value = union(enum) {
    null_,
    boolean: bool,
    byte: u8,
    sbyte: i8,
    int16: i16,
    uint16: u16,
    char: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    single: f32,
    double: f64,
    string: []const u8,
    array: *Array,
    object: *Object,
    vec: Vec,
    color32: [4]u8,

    /// Udon type name of the value's runtime type, for diagnostics.
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null_ => "null",
            .boolean => "SystemBoolean",
            .byte => "SystemByte",
            .sbyte => "SystemSByte",
            .int16 => "SystemInt16",
            .uint16 => "SystemUInt16",
            .char => "SystemChar",
            .int32 => "SystemInt32",
            .uint32 => "SystemUInt32",
            .int64 => "SystemInt64",
            .uint64 => "SystemUInt64",
            .single => "SystemSingle",
            .double => "SystemDouble",
            .string => "SystemString",
            .array => |a| a.type_name,
            .object => |o| o.type_name,
            .vec => |v| v.typeName(),
            .color32 => "UnityEngineColor32",
        };
    }

    /// The value a slot declared `%<type_name>, null` starts with: the
    /// type's default for value types, a null reference otherwise
    /// (`docs/udon_specs.md` §4.5).
    pub fn defaultFor(type_name: []const u8) Value {
        const table = .{
            .{ "SystemBoolean", Value{ .boolean = false } },
            .{ "SystemByte", Value{ .byte = 0 } },
            .{ "SystemSByte", Value{ .sbyte = 0 } },
            .{ "SystemInt16", Value{ .int16 = 0 } },
            .{ "SystemUInt16", Value{ .uint16 = 0 } },
            .{ "SystemChar", Value{ .char = 0 } },
            .{ "SystemInt32", Value{ .int32 = 0 } },
            .{ "SystemUInt32", Value{ .uint32 = 0 } },
            .{ "SystemInt64", Value{ .int64 = 0 } },
            .{ "SystemUInt64", Value{ .uint64 = 0 } },
            .{ "SystemSingle", Value{ .single = 0 } },
            .{ "SystemDouble", Value{ .double = 0 } },
            .{ "UnityEngineVector2", Value{ .vec = .{ .kind = .vector2 } } },
            .{ "UnityEngineVector3", Value{ .vec = .{ .kind = .vector3 } } },
            .{ "UnityEngineVector4", Value{ .vec = .{ .kind = .vector4 } } },
            .{ "UnityEngineQuaternion", Value{ .vec = .{ .kind = .quaternion } } },
            .{ "UnityEngineColor", Value{ .vec = .{ .kind = .color } } },
            .{ "UnityEngineColor32", Value{ .color32 = .{ 0, 0, 0, 0 } } },
        };
        inline for (table) |e| if (std.mem.eql(u8, type_name, e[0])) return e[1];
        return .null_;
    }

    pub fn elemKindFor(elem_type: []const u8) ElemKind {
        const table = .{
            .{ "SystemBoolean", ElemKind.boolean }, .{ "SystemByte", ElemKind.byte },
            .{ "SystemSByte", ElemKind.sbyte },     .{ "SystemInt16", ElemKind.int16 },
            .{ "SystemUInt16", ElemKind.uint16 },   .{ "SystemChar", ElemKind.char },
            .{ "SystemInt32", ElemKind.int32 },     .{ "SystemUInt32", ElemKind.uint32 },
            .{ "SystemInt64", ElemKind.int64 },     .{ "SystemUInt64", ElemKind.uint64 },
            .{ "SystemSingle", ElemKind.single },   .{ "SystemDouble", ElemKind.double },
        };
        inline for (table) |e| if (std.mem.eql(u8, elem_type, e[0])) return e[1];
        return .value;
    }

    /// `ToString()` as Unity's `Debug.Log` would print it. Close enough for
    /// log comparison; float formatting is shortest-round-trip rather than
    /// .NET's `G7`/`G15`.
    pub fn format(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .null_ => try w.writeAll("Null"),
            .boolean => |b| try w.writeAll(if (b) "True" else "False"),
            .char => |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch 0;
                try w.writeAll(buf[0..n]);
            },
            inline .byte, .sbyte, .int16, .uint16, .int32, .uint32, .int64, .uint64 => |v| try w.print("{d}", .{v}),
            inline .single, .double => |v| try w.print("{d}", .{v}),
            .string => |s| try w.writeAll(s),
            .array => |a| try w.print("{s}[{d}]", .{ a.elemTypeName(), a.len }),
            .object => |o| if (o.name.len != 0) try w.print("{s} ({s})", .{ o.name, o.type_name }) else try w.writeAll(o.type_name),
            .vec => |v| {
                const n: usize = switch (v.kind) {
                    .vector2 => 2,
                    .vector3 => 3,
                    else => 4,
                };
                try w.writeAll(if (v.kind == .color) "RGBA(" else "(");
                for (v.v[0..n], 0..) |c, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.print("{d:.2}", .{c});
                }
                try w.writeAll(")");
            },
            .color32 => |c| try w.print("RGBA({d}, {d}, {d}, {d})", .{ c[0], c[1], c[2], c[3] }),
        }
    }
};

test "defaults follow the declared type" {
    try std.testing.expectEqual(Value{ .int64 = 0 }, Value.defaultFor("SystemInt64"));
    try std.testing.expectEqual(Value.null_, Value.defaultFor("SystemString"));
    try std.testing.expectEqual(Value.null_, Value.defaultFor("SystemByteArray"));
    try std.testing.expectEqual(ElemKind.byte, Value.elemKindFor("SystemByte"));
    try std.testing.expectEqual(ElemKind.value, Value.elemKindFor("UnityEngineVector3"));
}

test "format" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Value{ .int32 = -7 }).format(&w);
    try w.writeAll(" ");
    try (Value{ .boolean = true }).format(&w);
    try w.writeAll(" ");
    try (Value{ .vec = .{ .kind = .vector3, .v = .{ 1, 2.5, 3, 0 } } }).format(&w);
    try std.testing.expectEqualStrings("-7 True (1.00, 2.50, 3.00)", w.buffered());
}
