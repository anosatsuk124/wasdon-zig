//! Digits of π by the Rabinowitz–Wagon spigot algorithm, four decimal
//! digits per step.
//!
//! Integer-only and incremental: the caller decides how many steps to run
//! per frame, which is what a computation needs to look like to live inside
//! Udon's per-event time limit.

/// With 32-bit arithmetic the running sum stays in range for up to 2800
/// terms, which is 800 digits.
pub const max_digits = 800;
const group = 4;
const base = 10000;
/// Each group of four digits consumes 14 terms of the series.
const max_terms = max_digits / group * 14;

pub const State = struct {
    /// Mixed-radix remainders; `f[0]` is unused.
    f: [max_terms + 1]i32 = undefined,
    /// Terms still in play; shrinks by 14 per step.
    terms: i32 = 0,
    carry: i32 = 0,
    /// ASCII output: "3." followed by the digits after the decimal point.
    out: [max_digits + 2]u8 = undefined,
    len: usize = 0,
    /// Digits requested, including the leading 3.
    wanted: usize = 0,
    emitted: usize = 0,

    pub fn init(s: *State, digits: usize) void {
        const n: usize = @min(@max(digits, group), max_digits);
        s.wanted = n;
        s.terms = @intCast((n + group - 1) / group * 14);
        s.carry = 0;
        s.len = 0;
        s.emitted = 0;
        var i: usize = 0;
        while (i <= @as(usize, @intCast(s.terms))) : (i += 1) s.f[i] = base / 5;
    }

    pub fn done(s: *const State) bool {
        return s.emitted >= s.wanted;
    }

    pub fn text(s: *const State) []const u8 {
        return s.out[0..s.len];
    }

    /// Produce the next four digits. Cost is proportional to `terms`.
    pub fn step(s: *State) void {
        if (s.done()) return;
        var d: i32 = 0;
        var g: i32 = s.terms * 2;
        var b: i32 = s.terms;
        while (true) {
            d += s.f[@intCast(b)] * base;
            g -= 1;
            s.f[@intCast(b)] = @rem(d, g);
            d = @divTrunc(d, g);
            g -= 1;
            b -= 1;
            if (b == 0) break;
            d *= b;
        }
        s.terms -= 14;
        var value = s.carry + @divTrunc(d, base);
        s.carry = @rem(d, base);

        var digits: [group]u8 = undefined;
        var k: usize = group;
        while (k > 0) {
            k -= 1;
            digits[k] = @intCast(@rem(value, 10) + '0');
            value = @divTrunc(value, 10);
        }
        for (digits) |c| {
            if (s.emitted == s.wanted) break;
            s.out[s.len] = c;
            s.len += 1;
            s.emitted += 1;
            if (s.emitted == 1) {
                s.out[s.len] = '.';
                s.len += 1;
            }
        }
    }
};

pub const reference_100 = "3.141592653589793238462643383279502884197169399375105820974944592307816406286208998628034825342117067";

test "first 100 digits" {
    const std = @import("std");
    var s: State = .{};
    s.init(100);
    while (!s.done()) s.step();
    try std.testing.expectEqualStrings(reference_100, s.text());
}

test "any digit count up to the maximum, checked against a longer run" {
    const std = @import("std");
    var long: State = .{};
    long.init(max_digits);
    while (!long.done()) long.step();
    for ([_]usize{ 4, 5, 7, 50, 333, 799 }) |n| {
        var s: State = .{};
        s.init(n);
        while (!s.done()) s.step();
        // The last digits of a short run can differ from the true expansion
        // (the series is truncated); all but the final group must agree.
        const stable = s.len - @min(s.len, 6);
        try std.testing.expectEqualStrings(long.text()[0..stable], s.text()[0..stable]);
    }
}
