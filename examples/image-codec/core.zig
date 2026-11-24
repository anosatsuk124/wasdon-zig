//! QOI ("Quite OK Image") encoder and decoder, both incremental.
//!
//! The format is small enough to implement completely — every chunk type,
//! the running index, run lengths — and byte-oriented, which makes it a
//! fair test of what image decoding costs on the Udon VM. Decoding and
//! encoding are cut into steps of a chosen number of pixels so the caller
//! can spread the work over frames.
//!
//! Pixels are `u32`s holding RGBA in memory order (R in the low byte), the
//! layout Unity's RGBA32 textures use.

/// Every picture in this example is `side` x `side`.
pub const side = 48;
pub const pixel_count = side * side;
const header_len = 14;
const end_marker = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
/// Worst case: every pixel a five-byte RGBA chunk.
pub const max_encoded = header_len + pixel_count * 5 + end_marker.len;

const op_index = 0x00;
const op_diff = 0x40;
const op_luma = 0x80;
const op_run = 0xC0;
const op_rgb = 0xFE;
const op_rgba = 0xFF;
/// The pixel before the first one.
const start_pixel = 0xFF000000;

fn hash(px: u32) u32 {
    const r = px & 0xFF;
    const g = (px >> 8) & 0xFF;
    const b = (px >> 16) & 0xFF;
    const a = px >> 24;
    return (r * 3 + g * 5 + b * 7 + a * 11) & 63;
}

pub const Decoder = struct {
    data: []const u8 = &.{},
    pos: usize = 0,
    px: u32 = start_pixel,
    run: u32 = 0,
    index: [64]u32 = @splat(0),
    /// Pixels produced so far.
    count: usize = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub const Error = error{ BadHeader, Truncated };

    /// Parse the header. `data` must stay valid while decoding.
    pub fn begin(d: *Decoder, data: []const u8) Error!void {
        if (data.len < header_len + end_marker.len) return error.BadHeader;
        if (data[0] != 'q' or data[1] != 'o' or data[2] != 'i' or data[3] != 'f') return error.BadHeader;
        d.* = .{ .data = data, .pos = header_len, .width = be32(data[4..8]), .height = be32(data[8..12]) };
        if (d.width == 0 or d.height == 0) return error.BadHeader;
    }

    pub fn total(d: *const Decoder) usize {
        return d.width * d.height;
    }

    pub fn done(d: *const Decoder) bool {
        return d.count >= d.total();
    }

    /// Decode up to `budget` more pixels into `out`, which holds the whole
    /// image.
    pub fn step(d: *Decoder, out: []u32, budget: usize) Error!void {
        const stop = @min(d.total(), out.len, d.count + budget);
        // Chunks are at most five bytes; the end marker is eight. Checking
        // once per chunk against this bound covers every read below.
        const limit = d.data.len - end_marker.len;
        // Locals for the hot state: on Udon a local is free and a field in
        // memory costs an extern per access. That includes the slice being
        // read: after every store the compiler must assume `d.data` itself
        // may have changed and load it again.
        const data = d.data;
        var px = d.px;
        var run = d.run;
        var pos = d.pos;
        var at = d.count;
        defer {
            d.px = px;
            d.run = run;
            d.pos = pos;
            d.count = at;
        }
        while (at < stop) : (at += 1) {
            if (run != 0) {
                run -= 1;
            } else {
                if (pos >= limit) return error.Truncated;
                const b1: u32 = data[pos];
                pos += 1;
                if (b1 == op_rgb) {
                    px = (px & 0xFF000000) | data[pos] | @as(u32, data[pos + 1]) << 8 | @as(u32, data[pos + 2]) << 16;
                    pos += 3;
                } else if (b1 == op_rgba) {
                    px = data[pos] | @as(u32, data[pos + 1]) << 8 | @as(u32, data[pos + 2]) << 16 | @as(u32, data[pos + 3]) << 24;
                    pos += 4;
                } else switch (b1 & 0xC0) {
                    op_index => px = d.index[b1],
                    op_diff => px = shifted(px, (b1 >> 4 & 3) -% 2, (b1 >> 2 & 3) -% 2, (b1 & 3) -% 2),
                    op_luma => {
                        const b2: u32 = data[pos];
                        pos += 1;
                        const dg = (b1 & 0x3F) -% 32;
                        px = shifted(px, dg -% 8 +% (b2 >> 4), dg, dg -% 8 +% (b2 & 0x0F));
                    },
                    else => run = b1 & 0x3F,
                }
                d.index[hash(px)] = px;
            }
            out[at] = px;
        }
    }

    /// `px` with each colour channel moved by a (wrapping) difference.
    fn shifted(px: u32, dr: u32, dg: u32, db: u32) u32 {
        const r = (px +% dr) & 0xFF;
        const g = ((px >> 8) +% dg) & 0xFF;
        const b = ((px >> 16) +% db) & 0xFF;
        return (px & 0xFF000000) | r | g << 8 | b << 16;
    }
};

