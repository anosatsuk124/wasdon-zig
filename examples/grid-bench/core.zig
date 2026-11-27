//! Resumable grid kernels. One pixel is one output byte in every workload.
const std = @import("std");

pub const max_side = 1024;
pub const Kind = enum(i32) { julia, sieve, distance };

pub const Work = struct {
    kind: Kind,
    side: usize,
    cursor: usize = 0,
    column_count: usize = 0,

    pub fn done(w: Work) bool {
        return switch (w.kind) {
            .julia => w.cursor >= w.side,
            .sieve => (3 + 2 * w.cursor) * (3 + 2 * w.cursor) >= 2 * w.side * w.side,
            .distance => w.cursor >= 2 * w.side,
        };
    }

    pub fn step(w: *Work, pixels: []u8, columns: []usize) void {
        const side = w.side;
        switch (w.kind) {
            .julia => {
                const end = @min(w.cursor + 8, side);
                juliaRows(pixels, side, w.cursor, end);
                w.cursor = end;
            },
            .sieve => {
                var p = 3 + 2 * w.cursor;
                const end = p + 16;
                if (p == 3) {
                    seedWheel(pixels);
                    p = 11;
                }
                while (p < end and p * p < 2 * pixels.len) : (p += 2) {
                    if (pixels[p / 2] == 0) markMultiples(pixels, @intCast(p));
                }
                w.cursor = (p - 3) / 2;
            },
            .distance => {
                if (w.cursor < side) {
                    const end = @min(w.cursor + 8, side);
                    w.column_count += verticalBand(pixels, side, w.cursor, end, columns[w.column_count..]);
                    w.cursor = end;
                } else {
                    const start = w.cursor - side;
                    const end = @min(start + 8, side);
                    for (start..end) |y| distanceRow(pixels[y * side ..][0..side], columns[0..w.column_count]);
                    w.cursor = side + end;
                }
            },
        }
    }
};

fn juliaRows(pixels: []u8, side: usize, start: usize, end: usize) void {
    const scale = 3.0 / @as(f64, @floatFromInt(side));
    for (start..end) |y| {
        const row = pixels[y * side ..][0..side];
        // f(z) = z*z+c sends z and -z to the same point. On these
        // dyadic grids opposite initial coordinates are exact negatives.
        if (std.math.isPowerOfTwo(side) and y >= (side + 1) / 2) {
            const opposite = pixels[(side - 1 - y) * side ..][0..side];
            for (row, 0..) |*pixel, x| pixel.* = opposite[side - 1 - x];
        } else {
            const im = (@as(f64, @floatFromInt(y)) + 0.5) * scale - 1.5;
            for (row, 0..) |*pixel, x| {
                const re = (@as(f64, @floatFromInt(x)) + 0.5) * scale - 1.5;
                pixel.* = escape(re, im);
            }
        }
    }
}

fn escape(re: f64, im: f64) u8 {
    var a = re;
    var b = im;
    var aa = a * a;
    var bb = b * b;
    var n: u32 = 0;
    while (n < 64) : (n += 4) {
        inline for (0..4) |k| {
            if (aa + bb > 4.0) return @intCast(n + k);
            b = (a + a) * b + 0.125;
            a = aa - bb - 0.75;
            aa = a * a;
            bb = b * b;
        }
    }
    return 64;
}

// Odd candidates divisible by 3, 5 or 7 repeat every 105 bytes. Each
// period of 105 words starts back at the same phase of all three primes.
const wheel = blk: {
    var words: [105]u64 = undefined;
    @setEvalBranchQuota(10_000);
    for (&words, 0..) |*word, j| {
        word.* = 0;
        for (0..8) |k| {
            const n = 2 * (j * 8 + k) + 1;
            if (n % 3 == 0 or n % 5 == 0 or n % 7 == 0) word.* |= @as(u64, 255) << (8 * k);
        }
    }
    break :blk words;
};

fn seedWheel(pixels: []u8) void {
    var phase: usize = 0;
    var i: usize = 0;
    while (i + 8 <= pixels.len) : (i += 8) {
        std.mem.writeInt(u64, pixels[i..][0..8], wheel[phase], .little);
        phase += 1;
        if (phase == wheel.len) phase = 0;
    }
    var tail = wheel[phase];
    for (pixels[i..]) |*pixel| {
        pixel.* = @truncate(tail);
        tail >>= 8;
    }
    // The first four positions represent 1, 3, 5 and 7. A sieve
    // with fewer than five cells already satisfies the stop condition.
    std.mem.writeInt(u32, pixels[0..4], 255, .little);
}

