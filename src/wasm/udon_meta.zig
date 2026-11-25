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
pub const SourceKind = enum { global, symbol, name, @"export", import };
/// Resolve a `__udon_meta.fields[*].type` value to an Udon type name. The
/// short aliases cover the common cases; anything else is taken to already
/// be an Udon type name (`UnityEngineTexture2D`, `SystemByteArray`, …) and is
/// validated against the node list by the translator.
pub fn udonTypeName(s: []const u8) []const u8 {
    const aliases = [_]struct { []const u8, []const u8 }{
        .{ "bool", "SystemBoolean" },
        .{ "int", "SystemInt32" },
        .{ "uint", "SystemUInt32" },
        .{ "float", "SystemSingle" },
        .{ "string", "SystemString" },
        .{ "object", "SystemObject" },
        .{ "gameobject", "UnityEngineGameObject" },
        .{ "transform", "UnityEngineTransform" },
        .{ "udonBehaviour", "VRCUdonCommonInterfacesIUdonEventReceiver" },
        .{ "udon_behaviour", "VRCUdonCommonInterfacesIUdonEventReceiver" },
    };
    for (aliases) |a| if (std.mem.eql(u8, s, a[0])) return a[1];
    return s;
}

pub const EventKind = enum { Start, Update, Interact, custom };
pub const UnknownPolicy = enum { ignore, warn, error_ };
/// `stack`: functions on a call-graph cycle save their frame around calls
/// that may re-enter them. `disabled`: the producer asserts no function is
/// ever re-entered, and no frames are saved.
pub const RecursionMode = enum { disabled, stack };

pub const Source = struct {
    kind: SourceKind,
    name: ?[]const u8 = null,
    /// WASM import module name. Only meaningful when `kind == .import`;
    /// the matcher uses the `(module, name)` pair to bind a meta field
    /// to a `(import "<module>" "<name>" (global …))` declaration in
    /// the WASM binary.
    module: ?[]const u8 = null,
    /// Name of a second function import (same module) that writes the
    /// field. Only meaningful when `kind == .import`.
    setter: ?[]const u8 = null,
};

pub const FieldSync = struct {
    enabled: bool = false,
    mode: ?FieldSyncMode = null,
};

pub const Field = struct {
    key: []const u8,
    source: Source,
    udon_name: ?[]const u8 = null,
    /// Udon type name (aliases already resolved).
    type_name: ?[]const u8 = null,
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
    recursion: RecursionMode = .stack,
    /// Slots in the frame stack used by recursive functions.
    call_stack_size: ?u32 = null,
    /// Levels of a small self-recursive function that get slots of their
    /// own instead of saving frames; 0 turns that off.
    recursion_unroll: ?u32 = null,
};

/// What the translator can supply for an import of a module that has a
/// host of its own and cannot be rebuilt.
pub const HostFunction = enum {
    /// `(pointer, length) [→ length]`: console output, logged by line.
    write,
    /// `() → i64`: nanoseconds since the application started.
    clock,
    /// `(message)`: a NUL-terminated string for the error log; the event
    /// ends.
    panic,
    /// Any type: the call is reported and the event ends.
    halt,
};

pub const ImportBinding = struct {
    /// `module.name`; a trailing `*` stands for any rest. The first
    /// binding that matches an import applies.
    pattern: []const u8,
    as: ?HostFunction = null,
    /// Without `as`: the function's result, whatever its arguments.
    returns: i64 = 0,
};

pub const UdonMeta = struct {
    version: u32,
    behaviour: ?Behaviour = null,
    fields: []const Field = &.{},
    functions: []const Function = &.{},
    imports: []const ImportBinding = &.{},
    options: Options = .{},
    /// Keeps the backing std.json.Value alive for the duration of the meta
    /// (Field.default, Field.comment etc. may alias strings inside it).
    _json_root: std.json.Value = .null,
};

// ---------------- JSON ----------------

const ParseError = errors.ParseError;

/// One JSON object of the metadata, read member by member. A member of the
/// wrong JSON type is `MalformedMeta`; an absent one is null.
const Obj = struct {
    map: std.json.ObjectMap,

    fn of(v: std.json.Value) ParseError!Obj {
        return if (v == .object) .{ .map = v.object } else error.MalformedMeta;
    }

    fn get(o: Obj, comptime T: type, key: []const u8) ParseError!?T {
        const v = o.map.get(key) orelse return null;
        return switch (T) {
            Obj => try of(v),
            bool => if (v == .bool) v.bool else error.MalformedMeta,
            []const u8 => if (v == .string) v.string else error.MalformedMeta,
            i64 => if (v == .integer) v.integer else error.MalformedMeta,
            u32 => if (v == .integer) std.math.cast(u32, v.integer) orelse error.MalformedMeta else error.MalformedMeta,
            else => @compileError("no JSON reading for " ++ @typeName(T)),
        };
    }

    /// A string member naming a value of enum `E`. `error` is spelled
    /// `error_` in the enums, being a keyword.
    fn tag(o: Obj, comptime E: type, key: []const u8, comptime unknown: ParseError) ParseError!?E {
        const name = try o.get([]const u8, key) orelse return null;
        if (@hasField(E, "error_") and std.mem.eql(u8, name, "error")) return .error_;
        return std.meta.stringToEnum(E, name) orelse unknown;
    }

    /// The members of the object member `key`, each parsed by `each`.
    fn list(o: Obj, comptime T: type, allocator: std.mem.Allocator, key: []const u8, comptime each: fn ([]const u8, Obj) ParseError!T) ParseError![]const T {
        const members = try o.get(Obj, key) orelse return &.{};
        const out = try allocator.alloc(T, members.map.count());
        for (out, members.map.keys(), members.map.values()) |*item, name, v| item.* = try each(name, try of(v));
        return out;
    }
};

