//! Host interfaces, linked in as WebAssembly.
//!
//! A module built for `wasm32-wasi` imports its system interface from
//! `wasi_snapshot_preview1`. Udon has no such interface, so the translator
//! supplies one: before translation, `link` rewrites the module so that
//! every WASI import is an ordinary function *defined in the module*, its
//! body written here as WebAssembly instructions over Udon externs. The
//! lowering then treats them like any other code — nothing in it knows
//! about WASI (`docs/spec_wasi_preview_1.md`).
//!
//! What the Udon VM can offer is small: a log to write to, two clocks, a
//! random source. Everything else answers the way a system without files
//! does.
//!
//! The same is done for the imports of a module with a host of its own
//! that cannot be rebuilt: `__udon_meta.imports` names, for each, one of a
//! few things a host function typically is — a console, a clock, a panic,
//! a constant answer (`docs/spec_host_import_conversion.md` §8).

const std = @import("std");
const wasm = @import("wasm");

const I = wasm.Instruction;
const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const Module = wasm.Module;

pub const module_name = "wasi_snapshot_preview1";

/// `errno` values the shims return.
pub const errno = struct {
    pub const success = 0;
    pub const badf = 8;
    pub const inval = 28;
    pub const nosys = 52;
    pub const spipe = 70;
};

/// Functions the shims call: Udon externs, Udon variables (bound through
/// the fields `link` returns), and the translator's own `halt`.
const Dep = enum(u32) {
    string_from,
    string_concat,
    string_index_of,
    string_head,
    string_tail,
    string_length,
    string_trim_end,
    log,
    log_warning,
    log_error,
    uptime,
    utc_now,
    ticks,
    random,
    get_out,
    set_out,
    get_err,
    set_err,
    halt,
};

const DepInfo = struct { module: []const u8 = "env", name: []const u8, params: []const ValType, results: []const ValType = &.{} };

const deps = std.enums.EnumArray(Dep, DepInfo).init(.{
    // A string argument given as (pointer, length) is marshalled from
    // linear memory; `String.Copy` only hands the result back as a handle.
    .string_from = .{ .name = "SystemString.__Copy__SystemString__SystemString", .params = &.{ .i32, .i32 }, .results = &.{.i32} },
    .string_concat = .{ .name = "SystemString.__Concat__SystemString_SystemString__SystemString", .params = &.{ .i32, .i32 }, .results = &.{.i32} },
    .string_index_of = .{ .name = "SystemString.__IndexOf__SystemChar__SystemInt32", .params = &.{ .i32, .i32 }, .results = &.{.i32} },
    .string_head = .{ .name = "SystemString.__Substring__SystemInt32_SystemInt32__SystemString", .params = &.{ .i32, .i32, .i32 }, .results = &.{.i32} },
    .string_tail = .{ .name = "SystemString.__Substring__SystemInt32__SystemString", .params = &.{ .i32, .i32 }, .results = &.{.i32} },
    .string_trim_end = .{ .name = "SystemString.__TrimEnd__SystemString", .params = &.{.i32}, .results = &.{.i32} },
    .string_length = .{ .name = "SystemString.__get_Length__SystemInt32", .params = &.{.i32}, .results = &.{.i32} },
    .log = .{ .name = "UnityEngineDebug.__Log__SystemObject__SystemVoid", .params = &.{.i32} },
    .log_warning = .{ .name = "UnityEngineDebug.__LogWarning__SystemObject__SystemVoid", .params = &.{.i32} },
    .log_error = .{ .name = "UnityEngineDebug.__LogError__SystemObject__SystemVoid", .params = &.{.i32} },
    .uptime = .{ .name = "UnityEngineTime.__get_realtimeSinceStartupAsDouble__SystemDouble", .params = &.{}, .results = &.{.f64} },
    .utc_now = .{ .name = "SystemDateTime.__get_UtcNow__SystemDateTime", .params = &.{}, .results = &.{.i32} },
    .ticks = .{ .name = "SystemDateTime.__get_Ticks__SystemInt64", .params = &.{.i32}, .results = &.{.i64} },
    .random = .{ .name = "UnityEngineRandom.__Range__SystemInt32_SystemInt32__SystemInt32", .params = &.{ .i32, .i32 }, .results = &.{.i32} },
    .get_out = .{ .name = "wasi.stdout", .params = &.{}, .results = &.{.i32} },
    .set_out = .{ .name = "wasi.set_stdout", .params = &.{.i32} },
    .get_err = .{ .name = "wasi.stderr", .params = &.{}, .results = &.{.i32} },
    .set_err = .{ .name = "wasi.set_stderr", .params = &.{.i32} },
    .halt = .{ .module = halt_module, .name = halt_name, .params = &.{} },
});

