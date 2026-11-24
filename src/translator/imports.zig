//! Host import calls (`docs/spec_host_import_conversion.md`).
//!
//! A WASM function import whose name is an Udon extern signature is called
//! directly: the import name *is* the node name. Arguments map onto the
//! signature left to right:
//!
//!   * numeric WASM values convert to the primitive the signature asks for;
//!   * `SystemString` consumes a `(ptr, len)` pair and decodes UTF-8 from
//!     linear memory;
//!   * `<Primitive>Ref` consumes a pointer: the value is loaded before the
//!     call and stored back after it;
//!   * every other type is an opaque object handle carried in an i32 slot;
//!   * one extra leading WASM argument is the `this` of an instance method.
//!
//! Imports bound by a `kind: "import"` field in `__udon_meta` are not calls
//! at all: they read the bound Udon variable.

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const tr = @import("translate.zig");
const lower_mod = @import("lower.zig");

const Lower = lower_mod.Lower;
const Error = tr.Error;
const Var = tr.Var;
const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const convSig = lower_mod.convSig;
const ph = tr.placeholder;

/// Nodes Udon only exposes with a wider parameter type than the natural
/// C# overload; the narrow spelling in the import name selects the
/// marshalling, the wide one is what gets called.
const aliases = [_][2][]const u8{
    .{ "UnityEngineDebug.__Log__SystemString__SystemVoid", "UnityEngineDebug.__Log__SystemObject__SystemVoid" },
    .{ "UnityEngineDebug.__LogWarning__SystemString__SystemVoid", "UnityEngineDebug.__LogWarning__SystemObject__SystemVoid" },
    .{ "UnityEngineDebug.__LogError__SystemString__SystemVoid", "UnityEngineDebug.__LogError__SystemObject__SystemVoid" },
};

/// How a WASM value type maps onto an Udon primitive parameter.
const Primitive = struct {
    name: []const u8,
    wasm: ValType,
    /// .NET name of the variable type, when a conversion is needed.
    convert: ?[]const u8 = null,
};

const primitives = [_]Primitive{
    .{ .name = "SystemInt32", .wasm = .i32 },
    .{ .name = "SystemInt64", .wasm = .i64 },
    .{ .name = "SystemSingle", .wasm = .f32 },
    .{ .name = "SystemDouble", .wasm = .f64 },
    .{ .name = "SystemBoolean", .wasm = .i32, .convert = "Boolean" },
    .{ .name = "SystemByte", .wasm = .i32, .convert = "Byte" },
    .{ .name = "SystemSByte", .wasm = .i32, .convert = "SByte" },
    .{ .name = "SystemInt16", .wasm = .i32, .convert = "Int16" },
    .{ .name = "SystemUInt16", .wasm = .i32, .convert = "UInt16" },
    .{ .name = "SystemChar", .wasm = .i32, .convert = "Char" },
    .{ .name = "SystemUInt32", .wasm = .i32, .convert = "UInt32" },
    .{ .name = "SystemUInt64", .wasm = .i64, .convert = "UInt64" },
};

