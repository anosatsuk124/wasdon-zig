//! WASM test bench.
const std = @import("std");

extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;

fn log(s: []const u8) void {
    @"UnityEngineDebug.__Log__SystemString__SystemVoid"(s.ptr, s.len);
}

var fmt_buf: [512]u8 = undefined;

fn logf(comptime format: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&fmt_buf, format, args) catch return;
    log(s);
}

export var counter: i32 = 0;
export var accum: i64 = 0;
export var update_tick: i32 = 0;

var scratch: [256]u32 = [_]u32{0} ** 256;

const udon_meta_json =
    \\{
    \\  "version": 1,
    \\  "behaviour": { "syncMode": "manual" },
    \\  "functions": {
    \\    "start":    { "source": {"kind":"export","name":"on_start"},    "label":"_start",    "export": true, "event":"Start"    },
    \\    "update":   { "source": {"kind":"export","name":"on_update"},   "label":"_update",   "export": true, "event":"Update"   },
    \\    "interact": { "source": {"kind":"export","name":"on_interact"}, "label":"_interact", "export": true, "event":"Interact" }
    \\  },
    \\  "fields": {
    \\    "counter":     { "source": {"kind":"global","name":"counter"},     "udonName":"_counter",     "type":"int",  "export": true },
    \\    "accum":       { "source": {"kind":"global","name":"accum"},       "udonName":"_accum",       "type":"int" },
    \\    "update_tick": { "source": {"kind":"global","name":"update_tick"}, "udonName":"_updateTick",  "type":"int" }
    \\  },
    \\  "options": {
    \\    "strict": false,
    \\    "recursion": "stack",
    \\    "memory": { "initialPages": 1, "maxPages": 24, "udonName": "_memory" }
    \\  }
    \\}
;

export fn __udon_meta_ptr() [*]const u8 {
    return udon_meta_json.ptr;
}

export fn __udon_meta_len() u32 {
    return @intCast(udon_meta_json.len);
}

fn test_arithmetic() void {
    log("== arithmetic ==");
    logf("1 + 2 = {d}", .{1 + 2});
    logf("100 * 200 = {d}", .{100 * 200});
    logf("-50 / 7 = {d}", .{@divTrunc(@as(i32, -50), 7)});
    logf("17 % 5 = {d}", .{@mod(@as(i32, 17), 5)});
    logf("1 << 10 = {d}", .{@as(i32, 1) << 10});
    logf("0x7F00 | 0x00FF = 0x{x}", .{@as(u32, 0x7F00) | 0x00FF});
    logf("0xABCD ^ 0x00FF = 0x{x}", .{@as(u32, 0xABCD) ^ 0x00FF});
}

fn test_control_flow() void {
    log("== control_flow ==");

    var i: i32 = 0;
    while (i < 5) : (i += 1) logf("i = {d}", .{i});

    const x: i32 = 7;
    if (x > 5) log("x > 5") else log("x <= 5");

    const tag: i32 = 2;
    switch (tag) {
        0 => log("tag=0"),
        1 => log("tag=1"),
        2 => log("tag=2"),
        3 => log("tag=3"),
        else => log("tag=other"),
    }

    var sum: i32 = 0;
    var j: i32 = 1;
    while (j <= 10) : (j += 1) {
        if (@mod(j, 2) == 0) continue;
        sum += j;
    }
    logf("sum of odd 1..10 = {d}", .{sum}); // 25
}

fn test_globals() void {
    log("== globals ==");
    counter = 0;
    var i: i32 = 0;
    while (i < 4) : (i += 1) counter += i;
    logf("counter = {d}", .{counter}); // 6

    accum = 0;
    var k: i64 = 1;
    while (k <= 5) : (k += 1) accum += k;
    logf("accum = {d}", .{accum}); // 15
}

fn factorial(n: i32) i32 {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}

fn fib(n: i32) i32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn test_recursion() void {
    log("== recursion ==");
    logf("factorial(5) = {d}", .{factorial(5)}); // 120
    logf("fib(10) = {d}", .{fib(10)}); // 55
}