/// The import the lowering turns into "end this event".
pub const halt_module = "wasdon";
pub const halt_name = "halt";

/// Udon variables the shims keep state in: text written to stdout and
/// stderr that has not reached the end of a line yet.
pub const fields = [_]wasm.udon_meta.Field{
    .{ .key = "__wasi_stdout", .source = .{ .kind = .import, .name = "wasi.stdout", .setter = "wasi.set_stdout" }, .udon_name = "__wasi_stdout", .type_name = "SystemString", .default = .{ .string = "" } },
    .{ .key = "__wasi_stderr", .source = .{ .kind = .import, .name = "wasi.stderr", .setter = "wasi.set_stderr" }, .udon_name = "__wasi_stderr", .type_name = "SystemString", .default = .{ .string = "" } },
};

// ----------------------------------------------------------------------
//  Shim bodies
// ----------------------------------------------------------------------

/// Calls to `Dep`s are written with indices above this, resolved at link
/// time.
const dep_base: u32 = 0x4000_0000;

fn call(comptime d: Dep) I {
    return .{ .call = dep_base + @intFromEnum(d) };
}
fn get(comptime l: u32) I {
    return .{ .local_get = l };
}
fn set(comptime l: u32) I {
    return .{ .local_set = l };
}
fn c32(comptime x: i32) I {
    return .{ .i32_const = x };
}
fn at(comptime offset: u32) wasm.instruction.MemArg {
    return .{ .@"align" = 0, .offset = offset };
}
fn ifElse(comptime bt: wasm.types.BlockType, comptime then_body: []const I, comptime else_body: ?[]const I) I {
    return .{ .if_ = .{ .bt = bt, .then_body = then_body, .else_body = else_body } };
}
fn loopIn(comptime body: []const I) I {
    // block { loop { body } }: `br 1` leaves, `br 0` repeats.
    return .{ .block = .{ .bt = .empty, .body = &.{.{ .loop = .{ .bt = .empty, .body = body } }} } };
}

const Shim = struct {
    params: []const ValType,
    results: []const ValType = &.{.i32},
    locals: []const wasm.module.LocalGroup = &.{},
    body: []const I,
};

const i32x1 = [_]ValType{.i32};
const i32x2 = [_]ValType{ .i32, .i32 };
const i32x4 = [_]ValType{ .i32, .i32, .i32, .i32 };

/// Log every complete line of the text in local `s` — a (fd, …) function's
/// pending output — and leave the rest in `s`. `nl` is a scratch local.
/// With `terminal`, the text was written for a terminal and its lines end
/// in "\r\n": white space at the end of a line is dropped.
fn flushLines(comptime fd: u32, comptime s: u32, comptime nl: u32, comptime terminal: bool) I {
    const line = [_]I{ get(s), c32(0), get(nl), call(.string_head) } ++ (if (terminal) [_]I{call(.string_trim_end)} else [_]I{}) ++ [_]I{set(nl + 1)};
    return loopIn(&([_]I{
        // nl = s.IndexOf('\n'); done when there is none
        get(s), c32('\n'), call(.string_index_of), .{ .local_tee = nl },
        c32(0), .i32_lt_s, .{ .br_if = 1 },
        // log(s.Substring(0, nl))
    } ++ line ++ [_]I{
        get(fd),            c32(1),  .i32_eq,      ifElse(.empty, &.{ get(nl + 1), call(.log) }, &.{ get(nl + 1), call(.log_warning) }),
        // s = s.Substring(nl + 1)
        get(s),             get(nl), c32(1),       .i32_add,
        call(.string_tail), set(s),  .{ .br = 0 },
    }));
}