pub const Encoder = struct {
    out: []u8 = &.{},
    len: usize = 0,
    prev: u32 = start_pixel,
    run: u32 = 0,
    index: [64]u32 = @splat(0),
    /// Pixels consumed so far.
    count: usize = 0,
    pixel_total: usize = 0,
    finished: bool = false,

    /// Write the header. `out` needs room for the worst case
    /// (`14 + 5 * pixels + 8` bytes).
    pub fn begin(e: *Encoder, out: []u8, width: u32, height: u32) void {
        e.* = .{ .out = out, .pixel_total = width * height };
        const header = [header_len]u8{
            'q',                     'o',                     'i',                    'f',
            @truncate(width >> 24),  @truncate(width >> 16),  @truncate(width >> 8),  @truncate(width),
            @truncate(height >> 24), @truncate(height >> 16), @truncate(height >> 8), @truncate(height),
            4,                       0,
        };
        @memcpy(out[0..header_len], &header);
        e.len = header_len;
    }

    pub fn done(e: *const Encoder) bool {
        return e.finished;
    }

    pub fn bytes(e: *const Encoder) []const u8 {
        return e.out[0..e.len];
    }

    /// Encode up to `budget` more pixels; after the last one, the end
    /// marker.
    pub fn step(e: *Encoder, pixels: []const u32, budget: usize) void {
        if (e.finished) return;
        const stop = @min(e.pixel_total, pixels.len, e.count + budget);
        const out = e.out;
        var prev = e.prev;
        var run = e.run;
        var len = e.len;
        var at = e.count;
        while (at < stop) : (at += 1) {
            const px = pixels[at];
            if (px == prev) {
                run += 1;
                if (run == 62) {
                    out[len] = op_run | 61;
                    len += 1;
                    run = 0;
                }
                continue;
            }
            if (run != 0) {
                out[len] = @intCast(op_run | (run - 1));
                len += 1;
                run = 0;
            }
            const slot = hash(px);
            if (e.index[slot] == px) {
                out[len] = @intCast(op_index | slot);
                len += 1;
            } else {
                e.index[slot] = px;
                const r = px & 0xFF;
                const g = (px >> 8) & 0xFF;
                const b = (px >> 16) & 0xFF;
                if ((px ^ prev) >> 24 != 0) {
                    out[len] = op_rgba;
                    out[len + 1] = @intCast(r);
                    out[len + 2] = @intCast(g);
                    out[len + 3] = @intCast(b);
                    out[len + 4] = @intCast(px >> 24);
                    len += 5;
                } else {
                    // Channel differences as signed bytes.
                    const dr = signed8(r -% (prev & 0xFF));
                    const dg = signed8(g -% ((prev >> 8) & 0xFF));
                    const db = signed8(b -% ((prev >> 16) & 0xFF));
                    const dr_g = dr - dg;
                    const db_g = db - dg;
                    if (within(dr, 2) and within(dg, 2) and within(db, 2)) {
                        out[len] = @intCast(op_diff | (dr + 2) << 4 | (dg + 2) << 2 | (db + 2));
                        len += 1;
                    } else if (within(dg, 32) and within(dr_g, 8) and within(db_g, 8)) {
                        out[len] = @intCast(op_luma | (dg + 32));
                        out[len + 1] = @intCast((dr_g + 8) << 4 | (db_g + 8));
                        len += 2;
                    } else {
                        out[len] = op_rgb;
                        out[len + 1] = @intCast(r);
                        out[len + 2] = @intCast(g);
                        out[len + 3] = @intCast(b);
                        len += 4;
                    }
                }
            }
            prev = px;
        }
        if (at >= e.pixel_total) {
            if (run != 0) {
                out[len] = @intCast(op_run | (run - 1));
                len += 1;
                run = 0;
            }
            @memcpy(out[len..][0..end_marker.len], &end_marker);
            len += end_marker.len;
            e.finished = true;
        }
        e.prev = prev;
        e.run = run;
        e.len = len;
        e.count = at;
    }

    fn signed8(v: u32) i32 {
        return @as(i8, @bitCast(@as(u8, @truncate(v))));
    }

    /// `-bound <= v < bound`
    fn within(v: i32, bound: i32) bool {
        return v >= -bound and v < bound;
    }
};