fn test_memory() void {
    log("== memory ==");

    scratch[0] = 0xDEADBEEF;
    scratch[1] = 42;
    logf("scratch[0] = 0x{x}", .{scratch[0]}); // DEADBEEF
    logf("scratch[1] = {d}", .{scratch[1]}); // 42

    const bytes: [*]u8 = @ptrCast(&scratch[0]);
    bytes[8] = 0x11;
    bytes[9] = 0x22;
    bytes[10] = 0x33;
    bytes[11] = 0x44;
    logf("scratch[2] (LE byte assemble) = 0x{x}", .{scratch[2]}); // 44332211

    const before: i32 = @intCast(@wasmMemorySize(0));
    const grew: i32 = @wasmMemoryGrow(0, 1);
    const after: i32 = @intCast(@wasmMemorySize(0));
    logf("memory.size before = {d} pages", .{before});
    logf("memory.grow returned = {d}", .{grew});
    logf("memory.size after  = {d} pages", .{after});
}

fn double_it(x: i32) i32 {
    return x * 2;
}

fn negate_it(x: i32) i32 {
    return -x;
}

fn add_one(x: i32) i32 {
    return x + 1;
}

const FnPtr = *const fn (i32) i32;
const ops = [_]FnPtr{ &double_it, &negate_it, &add_one };

fn test_indirect_call() void {
    log("== call_indirect ==");
    logf("double_it(21) = {d}", .{ops[0](21)}); // 42
    logf("negate_it(7) = {d}", .{ops[1](7)}); // -7
    logf("add_one(99) = {d}", .{ops[2](99)}); // 100
}

const Point = struct {
    x: i32,
    y: i32,
};

const Rect = struct {
    tl: Point,
    br: Point,
    tag: i32,
};

fn point_area(p: Point) i32 {
    return p.x * p.y;
}

fn point_translate(p: *Point, dx: i32, dy: i32) void {
    p.x += dx;
    p.y += dy;
}

fn rect_width(r: *const Rect) i32 {
    return r.br.x - r.tl.x;
}

var g_rect: Rect = .{
    .tl = .{ .x = 1, .y = 2 },
    .br = .{ .x = 11, .y = 22 },
    .tag = 0x1234,
};

fn test_struct() void {
    log("== struct ==");

    const p: Point = .{ .x = 6, .y = 7 };
    logf("point_area({{6,7}}) = {d}", .{point_area(p)}); // 42

    var q: Point = .{ .x = 10, .y = 20 };
    point_translate(&q, 3, 4);
    logf("q after translate = ({d}, {d})", .{ q.x, q.y }); // (13, 24)

    logf("rect_width(g_rect) = {d}", .{rect_width(&g_rect)}); // 10
    logf("g_rect.tag = 0x{x}", .{g_rect.tag}); // 1234

    g_rect.tag += 1;
    logf("g_rect.tag after inc = 0x{x}", .{g_rect.tag}); // 1235

    var points: [3]Point = .{
        .{ .x = 1, .y = 1 },
        .{ .x = 2, .y = 4 },
        .{ .x = 3, .y = 9 },
    };
    var sum: i32 = 0;
    var i: usize = 0;
    while (i < points.len) : (i += 1) sum += point_area(points[i]);
    logf("sum of areas = {d}", .{sum}); // 1 + 8 + 27 = 36

    point_translate(&points[1], 100, 200);
    logf("points[1] after translate = ({d}, {d})", .{ points[1].x, points[1].y }); // (102, 204)
}

fn test_64bit_and_float() void {
    log("== 64bit_and_float ==");
    const a: i64 = 0x1_0000_0000;
    const b: i64 = 5;
    const r = a + b;
    logf("(0x100000000 + 5) hi32 = {d}", .{@as(i32, @intCast(r >> 32))}); // 1
    logf("(0x100000000 + 5) lo32 = {d}", .{@as(i32, @intCast(r & 0xFFFFFFFF))}); // 5

    const x: f64 = 3.14;
    const y: f64 = 2.0;
    const m = x * y; // 6.28
    logf("3.14 * 2.0 = {d}", .{m});
    logf("floor(m * 100) = {d}", .{@as(i32, @intFromFloat(@floor(m * 100.0)))}); // 628
}