/// fd_write(fd, iovs, iovs_len, nwritten) — stdout and stderr go to the
/// Unity log, a line at a time: the log has no notion of a partial line,
/// so text is held until its newline arrives.
const fd_write: Shim = .{
    .params = &i32x4,
    // 4 total, 5 text, 6 newline index, 7 line
    .locals = &.{.{ .count = 4, .ty = .i32 }},
    .body = &.{
        // Only fd 1 and 2 exist: (fd - 1) >u 1 → badf.
        get(0),                                                                     c32(1),                                                             .i32_sub, c32(1),
        .i32_gt_u,                                                                  ifElse(.empty, &.{ c32(errno.badf), .return_ }, null),              get(0),   c32(1),
        .i32_eq,                                                                    ifElse(.{ .value = .i32 }, &.{call(.get_out)}, &.{call(.get_err)}), set(5),
        loopIn(&.{
            get(2),               .i32_eqz,               .{ .br_if = 1 },
            // text += string(iov.buf, iov.len)
            get(5),               get(1),                 .{ .i32_load = at(0) },
            get(1),               .{ .i32_load = at(4) }, call(.string_from),
            call(.string_concat), set(5),
            // total += iov.len
                            get(4),
            get(1),               .{ .i32_load = at(4) }, .i32_add,
            set(4),               get(1),                 c32(8),
            .i32_add,             set(1),                 get(2),
            c32(1),               .i32_sub,               set(2),
            .{ .br = 0 },
        }),
        flushLines(0, 5, 6, false),                                                 get(0),                                                             c32(1),   .i32_eq,
        ifElse(.empty, &.{ get(5), call(.set_out) }, &.{ get(5), call(.set_err) }), get(3),                                                             get(4),   .{ .i32_store = at(0) },
        c32(errno.success),
    },
};

/// proc_exit(code) — show what is left of an unfinished line, then end the
/// event. Nothing of the program runs afterwards unless Udon delivers
/// another event.
const proc_exit: Shim = .{
    .params = &i32x1,
    .results = &.{},
    .body = &.{
        call(.get_out), call(.string_length), ifElse(.empty, &.{ call(.get_out), call(.log) }, null),
        call(.get_err), call(.string_length), ifElse(.empty, &.{ call(.get_err), call(.log_warning) }, null),
        call(.halt),    .unreachable_,
    },
};

/// fd_read(fd, iovs, iovs_len, nread) — standard input is always at its
/// end.
const fd_read: Shim = .{
    .params = &i32x4,
    .body = &.{
        get(3), c32(0),                                                                  .{ .i32_store = at(0) },
        get(0), ifElse(.{ .value = .i32 }, &.{c32(errno.badf)}, &.{c32(errno.success)}),
    },
};

/// args_sizes_get / environ_sizes_get(count, buf_size) — there are none.
const sizes_get: Shim = .{
    .params = &i32x2,
    .body = &.{ get(0), c32(0), .{ .i32_store = at(0) }, get(1), c32(0), .{ .i32_store = at(0) }, c32(errno.success) },
};

/// args_get / environ_get(ptrs, buf) — nothing to write.
const nothing_get: Shim = .{ .params = &i32x2, .body = &.{c32(errno.success)} };

/// clock_time_get(id, precision, time) — nanoseconds. Clock 0 is the wall
/// clock (`DateTime.UtcNow`, in 100 ns ticks since year 1), clock 1 the
/// time since the application started; there are no CPU-time clocks.
const clock_time_get: Shim = .{
    .params = &.{ .i32, .i64, .i32 },
    .body = &.{
        get(0),                  c32(1),             .i32_gt_u, ifElse(.empty, &.{ c32(errno.inval), .return_ }, null),
        get(2),                  get(0),
        ifElse(.{ .value = .i64 }, &.{
            call(.uptime), .{ .f64_const = 1e9 }, .f64_mul, .i64_trunc_sat_f64_s,
        }, &.{
            call(.utc_now), call(.ticks), .{ .i64_const = unix_epoch_ticks }, .i64_sub, .{ .i64_const = 100 }, .i64_mul,
        }),
        .{ .i64_store = at(0) }, c32(errno.success),
    },
};