fn primitive(name: []const u8) ?Primitive {
    for (primitives) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// WASM parameters one signature argument consumes.
fn width(arg: udon.sig.Arg) usize {
    return if (!arg.is_ref and std.mem.eql(u8, arg.ty, "SystemString")) 2 else 1;
}

pub fn lower(l: *Lower, imp: wasm.module.Import, ty: FuncType) Error!void {
    const t = l.t;
    if (try t.importVar(imp)) |v| {
        if (ty.params.len != 0 or ty.results.len != 1) return error.UnsupportedFeature;
        return l.push(ty.results[0], .{ .lazy = .{ .v = v, .stable = true } });
    }
    const sig = udon.sig.parse(imp.name) orelse return unsupported(l, imp, ty, "is not an Udon extern signature");
    var name = imp.name;
    for (aliases) |alias| if (std.mem.eql(u8, name, alias[0])) {
        name = alias[1];
    };
    if (t.options.nodes) |nodes| if (!nodes.contains(name))
        try t.warn("import \"{s}\" is not in the Udon node list; the program will not start", .{name});

    var expected: usize = 0;
    for (sig.args()) |arg| expected += width(arg);
    const has_this = ty.params.len == expected + 1;
    if (ty.params.len != expected + @intFromBool(has_this) or ty.results.len != @intFromBool(sig.returnsValue()))
        return unsupported(l, imp, ty, "does not match its WASM type");
    try l.need(ty.params.len);
    const first = l.stack.items.len - ty.params.len;

    // Build the operand list: [this] args... [result].
    var operands: std.ArrayList(Var) = .empty;
    var write_back: std.ArrayList(struct { v: Var, ptr: Var, prim: Primitive }) = .empty;
    var pos = first;
    if (has_this) {
        try operands.append(t.a, try l.use(pos));
        pos += 1;
    }
    for (sig.args(), 0..) |arg, i| {
        defer pos += width(arg);
        if (arg.is_ref) {
            // The WASM argument points at the value in linear memory.
            const prim = primitive(arg.ty) orelse return unsupported(l, imp, ty, "has a by-reference object parameter");
            // BitConverter has no single-byte accessors.
            if (std.mem.endsWith(u8, arg.ty, "Byte")) return unsupported(l, imp, ty, "has a by-reference byte parameter");
            const v = try scratch(l, "ref", arg.ty, i);
            const ptr = try t.named(try std.fmt.allocPrint(t.a, "__x_ptr_{d}", .{i}), "SystemInt32", .{ .int = 0 });
            try t.copy(try l.use(pos), ptr);
            try loadRef(l, prim, ptr, v);
            try write_back.append(t.a, .{ .v = v, .ptr = ptr, .prim = prim });
            try operands.append(t.a, v);
        } else if (std.mem.eql(u8, arg.ty, "SystemString")) {
            const str = try scratch(l, "str", "SystemString", i);
            _ = try t.ext("SystemTextEncoding.__GetString__SystemByteArray_SystemInt32_SystemInt32__SystemString", &.{ try t.utf8(), try t.mem(), try l.use(pos), try l.use(pos + 1), str });
            try operands.append(t.a, str);
        } else if (primitive(arg.ty)) |prim| {
            if (l.stack.items[pos].ty != prim.wasm) return unsupported(l, imp, ty, "does not match its WASM type");
            try operands.append(t.a, if (prim.convert == null) try l.use(pos) else try toUdon(l, prim, pos, try scratch(l, "arg", arg.ty, i)));
        } else {
            // Object handle, passed through untouched.
            try operands.append(t.a, try l.use(pos));
        }
    }

    const ret: ?Primitive = if (sig.returnsValue()) primitive(sig.ret) else null;
    if (ret) |prim| if (prim.wasm != ty.results[0]) return unsupported(l, imp, ty, "does not match its WASM type");
    l.drop(ty.params.len);
    // Where the extern writes its result: a boolean goes straight into the
    // comparison slot, other converted primitives into scratch, and
    // everything else wherever the consumer wants it.
    const converted = ret != null and ret.?.convert != null;
    const is_bool = converted and std.mem.eql(u8, ret.?.convert.?, "Boolean");
    const raw: Var = if (is_bool) try l.boolVar(l.stack.items.len) else if (converted) try scratch(l, "ret", sig.ret, 0) else ph;
    if (sig.returnsValue()) try operands.append(t.a, raw);
    const call = try t.ext(name, operands.items);

    for (write_back.items) |w| try storeRef(l, w.prim, w.ptr, w.v);
    if (!sig.returnsValue()) return;
    if (is_bool) return l.push(.i32, .{ .cond = .{ .v = raw } });
    if (converted) return fromUdon(l, ret.?, raw);
    try l.pushPending(ty.results[0], call, @intCast(operands.items.len - 1));
}

/// A call to an import the translator cannot bind. Strict mode rejects the
/// module; otherwise the call site traps if it is ever reached.
fn unsupported(l: *Lower, imp: wasm.module.Import, ty: FuncType, comptime why: []const u8) Error!void {
    const t = l.t;
    if (t.meta) |m| if (m.options.strict) return error.UnresolvedImport;
    try t.warn("import \"{s}\".\"{s}\" " ++ why ++ "; calls to it trap", .{ imp.module, imp.name });
    try t.trap(try std.fmt.allocPrint(t.a, "wasdon: call to unsupported import {s}.{s}", .{ imp.module, imp.name }));
    try l.need(ty.params.len);
    l.drop(ty.params.len);
    for (ty.results) |r| try l.push(r, .{ .konst = .{ .ty = r, .bits = 0 } });
    l.dead = true;
}

fn scratch(l: *Lower, comptime role: []const u8, ty: []const u8, i: usize) Error!Var {
    const short = if (std.mem.startsWith(u8, ty, "System")) ty[6..] else ty;
    const name = try std.fmt.allocPrint(l.t.a, "__x_" ++ role ++ "_{s}_{d}", .{ short, i });
    return l.t.named(name, ty, if (std.mem.eql(u8, ty, "SystemInt32")) .{ .int = 0 } else if (std.mem.eql(u8, ty, "SystemUInt32")) .{ .uint = 0 } else .null_);
}

fn dynSig(l: *Lower, comptime fmt: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(l.t.a, fmt, args);
}

/// Convert the WASM value at `pos` into the Udon primitive `prim`, in `dst`.
fn toUdon(l: *Lower, prim: Primitive, pos: usize, dst: Var) Error!Var {
    const t = l.t;
    const to = prim.convert.?;
    if (std.mem.eql(u8, to, "Boolean")) {
        // A comparison result already is a SystemBoolean.
        const loc = l.stack.items[pos].loc;
        if (loc == .cond and !loc.cond.negated) return loc.cond.v;
    }
    if (std.mem.eql(u8, to, "UInt32")) {
        // Reinterpret: zero-extend to 64 bits, then the checked conversion fits.
        const wide = try t.tmp(.i64, 0);
        _ = try t.ext(convSig("Int32", "Int64"), &.{ try l.use(pos), wide });
        _ = try t.ext(lower_mod.opSig("Int64", "LogicalAnd"), &.{ wide, try t.constant(.i64_(0xFFFF_FFFF)), wide });
        _ = try t.ext(convSig("Int64", "UInt32"), &.{ wide, dst });
    } else if (std.mem.eql(u8, to, "UInt64")) {
        _ = try reinterpret64(l, "Int64", "UInt64", try l.use(pos), dst);
    } else {
        // Range-checked like a C# `checked` cast (Boolean: non-zero is true).
        _ = try t.ext(try dynSig(l, "SystemConvert.__To{s}__SystemInt32__System{s}", .{ to, to }), &.{ try l.use(pos), dst });
    }
    return dst;
}

/// Push the non-boolean Udon primitive in `raw` as a WASM value.
fn fromUdon(l: *Lower, prim: Primitive, raw: Var) Error!void {
    const t = l.t;
    const from = prim.convert.?;
    if (std.mem.eql(u8, from, "UInt32")) {
        const wide = try t.tmp(.i64, 0);
        _ = try t.ext(convSig("UInt32", "Int64"), &.{ raw, wide });
        const n = try t.constI32(32);
        _ = try t.ext(lower_mod.shSig("Int64", "LeftShift"), &.{ wide, n, wide });
        _ = try t.ext(lower_mod.shSig("Int64", "RightShift"), &.{ wide, n, wide });
        return l.pushPending(.i32, try t.ext(convSig("Int64", "Int32"), &.{ wide, ph }), 1);
    } else if (std.mem.eql(u8, from, "UInt64")) {
        return l.pushPending(.i64, try reinterpret64(l, "UInt64", "Int64", raw, ph), 2);
    }
    const sig = try dynSig(l, "SystemConvert.__ToInt32__System{s}__SystemInt32", .{from});
    try l.pushPending(.i32, try t.ext(sig, &.{ raw, ph }), 1);
}

/// Bit-preserving `Int64` <-> `UInt64`; returns the instruction writing `dst`.
fn reinterpret64(l: *Lower, comptime from: []const u8, comptime to: []const u8, x: Var, dst: Var) Error!u32 {
    const t = l.t;
    const bytes = try t.named("__x_bytes", "SystemByteArray", .null_);
    _ = try t.ext("SystemBitConverter.__GetBytes__System" ++ from ++ "__SystemByteArray", &.{ x, bytes });
    return t.ext("SystemBitConverter.__To" ++ to ++ "__SystemByteArray_SystemInt32__System" ++ to, &.{ bytes, try t.constI32(0), dst });
}

/// `v = *(T*)ptr` for a by-reference primitive argument.
fn loadRef(l: *Lower, prim: Primitive, ptr: Var, v: Var) Error!void {
    const t = l.t;
    const short = prim.name[6..];
    const sig = try dynSig(l, "SystemBitConverter.__To{s}__SystemByteArray_SystemInt32__System{s}", .{ short, short });
    _ = try t.ext(sig, &.{ try t.mem(), ptr, v });
}

/// `*(T*)ptr = v` after the call.
fn storeRef(l: *Lower, prim: Primitive, ptr: Var, v: Var) Error!void {
    const t = l.t;
    const short = prim.name[6..];
    const bytes = try t.named("__x_bytes", "SystemByteArray", .null_);
    _ = try t.ext(try dynSig(l, "SystemBitConverter.__GetBytes__System{s}__SystemByteArray", .{short}), &.{ v, bytes });
    _ = try t.ext("SystemByteArray.__CopyTo__SystemArray_SystemInt32__SystemVoid", &.{ bytes, try t.mem(), ptr });
}
