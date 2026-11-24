//! wasdon-zig CLI. The only place that touches stdio and the file system;
//! everything else is library code under `src/`.

const std = @import("std");
const Io = std.Io;

const wasdon_zig = @import("wasdon_zig");
const udon = wasdon_zig.udon;

const usage =
    \\Usage:
    \\  wasdon-zig translate <input.wasm> [-o <output.uasm>] [--meta <file.json>] [--strict] [--stats]
    \\      Translate a WebAssembly module to Udon Assembly (stdout without -o).
    \\      A module built for WASI (wasm32-wasi, wasm32-wasip1) needs nothing
    \\      more. --meta reads __udon_meta from a JSON file instead of from the
    \\      module; --strict rejects imports that are not Udon externs; --stats
    \\      prints the size of the result, including the heap size it needs.
    \\  wasdon-zig inspect <input.wasm>
    \\      Report the module's size, its imports, and everything in it the
    \\      translator does not support — all of it, where `translate` stops
    \\      at the first.
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
    if (std.mem.eql(u8, cmd, "inspect")) return runInspect(&cli, rest);
    if (std.mem.eql(u8, cmd, "run")) return runProgram(&cli, rest);
    if (std.mem.eql(u8, cmd, "check")) return runCheck(&cli, rest);
    return cli.fail("unknown subcommand '{s}'\n\n{s}", .{ cmd, usage });
}

fn runInspect(cli: *Cli, args: []const []const u8) !u8 {
    if (args.len != 1) return cli.fail("inspect takes one WASM file", .{});
    const bytes = readFile(cli, args[0]) catch |e| return cli.fail("{s}: {t}", .{ args[0], e });
    const mod = wasdon_zig.wasm.parseModule(cli.arena, bytes) catch |e| return cli.fail("{s}: not a module this parser reads: {t}", .{ args[0], e });
    // Metadata that cannot be read is reported by `translate`; here it only
    // decides which imports count as bound.
    const meta = wasdon_zig.wasm.parseUdonMetaFromModule(cli.arena, mod) catch null;
    const census = try wasdon_zig.translator.inspect.census(cli.arena, mod, meta);
    const w = &cli.out.interface;
    try wasdon_zig.translator.inspect.report(&census, w);
    try w.flush();
    return @intFromBool(!census.translatable());
}

fn readFile(cli: *Cli, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(cli.init.io, path, cli.arena, .limited(1 << 30));
}

fn runTranslate(cli: *Cli, args: []const []const u8) !u8 {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var diagnostics: wasdon_zig.Diagnostics = .init(cli.arena);
    var options: wasdon_zig.Options = .{ .diagnostics = &diagnostics };
    var show_stats = false;
    var meta_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i == args.len) return cli.fail("-o requires a path", .{});
            output = args[i];
        } else if (std.mem.eql(u8, a, "--meta")) {
            i += 1;
            if (i == args.len) return cli.fail("--meta requires a path", .{});
            meta_path = args[i];
        } else if (std.mem.eql(u8, a, "--strict")) {
            options.strict = true;
        } else if (std.mem.eql(u8, a, "--stats")) {
            show_stats = true;
        } else if (a.len > 0 and a[0] == '-') {
            return cli.fail("unknown option '{s}'", .{a});
        } else input = a;
    }
    const in_path = input orelse return cli.fail("translate requires an input path", .{});
    const wasm_bytes = readFile(cli, in_path) catch |e| return cli.fail("cannot read {s}: {t}", .{ in_path, e });

    // Translate fully before touching the output so a failure leaves no
    // half-written file behind.
    const meta_json: ?[]const u8 = if (meta_path) |p| readFile(cli, p) catch |e| return cli.fail("cannot read {s}: {t}", .{ p, e }) else null;
    var text: Io.Writer.Allocating = .init(cli.arena);
    const stats = wasdon_zig.translateWithMeta(cli.arena, wasm_bytes, meta_json, &text.writer, options) catch |e|
        return cli.fail("{s}: {t}{s}{s}", .{ in_path, e, if (diagnostics.message.len != 0) ": " else "", diagnostics.message });
    const err = &cli.err.interface;
    for (diagnostics.warnings.items) |w| try err.print("warning: {s}\n", .{w});
    if (show_stats) try err.print(
        "{s}: heap {d} slots ({d} variables + {d} extern signatures), {d} instructions ({d} externs), {d} code bytes\n",
        .{ in_path, stats.heapSize(), stats.vars, stats.unique_externs, stats.instructions, stats.externs, stats.code_bytes },
    );
    try err.flush();
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
        \\  heap slots     {d}  ({d} variables + {d} string literals; the stock assembler heap is {d})
        \\  instructions   {d}  ({d} EXTERN, {d} distinct signatures)
        \\  code bytes     {d}
        \\
    , .{
        args[0],                              report.errors.len,
        report.heap_size,                     report.named_vars,
        report.heap_size - report.named_vars, udon.check.default_heap_size,
        report.instructions,                  report.externs,
        report.unique_externs,                report.code_bytes,
    });
    return @intFromBool(!report.ok());
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
    const prog = (try loadProgram(cli, path)) orelse return 1;
    for (prog.issues) |issue| return cli.fail("{s}:{d}: {s}", .{ path, issue.line, issue.message });

    const vm = try udon.vm.Vm.init(cli.arena, &prog, options);
    const w = &cli.out.interface;
    var steps: std.ArrayList(udon.vm.EventStat) = .empty;
    const outcome = vm.runScenario(events, &steps);
    if (!quiet) for (vm.logs.items) |l| try w.print("[{t}] {s}\n", .{ l.level, l.text });
    try w.print("{s}: heap {d} slots ({d} named), code {d} bytes\n", .{ path, prog.heapSize(), prog.named_count, prog.code_size });
    try w.print("{s:<16} {s:>6} {s:>14} {s:>12} {s:>12}\n", .{ "event", "runs", "instructions", "externs", "per run" });
    for (steps.items) |st| {
        if (!st.found) {
            try w.print("{s:<16} (not exported)\n", .{st.name});
            continue;
        }
        try w.print("{s:<16} {d:>6} {d:>14} {d:>12} {d:>12}\n", .{ st.name, st.runs, st.stats.instrs, st.stats.externs, st.stats.instrs / @max(st.runs, 1) });
    }
    try w.print("{s:<16} {s:>6} {d:>14} {d:>12}\n", .{ "total", "", vm.stats.instrs, vm.stats.externs });
    var status: u8 = 0;
    outcome catch |e| {
        const f = vm.fault orelse udon.vm.Fault{ .pc = 0, .message = "" };
        try w.flush();
        status = cli.fail("halted at pc=0x{X:0>8}: {t}: {s}", .{ f.pc, e, f.message });
    };
    if (profile_top) |top| {
        try w.writeAll("\nextern profile (executions):\n");
        for ((try vm.profile())[0..@min(top, vm.resolved.len)]) |r| {
            if (r.count == 0) break;
            try w.print("{d:>12}  {s}\n", .{ r.count, r.text });
        }
    }
    return status;
}