fn be32(b: *const [4]u8) u32 {
    return @as(u32, b[0]) << 24 | @as(u32, b[1]) << 16 | @as(u32, b[2]) << 8 | b[3];
}

// ---------------------------------------------------------------------
//  The pictures
// ---------------------------------------------------------------------

/// A picture defined by a function of its coordinates and shipped as QOI
/// bytes encoded at compile time.
pub const Picture = struct {
    name: []const u8,
    paint: *const fn (x: u32, y: u32) u32,
    qoi: []const u8,
};

pub const pictures = [_]Picture{
    picture("badge", paintBadge),
    picture("tiles", paintTiles),
    picture("static", paintStatic),
};

fn picture(comptime name: []const u8, comptime paint: fn (u32, u32) u32) Picture {
    @setEvalBranchQuota(4_000_000);
    const encoded = comptime blk: {
        var pixels: [pixel_count]u32 = undefined;
        for (&pixels, 0..) |*p, i| p.* = paint(i % side, i / side);
        var buf: [max_encoded]u8 = undefined;
        var e: Encoder = .{};
        e.begin(&buf, side, side);
        e.step(&pixels, pixel_count);
        const final = buf[0..e.len].*;
        break :blk final;
    };
    return .{ .name = name, .paint = paint, .qoi = &encoded };
}

fn rgba(r: u32, g: u32, b: u32, a: u32) u32 {
    return (r & 0xFF) | (g & 0xFF) << 8 | (b & 0xFF) << 16 | a << 24;
}

/// Concentric rings over a soft diagonal gradient: long runs, small
/// differences.
fn paintBadge(x: u32, y: u32) u32 {
    const dx = @as(i32, @intCast(x)) - side / 2;
    const dy = @as(i32, @intCast(y)) - side / 2;
    const d2: u32 = @intCast(dx * dx + dy * dy);
    if (d2 < 36) return rgba(250, 240, 120, 255);
    if (d2 < 400) {
        const ring = (d2 / 60) & 1;
        return if (ring == 0) rgba(200, 40 + d2 / 4, 60, 255) else rgba(30, 60, 160 + d2 / 8, 255);
    }
    return rgba(20 + x, 24 + y, 40 + (x + y) / 2, 255);
}

/// Flat tiles in a repeating order with a translucent band: index lookups
/// and alpha changes.
fn paintTiles(x: u32, y: u32) u32 {
    const palette = [_]u32{
        rgba(230, 70, 60, 255),  rgba(60, 170, 90, 255), rgba(70, 110, 220, 255),
        rgba(240, 200, 60, 255), rgba(40, 40, 48, 255),
    };
    const tile = (x / 6 + (y / 6) * 3) % palette.len;
    var px = palette[tile];
    if (y % 12 == 5) px = (px & 0x00FFFFFF) | 0x80000000;
    if ((x + y) % 24 == 0) px = rgba(255, 255, 255, 255);
    return px;
}

/// Hash noise on the left, a ramp on the right: the worst case for the
/// codec next to an easy one.
fn paintStatic(x: u32, y: u32) u32 {
    if (x >= side / 2) return rgba(x * 5, x * 5, x * 5 + y, 255);
    var h = x *% 374761393 +% y *% 668265263;
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return h | 0xFF000000;
}

// ---------------------------------------------------------------------
//  The demo: decode a picture, encode it again, compare
// ---------------------------------------------------------------------

