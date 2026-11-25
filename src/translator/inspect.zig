//! A census of a WebAssembly module from the translator's point of view:
//! how big it is, what it imports, and which of the things it uses the
//! translator — or the Udon VM itself — cannot provide.
//!
//! `translate` stops at the first unsupported construct. This reports all
//! of them at once, which is what one wants to know before deciding
//! whether a module can be made to fit (`wasdon-zig inspect`).

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");

const Instruction = wasm.Instruction;

pub const Census = struct {
    functions: usize = 0,
    imported_functions: usize = 0,
    instructions: u64 = 0,
    /// Deepest nesting of blocks in any function.
    max_block_depth: u32 = 0,
    calls: u64 = 0,
    indirect_calls: u64 = 0,
    memory_accesses: u64 = 0,

    memory: ?wasm.types.MemType = null,
    memory_imported: bool = false,
    active_segments: usize = 0,
    passive_segments: usize = 0,
    data_bytes: u64 = 0,
    table_size: u32 = 0,
    globals: usize = 0,
    exports: usize = 0,
    /// Exported functions without parameters or results: the ones that
    /// become Udon events when there is no `__udon_meta`.
    event_candidates: usize = 0,

    extern_imports: usize = 0,
    bound_imports: usize = 0,
    /// WASI functions the translator implements, and ones it accepts but
    /// answers "not available".
    wasi_implemented: usize = 0,
    wasi_stubbed: usize = 0,
    unknown_imports: std.ArrayList([]const u8) = .empty,

    atomics: [@typeInfo(wasm.instruction.Atomic.Kind).@"enum".fields.len]u64 = @splat(0),
    memory_init: u64 = 0,
    data_drop: u64 = 0,
    multi_value_blocks: u64 = 0,

    pub fn atomicTotal(c: *const Census) u64 {
        var n: u64 = 0;
        for (c.atomics) |x| n += x;
        return n;
    }

    /// Nothing in the module is beyond the translator.
    pub fn translatable(c: *const Census) bool {
        return c.multi_value_blocks == 0 and c.unknown_imports.items.len == 0;
    }
};

pub fn census(arena: std.mem.Allocator, mod: wasm.Module, meta: ?wasm.UdonMeta) !Census {
    var c: Census = .{ .functions = mod.codes.len, .globals = mod.globals.len, .exports = mod.exports.len };

    var func_types: std.ArrayList(u32) = .empty;
    var name_buf: [512]u8 = undefined;
    for (mod.imports) |imp| switch (imp.desc) {
        .func => |type_index| {
            c.imported_functions += 1;
            try func_types.append(arena, type_index);
            const wasi = @import("wasi.zig");
            const from_wasi = std.mem.eql(u8, imp.module, wasi.module_name);
            if (from_wasi and wasi.support(imp.name) == .implemented) {
                c.wasi_implemented += 1;
            } else if (from_wasi and wasi.support(imp.name) == .stubbed) {
                c.wasi_stubbed += 1;
            } else if (boundByMeta(meta, imp)) {
                c.bound_imports += 1;
            } else if (udon.nodes.resolveExtern(imp.name, &name_buf) != null) {
                c.extern_imports += 1;
            } else try c.unknown_imports.append(arena, try std.fmt.allocPrint(arena, "{s}.{s}", .{ imp.module, imp.name }));
        },
        .memory => |m| {
            c.memory = m;
            c.memory_imported = true;
        },
        .table => |t| c.table_size = t.limits.min,
        .global => {},
    };
    try func_types.appendSlice(arena, mod.funcs);
    if (mod.memories.len != 0) c.memory = mod.memories[0];
    if (mod.tables.len != 0) c.table_size = mod.tables[0].limits.min;

    for (mod.datas) |d| {
        if (d.passive) c.passive_segments += 1 else c.active_segments += 1;
        c.data_bytes += d.init.len;
    }
    for (mod.exports) |e| if (e.desc == .func and e.desc.func < func_types.items.len) {
        const ty = mod.types_[func_types.items[e.desc.func]];
        if (ty.params.len == 0 and ty.results.len == 0) c.event_candidates += 1;
    };
    for (mod.codes) |code| walk(&c, mod, code.body, 1);
    return c;
}