export fn on_start() void {
    // Stay within Udon's 10 s per-event VM budget; heavier tests run one
    // per click via `on_interact`.
    log("=== on_start begin ===");

    test_nofmt_simple();

    test_manual_fastpath();
    test_wl_slice_write();

    test_real_logf();

    log("=== on_start end ===");
}

export fn on_update() void {
    update_tick += 1;
    _ = counter;
}

var interact_step: i32 = 0;

fn test_nofmt_simple() void {
    log("-- nofmt_simple --");
    log("literal one");
    log("literal two");
    log("literal three");
    log("nofmt_simple done");
}

fn test_fmt_single() void {
    log("-- fmt_single --");
    logf("plain: {s}", .{"hi"});
    log("fmt_single done");
}

var int_log_buf: [16]u8 = undefined;

fn int_to_ascii(value: i32) []const u8 {
    var v: u32 = if (value < 0) @intCast(-@as(i64, value)) else @intCast(value);
    var i: usize = int_log_buf.len;
    if (v == 0) {
        i -= 1;
        int_log_buf[i] = '0';
    }
    while (v != 0) {
        i -= 1;
        int_log_buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    if (value < 0) {
        i -= 1;
        int_log_buf[i] = '-';
    }
    return int_log_buf[i..];
}

fn test_fmt_int_hand() void {
    log("-- fmt_int_hand --");
    log(int_to_ascii(42));
    log(int_to_ascii(-7));
    log(int_to_ascii(0));
    log("fmt_int_hand done");
}

var fast_buf: [512]u8 = undefined;
var fast_end: u32 = 0;

fn write_fast(bytes: []const u8) void {
    if (fast_end + bytes.len <= fast_buf.len) {
        var i: u32 = 0;
        const n: u32 = @intCast(bytes.len);
        while (i < n) : (i += 1) {
            fast_buf[fast_end + i] = bytes[i];
        }
        fast_end += n;
        return;
    }
    log("FAST PATH FAILED");
}

fn test_manual_fastpath() void {
    log("-- manual fastpath --");
    fast_end = 0;
    write_fast("plain: ");
    write_fast("hi");
    log(fast_buf[0..fast_end]);
    log("manual fastpath done");
}

fn test_memcpy_direct() void {
    log("-- memcpy direct --");
    const src = "abcdefg";
    @memcpy(fast_buf[0..src.len], src);
    log(fast_buf[0..src.len]);
    log("memcpy direct done");
}

// Same memory layout as `std.Io.Writer`:
// vtable: *const VTable @0, buffer: []u8 @4..11, end: usize @12.
const WriterLike = struct {
    vtable: u32,
    buf_ptr: u32,
    buf_len: u32,
    end: u32,
};

fn wl_write(w: *WriterLike, bytes: []const u8) void {
    if (w.end + bytes.len <= w.buf_len) {
        var i: u32 = 0;
        const n: u32 = @intCast(bytes.len);
        while (i < n) : (i += 1) {
            fast_buf[w.end + i] = bytes[i];
        }
        w.end += n;
        return;
    }
    log("WL FAST PATH FAILED");
}

fn test_writer_like_struct() void {
    log("-- writer-like struct --");
    var w = WriterLike{ .vtable = 0, .buf_ptr = 0, .buf_len = 512, .end = 0 };
    wl_write(&w, "plain: ");
    wl_write(&w, "hi");
    log(fast_buf[0..w.end]);
    log("writer-like done");
}

const WlVTable = struct {
    trivial: *const fn (*WriterLike) u32,
};

fn wl_trivial_impl(w: *WriterLike) u32 {
    return w.buf_len;
}

const wl_vtable_impl = WlVTable{ .trivial = wl_trivial_impl };

fn test_vtable_indirect() void {
    log("-- vtable indirect --");
    var w = WriterLike{ .vtable = 0, .buf_ptr = 0, .buf_len = 321, .end = 0 };
    const result = wl_vtable_impl.trivial(&w);
    log(int_to_ascii(@intCast(result))); // 321
    log("vtable indirect done");
}

// Embeds a `buffer: []u8` slice field like `std.Io.Writer` does.
const WlWithSlice = struct {
    vtable: u32,
    buffer: []u8,
    end: u32,
};

fn wl_slice_write(w: *WlWithSlice, bytes: []const u8) void {
    if (w.end + bytes.len <= w.buffer.len) {
        var i: u32 = 0;
        const n: u32 = @intCast(bytes.len);
        while (i < n) : (i += 1) {
            w.buffer[w.end + i] = bytes[i];
        }
        w.end += n;
        return;
    }
    log("WLS FAST PATH FAILED");
}

fn test_wl_slice_write() void {
    log("-- wl slice write --");
    var w = WlWithSlice{ .vtable = 0, .buffer = &fast_buf, .end = 0 };
    wl_slice_write(&w, "plain: ");
    wl_slice_write(&w, "hi");
    log(w.buffer[0..w.end]);
    log("wl slice write done");
}

fn wl_slice_memcpy(w: *WlWithSlice, bytes: []const u8) void {
    if (w.end + bytes.len <= w.buffer.len) {
        @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
        w.end += @intCast(bytes.len);
        return;
    }
    log("WLSM FAST PATH FAILED");
}

fn test_wl_slice_memcpy() void {
    log("-- wl slice memcpy --");
    var w = WlWithSlice{ .vtable = 0, .buffer = &fast_buf, .end = 0 };
    wl_slice_memcpy(&w, "plain: ");
    wl_slice_memcpy(&w, "hi");
    log(w.buffer[0..w.end]);
    log("wl slice memcpy done");
}

fn wl_slice_err(w: *WlWithSlice, bytes: []const u8) error{Failed}!u32 {
    if (w.end + bytes.len <= w.buffer.len) {
        @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
        w.end += @intCast(bytes.len);
        return @intCast(bytes.len);
    }
    return error.Failed;
}

fn test_wl_slice_err() void {
    log("-- wl slice err --");
    var w = WlWithSlice{ .vtable = 0, .buffer = &fast_buf, .end = 0 };
    _ = wl_slice_err(&w, "plain: ") catch {
        log("caught err on plain:");
        return;
    };
    _ = wl_slice_err(&w, "hi") catch {
        log("caught err on hi");
        return;
    };
    log(w.buffer[0..w.end]);
    log("wl slice err done");
}

fn test_real_logf_stage1_writer_init() void {
    log("-- stage1: Writer.fixed init only --");
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    _ = &w;
    log("stage1 done");
}

fn test_real_logf_stage2_bufprint_literal() void {
    log("-- stage2: bufPrint with literal only --");
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "abc", .{}) catch {
        log("stage2 bufPrint returned error");
        return;
    };
    log(s);
    log("stage2 done");
}

