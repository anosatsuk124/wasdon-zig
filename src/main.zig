//! wasdon-zig CLI. The only place that touches stdio and the file system;
//! everything else is library code under `src/`.

const std = @import("std");
const Io = std.Io;

const wasdon_zig = @import("wasdon_zig");
const udon = wasdon_zig.udon;

const usage =
    \\Usage:
    \\  wasdon-zig translate <input.wasm> [-o <output.uasm>] [--mem-oob-diagnostics]
    \\      Translate a WebAssembly module to Udon Assembly (stdout without -o).
    \\  wasdon-zig check <program.uasm>
    \\      Validate Udon Assembly against the spec and the Udon node list, and
    \\      report the heap size it needs.
    \\  wasdon-zig run <program.uasm> [--events <list>] [--profile [N]] [--quiet] [--max-steps N]
    \\      Execute Udon Assembly in the bundled Udon VM emulator and print the
    \\      log output plus executed-instruction statistics. <list> is a comma
    \\      separated event sequence, each optionally repeated with *N, e.g.
    \\      "_start,_interact*3,_update*60" (default: "_start").
    \\
;

const Cli = struct {
    init: std.process.Init,
    arena: std.mem.Allocator,
    out_buf: [8192]u8 = undefined,
    err_buf: [2048]u8 = undefined,
    out: Io.File.Writer = undefined,
    err: Io.File.Writer = undefined,

    fn fail(self: *Cli, comptime fmt: []const u8, args: anytype) u8 {
        const w = &self.err.interface;
        w.print("error: " ++ fmt ++ "\n", args) catch {};
        w.flush() catch {};
        return 1;
    }
};

pub fn main(init: std.process.Init) !u8 {
    var cli: Cli = .{ .init = init, .arena = init.arena.allocator() };
    cli.out = .init(.stdout(), init.io, &cli.out_buf);
    cli.err = .init(.stderr(), init.io, &cli.err_buf);
    defer cli.out.interface.flush() catch {};

    const args = try init.minimal.args.toSlice(cli.arena);
    if (args.len < 2) return cli.fail("missing subcommand\n\n{s}", .{usage});
    const cmd = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, cmd, "translate")) return runTranslate(&cli, rest);
    if (std.mem.eql(u8, cmd, "run")) return runProgram(&cli, rest);
    if (std.mem.eql(u8, cmd, "check")) return runCheck(&cli, rest);
    return cli.fail("unknown subcommand '{s}'\n\n{s}", .{ cmd, usage });
}

fn readFile(cli: *Cli, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(cli.init.io, path, cli.arena, .limited(1 << 30));
}

fn runTranslate(cli: *Cli, args: []const []const u8) !u8 {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var options: wasdon_zig.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i == args.len) return cli.fail("-o requires a path", .{});
            output = args[i];
        } else if (std.mem.eql(u8, a, "--mem-oob-diagnostics")) {
            options.mem_oob_diagnostics = true;
        } else if (a.len > 0 and a[0] == '-') {
            return cli.fail("unknown option '{s}'", .{a});
        } else input = a;
    }
    const in_path = input orelse return cli.fail("translate requires an input path", .{});
    const wasm_bytes = readFile(cli, in_path) catch |e| return cli.fail("cannot read {s}: {t}", .{ in_path, e });

    // Translate fully before touching the output so a failure leaves no
    // half-written file behind.
    var text: Io.Writer.Allocating = .init(cli.arena);
    wasdon_zig.translateBytes(cli.arena, wasm_bytes, &text.writer, options) catch |e|
        return cli.fail("translation failed: {t}", .{e});
    if (output) |p| {
        try std.Io.Dir.cwd().writeFile(cli.init.io, .{ .sub_path = p, .data = text.written() });
    } else {
        try cli.out.interface.writeAll(text.written());
    }
    return 0;
}

fn loadProgram(cli: *Cli, path: []const u8) !?udon.program.Program {
    const text = readFile(cli, path) catch |e| {
        _ = cli.fail("cannot read {s}: {t}", .{ path, e });
        return null;
    };
    var diag: udon.program.Diagnostic = .{};
    return udon.program.parse(cli.arena, text, &diag) catch |e| switch (e) {
        error.SyntaxError => {
            _ = cli.fail("{s}:{d}: {s}", .{ path, diag.line, diag.message });
            return null;
        },
        else => |x| return x,
    };
}

fn runCheck(cli: *Cli, args: []const []const u8) !u8 {
    if (args.len != 1) return cli.fail("check requires exactly one .uasm path", .{});
    const prog = (try loadProgram(cli, args[0])) orelse return 1;
    const report = try udon.check.check(cli.arena, &prog);
    const w = &cli.out.interface;
    for (report.errors) |e| try w.print("{s}:{d}: {s}\n", .{ args[0], e.line, e.message });
    try w.print(
        \\{s}: {d} error(s)
        \\  heap slots     {d}  ({d} variables + {d} string literals; stock assembler heap is {d})
        \\  instructions   {d}  ({d} EXTERN, {d} distinct signatures)
        \\  code bytes     {d}
        \\
    , .{
        args[0],              report.errors.len,
        report.heap_size,     report.named_vars,
        report.heap_size - report.named_vars, udon.check.default_heap_size,
        report.instructions,  report.externs,
        report.unique_externs, report.code_bytes,
    });
    return @intFromBool(!report.ok());
}