fn boundByMeta(meta: ?wasm.UdonMeta, imp: wasm.module.Import) bool {
    const m = meta orelse return false;
    for (m.imports) |b| if (@import("wasi.zig").matches(b.pattern, imp)) return true;
    for (m.fields) |f| {
        if (f.source.kind != .import) continue;
        if (f.source.name) |n| if (std.mem.eql(u8, n, imp.name)) return true;
        if (f.source.setter) |s| if (std.mem.eql(u8, s, imp.name)) return true;
    }
    return false;
}

fn walk(c: *Census, mod: wasm.Module, body: []const Instruction, depth: u32) void {
    c.max_block_depth = @max(c.max_block_depth, depth);
    for (body) |ins| {
        c.instructions += 1;
        switch (ins) {
            .block, .loop => |b| {
                multiValue(c, mod, b.bt);
                walk(c, mod, b.body, depth + 1);
            },
            .if_ => |b| {
                multiValue(c, mod, b.bt);
                walk(c, mod, b.then_body, depth + 1);
                if (b.else_body) |e| walk(c, mod, e, depth + 1);
            },
            .call => c.calls += 1,
            .call_indirect => c.indirect_calls += 1,
            .memory_init => c.memory_init += 1,
            .data_drop => c.data_drop += 1,
            .atomic => |a| c.atomics[@intFromEnum(a.kind().?)] += 1,
            else => if (std.mem.indexOf(u8, @tagName(ins), "_load") != null or std.mem.indexOf(u8, @tagName(ins), "_store") != null) {
                c.memory_accesses += 1;
            },
        }
    }
}

/// A block type that names a function type takes parameters or returns
/// several values.
fn multiValue(c: *Census, mod: wasm.Module, bt: wasm.types.BlockType) void {
    switch (bt) {
        .type_index => |i| if (i < mod.types_.len) {
            const ty = mod.types_[i];
            if (ty.params.len != 0 or ty.results.len > 1) c.multi_value_blocks += 1;
        },
        else => {},
    }
}

pub fn report(c: *const Census, w: *std.Io.Writer) !void {
    try w.print("functions            {d} defined, {d} imported\n", .{ c.functions, c.imported_functions });
    try w.print("instructions         {d} (blocks nest up to {d} deep)\n", .{ c.instructions, c.max_block_depth });
    try w.print("calls                {d} direct, {d} indirect; table of {d}\n", .{ c.calls, c.indirect_calls, c.table_size });
    try w.print("memory accesses      {d}\n", .{c.memory_accesses});
    if (c.memory) |m| {
        try w.print("memory               {d} pages initially", .{m.min});
        if (m.max) |max| try w.print(", at most {d}", .{max});
        try w.print("{s}{s}\n", .{ if (m.shared) ", shared" else "", if (c.memory_imported) ", imported" else "" });
    } else try w.writeAll("memory               none\n");
    try w.print("data                 {d} bytes in {d} active and {d} passive segments\n", .{ c.data_bytes, c.active_segments, c.passive_segments });
    try w.print("globals, exports     {d}, {d} ({d} exported functions could be events)\n", .{ c.globals, c.exports, c.event_candidates });
    try w.print("imports              {d} Udon externs, {d} bound by __udon_meta, {d} unknown\n", .{ c.extern_imports, c.bound_imports, c.unknown_imports.items.len });
    if (c.wasi_implemented + c.wasi_stubbed != 0)
        try w.print("WASI preview 1       {d} functions implemented, {d} answered \"not available\"\n", .{ c.wasi_implemented, c.wasi_stubbed });

    const shared = if (c.memory) |m| m.shared else false;
    if (shared or c.atomicTotal() != 0) {
        // Translated, but as one thread executes them: say so.
        try w.print("threads              {s}{d} atomic instructions, run as the one thread there is:", .{ if (shared) "shared memory, " else "", c.atomicTotal() });
        inline for (@typeInfo(wasm.instruction.Atomic.Kind).@"enum".fields, 0..) |f, i| {
            if (c.atomics[i] != 0) try w.print(" {s} {d}", .{ f.name, c.atomics[i] });
        }
        try w.writeAll("\n");
    }

    try w.writeAll("\nNot supported by the translator:\n");
    var any = false;
    if (c.multi_value_blocks != 0) {
        any = true;
        try w.print("  - {d} blocks with parameters or several results (multi-value)\n", .{c.multi_value_blocks});
    }
    if (c.unknown_imports.items.len != 0) {
        any = true;
        try w.print("  - {d} imports that are neither Udon externs nor bound by __udon_meta:\n", .{c.unknown_imports.items.len});
        const shown = @min(c.unknown_imports.items.len, 12);
        for (c.unknown_imports.items[0..shown]) |name| try w.print("      {s}\n", .{name});
        if (shown < c.unknown_imports.items.len) try w.print("      … and {d} more\n", .{c.unknown_imports.items.len - shown});
    }
    if (!any) try w.writeAll("  nothing\n");
}

