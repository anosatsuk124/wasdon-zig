//! Blockfall — a falling-block puzzle.
//!
//! Trios of coloured cells fall into a well six cells wide. When a trio
//! lands it comes apart: every cell drops as far as it can. Four or more
//! cells of one colour that touch disappear, what was resting on them
//! falls, and anything that connects as a result disappears too, each link
//! of the chain scoring more than the last.
//!
//! The whole game is one `extern struct` of bytes and words — no pointers —
//! so its memory image is also its save file and its network packet: the
//! Udon side syncs the game by copying these bytes.

pub const width = 6;
pub const height = 12;
pub const colour_count = 4;
/// Cells of one colour that must touch to clear.
pub const group_size = 4;
/// Seconds per game tick.
pub const tick: f32 = 1.0 / 30.0;
/// Ticks between steps while cells settle and while a group flashes.
const settle_ticks = 3;
const clear_ticks = 8;
/// Set on a cell that is about to clear.
pub const flash = 0x80;

pub const Phase = enum(u32) {
    /// A trio is falling under the player's control.
    falling,
    /// Loose cells are dropping, one row per step.
    settling,
    /// Matched groups are flashing before they vanish.
    clearing,
    /// The well is full.
    over,
};

pub const Command = enum(u8) { left, right, rotate, drop, restart };

/// Shapes a trio spawns in: 0 is three in a row, 1 an L of three.
const shape_count = 2;

/// Cell offsets from the pivot, for each shape as it spawns.
const shape_offsets = [2][3][2]i32{
    .{ .{ -1, 0 }, .{ 0, 0 }, .{ 1, 0 } },
    .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } },
};

