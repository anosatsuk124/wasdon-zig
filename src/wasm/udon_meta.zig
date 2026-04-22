//! `__udon_meta` JSON discovery and decoding.
//!
//! Surface: `parse` decodes a raw JSON payload; `findMetaBytes` locates the
//! payload inside a Module via the `__udon_meta_ptr` / `__udon_meta_len`
//! export convention documented in `docs/spec_udonmeta_conversion.md`;
//! `parseFromModule` glues them together.
//!
//! All allocations live in the caller-supplied allocator — use an arena so
//! `deinit()` frees everything, including the underlying std.json.Value tree.

const std = @import("std");
const errors = @import("errors.zig");
const module_mod = @import("module.zig");
const const_eval = @import("const_eval.zig");

pub const Module = module_mod.Module;

pub const SyncMode = enum { none, manual, continuous };
pub const FieldSyncMode = enum { none, linear, smooth };
/// `export` is a Zig keyword so the enum field is escaped; `stringToEnum`
/// matches on the unescaped name "export".
pub const SourceKind = enum { global, symbol, name, @"export" };
pub const FieldType = enum { bool_, int, uint, float, string, object };
pub const EventKind = enum { Start, Update, Interact, custom };
pub const UnknownPolicy = enum { ignore, warn, error_ };
pub const RecursionMode = enum { disabled, stack };

pub const Source = struct {
    kind: SourceKind,
    name: ?[]const u8 = null,
};

pub const FieldSync = struct {
    enabled: bool = false,
    mode: ?FieldSyncMode = null,
};

pub const Field = struct {
    key: []const u8,
    source: Source,
    udon_name: ?[]const u8 = null,
    type: ?FieldType = null,
    is_export: bool = false,
    sync: FieldSync = .{},
    default: ?std.json.Value = null,
    comment: ?[]const u8 = null,
};

pub const Function = struct {
    key: []const u8,
    source: Source,
    label: ?[]const u8 = null,
    is_export: bool = false,
    event: ?EventKind = null,
    comment: ?[]const u8 = null,
};

pub const Behaviour = struct {
    sync_mode: ?SyncMode = null,
    comment: ?[]const u8 = null,
};

pub const MemoryOptions = struct {
    initial_pages: ?u32 = null,
    max_pages: ?u32 = null,
    udon_name: ?[]const u8 = null,
};

pub const Options = struct {
    strict: bool = false,
    unknown_field_policy: ?UnknownPolicy = null,
    unknown_function_policy: ?UnknownPolicy = null,
    memory: MemoryOptions = .{},
    recursion: RecursionMode = .disabled,
};

pub const UdonMeta = struct {
    version: u32,
    behaviour: ?Behaviour = null,
    fields: []const Field = &.{},
    functions: []const Function = &.{},
    options: Options = .{},
    /// Keeps the backing std.json.Value alive for the duration of the meta
    /// (Field.default, Field.comment etc. may alias strings inside it).
    _json_root: std.json.Value = .null,
};

// ---------------- JSON helpers ----------------

fn getU32FromValue(v: std.json.Value) errors.ParseError!u32 {
    return switch (v) {
        .integer => |i| {
            if (i < 0 or i > std.math.maxInt(u32)) return error.MalformedMeta;
            return @intCast(i);
        },
        else => error.MalformedMeta,
    };
}

fn getBoolFromValue(v: std.json.Value) errors.ParseError!bool {
    return switch (v) {
        .bool => |b| b,
        else => error.MalformedMeta,
    };
}

fn getStringFromValue(v: std.json.Value) errors.ParseError![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.MalformedMeta,
    };
}

fn getObjectFromValue(v: std.json.Value) errors.ParseError!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.MalformedMeta,
    };
}

fn getOptionalField(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return obj.get(key);
}

fn enumFromStringOrError(comptime E: type, s: []const u8, comptime err: errors.ParseError) errors.ParseError!E {
    return std.meta.stringToEnum(E, s) orelse return err;
}

