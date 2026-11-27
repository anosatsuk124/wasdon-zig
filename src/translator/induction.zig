//! Eliminate a redundant countdown in a counted loop. With a unit-stride
//! cursor, `--n != 0` and `cursor != initial_cursor + initial_n` have the
//! same backedges, even across i32 wraparound.
const std = @import("std");
const wasm = @import("wasm");
const I = wasm.Instruction;
const Allocator = std.mem.Allocator;

pub fn optimize(arena: Allocator, code: wasm.module.Code, params: usize) Allocator.Error!wasm.module.Code {
    var n = params;
    for (code.locals) |g| n += g.count;
    if (n >= std.math.maxInt(u32)) return code;
    var pass: Pass = .{ .arena = arena, .first_temp = @intCast(n), .function_body = code.body };
    const body = try pass.rewrite(code.body);
    if (body.ptr == code.body.ptr) return code;
    const locals = try arena.alloc(wasm.module.LocalGroup, code.locals.len + 1);
    @memcpy(locals[0..code.locals.len], code.locals);
    locals[code.locals.len] = .{ .ty = .i32, .count = pass.temp_count };
    return .{ .locals = locals, .body = body };
}

const Pass = struct {
    arena: Allocator,
    // Innermost loops can share their preheader temporaries.
    first_temp: u32,
    temp_count: u32 = 0,
    function_body: []const I,
    live: ?@import("liveness.zig").Liveness = null,

    fn rewrite(self: *Pass, body: []const I) Allocator.Error![]const I {
        var out: std.ArrayList(I) = .empty;
        for (body, 0..) |ins, i| {
            var changed = ins;
            switch (ins) {
                .block, .loop => |b| {
                    if (ins == .loop) if (try self.counted(&body[i], body[0..i], &out)) continue;
                    const child = try self.rewrite(b.body);
                    if (child.ptr != b.body.ptr) {
                        if (ins == .loop) changed.loop.body = child else changed.block.body = child;
                    }
                },
                .if_ => |b| {
                    const t = try self.rewrite(b.then_body);
                    const e = if (b.else_body) |els| try self.rewrite(els) else null;
                    if (t.ptr != b.then_body.ptr or (e != null and e.?.ptr != b.else_body.?.ptr)) {
                        changed.if_.then_body = t;
                        changed.if_.else_body = e;
                    }
                },
                else => {},
            }
            if (out.capacity == 0) {
                const unchanged = switch (ins) {
                    .loop => ins.loop.body.ptr == changed.loop.body.ptr,
                    .block => ins.block.body.ptr == changed.block.body.ptr,
                    .if_ => |b| b.then_body.ptr == changed.if_.then_body.ptr and
                        (b.else_body == null or b.else_body.?.ptr == changed.if_.else_body.?.ptr),
                    else => true,
                };
                if (unchanged) continue;
                try out.appendSlice(self.arena, body[0..i]);
            }
            try out.append(self.arena, changed);
        }
        return if (out.capacity == 0) body else out.items;
    }

    fn counted(self: *Pass, loop: *const I, prefix: []const I, out: *std.ArrayList(I)) Allocator.Error!bool {
        const b = loop.loop;
        const body = b.body;
        if (b.bt != .empty or body.len < 9) return false;
        const latch = body[body.len - 5 ..];
        if (latch[0] != .local_get or latch[1] != .i32_const or latch[1].i32_const != -1 or
            latch[2] != .i32_add or latch[3] != .local_tee or latch[3].local_tee != latch[0].local_get or
            latch[4] != .br_if or latch[4].br_if != 0) return false;
        const count = latch[0].local_get;
        const work = body[0 .. body.len - 5];
        const cursor = for (0..work.len - 3) |i| {
            const s = work[i..][0..4];
            if (s[0] != .local_get or s[1] != .i32_const or s[1].i32_const != 1 or
                s[2] != .i32_add or s[3] != .local_set or s[3].local_set != s[0].local_get) continue;
            const candidate = s[0].local_get;
            if (candidate != count and candidate < self.first_temp and count < self.first_temp and
                independent(work[0..i], candidate, count, 0) and independent(work[i + 4 ..], candidate, count, 0))
                break candidate;
        } else return false;

        if (out.capacity == 0) try out.appendSlice(self.arena, prefix);
        try out.appendSlice(self.arena, &.{ .{ .local_get = cursor }, .{ .local_get = count }, .i32_add, .{ .local_set = self.first_temp } });
        self.temp_count = @max(self.temp_count, 1);
        const replacement = try self.arena.alloc(I, body.len - 1);
        @memcpy(replacement[0 .. body.len - 5], body[0 .. body.len - 5]);
        replacement[body.len - 5 ..][0..4].* = .{ .{ .local_get = cursor }, .{ .local_get = self.first_temp }, .i32_ne, .{ .br_if = 0 } };
        if (self.live == null) self.live = try @import("liveness.zig").analyzeAt(self.arena, self.first_temp, self.function_body, true);
        const live_out = self.live.?.after_loop.get(loop).?;
        const pointers = try @import("loop_offsets.zig").plan(self.arena, replacement, self.first_temp + 1, live_out);
        self.temp_count = @max(self.temp_count, pointers.temps + 1);
        try out.appendSlice(self.arena, pointers.before);
        try out.append(self.arena, .{ .loop = .{ .bt = .empty, .body = pointers.body } });
        try out.appendSlice(self.arena, pointers.after);
        if (live_out.isSet(count)) try out.appendSlice(self.arena, &.{ .{ .i32_const = 0 }, .{ .local_set = count } });
        return true;
    }
};

// All paths must reach the increment and countdown or trap/return. Reject
// nested loops because their end slot could be live at the same time.
fn independent(body: []const I, cursor: u32, count: u32, depth: u32) bool {
    for (body) |ins| switch (ins) {
        .local_get => |l| if (l == count) return false,
        .local_set, .local_tee => |l| if (l == count or l == cursor) return false,
        .loop, .br_table => return false,
        .br, .br_if => |d| if (d >= depth) return false,
        .block => |b| if (!independent(b.body, cursor, count, depth + 1)) return false,
        .if_ => |b| {
            if (!independent(b.then_body, cursor, count, depth + 1)) return false;
            if (b.else_body) |e| if (!independent(e, cursor, count, depth + 1)) return false;
        },
        else => {},
    };
    return true;
}
