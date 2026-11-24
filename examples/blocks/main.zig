//! A complete falling-block puzzle: seven pieces, rotation with wall kicks,
//! gravity, locking, line clears, scoring, levels and game over.
//!
//! Events: `_start` resets the game, `_update` advances one tick, and the
//! custom events `MoveLeft` / `MoveRight` / `Rotate` / `SoftDrop` /
//! `HardDrop` are the controls. `AutoPlay` lets a built-in player place the
//! current piece: it tries every rotation and column and keeps the landing
//! with the best board. `_interact` logs the board. A real world would
//! mirror `cells` onto renderers; here the board is logged as text.

const udon = @import("udon");

const width = 10;
const height = 20;

/// Each piece as four rotations of a 4x4 bitmask (bit 15 = top-left).
const shapes = [7][4]u16{
    .{ 0x0F00, 0x2222, 0x00F0, 0x4444 }, // I
    .{ 0x8E00, 0x6440, 0x0E20, 0x44C0 }, // J
    .{ 0x2E00, 0x4460, 0x0E80, 0xC440 }, // L
    .{ 0x6600, 0x6600, 0x6600, 0x6600 }, // O
    .{ 0x6C00, 0x4620, 0x06C0, 0x8C40 }, // S
    .{ 0x4E00, 0x4640, 0x0E40, 0x4C40 }, // T
    .{ 0xC600, 0x2640, 0x0C60, 0x4C80 }, // Z
};
const names = "IJLOSTZ";

/// 0 = empty, otherwise piece index + 1.
var cells: [width * height]u8 = undefined;
var piece: u32 = 0;
var rotation: u32 = 0;
var px: i32 = 0;
var py: i32 = 0;
var next_piece: u32 = 0;
var rng: u32 = 0;
var score: u32 = 0;
var lines: u32 = 0;
var level: u32 = 1;
var ticks: u32 = 0;
var game_over = false;

