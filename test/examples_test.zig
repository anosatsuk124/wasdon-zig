//! Integration tests: every example is translated, the result is checked
//! against the Udon Assembly rules, executed in the emulator, and compared
//! with its expected behaviour.

const std = @import("std");
const wasdon = @import("wasdon_zig");
const fixtures = @import("fixtures");

const testing = std.testing;

fn expectRuns(ex: fixtures.Example) !void {
    var r = try fixtures.run(testing.allocator, ex, .{});
    defer r.deinit();

    if (!r.report.ok()) {
        std.debug.print("{s}: the translation violates the Udon Assembly rules:\n", .{ex.name});
        for (r.report.errors[0..@min(r.report.errors.len, 20)]) |e| std.debug.print("  line {d}: {s}\n", .{ e.line, e.message });
        return error.TestUnexpectedResult;
    }
    if (r.fault) |f| {
        std.debug.print("{s}: halted at pc=0x{X:0>8}: {s}\n", .{ ex.name, f.pc, f.message });
        return error.TestUnexpectedResult;
    }
    // What the translator says the program needs is what the assembler
    // will allocate.
    try testing.expectEqual(r.size.heapSize(), r.report.heap_size);
    try testing.expectEqual(r.size.instructions, r.report.instructions);
    try testing.expectEqual(r.size.code_bytes, r.report.code_bytes);

    for (r.steps) |s| {
        if (!s.found) {
            std.debug.print("{s}: event {s} is not exported\n", .{ ex.name, s.name });
            return error.TestUnexpectedResult;
        }
    }
    if (ex.expected_log) |want| try testing.expectEqualStrings(want, try r.log());
    if (ex.verify) |f| try f(r.vm);
}

test "every example translates to valid Udon Assembly and behaves as expected" {
    for (fixtures.examples) |ex| {
        expectRuns(ex) catch |e| {
            std.debug.print("example '{s}' failed: {t}\n", .{ ex.name, e });
            return e;
        };
    }
}

test "the bench fixture parses as a WASM module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mod = try wasdon.wasm.parseModule(arena.allocator(), fixtures.find("wasm-bench").?.wasm);
    try testing.expect(mod.codes.len > 10);
    try testing.expect(mod.memories.len == 1);
    const meta = (try wasdon.wasm.parseUdonMetaFromModule(arena.allocator(), mod)).?;
    try testing.expectEqual(@as(usize, 3), meta.functions.len);
}

test "translation is deterministic" {
    const ex = fixtures.find("wasm-bench").?;
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    _ = try wasdon.translateBytes(testing.allocator, ex.wasm, &a.writer, .{});
    _ = try wasdon.translateBytes(testing.allocator, ex.wasm, &b.writer, .{});
    try testing.expectEqualStrings(a.written(), b.written());
}
