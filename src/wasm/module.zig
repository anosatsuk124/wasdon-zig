//! Top-level AST types and per-section decoders.
//!
//! Everything allocated here is expected to be backed by a single arena owned
//! by the caller; the Module itself carries no destructor.

const std = @import("std");
const errors = @import("errors.zig");
const Reader = @import("reader.zig").Reader;
const leb128 = @import("leb128.zig");
const types = @import("types.zig");
const section = @import("section.zig");
const instruction = @import("instruction.zig");

pub const Instruction = instruction.Instruction;

pub const ImportDesc = union(enum) {
    func: u32, // typeidx
    table: types.TableType,
    memory: types.MemType,
    global: types.GlobalType,
};

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    desc: ImportDesc,
};

pub const Global = struct {
    ty: types.GlobalType,
    init: []const Instruction,
};

pub const ExportDesc = union(enum) {
    func: u32,
    table: u32,
    memory: u32,
    global: u32,
};

pub const Export = struct {
    name: []const u8,
    desc: ExportDesc,
};

pub const Element = struct {
    table_index: u32, // MVP: always 0
    offset: []const Instruction,
    init: []const u32, // funcidx sequence
};

pub const LocalGroup = struct {
    count: u32,
    ty: types.ValType,
};

pub const Code = struct {
    locals: []const LocalGroup,
    body: []const Instruction,
};

pub const Data = struct {
    memory_index: u32, // MVP: always 0
    offset: []const Instruction,
    init: []const u8,
};

pub const CustomSection = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const Module = struct {
    types_: []const types.FuncType = &.{},
    imports: []const Import = &.{},
    funcs: []const u32 = &.{}, // typeidx per non-imported function
    tables: []const types.TableType = &.{},
    memories: []const types.MemType = &.{},
    globals: []const Global = &.{},
    exports: []const Export = &.{},
    start: ?u32 = null,
    elements: []const Element = &.{},
    codes: []const Code = &.{},
    datas: []const Data = &.{},
    customs: []const CustomSection = &.{},
};

// ---------------- vec helper ----------------

fn readVec(
    comptime T: type,
    allocator: std.mem.Allocator,
    r: *Reader,
    comptime decodeOne: fn (std.mem.Allocator, *Reader) errors.ParseError!T,
) errors.ParseError![]T {
    const n = try leb128.readULEB128(u32, r);
    const out = try allocator.alloc(T, n);
    errdefer allocator.free(out);
    for (out) |*slot| slot.* = try decodeOne(allocator, r);
    return out;
}

// ---------------- per-section decoders ----------------

fn decodeFuncTypeEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!types.FuncType {
    return types.decodeFuncType(allocator, r);
}