// The field enum uses `bool_` / `error_` because those words are Zig keywords.
// JSON emits the real names; translate manually.
fn parseFieldType(s: []const u8) errors.ParseError!FieldType {
    if (std.mem.eql(u8, s, "bool")) return .bool_;
    if (std.mem.eql(u8, s, "int")) return .int;
    if (std.mem.eql(u8, s, "uint")) return .uint;
    if (std.mem.eql(u8, s, "float")) return .float;
    if (std.mem.eql(u8, s, "string")) return .string;
    if (std.mem.eql(u8, s, "object")) return .object;
    return error.InvalidFieldType;
}

fn parseUnknownPolicy(s: []const u8) errors.ParseError!UnknownPolicy {
    if (std.mem.eql(u8, s, "ignore")) return .ignore;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error")) return .error_;
    return error.InvalidUnknownPolicy;
}

fn parseRecursionMode(s: []const u8) errors.ParseError!RecursionMode {
    if (std.mem.eql(u8, s, "disabled")) return .disabled;
    if (std.mem.eql(u8, s, "stack")) return .stack;
    return error.MalformedMeta;
}

fn parseSource(obj: std.json.ObjectMap) errors.ParseError!Source {
    const kind_v = obj.get("kind") orelse return error.MalformedMeta;
    const kind_s = try getStringFromValue(kind_v);
    const kind = try enumFromStringOrError(SourceKind, kind_s, error.InvalidSourceKind);
    var src: Source = .{ .kind = kind };
    if (obj.get("name")) |nv| src.name = try getStringFromValue(nv);
    return src;
}

fn parseSync(obj: std.json.ObjectMap) errors.ParseError!FieldSync {
    var s: FieldSync = .{};
    if (obj.get("enabled")) |e| s.enabled = try getBoolFromValue(e);
    if (obj.get("mode")) |m| {
        const ms = try getStringFromValue(m);
        if (std.mem.eql(u8, ms, "none")) {
            s.mode = .none;
        } else if (std.mem.eql(u8, ms, "linear")) {
            s.mode = .linear;
        } else if (std.mem.eql(u8, ms, "smooth")) {
            s.mode = .smooth;
        } else {
            return error.InvalidFieldSyncMode;
        }
    }
    if (s.enabled and s.mode == null) return error.MissingSyncMode;
    return s;
}

fn parseField(allocator: std.mem.Allocator, key: []const u8, v: std.json.Value) errors.ParseError!Field {
    _ = allocator;
    const obj = try getObjectFromValue(v);
    const source_v = obj.get("source") orelse return error.MalformedMeta;
    const source_obj = try getObjectFromValue(source_v);
    const source = try parseSource(source_obj);

    var f: Field = .{ .key = key, .source = source };
    if (obj.get("udonName")) |uv| f.udon_name = try getStringFromValue(uv);
    if (obj.get("type")) |tv| {
        const ts = try getStringFromValue(tv);
        f.type = try parseFieldType(ts);
    }
    if (obj.get("export")) |ev| f.is_export = try getBoolFromValue(ev);
    if (obj.get("sync")) |sv| {
        const sobj = try getObjectFromValue(sv);
        f.sync = try parseSync(sobj);
    }
    if (obj.get("default")) |dv| f.default = dv;
    if (obj.get("comment")) |cv| f.comment = try getStringFromValue(cv);
    return f;
}

fn parseFunction(allocator: std.mem.Allocator, key: []const u8, v: std.json.Value) errors.ParseError!Function {
    _ = allocator;
    const obj = try getObjectFromValue(v);
    const source_v = obj.get("source") orelse return error.MalformedMeta;
    const source_obj = try getObjectFromValue(source_v);
    const source = try parseSource(source_obj);

    var fn_: Function = .{ .key = key, .source = source };
    if (obj.get("label")) |lv| fn_.label = try getStringFromValue(lv);
    if (obj.get("export")) |ev| fn_.is_export = try getBoolFromValue(ev);
    if (obj.get("event")) |ev| {
        const es = try getStringFromValue(ev);
        fn_.event = try enumFromStringOrError(EventKind, es, error.InvalidEventKind);
    }
    if (obj.get("comment")) |cv| fn_.comment = try getStringFromValue(cv);
    return fn_;
}