/// Everything but the board is 32 bits wide, whatever its range: on the
/// Udon VM a word is read with one extern and a byte with two, and
/// arithmetic on narrow types needs masking that words do not.
pub const Game = extern struct {
    /// `board[y][x]`, row 0 at the bottom: 0 empty, 1..colour_count a
    /// colour, with `flash` set while the cell is clearing.
    board: [height][width]u8 = @splat(@splat(0)),
    /// The falling trio: offsets from the pivot and colours.
    dx: [3]i32 = @splat(0),
    dy: [3]i32 = @splat(0),
    colour: [3]u32 = @splat(0),
    next_colour: [3]u32 = @splat(0),
    next_shape: u32 = 0,
    /// Pivot position.
    px: i32 = 0,
    py: i32 = 0,
    phase: Phase = .falling,
    /// Links in the current chain.
    chain: u32 = 0,
    /// Ticks until the next step.
    wait: u32 = 0,
    level: u32 = 0,
    groups: u32 = 0,
    score: u32 = 0,
    best_chain: u32 = 0,
    rng: u32 = 0,
    /// Counts every visible change; a remote copy with the same number is
    /// up to date.
    revision: u32 = 0,
    /// Frame time not yet turned into ticks.
    clock: f32 = 0,

    pub fn init(g: *Game, seed: u32) void {
        g.* = .{ .rng = seed | 1 };
        g.roll();
        g.spawn();
    }

    pub fn bytes(g: *Game) []u8 {
        return @as([*]u8, @ptrCast(g))[0..@sizeOf(Game)];
    }

    /// Account for `frame_time` seconds; run at most one tick. Returns true
    /// if anything visible changed.
    pub fn advance(g: *Game, frame_time: f32) bool {
        g.clock += frame_time;
        if (g.clock < tick) return false;
        g.clock -= tick;
        if (g.clock > tick) g.clock = tick;
        return g.step();
    }

    /// One tick. Returns true if anything visible changed.
    pub fn step(g: *Game) bool {
        if (g.phase == .over) return false;
        if (g.wait > 1) {
            g.wait -= 1;
            return false;
        }
        switch (g.phase) {
            .falling => {
                if (g.fits(g.px, g.py - 1)) {
                    g.py -= 1;
                    g.wait = g.fallTicks();
                } else g.lock();
            },
            .settling => {
                if (g.settle()) {
                    g.wait = settle_ticks;
                } else if (g.mark() != 0) {
                    g.phase = .clearing;
                    g.wait = clear_ticks;
                } else {
                    g.chain = 0;
                    g.spawn();
                }
            },
            .clearing => {
                g.sweep();
                g.phase = .settling;
                g.wait = settle_ticks;
            },
            .over => unreachable,
        }
        g.revision += 1;
        return true;
    }

    /// Apply a player's command. Returns true if anything changed.
    pub fn input(g: *Game, command: Command) bool {
        if (command == .restart) {
            g.init(g.rng);
            g.revision += 1;
            return true;
        }
        if (g.phase != .falling) return false;
        switch (command) {
            .left => if (!g.shift(-1)) return false,
            .right => if (!g.shift(1)) return false,
            .rotate => if (!g.rotate()) return false,
            .drop => {
                while (g.fits(g.px, g.py - 1)) g.py -= 1;
                g.lock();
            },
            .restart => unreachable,
        }
        g.revision += 1;
        return true;
    }

    // ----- the falling trio -----

    fn fallTicks(g: *const Game) u32 {
        return 24 - 2 * g.level;
    }

    /// Would the trio fit with its pivot at (x, y)?
    fn fits(g: *const Game, x: i32, y: i32) bool {
        // Indexing rather than `for (g.dx, g.dy)`: iterating arrays by
        // value copies them first.
        for (0..3) |i| {
            const cx = x + g.dx[i];
            const cy = y + g.dy[i];
            // One unsigned comparison covers both ends of each range.
            if (@as(u32, @bitCast(cx)) >= width or @as(u32, @bitCast(cy)) >= height) return false;
            if (g.board[@intCast(cy)][@intCast(cx)] != 0) return false;
        }
        return true;
    }

    fn shift(g: *Game, by: i32) bool {
        if (!g.fits(g.px + by, g.py)) return false;
        g.px += by;
        return true;
    }

    /// A quarter turn clockwise, nudged sideways or up if the turned trio
    /// would not fit where it is.
    fn rotate(g: *Game) bool {
        for (0..3) |i| {
            const x = g.dx[i];
            g.dx[i] = g.dy[i];
            g.dy[i] = -x;
        }
        const nudges = [_][2]i32{ .{ 0, 0 }, .{ -1, 0 }, .{ 1, 0 }, .{ 0, 1 } };
        for (&nudges) |*n| {
            if (g.fits(g.px + n[0], g.py + n[1])) {
                g.px += n[0];
                g.py += n[1];
                return true;
            }
        }
        // Nowhere to go: turn it back.
        for (0..3) |i| {
            const x = g.dx[i];
            g.dx[i] = -g.dy[i];
            g.dy[i] = x;
        }
        return false;
    }

    /// Choose the trio after the next one.
    fn roll(g: *Game) void {
        g.next_shape = g.random() % shape_count;
        for (&g.next_colour) |*c| c.* = 1 + g.random() % colour_count;
    }

    fn spawn(g: *Game) void {
        const offsets = &shape_offsets[g.next_shape];
        for (0..3) |i| {
            g.dx[i] = offsets[i][0];
            g.dy[i] = offsets[i][1];
        }
        g.colour = g.next_colour;
        g.px = width / 2 - 1;
        g.py = height - 2;
        g.roll();
        if (g.fits(g.px, g.py)) {
            g.phase = .falling;
            g.wait = g.fallTicks();
        } else g.phase = .over;
    }

    /// The trio becomes part of the board.
    fn lock(g: *Game) void {
        for (0..3) |i| g.board[@intCast(g.py + g.dy[i])][@intCast(g.px + g.dx[i])] = @intCast(g.colour[i]);
        g.phase = .settling;
        g.wait = settle_ticks;
        g.chain = 0;
    }

    // ----- the board -----

    /// Drop every unsupported cell one row. Returns true if any moved.
    fn settle(g: *Game) bool {
        var moved = false;
        for (1..height) |y| {
            for (0..width) |x| {
                const c = g.board[y][x];
                if (c != 0 and g.board[y - 1][x] == 0) {
                    g.board[y - 1][x] = c;
                    g.board[y][x] = 0;
                    moved = true;
                }
            }
        }
        return moved;
    }

    /// Flag every cell that belongs to a group of `group_size` or more and
    /// score them. Returns the number of cells flagged.
    fn mark(g: *Game) u32 {
        var seen: [height * width]bool = @splat(false);
        // Cells of the group being traced; also the work list.
        var members: [height * width]u8 = undefined;
        var flagged: u32 = 0;
        var groups: u32 = 0;
        const cells: *[height * width]u8 = @ptrCast(&g.board);
        for (cells, 0..) |colour, start| {
            if (colour == 0 or seen[start]) continue;
            seen[start] = true;
            members[0] = @intCast(start);
            var count: usize = 1;
            var done: usize = 0;
            while (done < count) : (done += 1) {
                const at: usize = members[done];
                const x = at % width;
                // Left, right, below, above.
                const neighbours = [4]?usize{
                    if (x > 0) at - 1 else null,
                    if (x + 1 < width) at + 1 else null,
                    if (at >= width) at - width else null,
                    if (at + width < cells.len) at + width else null,
                };
                for (neighbours) |maybe| {
                    const n = maybe orelse continue;
                    if (seen[n] or cells[n] != colour) continue;
                    seen[n] = true;
                    members[count] = @intCast(n);
                    count += 1;
                }
            }
            if (count >= group_size) {
                for (members[0..count]) |m| cells[m] |= flash;
                flagged += @intCast(count);
                groups += 1;
            }
        }
        if (flagged != 0) {
            g.chain += 1;
            if (g.chain > g.best_chain) g.best_chain = g.chain;
            g.score += flagged * 10 * g.chain;
            g.groups += groups;
            g.level = @min(g.groups / 5, 9);
        }
        return flagged;
    }

    /// Remove the flagged cells.
    fn sweep(g: *Game) void {
        const cells: *[height * width]u8 = @ptrCast(&g.board);
        for (cells) |*c| {
            if (c.* & flash != 0) c.* = 0;
        }
    }

    fn random(g: *Game) u32 {
        g.rng = g.rng *% 1664525 +% 1013904223;
        return g.rng >> 16;
    }
};