/// Ticks (100 ns) from 0001-01-01 to 1970-01-01.
pub const unix_epoch_ticks: i64 = 621_355_968_000_000_000;

/// random_get(buf, len) — one byte per call of Unity's generator. Not a
/// cryptographic source.
const random_get: Shim = .{
    .params = &i32x2,
    .body = &.{
        loopIn(&.{
            get(1),        .i32_eqz,                 .{ .br_if = 1 },
            get(0),        c32(0),                   c32(256),
            call(.random), .{ .i32_store8 = at(0) }, get(0),
            c32(1),        .i32_add,                 set(0),
            get(1),        c32(1),                   .i32_sub,
            set(1),        .{ .br = 0 },
        }),
        c32(errno.success),
    },
};

/// fd_fdstat_get(fd, stat) — fds 0–2 are character devices with no rights,
/// which is what makes libc treat stdout as a terminal and flush at each
/// newline.
const fd_fdstat_get: Shim = .{
    .params = &i32x2,
    .body = &.{
        get(0), c32(2), .i32_gt_u,                ifElse(.empty, &.{ c32(errno.badf), .return_ }, null),
        get(1), c32(0), c32(24),                  .memory_fill,
        get(1), c32(2), .{ .i32_store8 = at(0) }, c32(errno.success),
    },
};

/// fd_seek(fd, offset, whence, newoffset) — nothing here can seek.
const fd_seek: Shim = .{
    .params = &.{ .i32, .i64, .i32, .i32 },
    .body = &.{ get(3), .{ .i64_const = 0 }, .{ .i64_store = at(0) }, c32(errno.spipe) },
};

// ----------------------------------------------------------------------
//  Host functions a module can be given through `__udon_meta.imports`
// ----------------------------------------------------------------------

/// Whatever stdout and stderr still hold goes to the log.
const flush_output = [_]I{
    call(.get_out), call(.string_length), ifElse(.empty, &.{ call(.get_out), call(.log) }, null),
    call(.get_err), call(.string_length), ifElse(.empty, &.{ call(.get_err), call(.log_warning) }, null),
};

/// write(pointer, length) [→ length] — console output: text for the log,
/// a line at a time, in the same buffer as WASI's stdout. A console driver
/// ends its lines for a terminal ("\r\n"); the log gets them without.
fn hostWrite(comptime returns: bool) Shim {
    return .{
        .params = &i32x2,
        .results = if (returns) &.{.i32} else &.{},
        // 2 "this is stdout", 3 text, 4 newline index, 5 line
        .locals = &.{.{ .count = 4, .ty = .i32 }},
        .body = &([_]I{
            c32(1),                    set(2),
            call(.get_out),            get(0),
            get(1),                    call(.string_from),
            call(.string_concat),      set(3),
            flushLines(2, 3, 4, true), get(3),
            call(.set_out),
        } ++ (if (returns) [_]I{get(1)} else [_]I{})),
    };
}
const host_write = [_]Shim{ hostWrite(true), hostWrite(false) };

/// clock() → nanoseconds since the application started.
const host_clock = [_]Shim{.{
    .params = &.{},
    .results = &.{.i64},
    .body = &.{ call(.uptime), .{ .f64_const = 1e9 }, .f64_mul, .i64_trunc_sat_f64_s },
}};

/// panic(message) — a NUL-terminated string for the error log, and the end
/// of the event.
const host_panic = [_]Shim{.{
    .params = &i32x1,
    .results = &.{},
    // 1 length
    .locals = &.{.{ .count = 1, .ty = .i32 }},
    .body = &(flush_output ++ [_]I{
        loopIn(&.{
            get(0), get(1), .i32_add, .{ .i32_load8_u = at(0) }, .i32_eqz,     .{ .br_if = 1 },
            get(1), c32(1), .i32_add, set(1),                    .{ .br = 0 },
        }),
        get(0),
        get(1),
        call(.string_from),
        call(.log_error),
        call(.halt),
        .unreachable_,
    }),
}};

