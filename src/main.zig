//! wasdon-zig CLI.
//!
//!   wasdon_zig translate <in.wasm> [-o <out.uasm>]   WASM → Udon Assembly
//!   wasdon_zig check <in.uasm>                       conformance check
//!   wasdon_zig run <in.uasm> [event...]              run events in the emulator
//!
//! `translate` writes to stdout without `-o`; warnings and the heap-slot
//! count go to stderr. `run` executes `_start` when no event is named and
//! prints everything the program logs.

const std = @import("std");
const Io = std.Io;
const wasdon = @import("wasdon_zig");
const udon = wasdon.udon;

const node_list = @embedFile("udon_nodes.txt");
/// Heap capacity of a stock Udon Assembly Program Asset (`docs/spec_heap_budget.md`).
const default_heap_capacity = 512;

const usage =
    \\Usage:
    \\  wasdon_zig translate <in.wasm> [-o <out.uasm>]
    \\  wasdon_zig check <in.uasm>
    \\  wasdon_zig run <in.uasm> [event...]
    \\
;

const Cli = struct {
    init: std.process.Init,
    arena: std.mem.Allocator,
    out_buf: [4096]u8 = undefined,
    err_buf: [4096]u8 = undefined,
    stdout: Io.File.Writer = undefined,
    stderr: Io.File.Writer = undefined,

    fn read(self: *Cli, path: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(self.init.io, path, self.arena, .limited(256 * 1024 * 1024));
    }

    fn fail(self: *Cli, comptime fmt: []const u8, args: anytype) !u8 {
        try self.stderr.interface.print("error: " ++ fmt ++ "\n", args);
        return 1;
    }

    fn nodes(self: *Cli) !udon.check.NodeSet {
        return udon.check.loadNodes(self.arena, node_list);
    }

    fn translate(self: *Cli, args: []const []const u8) !u8 {
        var input: ?[]const u8 = null;
        var output: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-o")) {
                i += 1;
                if (i == args.len) return self.fail("-o needs a path", .{});
                output = args[i];
            } else if (input == null) {
                input = args[i];
            } else return self.fail("unexpected argument '{s}'", .{args[i]});
        }
        const bytes = try self.read(input orelse return self.fail("translate needs an input file", .{}));
        var node_set = try self.nodes();
        var diagnostics: wasdon.Diagnostics = .init(self.arena);
        var text: Io.Writer.Allocating = .init(self.arena);
        wasdon.translateBytes(self.arena, bytes, &text.writer, .{ .nodes = &node_set, .diagnostics = &diagnostics }) catch |e|
            return self.fail("translation failed: {s}", .{@errorName(e)});

        const err = &self.stderr.interface;
        for (diagnostics.warnings.items) |w| try err.print("warning: {s}\n", .{w});
        try err.print("heap slots: {d}", .{diagnostics.heap_slots});
        if (diagnostics.heap_slots > default_heap_capacity)
            try err.print(" (above the default Udon heap of {d}: assemble with a larger heap, see docs/spec_heap_budget.md)", .{default_heap_capacity});
        try err.writeByte('\n');

        if (output) |path| {
            try Io.Dir.cwd().writeFile(self.init.io, .{ .sub_path = path, .data = text.written() });
        } else try self.stdout.interface.writeAll(text.written());
        return 0;
    }

    fn parse(self: *Cli, path: []const u8) !?udon.text.Program {
        var diag: udon.text.Diag = .{};
        return udon.text.parse(self.arena, try self.read(path), &diag) catch |e| switch (e) {
            error.Syntax => {
                try self.stderr.interface.print("{s}:{d}: syntax error: {s}\n", .{ path, diag.line, diag.msg });
                return null;
            },
            else => return e,
        };
    }

    fn check(self: *Cli, args: []const []const u8) !u8 {
        if (args.len != 1) return self.fail("check needs exactly one file", .{});
        const prog = try self.parse(args[0]) orelse return 1;
        var node_set = try self.nodes();
        const report = try udon.check.check(self.arena, &prog, .{ .nodes = &node_set });
        for (report.issues) |issue| try self.stderr.interface.print("{s}:{d}: {s}\n", .{ args[0], issue.line, issue.msg });
        try self.stdout.interface.print("{d} issue(s); heap slots: {d}; extern call sites: {d} ({d} distinct)\n", .{ report.issues.len, report.heap_slots, report.extern_calls, report.distinct_externs });
        return @intFromBool(!report.ok());
    }

    fn run(self: *Cli, args: []const []const u8) !u8 {
        if (args.len == 0) return self.fail("run needs a file", .{});
        const prog = try self.parse(args[0]) orelse return 1;
        var vm = try udon.Vm.init(self.arena, &prog);
        const events: []const []const u8 = if (args.len > 1) args[1..] else &.{"_start"};
        var status: u8 = 0;
        for (events) |event| {
            const logged = vm.log.items.len;
            vm.runEvent(event) catch |e| {
                try self.stderr.interface.print("{s}: {s}: {s}\n", .{ event, @errorName(e), vm.fault });
                status = 1;
            };
            try self.stdout.interface.writeAll(vm.log.items[logged..]);
            if (status != 0) break;
        }
        try self.stderr.interface.print("{d} instructions, {d} extern calls\n", .{ vm.steps, vm.extern_calls });
        return status;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var cli: Cli = .{ .init = init, .arena = arena };
    cli.stdout = .init(.stdout(), init.io, &cli.out_buf);
    cli.stderr = .init(.stderr(), init.io, &cli.err_buf);
    defer cli.stdout.interface.flush() catch {};
    defer cli.stderr.interface.flush() catch {};

    const commands = .{ .{ "translate", Cli.translate }, .{ "check", Cli.check }, .{ "run", Cli.run } };
    if (args.len >= 2) inline for (commands) |command| {
        if (std.mem.eql(u8, args[1], command[0])) return command[1](&cli, args[2..]);
    };
    try cli.stderr.interface.writeAll(usage);
    return 2;
}