test "census of a module with nothing unusual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = [_]Instruction{ .{ .i32_const = 0 }, .{ .i32_load = .{ .@"align" = 2, .offset = 0 } }, .drop, .{ .block = .{ .bt = .empty, .body = &.{.nop} } } };
    const mod: wasm.Module = .{
        .types_ = &.{.{ .params = &.{}, .results = &.{} }},
        .funcs = &.{0},
        .codes = &.{.{ .locals = &.{}, .body = &body }},
        .memories = &.{.{ .min = 1, .max = null }},
        .exports = &.{.{ .name = "_start", .desc = .{ .func = 0 } }},
    };
    var c = try census(arena.allocator(), mod, null);
    try std.testing.expect(c.translatable());
    try std.testing.expectEqual(@as(u64, 5), c.instructions);
    try std.testing.expectEqual(@as(u64, 1), c.memory_accesses);
    try std.testing.expectEqual(@as(u32, 2), c.max_block_depth);
    try std.testing.expectEqual(@as(usize, 1), c.event_candidates);
}

test "census names what a threaded module needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = [_]Instruction{
        .{ .i32_const = 0 },   .{ .atomic = .{ .op = 0x10 } }, .drop,
        .{ .i32_const = 0 },   .{ .i32_const = 0 },            .{ .i32_const = 4 },
        .{ .memory_init = 0 },
    };
    const mod: wasm.Module = .{
        .types_ = &.{.{ .params = &.{}, .results = &.{} }},
        .funcs = &.{0},
        .codes = &.{.{ .locals = &.{}, .body = &body }},
        .imports = &.{
            .{ .module = "env", .name = "memory", .desc = .{ .memory = .{ .min = 15, .max = 65536, .shared = true } } },
            .{ .module = "env", .name = "spawn_worker", .desc = .{ .func = 0 } },
            .{ .module = "env", .name = "UnityEngineDebug.__Log__SystemString__SystemVoid", .desc = .{ .func = 0 } },
        },
        .datas = &.{.{ .memory_index = 0, .passive = true, .offset = &.{}, .init = "abcd" }},
    };
    var c = try census(arena.allocator(), mod, null);
    try std.testing.expect(!c.translatable());
    // Bound by the metadata, the one unknown import is no obstacle.
    const bound = try census(arena.allocator(), mod, .{ .version = 1, .imports = &.{.{ .pattern = "env.spawn_*", .as = .halt }} });
    try std.testing.expect(bound.translatable());
    try std.testing.expectEqual(@as(usize, 1), bound.bound_imports);
    try std.testing.expect(c.memory.?.shared and c.memory_imported);
    try std.testing.expectEqual(@as(u64, 1), c.atomicTotal());
    try std.testing.expectEqual(@as(usize, 1), c.passive_segments);
    try std.testing.expectEqual(@as(u64, 1), c.memory_init);
    try std.testing.expectEqual(@as(usize, 1), c.extern_imports);
    try std.testing.expectEqualStrings("env.spawn_worker", c.unknown_imports.items[0]);
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try report(&c, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "shared memory, 1 atomic instructions, run as the one thread there is: load 1") != null);
}
