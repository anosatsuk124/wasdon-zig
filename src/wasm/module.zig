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

/// Data segment, post-MVP `bulk-memory`-aware.
///
/// Mode 0x00 / 0x02 produce `.active` (with the offset expression and
/// memidx); the translator expects `memory_index == 0` (single-memory
/// assumption — see `docs/spec_linear_memory.md`) and the parser rejects
/// other values with `MultiMemoryNotYetSupported` rather than letting them
/// flow through.
///
/// Mode 0x01 produces `.passive`: just the init bytes, no offset, no
/// memidx. Passive segments are not applied at instantiation; `memory.init`
/// later copies their bytes into linear memory and `data.drop` marks them
/// as discarded. See `docs/spec_linear_memory.md` "Passive data segments".
pub const Data = struct {
    mode: union(enum) {
        active: struct {
            memory_index: u32,
            offset: []const Instruction,
        },
        passive,
    },
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
    /// Populated when the post-MVP `datacount` section is present (binary
    /// id 12, `bulk-memory` proposal). The value is the declared count of
    /// data segments. Validation that this matches `datas.len` and is
    /// compatible with `memory.init` / `data.drop` indices is deferred to
    /// the translator (Phase 3).
    data_count: ?u32 = null,
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
    // Per `docs/w3c_wasm_binary_format_note.md` §"Data segment modes
    // (post-MVP, bulk-memory)" the leading byte tags one of three modes:
    //   0x00 — active segment, implicit memidx=0
    //   0x01 — passive segment (no memidx, no offset)
    //   0x02 — active segment with explicit memidx (uleb128)
    const mode = try leb128.readULEB128(u32, r);
    switch (mode) {
        0x00 => {
            const offset = try instruction.decodeExpr(allocator, r);
            errdefer allocator.free(offset);
            const n = try leb128.readULEB128(u32, r);
            const bytes = try r.readBytes(n);
            return .{
                .mode = .{ .active = .{ .memory_index = 0, .offset = offset } },
                .init = bytes,
            };
        },
        0x01 => {
            const n = try leb128.readULEB128(u32, r);
            const bytes = try r.readBytes(n);
            return .{ .mode = .passive, .init = bytes };
        },
        0x02 => {
            const memidx = try leb128.readULEB128(u32, r);
            // Single-memory assumption — see `docs/spec_linear_memory.md`.
            if (memidx != 0) return error.MultiMemoryNotYetSupported;
            const offset = try instruction.decodeExpr(allocator, r);
            errdefer allocator.free(offset);
            const n = try leb128.readULEB128(u32, r);
            const bytes = try r.readBytes(n);
            return .{
                .mode = .{ .active = .{ .memory_index = memidx, .offset = offset } },
                .init = bytes,
            };
        },
        else => return error.MalformedDataSegment,
    }
}

pub fn parseDataSection(allocator: std.mem.Allocator, payload: []const u8) errors.ParseError![]Data {
    var r = Reader.init(payload);
    const out = try readVec(Data, allocator, &r, decodeDataEntry);
    if (!r.eof()) return error.SectionSizeMismatch;
    return out;
}

