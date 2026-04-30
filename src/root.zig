//! wasdon-zig: WASM → Udon Assembly translator.
//!
//! Public library surface. The CLI in `src/main.zig` is a thin driver that
//! composes these building blocks.

const std = @import("std");
const Io = std.Io;

pub const wasm = @import("wasm");
pub const udon = @import("udon");
pub const translator = @import("translator");

pub const translate = translator.translateModule;
pub const Options = translator.Options;

/// Read a WASM binary from bytes, optionally consume a sidecar `__udon_meta`
/// JSON payload, and emit Udon Assembly text into `writer`. Pass `null` for
/// `udon_meta_json` when no sidecar is provided — the translator falls back
/// to defaults. All allocations live in `gpa`; the caller owns whatever the
/// writer is backed by.
pub fn translateBytes(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    udon_meta_json: ?[]const u8,
    writer: *Io.Writer,
    options: Options,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const mod = try wasm.parseModule(aa, wasm_bytes);
    const meta: ?wasm.UdonMeta = if (udon_meta_json) |json|
        try wasm.parseUdonMeta(aa, json)
    else
        null;
    try translate(gpa, mod, meta, writer, options);
}

test "library translate surface wires up" {
    // Tiny WASM module: magic + version + empty sections.
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var buf: Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translateBytes(std.testing.allocator, &bytes, null, &buf.writer, .{});
    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, ".data_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".code_start") != null);
}