fn test_real_logf_stage3_bufprint_s() void {
    log("-- stage3: bufPrint with {s} --");
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "x={s}", .{"y"}) catch {
        log("stage3 bufPrint returned error");
        return;
    };
    log(s);
    log("stage3 done");
}

fn test_real_logf_stage4_bufprint_d() void {
    log("-- stage4: bufPrint with {d} --");
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "n={d}", .{@as(i32, 42)}) catch {
        log("stage4 bufPrint returned error");
        return;
    };
    log(s);
    log("stage4 done");
}

fn test_real_logf() void {
    log("-- real logf (staged) --");
    test_real_logf_stage1_writer_init();
    test_real_logf_stage2_bufprint_literal();
    test_real_logf_stage3_bufprint_s();
    test_real_logf_stage4_bufprint_d();
    log("real logf all stages done");
}

export fn on_interact() void {
    // One click = one step = one test. Each invocation gets its own 10 s
    // VM budget, so heavy tests finish as long as they run solo.
    const step = interact_step;
    interact_step +%= 1;
    switch (step) {
        0 => test_fmt_int_hand(),
        1 => test_memcpy_direct(),
        2 => test_writer_like_struct(),
        3 => test_vtable_indirect(),
        4 => test_wl_slice_memcpy(),
        5 => test_wl_slice_err(),
        6 => test_fmt_single(),
        7 => test_arithmetic(),
        8 => test_control_flow(),
        9 => test_globals(),
        10 => test_recursion(),
        11 => test_memory(),
        12 => test_indirect_call(),
        13 => test_struct(),
        14 => test_64bit_and_float(),
        else => log("(no more steps)"),
    }
    counter +%= 1;
}