fn parseBehaviour(obj: std.json.ObjectMap) errors.ParseError!Behaviour {
    var b: Behaviour = .{};
    if (obj.get("syncMode")) |sv| {
        const ss = try getStringFromValue(sv);
        b.sync_mode = try enumFromStringOrError(SyncMode, ss, error.InvalidBehaviourSyncMode);
    }
    if (obj.get("comment")) |cv| b.comment = try getStringFromValue(cv);
    return b;
}

fn parseMemoryOptions(obj: std.json.ObjectMap) errors.ParseError!MemoryOptions {
    var m: MemoryOptions = .{};
    if (obj.get("initialPages")) |iv| m.initial_pages = try getU32FromValue(iv);
    if (obj.get("maxPages")) |mv| m.max_pages = try getU32FromValue(mv);
    if (obj.get("udonName")) |uv| m.udon_name = try getStringFromValue(uv);
    if (m.initial_pages) |ip| if (m.max_pages) |mp| if (ip > mp) return error.InvalidMemoryPageBounds;
    return m;
}

fn parseOptions(obj: std.json.ObjectMap) errors.ParseError!Options {
    var o: Options = .{};
    if (obj.get("strict")) |sv| o.strict = try getBoolFromValue(sv);
    if (obj.get("unknownFieldPolicy")) |pv| {
        const ps = try getStringFromValue(pv);
        o.unknown_field_policy = try parseUnknownPolicy(ps);
    }
    if (obj.get("unknownFunctionPolicy")) |pv| {
        const ps = try getStringFromValue(pv);
        o.unknown_function_policy = try parseUnknownPolicy(ps);
    }
    if (obj.get("memory")) |mv| {
        const mobj = try getObjectFromValue(mv);
        o.memory = try parseMemoryOptions(mobj);
    }
    if (obj.get("recursion")) |rv| {
        const rs = try getStringFromValue(rv);
        o.recursion = try parseRecursionMode(rs);
    }
    return o;
}

pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) errors.ParseError!UdonMeta {
    if (!std.unicode.utf8ValidateSlice(json_bytes)) return error.InvalidUtf8MetaPayload;

    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        json_bytes,
        .{},
    ) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedMeta,
    };

    const obj = try getObjectFromValue(root);
    const version_v = obj.get("version") orelse return error.MalformedMeta;
    const version = try getU32FromValue(version_v);
    if (version != 1) return error.UnsupportedUdonMetaVersion;

    var meta: UdonMeta = .{ .version = version, ._json_root = root };

    if (obj.get("behaviour")) |bv| {
        const bobj = try getObjectFromValue(bv);
        meta.behaviour = try parseBehaviour(bobj);
    }

    if (obj.get("fields")) |fv| {
        const fobj = try getObjectFromValue(fv);
        var list = try allocator.alloc(Field, fobj.count());
        var i: usize = 0;
        var it = fobj.iterator();
        while (it.next()) |entry| : (i += 1) {
            list[i] = try parseField(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        meta.fields = list;
    }

    if (obj.get("functions")) |fv| {
        const fobj = try getObjectFromValue(fv);
        var list = try allocator.alloc(Function, fobj.count());
        var i: usize = 0;
        var it = fobj.iterator();
        while (it.next()) |entry| : (i += 1) {
            list[i] = try parseFunction(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        meta.functions = list;
    }

    if (obj.get("options")) |ov| {
        const oobj = try getObjectFromValue(ov);
        meta.options = try parseOptions(oobj);
    }

    return meta;
}

// ---------------- module-side discovery ----------------

pub fn findMetaBytes(mod: Module) errors.ParseError!?[]const u8 {
    const ptr_opt = try const_eval.evalExportedI32(mod, "__udon_meta_ptr");
    const len_opt = try const_eval.evalExportedI32(mod, "__udon_meta_len");
    if (ptr_opt == null or len_opt == null) return null;
    const ptr = ptr_opt.?;
    const len = len_opt.?;
    if (ptr < 0 or len < 0) return error.NonConstMetaLocator;

    const uptr: u32 = @intCast(ptr);
    const ulen: u32 = @intCast(len);
    return try resolveDataRange(mod, uptr, ulen);
}

fn resolveDataRange(mod: Module, ptr: u32, len: u32) errors.ParseError![]const u8 {
    var saw_partial = false;
    for (mod.datas) |d| {
        const off_i32 = try const_eval.evalConstI32(mod, d.offset);
        if (off_i32 < 0) continue;
        const off: u32 = @intCast(off_i32);
        const seg_end = off +% @as(u32, @intCast(d.init.len));
        // Fully inside this segment?
        if (ptr >= off and ptr + len >= ptr and ptr + len <= seg_end) {
            return d.init[ptr - off .. ptr - off + len];
        }
        // Partial overlap detection.
        const req_end = ptr + len;
        const overlaps = ptr < seg_end and req_end > off;
        if (overlaps) saw_partial = true;
    }
    if (saw_partial) return error.MetaSpansMultipleSegments;
    return error.MetaRangeOutOfData;
}

pub fn parseFromModule(allocator: std.mem.Allocator, mod: Module) errors.ParseError!?UdonMeta {
    const bytes_opt = try findMetaBytes(mod);
    if (bytes_opt == null) return null;
    return try parse(allocator, bytes_opt.?);
}

// ---------------- tests ----------------

const minimal_json =
    \\{
    \\  "version": 1,
    \\  "fields": {
    \\    "playerName": {
    \\      "source": { "kind": "global", "name": "player_name" },
    \\      "udonName": "_playerName",
    \\      "type": "string",
    \\      "export": true,
    \\      "sync": { "enabled": true, "mode": "none" }
    \\    }
    \\  },
    \\  "functions": {
    \\    "start": {
    \\      "source": { "kind": "export", "name": "on_start" },
    \\      "label": "_start",
    \\      "export": true,
    \\      "event": "Start"
    \\    }
    \\  }
    \\}
;

test "parse minimal example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), minimal_json);
    try std.testing.expectEqual(@as(u32, 1), m.version);
    try std.testing.expectEqual(@as(usize, 1), m.fields.len);
    try std.testing.expectEqualStrings("playerName", m.fields[0].key);
    try std.testing.expectEqual(SourceKind.global, m.fields[0].source.kind);
    try std.testing.expectEqualStrings("player_name", m.fields[0].source.name.?);
    try std.testing.expectEqualStrings("_playerName", m.fields[0].udon_name.?);
    try std.testing.expect(m.fields[0].is_export);
    try std.testing.expect(m.fields[0].sync.enabled);
    try std.testing.expectEqual(FieldSyncMode.none, m.fields[0].sync.mode.?);

    try std.testing.expectEqual(@as(usize, 1), m.functions.len);
    try std.testing.expectEqualStrings("_start", m.functions[0].label.?);
    try std.testing.expectEqual(EventKind.Start, m.functions[0].event.?);
}

const complete_json =
    \\{
    \\  "version": 1,
    \\  "behaviour": { "syncMode": "manual", "comment": "hi" },
    \\  "fields": {
    \\    "counter": {
    \\      "source": { "kind": "global", "name": "counter" },
    \\      "type": "int"
    \\    }
    \\  },
    \\  "functions": {
    \\    "update": {
    \\      "source": { "kind": "export", "name": "on_update" },
    \\      "label": "_update",
    \\      "event": "Update"
    \\    }
    \\  },
    \\  "options": {
    \\    "strict": false,
    \\    "unknownFieldPolicy": "warn",
    \\    "memory": { "initialPages": 1, "maxPages": 16, "udonName": "_memory" }
    \\  }
    \\}
;

test "parse complete example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), complete_json);
    try std.testing.expectEqual(SyncMode.manual, m.behaviour.?.sync_mode.?);
    try std.testing.expectEqualStrings("hi", m.behaviour.?.comment.?);
    try std.testing.expectEqual(UnknownPolicy.warn, m.options.unknown_field_policy.?);
    try std.testing.expectEqual(@as(u32, 1), m.options.memory.initial_pages.?);
    try std.testing.expectEqual(@as(u32, 16), m.options.memory.max_pages.?);
    try std.testing.expectEqualStrings("_memory", m.options.memory.udon_name.?);
}

test "parse rejects unsupported version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnsupportedUdonMetaVersion,
        parse(arena.allocator(), "{\"version\": 2}"),
    );
}