const EventStep = struct { name: []const u8, count: u32 };

fn parseEvents(arena: std.mem.Allocator, spec: []const u8) ![]EventStep {
    var steps: std.ArrayList(EventStep) = .empty;
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |tok| {
        const star = std.mem.indexOfScalar(u8, tok, '*');
        const name = if (star) |s| tok[0..s] else tok;
        const count = if (star) |s| try std.fmt.parseInt(u32, tok[s + 1 ..], 10) else 1;
        try steps.append(arena, .{ .name = name, .count = count });
    }
    return steps.items;
}

fn runProgram(cli: *Cli, args: []const []const u8) !u8 {
    var input: ?[]const u8 = null;
    var events: []const u8 = "_start";
    var profile_top: ?usize = null;
    var quiet = false;
    var options: udon.vm.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--events")) {
            i += 1;
            if (i == args.len) return cli.fail("--events requires a list", .{});
            events = args[i];
        } else if (std.mem.eql(u8, a, "--max-steps")) {
            i += 1;
            if (i == args.len) return cli.fail("--max-steps requires a number", .{});
            options.max_steps = std.fmt.parseInt(u64, args[i], 10) catch return cli.fail("bad --max-steps", .{});
        } else if (std.mem.eql(u8, a, "--profile")) {
            profile_top = 15;
            if (i + 1 < args.len) if (std.fmt.parseInt(usize, args[i + 1], 10)) |n| {
                profile_top = n;
                i += 1;
            } else |_| {};
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (a.len > 0 and a[0] == '-') {
            return cli.fail("unknown option '{s}'", .{a});
        } else input = a;
    }
    const path = input orelse return cli.fail("run requires a .uasm path", .{});
    const steps = parseEvents(cli.arena, events) catch return cli.fail("bad --events list", .{});
    const prog = (try loadProgram(cli, path)) orelse return 1;
    for (prog.issues) |issue| return cli.fail("{s}:{d}: {s}", .{ path, issue.line, issue.message });

    const vm = try udon.vm.Vm.init(cli.arena, &prog, options);
    const w = &cli.out.interface;
    var printed: usize = 0;
    var status: u8 = 0;
    try w.print("{s}: heap {d} slots ({d} named), code {d} bytes\n", .{ path, prog.heapSize(), prog.named_count, prog.code_size });
    try w.print("{s:<14} {s:>6} {s:>14} {s:>12} {s:>12}\n", .{ "event", "runs", "instructions", "externs", "per run" });
    outer: for (steps) |step| {
        const before = vm.stats;
        var ran: u32 = 0;
        while (ran < step.count) : (ran += 1) {
            const is_update = std.mem.eql(u8, step.name, "_update");
            const found = (if (is_update) blk: {
                vm.tick() catch |e| break :blk e;
                break :blk true;
            } else vm.runEvent(step.name)) catch |e| {
                if (!quiet) for (vm.logs.items[printed..]) |l| try w.print("  [{t}] {s}\n", .{ l.level, l.text });
                const f = vm.fault orelse udon.vm.Fault{ .pc = 0, .message = "" };
                try w.flush();
                status = cli.fail("{s} halted at pc=0x{X:0>8}: {t}: {s}", .{ step.name, f.pc, e, f.message });
                break :outer;
            };
            if (!found) {
                try w.print("{s:<14} (not exported)\n", .{step.name});
                continue :outer;
            }
            if (!quiet) for (vm.logs.items[printed..]) |l| try w.print("  [{t}] {s}\n", .{ l.level, l.text });
            printed = vm.logs.items.len;
        }
        const d = vm.stats.sub(before);
        try w.print("{s:<14} {d:>6} {d:>14} {d:>12} {d:>12}\n", .{ step.name, step.count, d.instrs, d.externs, d.instrs / @max(step.count, 1) });
    }
    try w.print("{s:<14} {s:>6} {d:>14} {d:>12}\n", .{ "total", "", vm.stats.instrs, vm.stats.externs });
    if (profile_top) |top| {
        try w.writeAll("\nextern profile (executions):\n");
        for ((try vm.profile())[0..@min(top, vm.resolved.len)]) |r| {
            if (r.count == 0) break;
            try w.print("{d:>12}  {s}\n", .{ r.count, r.text });
        }
    }
    return status;
}

test "parseEvents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const steps = try parseEvents(arena.allocator(), "_start,_interact*3,_update*60");
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try std.testing.expectEqualStrings("_interact", steps[1].name);
    try std.testing.expectEqual(@as(u32, 60), steps[2].count);
}
