//! The benchmark's five workloads in Zig — the same ones as
//! `../usharp/UdonBench.cs`, with the same inputs and the same results in
//! the same Udon variables.
//!
//! Each exported function is one workload and one Udon event.

const udon = @import("udon");

// Udon variables (see the metadata at the bottom).
extern "env" fn @"bench.fib_n"() i32;
extern "env" fn @"bench.set_fib"(v: i32) void;
extern "env" fn @"bench.set_mandel"(v: i32) void;
extern "env" fn @"bench.set_str"(v: i32) void;
extern "env" fn @"bench.tak_x"() i32;
extern "env" fn @"bench.tak_y"() i32;
extern "env" fn @"bench.tak_z"() i32;
extern "env" fn @"bench.set_tak"(v: i32) void;
extern "env" fn @"bench.ack_m"() i32;
extern "env" fn @"bench.ack_n"() i32;
extern "env" fn @"bench.set_ack"(v: i32) void;

fn fib(n: i32) i32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

export fn Fib() void {
    @"bench.set_fib"(fib(@"bench.fib_n"()));
}

/// Escape iterations summed over a 16 x 8 grid, in fixed point (scale
/// 1024). `*%` because the reference versions wrap rather than trap.
fn mandel() i32 {
    var total: i32 = 0;
    const h = 8;
    const w = 16;
    const max_iter = 24;
    var py: i32 = 0;
    while (py < h) : (py += 1) {
        var px: i32 = 0;
        while (px < w) : (px += 1) {
            const x0 = @divTrunc(px * 3072, w) - 2048;
            const y0 = @divTrunc(py * 2048, h) - 1024;
            var x: i32 = 0;
            var y: i32 = 0;
            var it: i32 = 0;
            while (it < max_iter) : (it += 1) {
                const xx = @divTrunc(x *% x, 1024);
                const yy = @divTrunc(y *% y, 1024);
                if (xx + yy > 4096) break;
                const xy = @divTrunc(x *% y, 1024);
                x = xx - yy + x0;
                y = 2 * xy + y0;
            }
            total += it;
        }
    }
    return total;
}

export fn Mandel() void {
    @"bench.set_mandel"(mandel());
}

/// "abc" appended 64 times, as a .NET string: U# builds it that way too.
export fn Str() void {
    var s = udon.str.from("");
    const abc = udon.str.from("abc");
    var i: u32 = 0;
    while (i < 64) : (i += 1) s = udon.str.concat(s, abc);
    @"bench.set_str"(@intCast(udon.str.len(s)));
}

/// The Takeuchi function ("tarai").
fn tak(x: i32, y: i32, z: i32) i32 {
    if (x <= y) return y;
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y));
}

export fn Tak() void {
    @"bench.set_tak"(tak(@"bench.tak_x"(), @"bench.tak_y"(), @"bench.tak_z"()));
}

/// The Ackermann function.
fn ack(m: i32, n: i32) i32 {
    if (m == 0) return n + 1;
    if (n == 0) return ack(m - 1, 1);
    return ack(m - 1, ack(m, n - 1));
}

export fn Ack() void {
    @"bench.set_ack"(ack(@"bench.ack_m"(), @"bench.ack_n"()));
}

comptime {
    udon.exportMeta(
        \\{
        \\  "version": 1,
        \\  "fields": {
        \\    "fibN":   { "source": {"kind":"import","name":"bench.fib_n"}, "udonName":"fibN", "type":"int", "export": true, "default": 20 },
        \\    "fib":    { "source": {"kind":"import","name":"bench.fib","setter":"bench.set_fib"}, "udonName":"fibResult", "type":"int", "export": true },
        \\    "mandel": { "source": {"kind":"import","name":"bench.mandel","setter":"bench.set_mandel"}, "udonName":"mandelResult", "type":"int", "export": true },
        \\    "str":    { "source": {"kind":"import","name":"bench.str","setter":"bench.set_str"}, "udonName":"strResult", "type":"int", "export": true },
        \\    "takX":   { "source": {"kind":"import","name":"bench.tak_x"}, "udonName":"takX", "type":"int", "export": true, "default": 8 },
        \\    "takY":   { "source": {"kind":"import","name":"bench.tak_y"}, "udonName":"takY", "type":"int", "export": true, "default": 4 },
        \\    "takZ":   { "source": {"kind":"import","name":"bench.tak_z"}, "udonName":"takZ", "type":"int", "export": true, "default": 0 },
        \\    "tak":    { "source": {"kind":"import","name":"bench.tak","setter":"bench.set_tak"}, "udonName":"takResult", "type":"int", "export": true },
        \\    "ackM":   { "source": {"kind":"import","name":"bench.ack_m"}, "udonName":"ackM", "type":"int", "export": true, "default": 3 },
        \\    "ackN":   { "source": {"kind":"import","name":"bench.ack_n"}, "udonName":"ackN", "type":"int", "export": true, "default": 4 },
        \\    "ack":    { "source": {"kind":"import","name":"bench.ack","setter":"bench.set_ack"}, "udonName":"ackResult", "type":"int", "export": true }
        \\  }
        \\}
    );
}
