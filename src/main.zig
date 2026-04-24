//! wasdon-zig CLI.
//!
//! Usage:
//!   wasdon-zig translate <input.wasm> [-o <output.uasm>] [--mem-oob-diagnostics]
//!
//! If `-o` is omitted, the translation is written to stdout. The CLI is the
//! only place that touches stdio; the translator itself is a pure library.
//!
//! `--mem-oob-diagnostics` instruments every memory op with a unique site id
//! and the effective byte address. On an OOB trap the Unity log line grows
//! from `page=P; max=M` to `site=N; addr=A; page=P; max=M`, and each memory
//! op gains a `; mem op site=N fn=F op=... kind=...` comment in the uasm —
//! grep the output for `site=N` to identify the WASM source. Off by default
//! because the preamble materially bloats the image.

const std = @import("std");
const Io = std.Io;

const wasdon_zig = @import("wasdon_zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        try printUsage(init, "missing subcommand");
        return;
    }

    if (std.mem.eql(u8, args[1], "translate")) {
        try runTranslate(init, args[2..]);
        return;
    }

    try printUsage(init, "unknown subcommand");
    _ = io;
}

fn printUsage(init: std.process.Init, reason: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), init.io, &buf);
    const w = &fw.interface;
    try w.print(
        \\error: {s}
        \\
        \\Usage: wasdon-zig translate <input.wasm> [-o <output.uasm>] [--mem-oob-diagnostics]
        \\
    , .{reason});
    try w.flush();
}

fn runTranslate(init: std.process.Init, args: []const []const u8) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    if (args.len < 1) {
        try printUsage(init, "translate requires an input path");
        return;
    }
    const input_path = args[0];
    var output_path: ?[]const u8 = null;
    var mem_oob_diagnostics: bool = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            if (i + 1 >= args.len) {
                try printUsage(init, "-o requires a path");
                return;
            }
            output_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--mem-oob-diagnostics")) {
            mem_oob_diagnostics = true;
        } else {
            try printUsage(init, "unknown argument");
            return;
        }
    }

    const cwd = std.Io.Dir.cwd();
    const wasm_bytes = try cwd.readFileAlloc(init.io, input_path, arena, .limited(64 * 1024 * 1024));

    // Translate into a growing buffer first so errors surface before we open
    // the output file.
    var allocating: Io.Writer.Allocating = .init(arena);
    defer allocating.deinit();
    try wasdon_zig.translateBytes(arena, wasm_bytes, &allocating.writer, .{
        .mem_oob_diagnostics = mem_oob_diagnostics,
    });
    const out = allocating.written();

    if (output_path) |p| {
        try cwd.writeFile(init.io, .{ .sub_path = p, .data = out });
    } else {
        var buf: [4096]u8 = undefined;
        var stdout_fw: Io.File.Writer = .init(.stdout(), init.io, &buf);
        const stdout = &stdout_fw.interface;
        try stdout.writeAll(out);
        try stdout.flush();
    }
}

test "main smoke" {
    // Just ensure the library is linked; proper e2e tests live in
    // src/translator/translate.zig and src/root.zig.
    try std.testing.expect(true);
}
