//! wasdon-zig: WebAssembly → Udon Assembly translator.
//!
//! Library surface; `src/main.zig` is a thin CLI over it.
//!
//!   * `wasm`       — WASM binary parser and `__udon_meta` reader.
//!   * `udon`       — Udon Assembly writer, parser, conformance checker and
//!                    VM emulator.
//!   * `translator` — the WASM → Udon lowering.

const std = @import("std");

pub const wasm = @import("wasm");
pub const udon = @import("udon");
pub const translator = @import("translator");

pub const Options = translator.Options;
pub const Diagnostics = translator.Diagnostics;

/// Parse a WASM binary, read its `__udon_meta` (if any) and write the
/// equivalent Udon Assembly program to `writer`.
pub fn translateBytes(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const mod = try wasm.parseModule(arena.allocator(), wasm_bytes);
    const meta = try wasm.parseUdonMetaFromModule(arena.allocator(), mod);
    try translator.translateModule(gpa, mod, meta, writer, options);
}

test "translateBytes accepts an empty module" {
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try translateBytes(std.testing.allocator, &bytes, &buf.writer, .{});
    try std.testing.expect(std.mem.startsWith(u8, buf.written(), ".data_start\n"));
    try std.testing.expect(std.mem.endsWith(u8, buf.written(), ".code_end\n"));
}
