//! Top-level entry point: consume a `.wasm` byte slice and return a Module.
//!
//! The parser walks the section envelope layer (`section.zig`), dispatches
//! payloads to their per-section decoders (`module.zig`), and enforces the
//! module-level constraints listed at the end of
//! docs/w3c_wasm_binary_format_note.md: magic/version, non-custom section
//! ordering and uniqueness, function/code count correspondence.
//!
//! The caller passes an allocator; use an arena so all nested slices share
//! a lifetime and can be freed in one `deinit()`.

const std = @import("std");
const errors = @import("errors.zig");
const Reader = @import("reader.zig").Reader;
const section = @import("section.zig");
const module = @import("module.zig");

pub const Module = module.Module;
pub const CustomSection = module.CustomSection;

pub const WASM_MAGIC = [_]u8{ 0x00, 0x61, 0x73, 0x6D };
pub const WASM_VERSION = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

/// Ordinal position in the binary stream used for ascending-order checks.
/// For Core 1 sections this is just the binary id; the post-MVP `datacount`
/// section has binary id 12 but per spec sits between Element (9) and Code
/// (10), so we map it to "9.5" by giving it ordinal 10 and shifting Code (10)
/// → 11 and Data (11) → 12. This way a single `prev <= cur` ascending check
/// keeps the existing semantics.
fn sectionOrder(id: section.SectionId) u8 {
    return switch (id) {
        .custom => 0, // unused: custom sections bypass the ordering check
        .type => 1,
        .import => 2,
        .function => 3,
        .table => 4,
        .memory => 5,
        .global => 6,
        .@"export" => 7,
        .start => 8,
        .element => 9,
        .datacount => 10,
        .code => 11,
        .data => 12,
    };
}

pub fn parseModule(allocator: std.mem.Allocator, bytes: []const u8) errors.ParseError!Module {
    var r = Reader.init(bytes);

    const magic = try r.readBytes(4);
    if (!std.mem.eql(u8, magic, &WASM_MAGIC)) return error.BadMagic;
    const version = try r.readBytes(4);
    if (!std.mem.eql(u8, version, &WASM_VERSION)) return error.BadVersion;

    var mod: Module = .{};
    // Track non-custom sections for ordering + duplicate checks. Custom
    // sections are permitted at any position and may repeat freely. Indexed
    // by raw binary id (0..12 inclusive).
    var last_ord: ?u8 = null;
    var seen = [_]bool{false} ** 13;
    var customs: std.ArrayList(CustomSection) = .empty;
    defer customs.deinit(allocator);

    while (!r.eof()) {
        const raw = try section.readSection(&r);
        const id_byte: u8 = @intFromEnum(raw.id);

        if (raw.id == .custom) {
            const c = try module.parseCustomSection(raw.payload);
            try customs.append(allocator, c);
            continue;
        }

        if (seen[id_byte]) return error.DuplicateSection;
        const ord = sectionOrder(raw.id);
        if (last_ord) |prev| {
            if (ord <= prev) return error.SectionOutOfOrder;
        }
        seen[id_byte] = true;
        last_ord = ord;

        switch (raw.id) {
            .custom => unreachable,
            .type => mod.types_ = try module.parseTypeSection(allocator, raw.payload),
            .import => mod.imports = try module.parseImportSection(allocator, raw.payload),
            .function => mod.funcs = try module.parseFunctionSection(allocator, raw.payload),
            .table => mod.tables = try module.parseTableSection(allocator, raw.payload),
            .memory => mod.memories = try module.parseMemorySection(allocator, raw.payload),
            .global => mod.globals = try module.parseGlobalSection(allocator, raw.payload),
            .@"export" => mod.exports = try module.parseExportSection(allocator, raw.payload),
            .start => mod.start = try module.parseStartSection(raw.payload),
            .element => mod.elements = try module.parseElementSection(allocator, raw.payload),
            .code => mod.codes = try module.parseCodeSection(allocator, raw.payload),
            .data => mod.datas = try module.parseDataSection(allocator, raw.payload),
            .datacount => mod.data_count = try module.parseDataCountSection(raw.payload),
        }
    }

    // Function/Code correspondence: the function section carries one typeidx
    // per non-imported function, and the code section carries one body per
    // non-imported function. Their counts must match exactly.
    if (mod.funcs.len != mod.codes.len) return error.FuncCodeCountMismatch;

    mod.customs = try customs.toOwnedSlice(allocator);
    return mod;
}

// ---------------- tests ----------------

