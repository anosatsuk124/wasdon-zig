//! The threads proposal, for a machine with one thread.
//!
//! A module built with atomics (`-matomics`, shared memory) expects other
//! threads to exist. The Udon VM runs one. On one thread an atomic access
//! is an ordinary access: nothing can come between its read and its write.
//! `singleThread` rewrites every instruction of the 0xFE prefix into plain
//! WebAssembly before translation, so the lowering never sees one
//! (`docs/spec_linear_memory.md` §12).
//!
//! The two instructions that are about *other* threads keep the only
//! meaning they can have here: `memory.atomic.notify` wakes nobody and
//! returns 0; `memory.atomic.wait` returns "not equal" or "timed out", and
//! traps where it would wait forever — nobody is there to wake it.

const std = @import("std");
const wasm = @import("wasm");

const I = wasm.Instruction;
const ValType = wasm.types.ValType;
const MemArg = wasm.instruction.MemArg;
const Module = wasm.Module;

/// Scratch locals appended to a function that uses atomics.
const Scratch = struct {
    addr: u32,
    /// By type (`i32`, `i64`): the operand, the expected value, the value
    /// that was in memory.
    value: [2]u32,
    expected: [2]u32,
    old: [2]u32,

    const groups = [_]wasm.module.LocalGroup{ .{ .count = 4, .ty = .i32 }, .{ .count = 3, .ty = .i64 } };

    fn at(first: u32) Scratch {
        return .{ .addr = first, .value = .{ first + 1, first + 4 }, .expected = .{ first + 2, first + 5 }, .old = .{ first + 3, first + 6 } };
    }
};

/// The access an atomic instruction makes: operand type and width in
/// bytes. The seven variants come in the same order in every group of
/// opcodes.
const Access = struct {
    wide: bool,
    size: u8,

    const order = [_]Access{
        .{ .wide = false, .size = 4 }, .{ .wide = true, .size = 8 },
        .{ .wide = false, .size = 1 }, .{ .wide = false, .size = 2 },
        .{ .wide = true, .size = 1 },  .{ .wide = true, .size = 2 },
        .{ .wide = true, .size = 4 },
    };

    fn load(a: Access, m: MemArg) I {
        return switch (a.size) {
            1 => if (a.wide) .{ .i64_load8_u = m } else .{ .i32_load8_u = m },
            2 => if (a.wide) .{ .i64_load16_u = m } else .{ .i32_load16_u = m },
            4 => if (a.wide) .{ .i64_load32_u = m } else .{ .i32_load = m },
            else => .{ .i64_load = m },
        };
    }

    fn store(a: Access, m: MemArg) I {
        return switch (a.size) {
            1 => if (a.wide) .{ .i64_store8 = m } else .{ .i32_store8 = m },
            2 => if (a.wide) .{ .i64_store16 = m } else .{ .i32_store16 = m },
            4 => if (a.wide) .{ .i64_store32 = m } else .{ .i32_store = m },
            else => .{ .i64_store = m },
        };
    }

    /// Bits of the operand type the access does not cover, or null.
    fn mask(a: Access) ?I {
        const full: u8 = if (a.wide) 8 else 4;
        if (a.size == full) return null;
        const bits = (@as(u64, 1) << @intCast(@as(u32, a.size) * 8)) - 1;
        return if (a.wide) .{ .i64_const = @intCast(bits) } else .{ .i32_const = @intCast(bits) };
    }
};

const Rmw = enum { add, sub, and_, or_, xor, xchg };

fn operator(op: Rmw, wide: bool) ?I {
    return switch (op) {
        .add => if (wide) .i64_add else .i32_add,
        .sub => if (wide) .i64_sub else .i32_sub,
        .and_ => if (wide) .i64_and else .i32_and,
        .or_ => if (wide) .i64_or else .i32_or,
        .xor => if (wide) .i64_xor else .i32_xor,
        .xchg => null,
    };
}

/// True if any function of the module uses the threads proposal.
pub fn used(mod: Module) bool {
    for (mod.codes) |code| if (has(code.body)) return true;
    return false;
}

fn has(body: []const I) bool {
    for (body) |ins| switch (ins) {
        .atomic => return true,
        .block, .loop => |b| if (has(b.body)) return true,
        .if_ => |b| if (has(b.then_body) or (b.else_body != null and has(b.else_body.?))) return true,
        else => {},
    };
    return false;
}

/// The module with every atomic instruction replaced by what it does on
/// one thread.
pub fn singleThread(arena: std.mem.Allocator, mod: Module) error{OutOfMemory}!Module {
    const codes = try arena.dupe(wasm.module.Code, mod.codes);
    for (codes, mod.funcs) |*code, type_index| {
        if (!has(code.body)) continue;
        var first: u32 = @intCast(mod.types_[type_index].params.len);
        for (code.locals) |g| first += g.count;
        const locals = try arena.alloc(wasm.module.LocalGroup, code.locals.len + Scratch.groups.len);
        @memcpy(locals[0..code.locals.len], code.locals);
        @memcpy(locals[code.locals.len..], &Scratch.groups);
        code.* = .{ .locals = locals, .body = try rewrite(arena, code.body, .at(first)) };
    }
    var out = mod;
    out.codes = codes;
    return out;
}

