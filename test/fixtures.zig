//! The example programs as test fixtures: their WASM binaries (built by
//! `build.zig` and imported by name), the event scenario each is exercised
//! with, and what running it must produce.
//!
//! Shared by the integration tests (`examples_test.zig`) and the statistics
//! tool (`stats.zig`), so the numbers that are tracked are measured on
//! exactly the runs that are verified.

const std = @import("std");
const wasdon = @import("wasdon_zig");
const build_options = @import("build_options");

const udon = wasdon.udon;
const Vm = udon.vm.Vm;

pub const Example = struct {
    name: []const u8,
    wasm: []const u8,
    /// Events to deliver, in `wasdon-zig run --events` syntax.
    scenario: []const u8,
    /// Expected `Debug.Log` output, one message per line.
    expected_log: ?[]const u8 = null,
    /// Prepare the emulated scene before the first event.
    setup: ?*const fn (*Vm) anyerror!void = null,
    /// Inspect the emulated scene after the last event.
    verify: ?*const fn (*Vm) anyerror!void = null,
};

const bench_scenario = "_start,_interact*16,_update*10";
const orbit_scenario = "_start,_update*100,_interact*2";

const zig_examples = [_]Example{
    .{
        .name = "wasm-bench",
        .wasm = @embedFile("wasm-bench.wasm"),
        .scenario = bench_scenario,
        .expected_log = @embedFile("expected/wasm-bench.log"),
    },
    .{
        .name = "udon-orbit",
        .wasm = @embedFile("udon-orbit.wasm"),
        .scenario = orbit_scenario,
        .expected_log = "udon-orbit: _start\nudon-orbit: cloned\nudon-orbit: cloned\n",
        .setup = orbitSetup,
        .verify = orbitVerify,
    },
    .{
        .name = "pi",
        .wasm = @embedFile("pi.wasm"),
        // 100 digits take 25 steps; the extra frames are idle.
        .scenario = "_start,_update*30",
        .expected_log = "pi: started\n" ++ @import("pi-core").reference_100 ++ "\n",
        .setup = piSetup,
        .verify = piVerify,
    },
    .{
        .name = "mandelbrot",
        .wasm = @embedFile("mandelbrot.wasm"),
        // 64 rows at 2 per frame: 32 frames per view.
        .scenario = "_start,_update*33,_interact,_update*33",
        .expected_log = "mandelbrot: started\nmandelbrot: view 0 done\nmandelbrot: view 1 done\n",
        .setup = rendererSetup,
        .verify = mandelbrotVerify,
    },
    .{
        .name = "image-codec",
        .wasm = @embedFile("image-codec.wasm"),
        // 2304 pixels at 96 per frame: 24 frames to decode, 24 to encode.
        .scenario = "_start,_update*50,_interact,_update*50",
        .expected_log = codecLog(),
        .setup = rendererSetup,
        .verify = codecVerify,
    },
    .{
        .name = "ragdoll",
        .wasm = @embedFile("ragdoll.wasm"),
        .scenario = std.fmt.comptimePrint("_start,_update*{d},_interact,_update*{d}", .{ ragdoll_frames[0], ragdoll_frames[1] }),
        .setup = ragdollSetup,
        .verify = ragdollVerify,
    },
};

fn piSetup(vm: *Vm) !void {
    const text = try vm.newObject("UnityEngineUIText");
    try std.testing.expect(vm.setVar("_display", .{ .object = text }));
}

fn piVerify(vm: *Vm) !void {
    const reference = @import("pi-core").reference_100;
    // The UI text ends up holding the digits.
    const text = vm.getVar("_display").?.object;
    try std.testing.expectEqualStrings(reference, text.get("text").?.string);
}

fn mandelbrotVerify(vm: *Vm) !void {
    const core = @import("mandelbrot-core");
    const gpa = std.heap.page_allocator;
    const texture = vm.getVar("_texture").?.object;
    try std.testing.expectEqual(@as(i32, core.width), texture.get("width").?.int32);
    try std.testing.expectEqual(@as(i32, core.height), texture.get("height").?.int32);

    // The scenario leaves view 1 fully rendered; the uploaded pixels must
    // be bit-identical to the same code compiled natively.
    const reference = try gpa.create(core.State);
    defer gpa.destroy(reference);
    reference.* = .{};
    reference.init();
    reference.setView(1);
    reference.render(core.height);
    try std.testing.expectEqualSlices(u8, reference.bytes(), texture.get("rawTextureData").?.array.bytes);

    // And the renderer shows that texture.
    const material = vm.getVar("_renderer").?.object.get("material").?.object;
    try std.testing.expectEqual(texture, material.get("mainTexture").?.object);
}