// ---------------------------------------------------------------------
//  Drawing: one pixel per cell
// ---------------------------------------------------------------------

/// The picture is the well, a divider, and a panel showing the next trio.
/// With point filtering a texture this small is all a crisp display needs.
pub const picture_width = width + 4;
pub const picture_height = height;
pub const picture_bytes = picture_width * picture_height * 4;

/// RGBA in memory order.
const palette = [_]u32{
    0xFF201810, // empty well
    0xFF4040E0, // red
    0xFF40C040, // green
    0xFFE08040, // blue
    0xFF30D0F0, // yellow
};
const divider_colour = 0xFF605040;
const panel_colour = 0xFF100C08;
const flash_colour = 0xFFFFFFFF;
const over_tint = 0xFF303030;

/// Colour of every cell value, flash bit included, so that painting a cell
/// is one lookup and no branches.
const cell_colours = colourTable(false);
/// The same once the game is over: settled cells are greyed out.
const over_colours = colourTable(true);

fn colourTable(comptime over: bool) [flash + colour_count + 1]u32 {
    var table: [flash + colour_count + 1]u32 = @splat(palette[0]);
    for (1..colour_count + 1) |c| {
        table[c] = if (over) over_tint else palette[c];
        table[flash + c] = flash_colour;
    }
    return table;
}

pub const Picture = [picture_width * picture_height]u32;

