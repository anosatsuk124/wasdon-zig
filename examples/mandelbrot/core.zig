//! Escape-time Mandelbrot renderer into an RGBA32 pixel buffer.
//!
//! Rendering is incremental — `render(rows)` continues where the last call
//! stopped — so the caller can spread a frame over as many Udon events as it
//! takes. Everything here is plain arithmetic on linear memory; the Udon
//! side only uploads the finished rows.

pub const width = 64;
pub const height = 64;
pub const max_iter = 96;
/// Size of the pixel buffer in bytes.
pub const byte_len = width * height * 4;

/// Where the zoom sequence heads: a spiral in "seahorse valley".
const target_x = -0.743643887037151;
const target_y = 0.131825904205330;
const view_count = 16;

pub const State = struct {
    /// One `u32` per pixel, R in the low byte (RGBA32 in memory order). Row 0
    /// is the bottom of the image, as in a Unity texture.
    pixels: [width * height]u32 = undefined,
    palette: [max_iter + 1]u32 = undefined,
    /// Centre of the view and the width of the image in the complex plane.
    cx: f64 = 0,
    cy: f64 = 0,
    span: f64 = 0,
    view: u32 = 0,
    /// Next row to render; `height` when the frame is complete.
    row: u32 = 0,

    pub fn init(s: *State) void {
        for (&s.palette, 0..) |*p, i| p.* = color(@intCast(i));
        s.setView(0);
    }

    /// View 0 shows the whole set; each later view halves the width around
    /// the zoom target.
    pub fn setView(s: *State, n: u32) void {
        s.view = n % view_count;
        if (s.view == 0) {
            s.cx = -0.75;
            s.cy = 0;
            s.span = 3.0;
        } else {
            s.cx = target_x;
            s.cy = target_y;
            var span: f64 = 1.5;
            var k: u32 = 1;
            while (k < s.view) : (k += 1) span *= 0.5;
            s.span = span;
        }
        s.row = 0;
    }

    pub fn done(s: *const State) bool {
        return s.row >= height;
    }

    pub fn bytes(s: *const State) []const u8 {
        return @as([*]const u8, @ptrCast(&s.pixels))[0..byte_len];
    }

    /// Render up to `rows` more rows.
    pub fn render(s: *State, rows: u32) void {
        const step = s.span / width;
        const left = s.cx - step * (width / 2);
        var n = rows;
        while (n != 0 and s.row < height) : (n -= 1) {
            const ci = s.cy + step * @as(f64, @floatFromInt(@as(i32, @intCast(s.row)) - height / 2));
            const line = s.pixels[s.row * width ..][0..width];
            var cr = left;
            for (line) |*p| {
                p.* = s.palette[iterations(cr, ci)];
                cr += step;
            }
            s.row += 1;
        }
    }
};

/// Iterations before `c` escapes, or `max_iter` if it does not.
pub fn iterations(cr: f64, ci: f64) u32 {
    // The main cardioid and the period-2 bulb hold most of the points that
    // never escape; recognizing them skips the longest loops.
    const ci2 = ci * ci;
    const xq = cr - 0.25;
    const q = xq * xq + ci2;
    if (q * (q + xq) <= 0.25 * ci2) return max_iter;
    const xp = cr + 1.0;
    if (xp * xp + ci2 <= 0.0625) return max_iter;

    var x: f64 = 0;
    var y: f64 = 0;
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const x2 = x * x;
        const y2 = y * y;
        if (x2 + y2 > 4.0) break;
        y = (x + x) * y + ci;
        x = x2 - y2 + cr;
    }
    return i;
}

/// Palette entry for an iteration count: black inside the set, a cyclic
/// gradient outside.
fn color(i: u32) u32 {
    const alpha = 0xFF000000;
    if (i >= max_iter) return alpha;
    const t = i * 12;
    return alpha | wave(t) | wave(t + 170) << 8 | wave(t + 340) << 16;
}

/// Triangle wave with period 512 and range 0..255.
fn wave(t: u32) u32 {
    const p = t & 511;
    return if (p < 256) p else 511 - p;
}

const std = @import("std");

test "known points" {
    try std.testing.expectEqual(@as(u32, max_iter), iterations(0, 0));
    try std.testing.expectEqual(@as(u32, max_iter), iterations(-1, 0));
    // The centre of the period-3 bulb: inside, but found by iterating.
    try std.testing.expectEqual(@as(u32, max_iter), iterations(-0.1225611669, 0.7448617666));
    try std.testing.expectEqual(@as(u32, 1), iterations(2, 2));
    try std.testing.expectEqual(@as(u32, 3), iterations(1, 0));
}

test "the shortcuts agree with plain iteration" {
    // A point just inside the cardioid and one just outside it.
    try std.testing.expectEqual(@as(u32, max_iter), iterations(0.24, 0));
    try std.testing.expect(iterations(0.26, 0) < max_iter);
}

test "incremental rendering equals rendering at once" {
    var a: State = .{};
    var b: State = .{};
    a.init();
    b.init();
    a.render(height);
    while (!b.done()) b.render(3);
    try std.testing.expect(a.done());
    try std.testing.expectEqualSlices(u32, &a.pixels, &b.pixels);
    // The picture is not blank: the centre is inside, a corner outside.
    try std.testing.expectEqual(@as(u32, 0xFF000000), a.pixels[(height / 2) * width + width / 2]);
    try std.testing.expect(a.pixels[0] != 0xFF000000);
}

test "views wrap around" {
    var s: State = .{};
    s.init();
    s.setView(view_count + 2);
    try std.testing.expectEqual(@as(u32, 2), s.view);
    try std.testing.expectEqual(@as(f64, 0.75), s.span);
}