fn parseSource(obj: Obj) ParseError!Source {
    const o = try obj.get(Obj, "source") orelse return error.MalformedMeta;
    return .{
        .kind = try o.tag(SourceKind, "kind", error.InvalidSourceKind) orelse return error.MalformedMeta,
        .name = try o.get([]const u8, "name"),
        .module = try o.get([]const u8, "module"),
        .setter = try o.get([]const u8, "setter"),
    };
}

fn parseField(key: []const u8, o: Obj) ParseError!Field {
    var f: Field = .{ .key = key, .source = try parseSource(o) };
    f.udon_name = try o.get([]const u8, "udonName");
    if (try o.get([]const u8, "type")) |t| f.type_name = udonTypeName(t);
    f.is_export = try o.get(bool, "export") orelse false;
    if (try o.get(Obj, "sync")) |sync| {
        f.sync = .{ .enabled = try sync.get(bool, "enabled") orelse false, .mode = try sync.tag(FieldSyncMode, "mode", error.InvalidFieldSyncMode) };
        if (f.sync.enabled and f.sync.mode == null) return error.MissingSyncMode;
    }
    f.default = o.map.get("default");
    f.comment = try o.get([]const u8, "comment");
    return f;
}

fn parseFunction(key: []const u8, o: Obj) ParseError!Function {
    var f: Function = .{ .key = key, .source = try parseSource(o) };
    f.label = try o.get([]const u8, "label");
    f.is_export = try o.get(bool, "export") orelse false;
    f.event = try o.tag(EventKind, "event", error.InvalidEventKind);
    f.comment = try o.get([]const u8, "comment");
    return f;
}

fn parseImport(pattern: []const u8, o: Obj) ParseError!ImportBinding {
    const as = try o.tag(HostFunction, "as", error.MalformedMeta);
    const returns = try o.get(i64, "returns");
    // Exactly one of the two.
    if ((as != null) == (returns != null)) return error.MalformedMeta;
    return .{ .pattern = pattern, .as = as, .returns = returns orelse 0 };
}

fn parseOptions(o: Obj) ParseError!Options {
    var out: Options = .{};
    out.strict = try o.get(bool, "strict") orelse false;
    out.unknown_field_policy = try o.tag(UnknownPolicy, "unknownFieldPolicy", error.InvalidUnknownPolicy);
    out.unknown_function_policy = try o.tag(UnknownPolicy, "unknownFunctionPolicy", error.InvalidUnknownPolicy);
    if (try o.tag(RecursionMode, "recursion", error.MalformedMeta)) |mode| out.recursion = mode;
    out.call_stack_size = try o.get(u32, "callStackSize");
    out.recursion_unroll = try o.get(u32, "recursionUnroll");
    if (try o.get(Obj, "memory")) |m| {
        out.memory = .{
            .initial_pages = try m.get(u32, "initialPages"),
            .max_pages = try m.get(u32, "maxPages"),
            .udon_name = try m.get([]const u8, "udonName"),
        };
        if (out.memory.initial_pages) |initial| if (out.memory.max_pages) |max| {
            if (initial > max) return error.InvalidMemoryPageBounds;
        };
    }
    return out;
}

pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) ParseError!UdonMeta {
    if (!std.unicode.utf8ValidateSlice(json_bytes)) return error.InvalidUtf8MetaPayload;
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedMeta,
    };
    const o = try Obj.of(root);
    const version = try o.get(u32, "version") orelse return error.MalformedMeta;
    if (version != 1) return error.UnsupportedUdonMetaVersion;

    var meta: UdonMeta = .{ .version = version, ._json_root = root };
    if (try o.get(Obj, "behaviour")) |b| meta.behaviour = .{
        .sync_mode = try b.tag(SyncMode, "syncMode", error.InvalidBehaviourSyncMode),
        .comment = try b.get([]const u8, "comment"),
    };
    meta.fields = try o.list(Field, allocator, "fields", parseField);
    meta.functions = try o.list(Function, allocator, "functions", parseFunction);
    meta.imports = try o.list(ImportBinding, allocator, "imports", parseImport);
    if (try o.get(Obj, "options")) |options| meta.options = try parseOptions(options);
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

test "parse options.recursion default is stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = "{\"version\":1,\"options\":{}}";
    const m = try parse(arena.allocator(), j);
    try std.testing.expectEqual(RecursionMode.stack, m.options.recursion);
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

test "imports: host functions and constant answers, in the order written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const meta = try parse(arena.allocator(),
        \\{"version":1,"imports":{
        \\  "env.put":{"as":"write"},
        \\  "env.sys_*":{"returns":-38},
        \\  "env.*":{"as":"halt"}}}
    );
    try std.testing.expectEqual(@as(usize, 3), meta.imports.len);
    try std.testing.expectEqualStrings("env.put", meta.imports[0].pattern);
    try std.testing.expectEqual(HostFunction.write, meta.imports[0].as.?);
    try std.testing.expectEqual(@as(i64, -38), meta.imports[1].returns);
    try std.testing.expect(meta.imports[1].as == null);
    try std.testing.expectEqual(HostFunction.halt, meta.imports[2].as.?);
    // Exactly one of "as" and "returns"; a known host function.
    for ([_][]const u8{
        \\{"version":1,"imports":{"env.x":{}}}
        ,
        \\{"version":1,"imports":{"env.x":{"as":"write","returns":0}}}
        ,
        \\{"version":1,"imports":{"env.x":{"as":"teleport"}}}
    }) |bad| try std.testing.expectError(error.MalformedMeta, parse(arena.allocator(), bad));
}