fn markMultiples(pixels: []u8, p: i32) void {
    // Every third odd multiple was already struck by 3. The other
    // two alternate at distances p and 2*p in the odd-only array.
    const end: i32 = @intCast(pixels.len);
    const first_gap = if (@rem(p, 3) == 1) 2 * p else p;
    const pair = 3 * p;
    var i = @divTrunc(p * p, 2);
    while (i < end - first_gap) : (i += pair) {
        pixels[@intCast(i)] = 255;
        pixels[@intCast(i + first_gap)] = 255;
    }
    if (i < end) pixels[@intCast(i)] = 255;
}

// Distance is separable. Only columns containing sites can contribute a
// vertical distance. Discover those columns eight at a time from the mask.
fn verticalBand(pixels: []u8, side: usize, start: usize, end: usize, columns: []usize) usize {
    var empty: u64 = ~@as(u64, 0);
    if (end - start == 8) {
        var i = start;
        while (i < pixels.len) : (i += side) empty &= std.mem.readInt(u64, pixels[i..][0..8], .little);
    } else {
        for (start..end) |x| {
            var i = x;
            while (i < pixels.len) : (i += side) {
                if (pixels[i] == 0) {
                    empty &= ~(@as(u64, 255) << @intCast(8 * (x - start)));
                    break;
                }
            }
        }
    }
    var n: usize = 0;
    for (start..end) |x| {
        const occupied = @as(u8, @truncate(empty)) == 0;
        empty >>= 8;
        if (!occupied) continue;
        columns[n] = x;
        n += 1;
        var carry: i32 = 255;
        var i = x;
        while (i < pixels.len) : (i += side) {
            carry = @min(@as(i32, pixels[i]), carry + 1);
            pixels[i] = @intCast(carry);
        }
        carry = 255;
        for (0..side) |_| {
            i -= side;
            carry = @min(@as(i32, pixels[i]), carry + 1);
            pixels[i] = @intCast(carry);
        }
    }
    return n;
}

fn distanceRow(row: []u8, columns: []const usize) void {
    if (columns.len == 0) return;
    // Relax the distances at the occupied columns in both directions.
    var previous = columns[0];
    var distance: usize = row[previous];
    for (columns[1..]) |x| {
        distance = @min(row[x], distance + (x - previous));
        row[x] = @intCast(distance);
        previous = x;
    }
    ramp(row[previous + 1 ..], @intCast(distance), true);
    var j = columns.len - 1;
    while (j > 0) {
        j -= 1;
        const x = columns[j];
        const gap = previous - x;
        const left: usize = @min(row[x], distance + gap);
        row[x] = @intCast(left);
        // Inside the gap the lower of the two endpoint ramps is the
        // exact answer. Split at their intersection, including ties.
        const split = @min((gap + distance - left) / 2, gap - 1);
        ramp(row[x + 1 ..][0..split], @intCast(left), true);
        ramp(row[x + 1 + split .. previous], @intCast(distance), false);
        previous = x;
        distance = left;
    }
    ramp(row[0..previous], @intCast(distance), false);
}

// Write the ascending byte distances away from a known endpoint. The
// untouched tail already holds the input's saturated distance of 255.
fn ramp(out: []u8, base: u32, comptime forward: bool) void {
    const n = @min(out.len, 255 - base);
    var word = base * 0x01010101 +% @as(u32, if (forward) 0x04030201 else 0x01020304);
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const at = if (forward) i else out.len - i - 4;
        std.mem.writeInt(u32, out[at..][0..4], word, .little);
        word +%= 0x04040404;
    }
    while (i < n) : (i += 1) {
        out[if (forward) i else out.len - 1 - i] = @intCast(base + i + 1);
    }
}

test "distance transform preserves saturation, empty masks and incomplete column bands" {
    const side = 263;
    var pixels: [side * side]u8 = undefined;
    var columns: [side]usize = undefined;
    const sites = [_][2]usize{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 5 }, .{ 262, 262 } };
    for (0..sites.len + 1) |count| {
        @memset(&pixels, 255);
        for (sites[0..count]) |s| pixels[s[1] * side + s[0]] = 0;
        var work = Work{ .kind = .distance, .side = side };
        while (!work.done()) work.step(&pixels, &columns);
        for (pixels, 0..) |value, i| {
            const x = i % side;
            const y = i / side;
            var closest: usize = 255;
            for (sites[0..count]) |s| {
                const dx = @max(x, s[0]) - @min(x, s[0]);
                const dy = @max(y, s[1]) - @min(y, s[1]);
                closest = @min(closest, dx + dy);
            }
            try std.testing.expectEqual(@as(u8, @intCast(closest)), value);
        }
    }
}