const Known = struct { name: []const u8, shim: ?*const Shim = null, result: i32 = errno.nosys };

/// Every function of the interface. One without a shim returns `result`
/// whatever its arguments, which for most is "not implemented".
const table = [_]Known{
    .{ .name = "fd_write", .shim = &fd_write },
    .{ .name = "proc_exit", .shim = &proc_exit },
    .{ .name = "fd_read", .shim = &fd_read },
    .{ .name = "args_sizes_get", .shim = &sizes_get },
    .{ .name = "environ_sizes_get", .shim = &sizes_get },
    .{ .name = "args_get", .shim = &nothing_get },
    .{ .name = "environ_get", .shim = &nothing_get },
    .{ .name = "clock_time_get", .shim = &clock_time_get },
    .{ .name = "random_get", .shim = &random_get },
    .{ .name = "fd_fdstat_get", .shim = &fd_fdstat_get },
    .{ .name = "fd_seek", .shim = &fd_seek },
    // Harmless to accept.
    .{ .name = "fd_close", .result = errno.success },
    .{ .name = "fd_fdstat_set_flags", .result = errno.success },
    .{ .name = "fd_sync", .result = errno.success },
    .{ .name = "fd_datasync", .result = errno.success },
    .{ .name = "sched_yield", .result = errno.success },
    // "No such descriptor" is how libc learns there are no preopened
    // directories.
    .{ .name = "fd_prestat_get", .result = errno.badf },
    .{ .name = "fd_prestat_dir_name", .result = errno.badf },
    .{ .name = "fd_filestat_get", .result = errno.badf },
    .{ .name = "fd_tell", .result = errno.spipe },
    // "Cannot seek" is what a positional read or write of a stream
    // answers; callers that try those first (Zig's std does) then fall
    // back to fd_read / fd_write.
    .{ .name = "fd_pread", .result = errno.spipe },
    .{ .name = "fd_pwrite", .result = errno.spipe },
    .{ .name = "clock_res_get" },
    .{ .name = "fd_advise" },
    .{ .name = "fd_allocate" },
    .{ .name = "fd_fdstat_set_rights" },
    .{ .name = "fd_filestat_set_size" },
    .{ .name = "fd_filestat_set_times" },
    .{ .name = "fd_readdir" },
    .{ .name = "fd_renumber" },
    .{ .name = "path_create_directory" },
    .{ .name = "path_filestat_get" },
    .{ .name = "path_filestat_set_times" },
    .{ .name = "path_link" },
    .{ .name = "path_open" },
    .{ .name = "path_readlink" },
    .{ .name = "path_remove_directory" },
    .{ .name = "path_rename" },
    .{ .name = "path_symlink" },
    .{ .name = "path_unlink_file" },
    .{ .name = "poll_oneoff" },
    .{ .name = "proc_raise" },
    .{ .name = "sock_accept" },
    .{ .name = "sock_recv" },
    .{ .name = "sock_send" },
    .{ .name = "sock_shutdown" },
};

pub const Support = enum { implemented, stubbed, unknown };

/// How a `wasi_snapshot_preview1` import is handled.
pub fn support(name: []const u8) Support {
    for (table) |k| if (std.mem.eql(u8, k.name, name)) return if (k.shim != null) .implemented else .stubbed;
    return .unknown;
}

// ----------------------------------------------------------------------
//  Linking
// ----------------------------------------------------------------------

pub const LinkError = error{ OutOfMemory, WasiSignatureMismatch, WasiUnknownImport };

const Binding = wasm.udon_meta.ImportBinding;
const Field = wasm.udon_meta.Field;

/// What becomes of a function import.
const How = union(enum) {
    /// It stays an import: an Udon extern, or something for the lowering
    /// to reject.
    keep,
    shim: *const Shim,
    /// A function that returns this whatever its arguments.
    constant: i64,
    /// A function that reports having been called and ends the event.
    halt,
};