/// Decode the post-MVP `datacount` section payload — a single uleb128
/// `u32` declaring how many data segments the immediately following Data
/// section will carry. See `docs/w3c_wasm_binary_format_note.md`
/// §"Section IDs" + §"DataCount ordering exception".
pub fn parseDataCountSection(payload: []const u8) errors.ParseError!u32 {
    var r = Reader.init(payload);
    const count = try leb128.readULEB128(u32, &r);
    if (!r.eof()) return error.SectionSizeMismatch;
    return count;
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

test "parseDataSection offset + bytes (mode 0x00, MVP active)" {
    // 1 data: offset=(i32.const 1024), bytes="ok"
    // flags=00  expr=41 80 08 0B   init=vec(2, 'o','k')
    const payload = &[_]u8{ 0x01, 0x00, 0x41, 0x80, 0x08, 0x0B, 0x02, 'o', 'k' };
    const ds = try parseDataSection(std.testing.allocator, payload);
    defer {
        for (ds) |d| switch (d.mode) {
            .active => |a| std.testing.allocator.free(a.offset),
            .passive => {},
        };
        std.testing.allocator.free(ds);
    }
    try std.testing.expectEqual(@as(usize, 1), ds.len);
    try std.testing.expectEqualStrings("ok", ds[0].init);
    switch (ds[0].mode) {
        .active => |a| {
            try std.testing.expectEqual(@as(u32, 0), a.memory_index);
            try std.testing.expectEqual(@as(i32, 1024), a.offset[0].i32_const);
        },
        .passive => return error.TestExpectedEqual,
    }
}

test "parseDataSection passive segment (mode 0x01, post-MVP bulk-memory)" {
    // 1 data: passive (no offset), bytes="ABC"
    // flags=01 init=vec(3, 'A','B','C')
    const payload = &[_]u8{ 0x01, 0x01, 0x03, 'A', 'B', 'C' };
    const ds = try parseDataSection(std.testing.allocator, payload);
    defer std.testing.allocator.free(ds);
    try std.testing.expectEqual(@as(usize, 1), ds.len);
    try std.testing.expectEqualStrings("ABC", ds[0].init);
    try std.testing.expect(ds[0].mode == .passive);
}

test "parseDataSection active with explicit memidx=0 (mode 0x02)" {
    // 1 data: mode=02 memidx=0 offset=(i32.const 8) init=vec(1,'X')
    const payload = &[_]u8{ 0x01, 0x02, 0x00, 0x41, 0x08, 0x0B, 0x01, 'X' };
    const ds = try parseDataSection(std.testing.allocator, payload);
    defer {
        for (ds) |d| switch (d.mode) {
            .active => |a| std.testing.allocator.free(a.offset),
            .passive => {},
        };
        std.testing.allocator.free(ds);
    }
    try std.testing.expectEqual(@as(usize, 1), ds.len);
    try std.testing.expectEqualStrings("X", ds[0].init);
    switch (ds[0].mode) {
        .active => |a| {
            try std.testing.expectEqual(@as(u32, 0), a.memory_index);
            try std.testing.expectEqual(@as(i32, 8), a.offset[0].i32_const);
        },
        .passive => return error.TestExpectedEqual,
    }
}

test "parseDataSection rejects mode 0x02 with non-zero memidx" {
    // mode=02 memidx=1 offset=(i32.const 0) init=vec(0)
    const payload = &[_]u8{ 0x01, 0x02, 0x01, 0x41, 0x00, 0x0B, 0x00 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.MultiMemoryNotYetSupported,
        parseDataSection(arena.allocator(), payload),
    );
}

test "parseDataSection rejects unknown mode prefix" {
    // mode=05 — undefined
    const payload = &[_]u8{ 0x01, 0x05, 0x00 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.MalformedDataSegment,
        parseDataSection(arena.allocator(), payload),
    );
}

test "parseDataCountSection one entry" {
    // payload = 03 → count=3
    const c = try parseDataCountSection(&[_]u8{0x03});
    try std.testing.expectEqual(@as(u32, 3), c);
}

test "parseDataCountSection rejects trailing bytes" {
    try std.testing.expectError(
        error.SectionSizeMismatch,
        parseDataCountSection(&[_]u8{ 0x03, 0x00 }),
    );
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

test "parseImportSection accepts mutable global import" {
    // Post-MVP "mutable-globals" proposal: an imported global with `mut = 0x01`
    // must round-trip through the parser unmodified. The translator already
    // emits every global as a mutable Udon field (Udon has no const concept
    // for fields), so allowing the bit through here is the only piece of
    // parser-side support the feature needs. See `docs/spec_variable_conversion.md`
    // ("Mutability") and `docs/producer_guide.md` §1.
    //
    // count=01 mod="env" name="g" desc=0x03 valtype=i32 mut=0x01
    const payload = &[_]u8{ 0x01, 0x03, 'e', 'n', 'v', 0x01, 'g', 0x03, 0x7F, 0x01 };
    const is = try parseImportSection(std.testing.allocator, payload);
    defer std.testing.allocator.free(is);
    try std.testing.expectEqual(@as(usize, 1), is.len);
    try std.testing.expectEqualStrings("env", is[0].module);
    try std.testing.expectEqualStrings("g", is[0].name);
    switch (is[0].desc) {
        .global => |gt| {
            try std.testing.expectEqual(types.ValType.i32, gt.valtype);
            try std.testing.expectEqual(types.Mutability.mutable, gt.mut);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parseImportSection one func import" {
    // count=01 mod="env" name="foo" desc=0x00 typeidx=0
    const payload = &[_]u8{
        0x01, // count
        0x03,
        'e',
        'n',
        'v',
        0x03,
        'f',
        'o',
        'o',
        0x00,
        0x00,
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
