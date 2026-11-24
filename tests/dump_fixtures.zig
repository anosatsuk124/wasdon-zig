//! Writes the hand-assembled test programs to a directory so a real WASM
//! engine can replay them: `zig build dump-fixtures`, then
//! `node tools/golden.mjs --check zig-out/fixtures`.

const std = @import("std");
const structure = @import("structure.zig");
const builder = @import("wasm_builder.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.MissingOutputDirectory;
    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer dir.close(init.io);
    for (structure.cases) |case| {
        if (case.emulator_only) continue;
        var m: builder.Module = .{ .a = arena };
        try case.build(&m);
        inline for (.{ "wasm", "scenario", "log" }, .{ try m.build(), case.scenario, case.expected }) |ext, data| {
            const name = try std.fmt.allocPrint(arena, "{s}." ++ ext, .{case.name});
            try dir.writeFile(init.io, .{ .sub_path = name, .data = data });
        }
    }
}
