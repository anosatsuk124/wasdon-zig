//! End-to-end tests: WASM → Udon Assembly → conformance check → emulator.

const std = @import("std");
const wasm = @import("wasm");
const udon = @import("udon");
const translate = @import("translate.zig");

const testing = std.testing;

test "empty module translates to a valid program" {
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mod = try wasm.parseModule(a, &bytes);
    var out: std.Io.Writer.Allocating = .init(a);
    try translate.translate(a, mod, null, &out.writer, .{});
    var diag: udon.text.Diag = .{};
    const prog = try udon.text.parse(a, out.written(), &diag);
    const report = try udon.check.check(a, &prog, .{});
    try testing.expect(report.ok());
}