fn rewrite(arena: std.mem.Allocator, body: []const I, s: Scratch) error{OutOfMemory}![]const I {
    var out: std.ArrayList(I) = try .initCapacity(arena, body.len);
    for (body) |ins| switch (ins) {
        .atomic => |a| try expand(arena, &out, a, s),
        .block => |b| try out.append(arena, .{ .block = .{ .bt = b.bt, .body = try rewrite(arena, b.body, s) } }),
        .loop => |b| try out.append(arena, .{ .loop = .{ .bt = b.bt, .body = try rewrite(arena, b.body, s) } }),
        .if_ => |b| try out.append(arena, .{ .if_ = .{
            .bt = b.bt,
            .then_body = try rewrite(arena, b.then_body, s),
            .else_body = if (b.else_body) |e| try rewrite(arena, e, s) else null,
        } }),
        else => try out.append(arena, ins),
    };
    return out.items;
}

fn expand(arena: std.mem.Allocator, out: *std.ArrayList(I), a: wasm.instruction.Atomic, s: Scratch) error{OutOfMemory}!void {
    const m = a.memarg;
    switch (a.op) {
        // notify(address, count) → number of threads woken
        0x00 => try out.appendSlice(arena, &.{ .drop, .drop, .{ .i32_const = 0 } }),
        // wait(address, expected, timeout) → 1 not equal, 2 timed out
        0x01, 0x02 => {
            const wide = a.op == 0x02;
            const w = @intFromBool(wide);
            const forever = try arena.dupe(I, &.{.unreachable_});
            const timed_out = try arena.dupe(I, &.{
                .{ .local_get = s.value[1] },                                           .{ .i64_const = 0 }, .i64_lt_s,
                .{ .if_ = .{ .bt = .empty, .then_body = forever, .else_body = null } }, .{ .i32_const = 2 },
            });
            const not_equal = try arena.dupe(I, &.{.{ .i32_const = 1 }});
            try out.appendSlice(arena, &.{
                .{ .local_set = s.value[1] },
                .{ .local_set = s.expected[w] },
                if (wide) .{ .i64_load = m } else .{ .i32_load = m },
                .{ .local_get = s.expected[w] },
                if (wide) .i64_ne else .i32_ne,
                .{ .if_ = .{ .bt = .{ .value = .i32 }, .then_body = not_equal, .else_body = timed_out } },
            });
        },
        // fence
        0x03 => {},
        0x10...0x16 => try out.append(arena, Access.order[a.op - 0x10].load(m)),
        0x17...0x1D => try out.append(arena, Access.order[a.op - 0x17].store(m)),
        // rmw(address, operand) → the value that was there
        0x1E...0x47 => {
            const acc = Access.order[(a.op - 0x1E) % 7];
            const op: Rmw = @enumFromInt((a.op - 0x1E) / 7);
            const w = @intFromBool(acc.wide);
            try out.appendSlice(arena, &.{
                .{ .local_set = s.value[w] }, .{ .local_tee = s.addr }, acc.load(m),
                .{ .local_set = s.old[w] },   .{ .local_get = s.addr },
            });
            if (operator(op, acc.wide)) |f| {
                try out.appendSlice(arena, &.{ .{ .local_get = s.old[w] }, .{ .local_get = s.value[w] }, f });
            } else {
                try out.append(arena, .{ .local_get = s.value[w] });
            }
            try out.appendSlice(arena, &.{ acc.store(m), .{ .local_get = s.old[w] } });
        },
        // cmpxchg(address, expected, replacement) → the value that was there
        0x48...0x4E => {
            const acc = Access.order[a.op - 0x48];
            const w = @intFromBool(acc.wide);
            try out.appendSlice(arena, &.{
                .{ .local_set = s.value[w] },    .{ .local_set = s.expected[w] }, .{ .local_tee = s.addr },
                acc.load(m),                     .{ .local_set = s.old[w] },
                // memory = old == expected ? replacement : old
                     .{ .local_get = s.addr },
                .{ .local_get = s.value[w] },    .{ .local_get = s.old[w] },      .{ .local_get = s.old[w] },
                .{ .local_get = s.expected[w] },
            });
            // Only the bytes the access covers take part in the comparison.
            if (acc.mask()) |bits| try out.appendSlice(arena, &.{ bits, if (acc.wide) .i64_and else .i32_and });
            try out.appendSlice(arena, &.{ if (acc.wide) .i64_eq else .i32_eq, .select, acc.store(m), .{ .local_get = s.old[w] } });
        },
        else => unreachable, // the parser rejects other sub-opcodes
    }
}