/// The scene every texture example needs: a renderer to show it on.
fn rendererSetup(vm: *Vm) !void {
    const renderer = try vm.newObject("UnityEngineMeshRenderer");
    try std.testing.expect(vm.setVar("_renderer", .{ .object = renderer }));
}

const codec = @import("image-codec-core");

fn codecLog() []const u8 {
    comptime {
        var text: []const u8 = "";
        for (codec.pictures[0..2]) |pic| {
            text = text ++ std.fmt.comptimePrint(
                "image-codec: {s} decoded, {d} bytes to {d}\nimage-codec: {s} encoded again, {d} bytes, identical\n",
                .{ pic.name, pic.qoi.len, codec.pixel_count * 4, pic.name, pic.qoi.len },
            );
        }
        return text;
    }
}

fn codecVerify(vm: *Vm) !void {
    // The texture holds the second picture, exactly as painted.
    const uploaded = vm.getVar("_texture").?.object.get("rawTextureData").?.array.bytes;
    try std.testing.expectEqual(@as(usize, codec.pixel_count * 4), uploaded.len);
    for (0..codec.pixel_count) |i| {
        const want = codec.pictures[1].paint(@intCast(i % codec.side), @intCast(i / codec.side));
        try std.testing.expectEqual(want, std.mem.readInt(u32, uploaded[i * 4 ..][0..4], .little));
    }
}

const ragdoll = @import("ragdoll-core");
const ragdoll_frames = [2]u32{ 150, 250 };

fn ragdollSetup(vm: *Vm) !void {
    const a = vm.arena.allocator();
    const joints = try vm.newObject("UnityEngineTransform");
    for (0..ragdoll.joint_count) |_| try joints.children.append(a, try vm.newObject("UnityEngineTransform"));
    try std.testing.expect(vm.setVar("_joints", .{ .object = joints }));
    try std.testing.expect(vm.setVar("_line", .{ .object = try vm.newObject("UnityEngineLineRenderer") }));
}

/// Replays the scenario on the natively compiled simulation: the Udon run
/// must have logged the same transitions and left every joint at exactly
/// the same coordinates.
fn ragdollVerify(vm: *Vm) !void {
    const names = [_][]const u8{ "idle", "walking", "down", "getting up" };
    var log: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer log.deinit();
    const w = &log.writer;

    var body: ragdoll.Body = .{};
    body.init(1);
    try w.print("ragdoll: {s}\n", .{names[@intFromEnum(body.mode)]});
    for (ragdoll_frames, 0..) |frames, part| {
        if (part == 1) {
            body.hit();
            try w.writeAll("ragdoll: hit\n");
        }
        for (0..frames) |_| {
            const before = body.mode;
            if (body.advance(vm.host.delta_time) and body.mode != before)
                try w.print("ragdoll: {s}\n", .{names[@intFromEnum(body.mode)]});
        }
    }
    // The scenario covers the whole story: walking, the fall, getting up.
    try std.testing.expect(std.mem.indexOf(u8, log.written(), "getting up\nragdoll: idle") != null);
    try std.testing.expectEqualStrings(log.written(), try vm.logText());

    const markers = vm.getVar("_joints").?.object.children.items;
    for (markers, body.pos) |marker, want| {
        const got = marker.get("localPosition").?.vec.v;
        for (want, got[0..3]) |x, y| try std.testing.expectEqual(@as(u32, @bitCast(x)), @as(u32, @bitCast(y)));
    }
    const points = vm.getVar("_line").?.object.get("positions").?.array;
    try std.testing.expectEqual(@as(u32, ragdoll.outline.len), points.len);
    for (points.values, ragdoll.outline) |point, joint| {
        for (body.pos[joint], point.vec.v[0..3]) |x, y| try std.testing.expectEqual(x, y);
    }
}