test "parse rejects sync.enabled without mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j =
        \\{
        \\  "version": 1,
        \\  "fields": {
        \\    "f": {
        \\      "source": { "kind": "global", "name": "f" },
        \\      "sync": { "enabled": true }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.MissingSyncMode, parse(arena.allocator(), j));
}

test "parse rejects unknown sync mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j =
        \\{
        \\  "version": 1,
        \\  "fields": {
        \\    "f": {
        \\      "source": { "kind": "global", "name": "f" },
        \\      "sync": { "enabled": true, "mode": "bouncy" }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.InvalidFieldSyncMode, parse(arena.allocator(), j));
}

test "parse rejects initialPages > maxPages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j =
        \\{
        \\  "version": 1,
        \\  "options": { "memory": { "initialPages": 10, "maxPages": 2 } }
        \\}
    ;
    try std.testing.expectError(error.InvalidMemoryPageBounds, parse(arena.allocator(), j));
}

test "parse options.recursion=stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = "{\"version\":1,\"options\":{\"recursion\":\"stack\"}}";
    const m = try parse(arena.allocator(), j);
    try std.testing.expectEqual(RecursionMode.stack, m.options.recursion);
}

test "parse options.recursion default is disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = "{\"version\":1,\"options\":{}}";
    const m = try parse(arena.allocator(), j);
    try std.testing.expectEqual(RecursionMode.disabled, m.options.recursion);
}

test "parse options.recursion invalid string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = "{\"version\":1,\"options\":{\"recursion\":\"nope\"}}";
    try std.testing.expectError(error.MalformedMeta, parse(arena.allocator(), j));
}

test "parse rejects invalid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad: []const u8 = &[_]u8{ '{', 0xC3, '}' };
    try std.testing.expectError(error.InvalidUtf8MetaPayload, parse(arena.allocator(), bad));
}

// ---- module-side discovery tests ----

fn makeBenchLikeModule(allocator: std.mem.Allocator, json: []const u8) !Module {
    const Instruction = @import("instruction.zig").Instruction;
    const instrs_ptr = try allocator.alloc(Instruction, 1);
    instrs_ptr[0] = .{ .i32_const = 1024 };
    const instrs_len = try allocator.alloc(Instruction, 1);
    instrs_len[0] = .{ .i32_const = @intCast(json.len) };

    const codes = try allocator.alloc(module_mod.Code, 2);
    codes[0] = .{ .locals = &.{}, .body = instrs_ptr };
    codes[1] = .{ .locals = &.{}, .body = instrs_len };

    const exports = try allocator.alloc(module_mod.Export, 2);
    exports[0] = .{ .name = "__udon_meta_ptr", .desc = .{ .func = 0 } };
    exports[1] = .{ .name = "__udon_meta_len", .desc = .{ .func = 1 } };

    const offset_expr = try allocator.alloc(Instruction, 1);
    offset_expr[0] = .{ .i32_const = 1024 };
    const datas = try allocator.alloc(module_mod.Data, 1);
    datas[0] = .{ .memory_index = 0, .offset = offset_expr, .init = json };

    return .{ .exports = exports, .codes = codes, .datas = datas };
}

test "findMetaBytes locates payload via func exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mod = try makeBenchLikeModule(arena.allocator(), minimal_json);
    const bytes = try findMetaBytes(mod);
    try std.testing.expect(bytes != null);
    try std.testing.expectEqualStrings(minimal_json, bytes.?);
}