fn leb_u32(writer: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var n = v;
    while (true) {
        var b: u8 = @intCast(n & 0x7F);
        n >>= 7;
        if (n != 0) b |= 0x80;
        try writer.append(allocator, b);
        if (n == 0) break;
    }
}

/// Build a synthetic section header + payload into `buf`.
fn pushSection(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    id: u8,
    payload: []const u8,
) !void {
    try buf.append(allocator, id);
    try leb_u32(buf, allocator, @intCast(payload.len));
    try buf.appendSlice(allocator, payload);
}

test "parseModule rejects bad magic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6E, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.BadMagic, parseModule(arena.allocator(), &bytes));
}

test "parseModule rejects bad version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.BadVersion, parseModule(arena.allocator(), &bytes));
}

test "parseModule header-only (empty module)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    const mod = try parseModule(arena.allocator(), &bytes);
    try std.testing.expectEqual(@as(usize, 0), mod.types_.len);
    try std.testing.expectEqual(@as(usize, 0), mod.funcs.len);
    try std.testing.expectEqual(@as(usize, 0), mod.codes.len);
    try std.testing.expect(mod.start == null);
}

test "parseModule simple: 1 type, 1 func, 1 code, 1 export" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &WASM_MAGIC);
    try buf.appendSlice(gpa, &WASM_VERSION);

    // Type section: 1 functype () -> (i32)  → 60 00 01 7F
    try pushSection(&buf, gpa, 1, &[_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7F });
    // Function section: 1 entry typeidx=0
    try pushSection(&buf, gpa, 3, &[_]u8{ 0x01, 0x00 });
    // Export section: 1 entry "main" func 0
    try pushSection(&buf, gpa, 7, &[_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x00 });
    // Code section: 1 code, size=4, body={locals=00, expr=41 2A 0B}
    try pushSection(&buf, gpa, 10, &[_]u8{ 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B });

    const mod = try parseModule(arena.allocator(), buf.items);
    try std.testing.expectEqual(@as(usize, 1), mod.types_.len);
    try std.testing.expectEqual(@as(usize, 1), mod.funcs.len);
    try std.testing.expectEqual(@as(usize, 1), mod.codes.len);
    try std.testing.expectEqual(@as(usize, 1), mod.exports.len);
    try std.testing.expectEqualStrings("main", mod.exports[0].name);
    try std.testing.expectEqual(@as(i32, 42), mod.codes[0].body[0].i32_const);
}

test "parseModule rejects non-custom section out of order" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &WASM_MAGIC);
    try buf.appendSlice(gpa, &WASM_VERSION);
    // function (3) before type (1)
    try pushSection(&buf, gpa, 3, &[_]u8{0x00});
    try pushSection(&buf, gpa, 1, &[_]u8{0x00});

    try std.testing.expectError(error.SectionOutOfOrder, parseModule(arena.allocator(), buf.items));
}

test "parseModule rejects duplicate non-custom section" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &WASM_MAGIC);
    try buf.appendSlice(gpa, &WASM_VERSION);
    try pushSection(&buf, gpa, 1, &[_]u8{0x00});
    try pushSection(&buf, gpa, 1, &[_]u8{0x00});

    try std.testing.expectError(error.DuplicateSection, parseModule(arena.allocator(), buf.items));
}

test "parseModule accepts custom sections at arbitrary positions and preserves them" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &WASM_MAGIC);
    try buf.appendSlice(gpa, &WASM_VERSION);
    // custom before type
    try pushSection(&buf, gpa, 0, &[_]u8{ 0x03, 'z', 'z', 'z', 0xAA });
    try pushSection(&buf, gpa, 1, &[_]u8{0x00});
    // custom between type and function
    try pushSection(&buf, gpa, 0, &[_]u8{ 0x03, 'a', 'a', 'a', 0xBB });
    try pushSection(&buf, gpa, 3, &[_]u8{0x00});

    const mod = try parseModule(arena.allocator(), buf.items);
    try std.testing.expectEqual(@as(usize, 2), mod.customs.len);
    try std.testing.expectEqualStrings("zzz", mod.customs[0].name);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xAA}, mod.customs[0].bytes);
    try std.testing.expectEqualStrings("aaa", mod.customs[1].name);
}