/// Whether a binding's pattern — `module.name`, or a prefix of it ending
/// in `*` — names the import.
pub fn matches(pattern: []const u8, imp: wasm.module.Import) bool {
    const open = pattern.len != 0 and pattern[pattern.len - 1] == '*';
    // Compare against "module.name" without building it.
    var rest = if (open) pattern[0 .. pattern.len - 1] else pattern;
    for ([_][]const u8{ imp.module, ".", imp.name }) |part| {
        const n = @min(rest.len, part.len);
        if (!std.mem.eql(u8, rest[0..n], part[0..n])) return false;
        if (n < part.len) return open;
        rest = rest[n..];
    }
    return rest.len == 0;
}

fn how(imp: wasm.module.Import, ty: FuncType, bindings: []const Binding, strict: bool, offender: *[]const u8) LinkError!How {
    offender.* = imp.name;
    if (std.mem.eql(u8, imp.module, module_name)) {
        const known = find(imp.name) orelse return if (strict) error.WasiUnknownImport else .{ .constant = errno.nosys };
        const s = known.shim orelse return .{ .constant = known.result };
        if (!sameTypes(ty.params, s.params) or !sameTypes(ty.results, s.results)) return error.WasiSignatureMismatch;
        return .{ .shim = s };
    }
    const b = for (bindings) |b| {
        if (matches(b.pattern, imp)) break b;
    } else return .keep;
    const variants: []const Shim = switch (b.as orelse return .{ .constant = b.returns }) {
        .halt => return .halt,
        .write => &host_write,
        .clock => &host_clock,
        .panic => &host_panic,
    };
    for (variants) |*s| if (sameTypes(ty.params, s.params) and sameTypes(ty.results, s.results)) return .{ .shim = s };
    return error.WasiSignatureMismatch;
}