fn random() u32 {
    // xorshift32
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

fn occupied(shape: u16, cx: u32, cy: u32) bool {
    return (shape >> @intCast(15 - (cy * 4 + cx))) & 1 != 0;
}

fn fits(p: u32, r: u32, x: i32, y: i32) bool {
    const shape = shapes[p][r];
    var cy: u32 = 0;
    while (cy < 4) : (cy += 1) {
        var cx: u32 = 0;
        while (cx < 4) : (cx += 1) {
            if (!occupied(shape, cx, cy)) continue;
            const bx = x + @as(i32, @intCast(cx));
            const by = y + @as(i32, @intCast(cy));
            if (bx < 0 or bx >= width or by >= height) return false;
            if (by >= 0 and cells[@intCast(by * width + bx)] != 0) return false;
        }
    }
    return true;
}

fn spawn() void {
    piece = next_piece;
    next_piece = random() % 7;
    rotation = 0;
    px = 3;
    py = -1;
    if (!fits(piece, rotation, px, py)) {
        game_over = true;
        var line: udon.Line = .{};
        line.str("game over: score=").int(score).str(" lines=").int(lines).flush();
    }
}

fn clearLines() void {
    var cleared: u32 = 0;
    var y: i32 = height - 1;
    while (y >= 0) {
        var full = true;
        for (cells[@intCast(y * width)..][0..width]) |c| full = full and c != 0;
        if (!full) {
            y -= 1;
            continue;
        }
        cleared += 1;
        // Shift everything above down by one row (overlapping copy).
        const row: usize = @intCast(y * width);
        @import("std").mem.copyBackwards(u8, cells[width .. row + width], cells[0..row]);
        @memset(cells[0..width], 0);
    }
    if (cleared == 0) return;
    lines += cleared;
    score += ([_]u32{ 0, 100, 300, 500, 800 })[cleared] * level;
    level = 1 + lines / 5;
    var line: udon.Line = .{};
    line.str("cleared ").int(cleared).str(" -> score=").int(score).str(" level=").int(level).flush();
}

fn lock() void {
    const shape = shapes[piece][rotation];
    var cy: u32 = 0;
    while (cy < 4) : (cy += 1) {
        var cx: u32 = 0;
        while (cx < 4) : (cx += 1) {
            const by = py + @as(i32, @intCast(cy));
            if (occupied(shape, cx, cy) and by >= 0)
                cells[@intCast(by * width + px + @as(i32, @intCast(cx)))] = @intCast(piece + 1);
        }
    }
    clearLines();
    spawn();
}

/// Move the piece down one row, locking it when it lands.
fn fall() bool {
    if (fits(piece, rotation, px, py + 1)) {
        py += 1;
        return true;
    }
    lock();
    return false;
}

fn shift(dx: i32) void {
    if (!game_over and fits(piece, rotation, px + dx, py)) px += dx;
}

export fn start() void {
    @memset(&cells, 0);
    rng = 0x2545F491;
    score = 0;
    lines = 0;
    level = 1;
    ticks = 0;
    game_over = false;
    next_piece = random() % 7;
    spawn();
    udon.log("blocks: new game");
}

export fn update() void {
    if (game_over) return;
    ticks += 1;
    // Gravity speeds up with the level.
    const period = if (level >= 10) 1 else 11 - level;
    if (ticks % period == 0) _ = fall();
}

export fn moveLeft() void {
    shift(-1);
}

export fn moveRight() void {
    shift(1);
}

export fn rotate() void {
    if (game_over) return;
    const r = (rotation + 1) & 3;
    // Try in place, then kick one or two cells off a wall.
    for ([_]i32{ 0, -1, 1, -2, 2 }) |kick| {
        if (fits(piece, r, px + kick, py)) {
            rotation = r;
            px += kick;
            return;
        }
    }
}

export fn softDrop() void {
    if (!game_over and fall()) score += 1;
}

export fn hardDrop() void {
    if (game_over) return;
    while (fall()) score += 2;
}

/// Board quality after the current piece is dropped at (r, x): a low
/// landing, few holes, low stacks and completed rows are better.
fn evaluate(r: u32, x: i32) i32 {
    var y: i32 = -2;
    if (!fits(piece, r, x, y)) return -1_000_000;
    while (fits(piece, r, x, y + 1)) y += 1;
    const shape = shapes[piece][r];
    var value: i32 = y * 6; // land low
    var col: i32 = 0;
    while (col < width) : (col += 1) {
        var seen_block = false;
        var row: i32 = 0;
        while (row < height) : (row += 1) {
            const cx = col - x;
            const cy = row - y;
            const filled = cells[@intCast(row * width + col)] != 0 or
                (cx >= 0 and cx < 4 and cy >= 0 and cy < 4 and occupied(shape, @intCast(cx), @intCast(cy)));
            if (filled and !seen_block) {
                seen_block = true;
                value -= (height - row) * 2; // column height
            } else if (!filled and seen_block) {
                value -= 12; // hole
            }
        }
    }
    // Reward rows the piece would complete.
    var cy: u32 = 0;
    while (cy < 4) : (cy += 1) {
        const row = y + @as(i32, @intCast(cy));
        if (row < 0 or row >= height) continue;
        var full = true;
        var c: i32 = 0;
        while (c < width) : (c += 1) {
            const cx = c - x;
            const piece_here = cx >= 0 and cx < 4 and occupied(shape, @intCast(cx), cy);
            full = full and (piece_here or cells[@intCast(row * width + c)] != 0);
        }
        if (full) value += 40;
    }
    return value;
}

export fn autoPlay() void {
    if (game_over) return;
    var best: i32 = -2_000_000;
    var best_r: u32 = 0;
    var best_x: i32 = px;
    var r: u32 = 0;
    while (r < 4) : (r += 1) {
        var x: i32 = -2;
        while (x < width) : (x += 1) {
            const value = evaluate(r, x);
            if (value > best) {
                best = value;
                best_r = r;
                best_x = x;
            }
        }
    }
    rotation = best_r;
    px = best_x;
    py = -2;
    hardDrop();
}

export fn show() void {
    var line: udon.Line = .{};
    line.str("score=").int(score).str(" lines=").int(lines).str(" level=").int(level)
        .str(" piece=").char(names[piece]).str(" next=").char(names[next_piece]).flush();
    const shape = shapes[piece][rotation];
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        _ = line.char('|');
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            const c = cells[@intCast(y * width + x)];
            const cx = x - px;
            const cy = y - py;
            const falling = !game_over and cx >= 0 and cx < 4 and cy >= 0 and cy < 4 and occupied(shape, @intCast(cx), @intCast(cy));
            _ = line.char(if (falling) '@' else if (c != 0) names[c - 1] else ' ');
        }
        line.char('|').flush();
    }
}

const meta =
    \\{
    \\  "version": 1,
    \\  "functions": {
    \\    "start":    { "source": {"kind":"export","name":"start"},     "event":"Start" },
    \\    "update":   { "source": {"kind":"export","name":"update"},    "event":"Update" },
    \\    "interact": { "source": {"kind":"export","name":"show"},      "event":"Interact" },
    \\    "left":     { "source": {"kind":"export","name":"moveLeft"},  "label":"MoveLeft",  "event":"custom" },
    \\    "right":    { "source": {"kind":"export","name":"moveRight"}, "label":"MoveRight", "event":"custom" },
    \\    "rotate":   { "source": {"kind":"export","name":"rotate"},    "label":"Rotate",    "event":"custom" },
    \\    "soft":     { "source": {"kind":"export","name":"softDrop"},  "label":"SoftDrop",  "event":"custom" },
    \\    "hard":     { "source": {"kind":"export","name":"hardDrop"},  "label":"HardDrop",  "event":"custom" },
    \\    "auto":     { "source": {"kind":"export","name":"autoPlay"},  "label":"AutoPlay",  "event":"custom" }
    \\  },
    \\  "options": { "memory": { "maxPages": 4 } }
    \\}
;
export fn __udon_meta_ptr() [*]const u8 {
    return meta.ptr;
}
export fn __udon_meta_len() u32 {
    return meta.len;
}