test "parseModule accepts DataCount between Element and Code (post-MVP bulk-memory ordering)" {
    // Per docs/w3c_wasm_binary_format_note.md "DataCount ordering exception",
    // the DataCount section has binary id 12 but spec-wise sits between
    // Element (id 9) and Code (id 10). A naive ascending-id check rejects
    // this; the parser must use an ordinal mapping that places DataCount at
    // ordinal 9.5.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &WASM_MAGIC);
    try buf.appendSlice(gpa, &WASM_VERSION);
    // Type: 1 functype ()->()
    try pushSection(&buf, gpa, 1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    // Function: 1 entry typeidx=0
    try pushSection(&buf, gpa, 3, &[_]u8{ 0x01, 0x00 });
    // DataCount: count=1
    try pushSection(&buf, gpa, 12, &[_]u8{0x01});
    // Code: 1 trivial body
    try pushSection(&buf, gpa, 10, &[_]u8{ 0x01, 0x02, 0x00, 0x0B });
    // Data: 1 passive segment with init=""
    try pushSection(&buf, gpa, 11, &[_]u8{ 0x01, 0x01, 0x00 });

    const mod = try parseModule(arena.allocator(), buf.items);
    try std.testing.expectEqual(@as(?u32, 1), mod.data_count);
    try std.testing.expectEqual(@as(usize, 1), mod.datas.len);
}

test "parseModule rejects DataCount after Code" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &WASM_MAGIC);
    try buf.appendSlice(gpa, &WASM_VERSION);
    try pushSection(&buf, gpa, 1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    try pushSection(&buf, gpa, 3, &[_]u8{ 0x01, 0x00 });
    try pushSection(&buf, gpa, 10, &[_]u8{ 0x01, 0x02, 0x00, 0x0B });
    // DataCount placed after Code is malformed.
    try pushSection(&buf, gpa, 12, &[_]u8{0x01});

    try std.testing.expectError(error.SectionOutOfOrder, parseModule(arena.allocator(), buf.items));
}

test "parseModule enforces function/code count match" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &WASM_MAGIC);
    try buf.appendSlice(gpa, &WASM_VERSION);
    // type: 1 functype ()->()
    try pushSection(&buf, gpa, 1, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    // function: 2 entries
    try pushSection(&buf, gpa, 3, &[_]u8{ 0x02, 0x00, 0x00 });
    // code: only 1 entry (size=2, body={locals=00, end})
    try pushSection(&buf, gpa, 10, &[_]u8{ 0x01, 0x02, 0x00, 0x0B });

    try std.testing.expectError(error.FuncCodeCountMismatch, parseModule(arena.allocator(), buf.items));
}

test "parseModule integration: parses the bench.wasm fixture end-to-end" {
    // @embedFile picks up `zig-out/wasm/bench.wasm` produced by
    // `zig build wasm-example`. If the file is missing at compile time this
    // test fails to build — run `zig build wasm-example` first.
    const bench_wasm: []const u8 = @embedFile("testdata/bench.wasm");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mod = try parseModule(arena.allocator(), bench_wasm);

    // The bench exposes the Udon event-handler functions; meta is supplied
    // as a sidecar JSON, never embedded in the module.
    var saw_on_start = false;
    var saw_on_update = false;
    var saw_on_interact = false;
    for (mod.exports) |exp| {
        if (std.mem.eql(u8, exp.name, "on_start")) saw_on_start = true;
        if (std.mem.eql(u8, exp.name, "on_update")) saw_on_update = true;
        if (std.mem.eql(u8, exp.name, "on_interact")) saw_on_interact = true;
    }
    try std.testing.expect(saw_on_start);
    try std.testing.expect(saw_on_update);
    try std.testing.expect(saw_on_interact);

    // The sidecar JSON for the bench fixture is mirrored into testdata by
    // `build.zig`'s `wasm-example` step; parse it through the public
    // `udon_meta.parse` entry point to make sure the schema decodes.
    const udon_meta = @import("udon_meta.zig");
    const meta_json = @embedFile("testdata/bench.udon_meta.json");
    const meta = try udon_meta.parse(arena.allocator(), meta_json);
    try std.testing.expectEqual(@as(u32, 1), meta.version);
    // `behaviour.syncMode == "manual"` per examples/wasm-bench/bench.udon_meta.json.
    try std.testing.expect(meta.behaviour != null);
    try std.testing.expectEqual(udon_meta.SyncMode.manual, meta.behaviour.?.sync_mode.?);
    // At least one of the documented functions must be present.
    var saw_start_fn = false;
    for (meta.functions) |f| {
        if (std.mem.eql(u8, f.key, "start")) saw_start_fn = true;
    }
    try std.testing.expect(saw_start_fn);
}