/// Replace the module's WASI imports, and the imports `bindings` names, by
/// functions defined in it; the Udon variables those keep their state in
/// are appended to `fields_out`. With `strict`, a WASI import the
/// interface does not have is an error; otherwise it becomes a function
/// returning `nosys`. On an error `offender` names the import.
pub fn link(arena: std.mem.Allocator, mod: Module, bindings: []const Binding, strict: bool, fields_out: *std.ArrayList(Field), offender: *[]const u8) LinkError!Module {
    var old_func_imports: u32 = 0;
    for (mod.imports) |imp| old_func_imports += @intFromBool(imp.desc == .func);

    // What each import becomes, and which dependencies that needs.
    const hows = try arena.alloc(How, old_func_imports);
    var needed = std.EnumSet(Dep).initEmpty();
    var shim_count: u32 = 0;
    {
        var k: u32 = 0;
        for (mod.imports) |imp| {
            if (imp.desc != .func) continue;
            hows[k] = try how(imp, mod.types_[imp.desc.func], bindings, strict, offender);
            switch (hows[k]) {
                .keep, .constant => {},
                .shim => |s| collect(s.body, &needed),
                .halt => {
                    collect(&flush_output, &needed);
                    needed.insert(.log_error);
                    needed.insert(.halt);
                },
            }
            shim_count += @intFromBool(hows[k] != .keep);
            k += 1;
        }
    }
    if (shim_count == 0) return mod;

    // New index space:
    // [kept imports][dependencies][names of halting imports][shims][old functions].
    var types: std.ArrayList(FuncType) = .empty;
    try types.appendSlice(arena, mod.types_);
    var imports: std.ArrayList(wasm.module.Import) = .empty;
    const remap = try arena.alloc(u32, old_func_imports + mod.funcs.len);
    var kept: u32 = 0;
    {
        var k: u32 = 0;
        for (mod.imports) |imp| {
            const replaced = imp.desc == .func and hows[k] != .keep;
            if (!replaced) try imports.append(arena, imp);
            if (imp.desc == .func) {
                kept += @intFromBool(!replaced);
                k += 1;
            }
        }
    }
    var dep_index = std.EnumArray(Dep, u32).initUndefined();
    var next = kept;
    var it = needed.iterator();
    while (it.next()) |d| {
        const info = deps.get(d);
        try imports.append(arena, .{ .module = info.module, .name = info.name, .desc = .{ .func = try typeIndex(arena, &types, info.params, info.results) } });
        dep_index.set(d, next);
        next += 1;
    }
    // Only the buffers the linked functions actually use.
    if (needed.contains(.get_out) or needed.contains(.set_out)) try fields_out.append(arena, fields[0]);
    if (needed.contains(.get_err) or needed.contains(.set_err)) try fields_out.append(arena, fields[1]);
    // The message of a halting import is the default value of an Udon
    // variable: a string constant the function can get a handle to.
    const first_name = next;
    {
        const getter = try typeIndex(arena, &types, &.{}, &.{.i32});
        var k: u32 = 0;
        for (mod.imports) |imp| {
            if (imp.desc != .func) continue;
            defer k += 1;
            if (hows[k] != .halt) continue;
            const n = next - first_name;
            const import_name = try std.fmt.allocPrint(arena, "wasdon.import{d}", .{n});
            const field_name = try std.fmt.allocPrint(arena, "__import{d}", .{n});
            try imports.append(arena, .{ .module = "env", .name = import_name, .desc = .{ .func = getter } });
            try fields_out.append(arena, .{
                .key = field_name,
                .source = .{ .kind = .import, .name = import_name },
                .udon_name = field_name,
                .type_name = "SystemString",
                .default = .{ .string = try std.fmt.allocPrint(arena, "{s}.{s} was called: this host does not have it, and the event ends here", .{ imp.module, imp.name }) },
            });
            next += 1;
        }
    }
    const first_shim = next;
    const first_old = first_shim + shim_count;

    var funcs: std.ArrayList(u32) = .empty;
    var codes: std.ArrayList(wasm.module.Code) = .empty;
    {
        var old: u32 = 0;
        var kept_seen: u32 = 0;
        var shim_seen: u32 = 0;
        var halt_seen: u32 = 0;
        for (mod.imports) |imp| {
            if (imp.desc != .func) continue;
            defer old += 1;
            if (hows[old] == .keep) {
                remap[old] = kept_seen;
                kept_seen += 1;
                continue;
            }
            remap[old] = first_shim + shim_seen;
            shim_seen += 1;

            const ty = mod.types_[imp.desc.func];
            try funcs.append(arena, imp.desc.func);
            try codes.append(arena, switch (hows[old]) {
                .keep => unreachable,
                .shim => |shim| .{ .locals = shim.locals, .body = try resolve(arena, shim.body, &dep_index) },
                .constant => |value| body: {
                    // Any parameters; one integer result at most.
                    if (ty.results.len > 1 or (ty.results.len == 1 and ty.results[0] != .i32 and ty.results[0] != .i64)) {
                        offender.* = imp.name;
                        return error.WasiSignatureMismatch;
                    }
                    const body = try arena.alloc(I, ty.results.len);
                    for (body, ty.results) |*ins, r| ins.* = if (r == .i64) .{ .i64_const = value } else .{ .i32_const = @truncate(value) };
                    break :body .{ .locals = &.{}, .body = body };
                },
                .halt => body: {
                    const tail = [_]I{ .{ .call = first_name + halt_seen }, call(.log_error), call(.halt), .unreachable_ };
                    halt_seen += 1;
                    break :body .{ .locals = &.{}, .body = try resolve(arena, &(flush_output ++ tail), &dep_index) };
                },
            });
        }
        for (mod.funcs, 0..) |_, k| remap[old_func_imports + k] = first_old + @as(u32, @intCast(k));
    }
    try funcs.appendSlice(arena, mod.funcs);
    for (mod.codes) |code| try codes.append(arena, .{ .locals = code.locals, .body = try renumber(arena, code.body, remap) });

    var out = mod;
    out.types_ = types.items;
    out.imports = imports.items;
    out.funcs = funcs.items;
    out.codes = codes.items;
    if (mod.start) |s| out.start = remap[s];

    const exports = try arena.dupe(wasm.module.Export, mod.exports);
    for (exports) |*e| if (e.desc == .func) {
        e.desc = .{ .func = remap[e.desc.func] };
    };
    out.exports = exports;

    const elements = try arena.dupe(wasm.module.Element, mod.elements);
    for (elements) |*e| {
        const init = try arena.dupe(u32, e.init);
        for (init) |*f| f.* = remap[f.*];
        e.init = init;
    }
    out.elements = elements;
    // The name section indexes the old function space; drop it rather than
    // mislabel functions.
    const customs = try arena.alloc(wasm.module.CustomSection, mod.customs.len);
    var n_customs: usize = 0;
    for (mod.customs) |c| if (!std.mem.eql(u8, c.name, "name")) {
        customs[n_customs] = c;
        n_customs += 1;
    };
    out.customs = customs[0..n_customs];
    return out;
}

