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

    if (ex.uasm == null and !r.report.ok()) {
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
    if (r.size) |size| {
        try testing.expectEqual(size.heapSize(), r.report.heap_size);
        try testing.expectEqual(size.instructions, r.report.instructions);
        try testing.expectEqual(size.code_bytes, r.report.code_bytes);
    }

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

test "the Unity Linux console boots in bounded events and reload starts fresh" {
    const linux = fixtures.find("linux") orelse return error.SkipZigTest;
    const gpa = testing.allocator;
    var raw: std.Io.Writer.Allocating = .init(gpa);
    defer raw.deinit();
    _ = try wasdon.translateWithMeta(gpa, linux.wasm, linux.meta, &raw.writer, .{ .disable = .{ .stack_return = true } });
    var sliced: std.Io.Writer.Allocating = .init(gpa);
    defer sliced.deinit();
    try @import("linux_boot").write(gpa, raw.written(), &sliced.writer);
    var program = try wasdon.udon.program.parse(gpa, sliced.written(), null);
    defer program.deinit();

    var report = try wasdon.udon.check.check(gpa, &program);
    defer report.deinit();
    if (!report.ok()) {
        for (report.errors[0..@min(report.errors.len, 20)]) |finding| {
            std.debug.print("linux-boot:{d}: {s}\n", .{ finding.line, finding.message });
        }
        return error.TestUnexpectedResult;
    }

    const vm = try wasdon.udon.vm.Vm.init(gpa, &program, .{});
    defer vm.deinit();
    try testing.expect(try vm.runEvent("Boot"));
    try testing.expectEqualStrings("", vm.getVar("bootConsole").?.string);
    for (0..30000) |_| {
        if (!vm.getVar("bootRunning").?.boolean) break;
        const before = vm.stats.instrs;
        try testing.expect(try vm.runEvent("BootStep"));
        try testing.expect(vm.stats.instrs - before < 1_000_000);
    }
    try testing.expect(!vm.getVar("bootRunning").?.boolean);
    try linux.verify.?(vm);
    try testing.expectEqualStrings(try vm.logText(), vm.getVar("bootConsole").?.string);

    try testing.expect(try vm.runEvent("Boot"));
    try testing.expect(vm.getVar("bootRunning").?.boolean);
    try testing.expectEqualStrings("", vm.getVar("bootConsole").?.string);
    for (0..30000) |_| {
        try testing.expect(try vm.runEvent("BootStep"));
        if (vm.getVar("bootConsole").?.string.len != 0) break;
    }
    try testing.expect(vm.getVar("bootRunning").?.boolean);
    try testing.expect(std.mem.startsWith(u8, vm.getVar("bootConsole").?.string, "Linux version "));
}

test "the Unity assets hold what the translator produces now" {
    inline for (.{ "wasm-bench", "udon-orbit", "pi", "mandelbrot", "image-codec", "ragdoll", "blockfall", "bench-zig", "wasi-hello", "sort-bench-zig" }) |name| {
        try expectUnityAsset(name, @embedFile("unity/" ++ name ++ ".uasm.txt"));
    }
    const with_rust = comptime fixtures.find("sort-bench-rs") != null;
    if (with_rust) {
        try expectUnityAsset("sort-bench-rs", @embedFile("unity/sort-bench-rs.uasm.txt"));
    }
    // Every example with an asset is in the list above.
    var with_asset: usize = 0;
    for (fixtures.examples) |ex| with_asset += @intFromBool(fixtures.hasUnityAsset(ex));
    try testing.expectEqual(@as(usize, 10) + @intFromBool(with_rust), with_asset);
}

fn expectUnityAsset(name: []const u8, asset: []const u8) !void {
    const ex = fixtures.find(name).?;
    try testing.expect(fixtures.hasUnityAsset(ex));
    var fresh: std.Io.Writer.Allocating = .init(testing.allocator);
    defer fresh.deinit();
    _ = try wasdon.translateBytes(testing.allocator, ex.wasm, &fresh.writer, .{});
    if (!std.mem.eql(u8, asset, fresh.written())) {
        std.debug.print("unity/Wasdon/Examples/{s}.uasm.txt is out of date: run `zig build unity` (add `-Drust` for Rust)\n", .{name});
        return error.TestUnexpectedResult;
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