test "findMetaBytes locates payload via global exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Instruction = @import("instruction.zig").Instruction;

    const init0 = try alloc.alloc(Instruction, 1);
    init0[0] = .{ .i32_const = 2048 };
    const init1 = try alloc.alloc(Instruction, 1);
    init1[0] = .{ .i32_const = @intCast(minimal_json.len) };

    const globals = try alloc.alloc(module_mod.Global, 2);
    globals[0] = .{ .ty = .{ .valtype = .i32, .mut = .immutable }, .init = init0 };
    globals[1] = .{ .ty = .{ .valtype = .i32, .mut = .immutable }, .init = init1 };

    const exports = try alloc.alloc(module_mod.Export, 2);
    exports[0] = .{ .name = "__udon_meta_ptr", .desc = .{ .global = 0 } };
    exports[1] = .{ .name = "__udon_meta_len", .desc = .{ .global = 1 } };

    const offset_expr = try alloc.alloc(Instruction, 1);
    offset_expr[0] = .{ .i32_const = 2048 };
    const datas = try alloc.alloc(module_mod.Data, 1);
    datas[0] = .{ .memory_index = 0, .offset = offset_expr, .init = minimal_json };

    const mod: Module = .{ .globals = globals, .exports = exports, .datas = datas };
    const bytes = try findMetaBytes(mod);
    try std.testing.expect(bytes != null);
    try std.testing.expectEqualStrings(minimal_json, bytes.?);
}

test "findMetaBytes returns null when exports are absent" {
    const mod: Module = .{};
    try std.testing.expect(try findMetaBytes(mod) == null);
}

test "findMetaBytes returns null if only one of ptr/len is present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Instruction = @import("instruction.zig").Instruction;
    const init0 = try arena.allocator().alloc(Instruction, 1);
    init0[0] = .{ .i32_const = 0 };
    const globals = try arena.allocator().alloc(module_mod.Global, 1);
    globals[0] = .{ .ty = .{ .valtype = .i32, .mut = .immutable }, .init = init0 };
    const exports = try arena.allocator().alloc(module_mod.Export, 1);
    exports[0] = .{ .name = "__udon_meta_ptr", .desc = .{ .global = 0 } };

    const mod: Module = .{ .globals = globals, .exports = exports };
    try std.testing.expect(try findMetaBytes(mod) == null);
}

test "findMetaBytes rejects range outside any data segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Instruction = @import("instruction.zig").Instruction;
    const alloc = arena.allocator();

    const init_ptr = try alloc.alloc(Instruction, 1);
    init_ptr[0] = .{ .i32_const = 5000 };
    const init_len = try alloc.alloc(Instruction, 1);
    init_len[0] = .{ .i32_const = 10 };
    const globals = try alloc.alloc(module_mod.Global, 2);
    globals[0] = .{ .ty = .{ .valtype = .i32, .mut = .immutable }, .init = init_ptr };
    globals[1] = .{ .ty = .{ .valtype = .i32, .mut = .immutable }, .init = init_len };
    const exports = try alloc.alloc(module_mod.Export, 2);
    exports[0] = .{ .name = "__udon_meta_ptr", .desc = .{ .global = 0 } };
    exports[1] = .{ .name = "__udon_meta_len", .desc = .{ .global = 1 } };

    // Single data segment at offset 0 with 16 bytes — doesn't cover 5000..5010.
    const offset_expr = try alloc.alloc(Instruction, 1);
    offset_expr[0] = .{ .i32_const = 0 };
    const seg = try alloc.alloc(u8, 16);
    @memset(seg, 0);
    const datas = try alloc.alloc(module_mod.Data, 1);
    datas[0] = .{ .memory_index = 0, .offset = offset_expr, .init = seg };

    const mod: Module = .{ .globals = globals, .exports = exports, .datas = datas };
    try std.testing.expectError(error.MetaRangeOutOfData, findMetaBytes(mod));
}

test "parseFromModule end-to-end with func exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mod = try makeBenchLikeModule(arena.allocator(), minimal_json);
    const meta_opt = try parseFromModule(arena.allocator(), mod);
    try std.testing.expect(meta_opt != null);
    const meta = meta_opt.?;
    try std.testing.expectEqual(@as(u32, 1), meta.version);
    try std.testing.expectEqualStrings("playerName", meta.fields[0].key);
}

test "parseFromModule returns null when meta is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mod: Module = .{};
    const meta_opt = try parseFromModule(arena.allocator(), mod);
    try std.testing.expect(meta_opt == null);
}