fn find(name: []const u8) ?*const Known {
    for (&table) |*k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

fn sameTypes(a: []const ValType, b: []const ValType) bool {
    return std.mem.eql(ValType, a, b);
}

fn typeIndex(arena: std.mem.Allocator, types: *std.ArrayList(FuncType), params: []const ValType, results: []const ValType) !u32 {
    for (types.items, 0..) |t, i| if (sameTypes(t.params, params) and sameTypes(t.results, results)) return @intCast(i);
    try types.append(arena, .{ .params = params, .results = results });
    return @intCast(types.items.len - 1);
}

fn collect(body: []const I, needed: *std.EnumSet(Dep)) void {
    for (body) |ins| switch (ins) {
        .call => |f| if (f >= dep_base) needed.insert(@enumFromInt(f - dep_base)),
        .block, .loop => |b| collect(b.body, needed),
        .if_ => |b| {
            collect(b.then_body, needed);
            if (b.else_body) |e| collect(e, needed);
        },
        else => {},
    };
}

/// A copy of a shim body with its dependency calls pointing at the
/// imports the module now has.
fn resolve(arena: std.mem.Allocator, body: []const I, dep_index: *const std.EnumArray(Dep, u32)) error{OutOfMemory}![]const I {
    const out = try arena.dupe(I, body);
    for (out) |*ins| switch (ins.*) {
        .call => |f| if (f >= dep_base) {
            ins.* = .{ .call = dep_index.get(@enumFromInt(f - dep_base)) };
        },
        .block => |b| ins.* = .{ .block = .{ .bt = b.bt, .body = try resolve(arena, b.body, dep_index) } },
        .loop => |b| ins.* = .{ .loop = .{ .bt = b.bt, .body = try resolve(arena, b.body, dep_index) } },
        .if_ => |b| ins.* = .{ .if_ = .{
            .bt = b.bt,
            .then_body = try resolve(arena, b.then_body, dep_index),
            .else_body = if (b.else_body) |e| try resolve(arena, e, dep_index) else null,
        } },
        else => {},
    };
    return out;
}

/// A copy of a function body with its calls renumbered.
fn renumber(arena: std.mem.Allocator, body: []const I, remap: []const u32) error{OutOfMemory}![]const I {
    const out = try arena.dupe(I, body);
    for (out) |*ins| switch (ins.*) {
        .call => |f| ins.* = .{ .call = if (f < remap.len) remap[f] else f },
        .block => |b| ins.* = .{ .block = .{ .bt = b.bt, .body = try renumber(arena, b.body, remap) } },
        .loop => |b| ins.* = .{ .loop = .{ .bt = b.bt, .body = try renumber(arena, b.body, remap) } },
        .if_ => |b| ins.* = .{ .if_ = .{
            .bt = b.bt,
            .then_body = try renumber(arena, b.then_body, remap),
            .else_body = if (b.else_body) |e| try renumber(arena, e, remap) else null,
        } },
        else => {},
    };
    return out;
}

test "support classifies the interface" {
    try std.testing.expectEqual(Support.implemented, support("fd_write"));
    try std.testing.expectEqual(Support.stubbed, support("path_open"));
    try std.testing.expectEqual(Support.unknown, support("fd_frobnicate"));
}