/// The parts of the picture that never change: the divider and the panel.
pub fn drawFrame(pixels: *Picture) void {
    for (0..picture_height) |y| {
        const row = pixels[y * picture_width ..][0..picture_width];
        row[width] = divider_colour;
        for (row[width + 1 ..]) |*p| p.* = panel_colour;
    }
}

/// Everything that does change: the well, the falling trio, the next one.
pub fn draw(g: *const Game, pixels: *Picture) void {
    const colours = if (g.phase == .over) &over_colours else &cell_colours;
    const cells: *const [height * width]u8 = @ptrCast(&g.board);
    var cell: usize = 0;
    var pixel: usize = 0;
    while (cell < cells.len) : (pixel += picture_width - width) {
        const row_end = cell + width;
        while (cell < row_end) : ({
            cell += 1;
            pixel += 1;
        }) pixels[pixel] = colours[cells[cell]];
    }
    if (g.phase == .falling) {
        for (0..3) |i| {
            const x: usize = @intCast(g.px + g.dx[i]);
            const y: usize = @intCast(g.py + g.dy[i]);
            pixels[y * picture_width + x] = palette[g.colour[i]];
        }
    }
    // The next trio in the panel: wipe the two rows it can occupy, then
    // paint its three cells.
    const corner = (height - 3) * picture_width + width + 1;
    for ([_]usize{ corner, corner + picture_width }) |row| {
        for (pixels[row..][0..3]) |*p| p.* = panel_colour;
    }
    const offsets = &shape_offsets[g.next_shape];
    for (0..3) |i| {
        const x: usize = @intCast(width + 2 + offsets[i][0]);
        const y: usize = @intCast(height - 3 + offsets[i][1]);
        pixels[y * picture_width + x] = palette[g.next_colour[i]];
    }
}

// ------------------------------- tests -------------------------------

const std = @import("std");

fn countCells(g: *const Game) u32 {
    var n: u32 = 0;
    for (g.board) |row| for (row) |c| {
        if (c != 0) n += 1;
    };
    return n;
}

/// Run ticks until the board is at rest and a new trio is falling.
fn resolve(g: *Game) void {
    while (g.phase == .settling or g.phase == .clearing) _ = g.step();
}

test "the state is plain bytes" {
    try std.testing.expectEqual(@as(usize, 172), @sizeOf(Game));
    var a: Game = .{};
    a.init(5);
    _ = a.input(.left);
    var b: Game = .{};
    @memcpy(b.bytes(), a.bytes());
    try std.testing.expectEqualSlices(u8, a.bytes(), b.bytes());
    // The copy plays on exactly like the original.
    for (0..200) |_| {
        _ = a.step();
        _ = b.step();
    }
    try std.testing.expectEqualSlices(u8, a.bytes(), b.bytes());
}

test "a trio falls, lands and comes apart" {
    var g: Game = .{};
    g.init(1);
    try std.testing.expectEqual(Phase.falling, g.phase);
    const start_y = g.py;
    for (0..24) |_| _ = g.step();
    try std.testing.expectEqual(start_y - 1, g.py);
    try std.testing.expect(g.input(.drop));
    try std.testing.expectEqual(Phase.settling, g.phase);
    resolve(&g);
    try std.testing.expectEqual(@as(u32, 3), countCells(&g));
    // Every cell rests on the floor or on another cell.
    for (1..height) |y| for (0..width) |x| {
        if (g.board[y][x] != 0) try std.testing.expect(g.board[y - 1][x] != 0);
    };
}

test "moves stop at the walls; rotation nudges away from them" {
    var g: Game = .{};
    g.init(1);
    for (0..10) |_| _ = g.input(.left);
    try std.testing.expect(!g.input(.left));
    var min_x: i32 = width;
    for (g.dx) |dx| min_x = @min(min_x, g.px + dx);
    try std.testing.expectEqual(@as(i32, 0), min_x);
    // Four quarter turns against the wall keep it inside and bring the
    // shape back.
    const before = g.dx;
    for (0..4) |_| try std.testing.expect(g.input(.rotate));
    try std.testing.expectEqualSlices(i32, &before, &g.dx);
    for (g.dx) |dx| try std.testing.expect(g.px + dx >= 0);
}

