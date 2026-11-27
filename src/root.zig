//! wasdon-zig: WASM → Udon Assembly translator.
//!
//! Public library surface. The CLI in `src/main.zig` is a thin driver that
//! composes these building blocks.

const std = @import("std");
const Io = std.Io;

pub const wasm = @import("wasm");
pub const udon = @import("udon");
pub const translator = @import("translator");

pub const Options = translator.Options;
pub const Diagnostics = translator.Diagnostics;
pub const Stats = translator.Stats;

/// Parse a WASM binary, read its `__udon_meta` (if any) and write the Udon
/// Assembly translation to `writer`. Scratch allocations use `gpa` and are
/// released before returning.
pub fn translateBytes(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    writer: *Io.Writer,
    options: Options,
) !Stats {
    return translateWithMeta(gpa, wasm_bytes, null, writer, options);
}

/// Like `translateBytes`, with the `__udon_meta` JSON given separately
/// (a "sidecar" file) instead of read from the module. A module that
/// carries its own metadata is overridden.
pub fn translateWithMeta(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    meta_json: ?[]const u8,
    writer: *Io.Writer,
    options: Options,
) !Stats {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const mod = try wasm.parseModule(aa, wasm_bytes);
    const meta = if (meta_json) |json| try wasm.parseUdonMeta(aa, json) else try wasm.parseUdonMetaFromModule(aa, mod);
    return translator.translate(gpa, mod, meta, writer, options);
}

test "library translate surface wires up" {
    // Tiny WASM module: magic + version + empty sections.
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var buf: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    _ = try translateBytes(std.testing.allocator, &bytes, &buf.writer, .{});
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, ".data_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".code_start") != null);
}
