//! Image encoding and decoding: the QOI ("Quite OK Image") format.
//!
//! `_start` paints a procedural RGBA image, encodes it, decodes the result
//! and verifies the round trip. `_interact` repeats with the next frame of
//! the animation. The encoded stream can be handed to any extern as a
//! `byte[]` through `udon.bytes.new`.

const udon = @import("udon");

const width = 48;
const height = 32;
const channels = 4;

const Pixel = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    fn eql(x: Pixel, y: Pixel) bool {
        return @as(u32, @bitCast(x)) == @as(u32, @bitCast(y));
    }
    fn index(p: Pixel) usize {
        return (@as(usize, p.r) * 3 + @as(usize, p.g) * 5 + @as(usize, p.b) * 7 + @as(usize, p.a) * 11) % 64;
    }
};

var image: [width * height]Pixel = undefined;
var decoded: [width * height]Pixel = undefined;
var stream: [width * height * (channels + 1) + 14 + 8]u8 = undefined;
var frame: u32 = 0;

fn paint() void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const p = &image[y * width + x];
            if (y < 8) {
                // Flat bands: long runs.
                p.* = .{ .r = @intCast((frame * 40) & 0xFF), .g = 64, .b = 200 };
            } else if (y < 16) {
                // Smooth gradient: small differences.
                p.* = .{ .r = @intCast(x * 2 + frame), .g = @intCast(x * 3), .b = @intCast(y * 4 + x) };
            } else if (y < 24) {
                // Checkerboard of two colours: index hits.
                const on = ((x >> 2) ^ (y >> 2) ^ frame) & 1 == 1;
                p.* = if (on) .{ .r = 250, .g = 250, .b = 10 } else .{ .r = 10, .g = 20, .b = 30, .a = 128 };
            } else {
                // Noise: literal pixels.
                var h = (x *% 0x9E3779B1) ^ (y *% 0x85EBCA6B) ^ (frame *% 0xC2B2AE35);
                h ^= h >> 15;
                h *%= 0x2C1B3C6D;
                h ^= h >> 12;
                p.* = .{ .r = @truncate(h), .g = @truncate(h >> 8), .b = @truncate(h >> 16), .a = if (h >> 31 == 0) 255 else @truncate(h >> 24) };
            }
        }
    }
}

fn put32(out: []u8, v: u32) void {
    out[0] = @truncate(v >> 24);
    out[1] = @truncate(v >> 16);
    out[2] = @truncate(v >> 8);
    out[3] = @truncate(v);
}

fn encode() usize {
    var seen: [64]Pixel = @splat(.{ .a = 0 });
    @memcpy(stream[0..4], "qoif");
    put32(stream[4..8], width);
    put32(stream[8..12], height);
    stream[12] = channels;
    stream[13] = 0;
    var n: usize = 14;
    var prev: Pixel = .{};
    var run: u8 = 0;
    for (image, 0..) |px, i| {
        if (px.eql(prev)) {
            run += 1;
            if (run == 62 or i == image.len - 1) {
                stream[n] = 0xC0 | (run - 1);
                n += 1;
                run = 0;
            }
            continue;
        }
        if (run > 0) {
            stream[n] = 0xC0 | (run - 1);
            n += 1;
            run = 0;
        }
        const slot = px.index();
        if (seen[slot].eql(px)) {
            stream[n] = @intCast(slot);
            n += 1;
        } else {
            seen[slot] = px;
            if (px.a == prev.a) {
                const dr = px.r -% prev.r;
                const dg = px.g -% prev.g;
                const db = px.b -% prev.b;
                const dr_dg = dr -% dg;
                const db_dg = db -% dg;
                if (dr +% 2 < 4 and dg +% 2 < 4 and db +% 2 < 4) {
                    stream[n] = 0x40 | ((dr +% 2) << 4) | ((dg +% 2) << 2) | (db +% 2);
                    n += 1;
                } else if (dg +% 32 < 64 and dr_dg +% 8 < 16 and db_dg +% 8 < 16) {
                    stream[n] = 0x80 | (dg +% 32);
                    stream[n + 1] = ((dr_dg +% 8) << 4) | (db_dg +% 8);
                    n += 2;
                } else {
                    stream[n] = 0xFE;
                    stream[n + 1] = px.r;
                    stream[n + 2] = px.g;
                    stream[n + 3] = px.b;
                    n += 4;
                }
            } else {
                stream[n] = 0xFF;
                stream[n + 1] = px.r;
                stream[n + 2] = px.g;
                stream[n + 3] = px.b;
                stream[n + 4] = px.a;
                n += 5;
            }
        }
        prev = px;
    }
    @memcpy(stream[n..][0..8], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 });
    return n + 8;
}

fn decode(data: []const u8) bool {
    if (data.len < 22 or data[0] != 'q' or data[1] != 'o' or data[2] != 'i' or data[3] != 'f') return false;
    var seen: [64]Pixel = @splat(.{ .a = 0 });
    var px: Pixel = .{};
    var run: u32 = 0;
    var p: usize = 14;
    const end = data.len - 8;
    for (&decoded) |*out| {
        if (run > 0) {
            run -= 1;
        } else if (p < end) {
            const b1 = data[p];
            p += 1;
            if (b1 == 0xFE or b1 == 0xFF) {
                px.r = data[p];
                px.g = data[p + 1];
                px.b = data[p + 2];
                p += 3;
                if (b1 == 0xFF) {
                    px.a = data[p];
                    p += 1;
                }
            } else switch (b1 >> 6) {
                0 => px = seen[b1],
                1 => {
                    px.r +%= ((b1 >> 4) & 3) -% 2;
                    px.g +%= ((b1 >> 2) & 3) -% 2;
                    px.b +%= (b1 & 3) -% 2;
                },
                2 => {
                    const b2 = data[p];
                    p += 1;
                    const dg = (b1 & 0x3F) -% 32;
                    px.r +%= dg -% 8 +% (b2 >> 4);
                    px.g +%= dg;
                    px.b +%= dg -% 8 +% (b2 & 0x0F);
                },
                else => run = b1 & 0x3F,
            }
            seen[px.index()] = px;
        }
        out.* = px;
    }
    return true;
}

fn roundTrip() void {
    paint();
    const size = encode();
    const raw: []const u8 = @ptrCast(&image);
    var line: udon.Line = .{};
    line.str("frame ").int(frame).str(": raw ").int(@intCast(raw.len)).str(" bytes ").hex(udon.hash(raw))
        .str(" -> qoi ").int(@intCast(size)).str(" bytes ").hex(udon.hash(stream[0..size])).flush();
    const ok = decode(stream[0..size]);
    var mismatches: u32 = 0;
    for (image, decoded) |a, b| mismatches += @intFromBool(!a.eql(b));
    if (ok and mismatches == 0) {
        udon.log("round trip ok");
    } else line.str("round trip FAILED: ").int(mismatches).str(" mismatching pixels").flush();
    // The stream as a .NET byte[] (e.g. for a string-loading or networking extern).
    line.str("byte[] length ").int(@intCast(udon.bytes.len(udon.bytes.new(stream[0..size])))).flush();
    frame += 1;
}

export fn _start() void {
    roundTrip();
}

export fn _interact() void {
    roundTrip();
}