test "four of a colour clear, and what falls can chain" {
    var g: Game = .{};
    g.init(1);
    g.board = @splat(@splat(0));
    // Column 0: three reds under a green, with a fourth red waiting on
    // top of the green's neighbours. Clearing the greens drops it.
    //   row 3:  R . . .
    //   row 2:  G G G G      <- clears first (4 greens)
    //   row 1:  R . . .
    //   row 0:  R R . .      then 4 reds touch
    g.board[0][0] = 1;
    g.board[0][1] = 1;
    g.board[1][0] = 1;
    g.board[2][0] = 2;
    g.board[2][1] = 2;
    g.board[2][2] = 2;
    g.board[2][3] = 2;
    g.board[3][0] = 1;
    g.phase = .settling;
    g.wait = 0;
    g.chain = 0;
    // Greens at (1..3, 2) are unsupported and fall first; build them a shelf.
    g.board[0][2] = 3;
    g.board[1][1] = 4;
    g.board[1][2] = 4;
    g.board[0][3] = 3;
    g.board[1][3] = 3;
    resolve(&g);
    // 4 greens x 10 x chain 1, then 4 reds x 10 x chain 2.
    try std.testing.expectEqual(@as(u32, 40 + 80), g.score);
    try std.testing.expectEqual(@as(u32, 2), g.best_chain);
    try std.testing.expectEqual(@as(u32, 2), g.groups);
    try std.testing.expectEqual(@as(u8, 0), g.board[0][0]);
    try std.testing.expectEqual(Phase.falling, g.phase);
}

test "the well fills up and the game ends; restart begins again" {
    var g: Game = .{};
    g.init(9);
    var drops: u32 = 0;
    while (g.phase != .over and drops < 500) : (drops += 1) {
        if (g.phase == .falling) _ = g.input(.drop) else _ = g.step();
    }
    try std.testing.expectEqual(Phase.over, g.phase);
    try std.testing.expect(!g.step());
    try std.testing.expect(!g.input(.left));
    try std.testing.expect(g.input(.restart));
    try std.testing.expectEqual(Phase.falling, g.phase);
    try std.testing.expectEqual(@as(u32, 0), countCells(&g));
    try std.testing.expectEqual(@as(u32, 0), g.score);
}

test "the picture shows the board, the trio and the next one" {
    var g: Game = .{};
    g.init(4);
    var pixels: Picture = undefined;
    drawFrame(&pixels);
    draw(&g, &pixels);
    var coloured: u32 = 0;
    var preview: u32 = 0;
    for (pixels, 0..) |p, i| {
        const x = i % picture_width;
        if (x < width and p != palette[0]) coloured += 1;
        if (x > width and p != panel_colour) preview += 1;
        if (x == width) try std.testing.expectEqual(@as(u32, divider_colour), p);
    }
    try std.testing.expectEqual(@as(u32, 3), coloured);
    try std.testing.expectEqual(@as(u32, 3), preview);
}

test "a played game keeps its invariants" {
    var g: Game = .{};
    g.init(77);
    var r: u32 = 12345;
    var ticks: u32 = 0;
    while (ticks < 20000 and g.phase != .over) : (ticks += 1) {
        r = r *% 1103515245 +% 12345;
        switch ((r >> 16) % 40) {
            0 => _ = g.input(.left),
            1 => _ = g.input(.right),
            2 => _ = g.input(.rotate),
            3 => _ = g.input(.drop),
            else => {},
        }
        _ = g.step();
        for (g.board) |row| for (row) |c| try std.testing.expect((c & ~@as(u8, flash)) <= colour_count);
        if (g.phase == .falling) try std.testing.expect(g.fits(g.px, g.py));
    }
    try std.testing.expect(g.score > 0);
}