pub const Session = struct {
    pub const Phase = enum(u8) { idle, decoding, encoding, verified, mismatch, failed };

    // Every default is zero or undefined so that a static `Session` lives
    // in zero-initialized memory instead of being shipped (and decoded at
    // startup) as 20 kB of data segment.
    phase: Phase = .idle,
    picture: usize = 0,
    pixels: [pixel_count]u32 = undefined,
    encoded: [max_encoded]u8 = undefined,
    decoder: Decoder = undefined,
    encoder: Encoder = undefined,

    pub fn begin(s: *Session, index: usize) void {
        s.picture = index % pictures.len;
        // Pixels not yet decoded show as transparent black.
        @memset(&s.pixels, 0);
        s.decoder.begin(pictures[s.picture].qoi) catch {
            s.phase = .failed;
            return;
        };
        s.phase = .decoding;
    }

    /// True while there is work left.
    pub fn busy(s: *const Session) bool {
        return s.phase == .decoding or s.phase == .encoding;
    }

    pub fn pixelBytes(s: *const Session) []const u8 {
        return @as([*]const u8, @ptrCast(&s.pixels))[0 .. pixel_count * 4];
    }

    /// Advance by up to `budget` pixels. Returns true when the phase
    /// changed.
    pub fn step(s: *Session, budget: usize) bool {
        switch (s.phase) {
            .decoding => {
                s.decoder.step(&s.pixels, budget) catch {
                    s.phase = .failed;
                    return true;
                };
                if (!s.decoder.done()) return false;
                s.encoder.begin(&s.encoded, s.decoder.width, s.decoder.height);
                s.phase = .encoding;
                return true;
            },
            .encoding => {
                s.encoder.step(&s.pixels, budget);
                if (!s.encoder.done()) return false;
                s.phase = if (equal(s.encoder.bytes(), pictures[s.picture].qoi)) .verified else .mismatch;
                return true;
            },
            else => return false,
        }
    }

    fn equal(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (x != y) return false;
        return true;
    }
};

// ------------------------------- tests -------------------------------

const std = @import("std");

test "decoding a picture gives the painted pixels; encoding gives the file back" {
    for (pictures, 0..) |pic, n| {
        var s: Session = .{};
        s.begin(n);
        var steps: usize = 0;
        while (s.busy()) : (steps += 1) _ = s.step(100);
        try std.testing.expectEqual(Session.Phase.verified, s.phase);
        for (s.pixels, 0..) |px, i| try std.testing.expectEqual(pic.paint(@intCast(i % side), @intCast(i / side)), px);
        try std.testing.expectEqualSlices(u8, pic.qoi, s.encoder.bytes());
        // 2304 pixels at 100 per step, twice.
        try std.testing.expectEqual(@as(usize, 48), steps);
    }
}

test "the pictures exercise every chunk type" {
    var seen = [_]bool{false} ** 6;
    for (pictures) |pic| {
        var pos: usize = header_len;
        while (pos < pic.qoi.len - end_marker.len) {
            const b = pic.qoi[pos];
            const kind: usize, const size: usize = if (b == op_rgb) .{ 0, 4 } else if (b == op_rgba) .{ 1, 5 } else switch (b & 0xC0) {
                op_index => .{ 2, 1 },
                op_diff => .{ 3, 1 },
                op_luma => .{ 4, 2 },
                else => .{ 5, 1 },
            };
            seen[kind] = true;
            pos += size;
        }
        try std.testing.expectEqualSlices(u8, &end_marker, pic.qoi[pic.qoi.len - end_marker.len ..]);
    }
    for (seen) |s| try std.testing.expect(s);
}

test "compression: flat pictures shrink, noise does not" {
    const raw = pixel_count * 4;
    try std.testing.expect(pictures[0].qoi.len < raw / 2);
    try std.testing.expect(pictures[1].qoi.len < raw / 4);
    try std.testing.expect(pictures[2].qoi.len > raw / 2);
}

test "a truncated or foreign file is rejected" {
    var d: Decoder = .{};
    try std.testing.expectError(error.BadHeader, d.begin("not a qoi file, but long enough"));
    const whole = pictures[2].qoi;
    try d.begin(whole[0 .. whole.len / 2]);
    var out: [pixel_count]u32 = undefined;
    try std.testing.expectError(error.Truncated, d.step(&out, pixel_count));
}

test "run lengths longer than one chunk" {
    var pixels = [_]u32{0xFF112233} ** 200;
    pixels[199] = 0xFF112234;
    var buf: [14 + 200 * 5 + 8]u8 = undefined;
    var e: Encoder = .{};
    e.begin(&buf, 20, 10);
    e.step(&pixels, 200);
    try std.testing.expect(e.done());
    var d: Decoder = .{};
    try d.begin(e.bytes());
    var out: [200]u32 = undefined;
    try d.step(&out, 200);
    try std.testing.expectEqualSlices(u32, &pixels, &out);
}
