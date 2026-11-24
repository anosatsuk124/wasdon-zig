//! Digits of pi with the Rabinowitz–Wagon spigot algorithm: integer
//! arithmetic only, dominated by division and remainder.
//!
//! `_start` prints 100 digits, each `_interact` 100 more (recomputing from
//! scratch with a longer working array).

const udon = @import("udon");

const max_digits = 400;
var work: [(max_digits + 2) * 10 / 3 + 1]u32 = undefined;
var digits: [max_digits + 16]u8 = undefined;
var shown: u32 = 0;

/// Fill `digits[0..count]` with the first `count` decimal digits of pi.
fn compute(count: u32) void {
    // Two spare digits so the held-back last digit is settled too.
    const len = (count + 2) * 10 / 3 + 1;
    for (work[0..len]) |*w| w.* = 2;
    var n: u32 = 0;
    var nines: u32 = 0;
    var predigit: u32 = 0;
    var first = true;
    while (n < count) {
        var carry: u32 = 0;
        var i = len;
        while (i > 0) {
            i -= 1;
            const x = work[i] * 10 + carry * (i + 1);
            work[i] = x % (2 * i + 1);
            carry = x / (2 * i + 1);
        }
        work[0] = carry % 10;
        const q = carry / 10;
        // Hold back runs of 9 until the next digit settles a possible carry.
        if (q == 9) {
            nines += 1;
            continue;
        }
        const bump: u32 = if (q == 10) 1 else 0;
        if (!first) n = put(n, @intCast('0' + predigit + bump));
        while (nines > 0) : (nines -= 1) n = put(n, if (bump == 1) '0' else '9');
        predigit = if (q == 10) 0 else q;
        first = false;
    }
}

fn put(n: u32, digit: u8) u32 {
    if (n < digits.len) digits[n] = digit;
    return n + 1;
}

fn show(count: u32) void {
    compute(count);
    var line: udon.Line = .{};
    line.str("pi digits ").int(shown).str("..").int(count).flush();
    var i: u32 = shown;
    while (i < count) : (i += 50) {
        const end = @min(i + 50, count);
        _ = line.str(digits[i..end]);
        line.flush();
    }
    line.str("hash=").hex(udon.hash(digits[0..count])).flush();
    shown = count;
}

export fn _start() void {
    show(100);
}

export fn _interact() void {
    if (shown + 100 <= max_digits) show(shown + 100) else udon.log("that is all the digits this buffer holds");
}
