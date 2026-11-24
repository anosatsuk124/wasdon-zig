//! `zig build stats` — translate and run every example and print what the
//! result costs: static size (heap slots, instructions, bytes) and the
//! instructions and externs executed by the example's scenario.
//!
//! The table goes to stdout in Markdown so it can be pasted into
//! `docs/benchmarks.md`. Options:
//!   --profile <example>   also list the externs it executes, by count
//!   --emit <dir>          write each translation to <dir>/<example>.uasm

const std = @import("std");
const wasdon = @import("wasdon_zig");
const fixtures = @import("fixtures");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var out_buf: [8192]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    var profile: ?[]const u8 = null;
    var emit_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--profile") and i + 1 < args.len) {
            i += 1;
            profile = args[i];
        } else if (std.mem.eql(u8, args[i], "--emit") and i + 1 < args.len) {
            i += 1;
            emit_dir = args[i];
        } else {
            std.debug.print("unknown argument '{s}'\n", .{args[i]});
            return 2;
        }
    }

    try w.writeAll("| Example | wasm bytes | heap | instr | externs (static) | code bytes | uasm bytes | executed instr | executed externs |\n");
    try w.writeAll("|---|---:|---:|---:|---:|---:|---:|---:|---:|\n");
    var failed = false;
    for (fixtures.examples) |ex| {
        var r = fixtures.run(arena, ex, .{}) catch |e| {
            try w.print("| `{s}` | translation failed: {t} |\n", .{ ex.name, e });
            failed = true;
            continue;
        };
        if (!r.report.ok() or r.fault != null) {
            failed = true;
            const why = if (r.fault) |f| f.message else r.report.errors[0].message;
            try w.print("| `{s}` | **failed**: {s} |\n", .{ ex.name, why });
            continue;
        }
        try w.print("| `{s}` | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} |\n", .{
            ex.name,            ex.wasm.len,       r.size.heapSize(), r.size.instructions,
            r.size.externs,     r.size.code_bytes, r.uasm.len,        r.vm.stats.instrs,
            r.vm.stats.externs,
        });
        if (emit_dir) |dir| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}.uasm", .{ dir, ex.name });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = r.uasm });
        }
    }

    try w.writeAll("\nPer event:\n\n| Example | event | runs | instr / run | externs / run |\n|---|---|---:|---:|---:|\n");
    for (fixtures.examples) |ex| {
        var r = fixtures.run(arena, ex, .{}) catch continue;
        for (r.steps) |s| {
            if (s.runs == 0) continue;
            try w.print("| `{s}` | `{s}` | {d} | {d} | {d} |\n", .{ ex.name, s.name, s.runs, s.stats.instrs / s.runs, s.stats.externs / s.runs });
        }
        if (profile) |p| if (std.mem.eql(u8, p, ex.name)) {
            try w.print("\nExtern profile of `{s}`:\n\n| executions | signature |\n|---:|---|\n", .{ex.name});
            for (try r.vm.profile()) |e| {
                if (e.count == 0) break;
                try w.print("| {d} | `{s}` |\n", .{ e.count, e.text });
            }
            try w.writeAll("\n");
        };
    }
    return @intFromBool(failed);
}