pub fn parseTypeSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]types.FuncType {
    var r = Reader.init(payload);
    const out = try readVec(types.FuncType, allocator, &r, decodeFuncTypeEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeImportDesc(r: *Reader) errors.ParseError!ImportDesc {
    const tag = try r.readByte();
    switch (tag) {
        0x00 => {
            const tidx = try leb128.readULEB128(u32, r);
            return .{ .func = tidx };
        },
        0x01 => return .{ .table = try types.decodeTableType(r) },
        0x02 => return .{ .memory = try types.decodeMemType(r) },
        0x03 => return .{ .global = try types.decodeGlobalType(r) },
        else => return error.MalformedImportDesc,
    }
}

fn decodeImportEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!Import {
    _ = allocator;
    const module_name = try types.decodeName(r);
    const name = try types.decodeName(r);
    const desc = try decodeImportDesc(r);
    return .{ .module = module_name, .name = name, .desc = desc };
}

pub fn parseImportSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]Import {
    var r = Reader.init(payload);
    const out = try readVec(Import, allocator, &r, decodeImportEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeTypeIdx(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!u32 {
    _ = allocator;
    return leb128.readULEB128(u32, r);
}

pub fn parseFunctionSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]u32 {
    var r = Reader.init(payload);
    const out = try readVec(u32, allocator, &r, decodeTypeIdx);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeTableEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!types.TableType {
    _ = allocator;
    return types.decodeTableType(r);
}

pub fn parseTableSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]types.TableType {
    var r = Reader.init(payload);
    const out = try readVec(types.TableType, allocator, &r, decodeTableEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeMemoryEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!types.MemType {
    _ = allocator;
    return types.decodeMemType(r);
}

pub fn parseMemorySection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]types.MemType {
    var r = Reader.init(payload);
    const out = try readVec(types.MemType, allocator, &r, decodeMemoryEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeGlobalEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!Global {
    const ty = try types.decodeGlobalType(r);
    const init = try instruction.decodeExpr(allocator, r);
    return .{ .ty = ty, .init = init };
}

pub fn parseGlobalSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]Global {
    var r = Reader.init(payload);
    const out = try readVec(Global, allocator, &r, decodeGlobalEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeExportDesc(r: *Reader) errors.ParseError!ExportDesc {
    const tag = try r.readByte();
    const idx = try leb128.readULEB128(u32, r);
    return switch (tag) {
        0x00 => .{ .func = idx },
        0x01 => .{ .table = idx },
        0x02 => .{ .memory = idx },
        0x03 => .{ .global = idx },
        else => error.MalformedExportDesc,
    };
}

fn decodeExportEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!Export {
    _ = allocator;
    const name = try types.decodeName(r);
    const desc = try decodeExportDesc(r);
    return .{ .name = name, .desc = desc };
}

pub fn parseExportSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]Export {
    var r = Reader.init(payload);
    const out = try readVec(Export, allocator, &r, decodeExportEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

pub fn parseStartSection(payload: []const u8) errors.ParseError!u32 {
    var r = Reader.init(payload);
    const idx = try leb128.readULEB128(u32, &r);
    if (!r.eof()) return error.SectionSizeMismatch;
    return idx;
}

fn decodeElementEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!Element {
    const prefix = try leb128.readULEB128(u32, r);
    if (prefix != 0) return error.MalformedElementSegment;
    const offset = try instruction.decodeExpr(allocator, r);
    errdefer allocator.free(offset);
    const init = try readVec(u32, allocator, r, decodeTypeIdx);
    return .{ .table_index = 0, .offset = offset, .init = init };
}

pub fn parseElementSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]Element {
    var r = Reader.init(payload);
    const out = try readVec(Element, allocator, &r, decodeElementEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeLocalGroupEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!LocalGroup {
    _ = allocator;
    const count = try leb128.readULEB128(u32, r);
    const ty = try types.decodeValType(r);
    return .{ .count = count, .ty = ty };
}

fn decodeCodeEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!Code {
    const size = try leb128.readULEB128(u32, r);
    const func_bytes = try r.readBytes(size);
    var sub = Reader.init(func_bytes);
    const locals = try readVec(LocalGroup, allocator, &sub, decodeLocalGroupEntry);
    errdefer allocator.free(locals);
    const body = try instruction.decodeExpr(allocator, &sub);
    if (!sub.eof()) return error.SectionSizeMismatch;
    return .{ .locals = locals, .body = body };
}

pub fn parseCodeSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]Code {
    var r = Reader.init(payload);
    const out = try readVec(Code, allocator, &r, decodeCodeEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

fn decodeDataEntry(allocator: std.mem.Allocator, r: *Reader) errors.ParseError!Data {
    const prefix = try leb128.readULEB128(u32, r);
    if (prefix != 0) return error.MalformedDataSegment;
    const offset = try instruction.decodeExpr(allocator, r);
    errdefer allocator.free(offset);
    const n = try leb128.readULEB128(u32, r);
    const bytes = try r.readBytes(n);
    return .{ .memory_index = 0, .offset = offset, .init = bytes };
}

pub fn parseDataSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]Data {
    var r = Reader.init(payload);
    const out = try readVec(Data, allocator, &r, decodeDataEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

pub fn parseCustomSection(payload: []const u8) errors.ParseError!CustomSection {
    var r = Reader.init(payload);
    const name = try types.decodeName(&r);
    const bytes = payload[r.pos..];
    return .{ .name = name, .bytes = bytes };
}

// ---------------- tests ----------------

fn mk(bytes: []const u8) Reader {
    return Reader.init(bytes);
}

test "parseTypeSection empty" {
    const ts = try parseTypeSection(std.testing.allocator, &[_]u8{0x00});
    defer std.testing.allocator.free(ts);
    try std.testing.expectEqual(@as(usize, 0), ts.len);
}

test "parseTypeSection one () -> ()" {
    const ts = try parseTypeSection(std.testing.allocator, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    defer {
        for (ts) |ft| {
            std.testing.allocator.free(ft.params);
            std.testing.allocator.free(ft.results);
        }
        std.testing.allocator.free(ts);
    }
    try std.testing.expectEqual(@as(usize, 1), ts.len);
}

test "parseTypeSection rejects trailing bytes" {
    try std.testing.expectError(
        error.SectionSizeMismatch,
        parseTypeSection(std.testing.allocator, &[_]u8{ 0x00, 0xAA }),
    );
}

test "parseFunctionSection one entry" {
    const fs = try parseFunctionSection(std.testing.allocator, &[_]u8{ 0x01, 0x00 });
    defer std.testing.allocator.free(fs);
    try std.testing.expectEqualSlices(u32, &[_]u32{0}, fs);
}

test "parseMemorySection [min=1]" {
    const ms = try parseMemorySection(std.testing.allocator, &[_]u8{ 0x01, 0x00, 0x01 });
    defer std.testing.allocator.free(ms);
    try std.testing.expectEqual(@as(usize, 1), ms.len);
    try std.testing.expectEqual(@as(u32, 1), ms[0].min);
}

test "parseExportSection one main func" {
    // 1 export: "main" func 0
    // count=01 len=04 "main" desc=0x00 idx=00
    const payload = &[_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x00 };
    const es = try parseExportSection(std.testing.allocator, payload);
    defer std.testing.allocator.free(es);
    try std.testing.expectEqual(@as(usize, 1), es.len);
    try std.testing.expectEqualStrings("main", es[0].name);
    try std.testing.expectEqual(@as(u32, 0), es[0].desc.func);
}

test "parseStartSection" {
    const idx = try parseStartSection(&[_]u8{0x05});
    try std.testing.expectEqual(@as(u32, 5), idx);
}

test "parseStartSection rejects trailing bytes" {
    try std.testing.expectError(error.SectionSizeMismatch, parseStartSection(&[_]u8{ 0x05, 0x00 }));
}

test "parseCodeSection one trivial fn" {
    // count=01
    //   size=0x04  body={ locals=[], expr=i32.const 0; end }
    // locals: vec(0)=00  expr: 0x41 0x00 0x0B  → func length = 4
    const payload = &[_]u8{ 0x01, 0x04, 0x00, 0x41, 0x00, 0x0B };
    const cs = try parseCodeSection(std.testing.allocator, payload);
    defer {
        for (cs) |c| {
            std.testing.allocator.free(c.locals);
            std.testing.allocator.free(c.body);
        }
        std.testing.allocator.free(cs);
    }
    try std.testing.expectEqual(@as(usize, 1), cs.len);
    try std.testing.expectEqual(@as(usize, 0), cs[0].locals.len);
    try std.testing.expectEqual(@as(usize, 1), cs[0].body.len);
    try std.testing.expectEqual(@as(i32, 0), cs[0].body[0].i32_const);
}

test "parseCodeSection rejects body length mismatch (trailing bytes inside func)" {
    // count=1 size=5 body={locals=00 expr=41 00 0B + stray 0xAA}
    // Parser consumes 4 bytes but declared size is 5 → SectionSizeMismatch.
    // Uses an arena so the partial allocations made before the error are
    // cleaned up by deinit rather than requiring deep errdefer in the parser.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload = &[_]u8{ 0x01, 0x05, 0x00, 0x41, 0x00, 0x0B, 0xAA };
    try std.testing.expectError(
        error.SectionSizeMismatch,
        parseCodeSection(arena.allocator(), payload),
    );
}

test "parseDataSection offset + bytes" {
    // 1 data: offset=(i32.const 1024), bytes="ok"
    // flags=00  expr=41 80 08 0B   init=vec(2, 'o','k')
    const payload = &[_]u8{ 0x01, 0x00, 0x41, 0x80, 0x08, 0x0B, 0x02, 'o', 'k' };
    const ds = try parseDataSection(std.testing.allocator, payload);
    defer {
        for (ds) |d| std.testing.allocator.free(d.offset);
        std.testing.allocator.free(ds);
    }
    try std.testing.expectEqual(@as(usize, 1), ds.len);
    try std.testing.expectEqualStrings("ok", ds[0].init);
    try std.testing.expectEqual(@as(i32, 1024), ds[0].offset[0].i32_const);
}

test "parseCustomSection keeps name + payload" {
    // name len=4 "name", rest=AA BB
    const payload = &[_]u8{ 0x04, 'n', 'a', 'm', 'e', 0xAA, 0xBB };
    const c = try parseCustomSection(payload);
    try std.testing.expectEqualStrings("name", c.name);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, c.bytes);
}

test "parseGlobalSection single i32 global" {
    // count=01 type=(i32, mutable) expr=i32.const 42 end
    // 01 7F 01 41 2A 0B
    const payload = &[_]u8{ 0x01, 0x7F, 0x01, 0x41, 0x2A, 0x0B };
    const gs = try parseGlobalSection(std.testing.allocator, payload);
    defer {
        for (gs) |g| std.testing.allocator.free(g.init);
        std.testing.allocator.free(gs);
    }
    try std.testing.expectEqual(@as(usize, 1), gs.len);
    try std.testing.expectEqual(types.ValType.i32, gs[0].ty.valtype);
    try std.testing.expectEqual(types.Mutability.mutable, gs[0].ty.mut);
    try std.testing.expectEqual(@as(i32, 42), gs[0].init[0].i32_const);
}

test "parseImportSection one func import" {
    // count=01 mod="env" name="foo" desc=0x00 typeidx=0
    const payload = &[_]u8{
        0x01, // count
        0x03, 'e', 'n', 'v',
        0x03, 'f', 'o', 'o',
        0x00, 0x00,
    };
    const is = try parseImportSection(std.testing.allocator, payload);
    defer std.testing.allocator.free(is);
    try std.testing.expectEqual(@as(usize, 1), is.len);
    try std.testing.expectEqualStrings("env", is[0].module);
    try std.testing.expectEqualStrings("foo", is[0].name);
    try std.testing.expectEqual(@as(u32, 0), is[0].desc.func);
}

test "parseElementSection single segment" {
    // count=01  flags=00  offset=i32.const 0; end  init=vec(2)=[1, 2]
    const payload = &[_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0B, 0x02, 0x01, 0x02 };
    const es = try parseElementSection(std.testing.allocator, payload);
    defer {
        for (es) |e| {
            std.testing.allocator.free(e.offset);
            std.testing.allocator.free(e.init);
        }
        std.testing.allocator.free(es);
    }
    try std.testing.expectEqual(@as(usize, 1), es.len);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2 }, es[0].init);
}