const rust_examples = if (build_options.with_rust) [_]Example{
    .{
        .name = "wasm-bench-rs",
        .wasm = @embedFile("wasm-bench-rs.wasm"),
        .scenario = bench_scenario,
        .expected_log = @embedFile("expected/wasm-bench-rs.log"),
    },
    .{
        .name = "wasm-bench-alloc-rs",
        .wasm = @embedFile("wasm-bench-alloc-rs.wasm"),
        .scenario = bench_scenario,
        .expected_log = @embedFile("expected/wasm-bench-alloc-rs.log"),
    },
    .{
        .name = "udon-orbit-rs",
        .wasm = @embedFile("udon-orbit-rs.wasm"),
        .scenario = orbit_scenario,
        .expected_log = "udon-orbit-rs: _start\nudon-orbit-rs: cloned\nudon-orbit-rs: cloned\n",
    },
} else [_]Example{};

pub const examples = zig_examples ++ rust_examples;

pub fn find(name: []const u8) ?Example {
    for (examples) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

// ---------------------------------------------------------------------
//  Running an example
// ---------------------------------------------------------------------

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    uasm: []const u8,
    /// Size of the translation as the translator reports it.
    size: wasdon.Stats,
    report: udon.check.Report,
    prog: *udon.program.Program,
    vm: *Vm,
    steps: []const udon.vm.EventStat,
    /// Set when the scenario stopped on a fault.
    fault: ?udon.vm.Fault = null,

    pub fn deinit(self: *Result) void {
        self.vm.deinit();
        self.report.deinit();
        self.prog.deinit();
        self.arena.deinit();
    }

    pub fn log(self: *Result) ![]const u8 {
        return self.vm.logText();
    }
};

/// Translate an example, check the output against the Udon Assembly rules,
/// and run its scenario in the emulator.
pub fn run(gpa: std.mem.Allocator, ex: Example, options: wasdon.Options) !Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var text: std.Io.Writer.Allocating = .init(a);
    const size = try wasdon.translateBytes(gpa, ex.wasm, &text.writer, options);
    const uasm = text.written();

    const prog = try a.create(udon.program.Program);
    prog.* = try udon.program.parse(gpa, uasm, null);
    errdefer prog.deinit();
    var report = try udon.check.check(gpa, prog);
    errdefer report.deinit();

    const vm = try Vm.init(gpa, prog, .{});
    errdefer vm.deinit();
    var result: Result = .{ .arena = arena, .uasm = uasm, .size = size, .report = report, .prog = prog, .vm = vm, .steps = &.{} };
    if (!report.ok()) return result;

    if (ex.setup) |f| try f(vm);
    var steps: std.ArrayList(udon.vm.EventStat) = .empty;
    vm.runScenario(ex.scenario, &steps) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => result.fault = vm.fault orelse .{ .pc = 0, .message = @errorName(e) },
    };
    result.steps = steps.items;
    return result;
}

// ---------------------------------------------------------------------
//  Scene setup and checks
// ---------------------------------------------------------------------

fn orbitSetup(vm: *Vm) !void {
    // An Inspector override: the default radius in the binary is 1.5.
    try std.testing.expect(vm.setVar("_radius", .{ .single = 2.0 }));
}

fn orbitVerify(vm: *Vm) !void {
    // 100 frames at 1/60 s and 2 rad/s put the phase at 10/3 rad; the
    // transform sits on a circle of the overridden radius around the origin.
    const pos = vm.host.transform.get("position").?.vec.v;
    const phase: f32 = 100.0 * (2.0 / 60.0);
    // The centre moves every frame (the example orbits around wherever it
    // currently is), so compare against the same accumulation.
    var x: f32 = 0;
    var z: f32 = 0;
    var p: f32 = 0;
    for (0..100) |_| {
        p += 2.0 * (1.0 / 60.0);
        x += 2.0 * @cos(p);
        z += 2.0 * @sin(p);
    }
    try std.testing.expectApproxEqAbs(phase, p, 1e-3);
    try std.testing.expectApproxEqAbs(x, pos[0], 1e-2);
    try std.testing.expectApproxEqAbs(z, pos[2], 1e-2);
    try std.testing.expectEqual(udon.vm.Value{ .int32 = 2 }, vm.getVar("_cloneCount").?);
    // Two clones were instantiated.
    var clones: usize = 0;
    for (vm.calls.items) |c| {
        if (std.mem.startsWith(u8, c.sig, "VRCInstantiate.")) clones += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), clones);
}
