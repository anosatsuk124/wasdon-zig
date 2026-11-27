# WASI preview 1

## 1. Problem

A program built for `wasm32-wasi` / `wasm32-wasip1` — Rust with `std`,
Zig with `std`, C with wasi-libc — imports its system interface from the
module `wasi_snapshot_preview1`: `fd_write`, `clock_time_get`, `proc_exit`
and some forty others. Udon has no such interface. It has a log, two
clocks and a random number generator.

This document specifies how the translator makes such a program run: which
functions exist, what each does on Udon, and how they get into the
program.

## 2. Linking, not lowering

The WASI functions are not special cases in the lowering. Before
translation, `src/translator/wasi.zig` *links* them into the module:

1. Every function import from `wasi_snapshot_preview1` is removed.
2. In its place the module gets a **defined function** of the same type,
   whose body is WebAssembly — written in `wasi.zig` as instruction arrays —
   over a handful of Udon externs.
3. Those externs are added as ordinary imports (their names are extern
   signatures, `docs/spec_host_import_conversion.md`), only the ones the
   linked functions use.
4. Function indices in code, exports, element segments and the start
   function are renumbered; the name section, which the renumbering would
   make wrong, is dropped.

After that the module contains nothing unusual and is translated like any
other. The shims are optimized, checked and tested by the same machinery
as user code, and a shim that is never called is never emitted.

Two Udon variables hold state between calls, bound the way
`__udon_meta` fields of kind `import` are
(`docs/spec_udonmeta_conversion.md`):

| Variable | Type | Holds |
|---|---|---|
| `__wasi_stdout` | `SystemString` | text written to fd 1 since its last newline |
| `__wasi_stderr` | `SystemString` | the same for fd 2 |

One import is the translator's own: `wasdon.halt`, lowered to `JUMP,
0xFFFFFFFC` — "end this event". `proc_exit` uses it.

## 3. Functions

`errno` values are those of the interface: `success` 0, `badf` 8,
`inval` 28, `nosys` 52, `spipe` 70.

### Implemented

| Function | Behaviour on Udon |
|---|---|
| `fd_write(fd, iovs, n, nwritten)` | fd 1 → `Debug.Log`, fd 2 → `Debug.LogWarning`, **one call per complete line**: each buffer is decoded as UTF-8 (`Encoding.UTF8.GetString`) and appended to the pending text; every line that now ends in `\n` is logged without its newline; the rest stays pending. `*nwritten` is the total length. Any other fd: `badf`. |
| `proc_exit(code)` | Logs what is pending on stdout and stderr, then ends the event. The exit code is not kept. |
| `fd_read(fd, iovs, n, nread)` | `*nread = 0`; `success` for fd 0 (end of input), `badf` otherwise. |
| `args_sizes_get`, `environ_sizes_get` | Both counts 0. |
| `args_get`, `environ_get` | Nothing to write; `success`. |
| `clock_time_get(id, precision, time)` | Nanoseconds. `realtime` (0): `(DateTime.UtcNow.Ticks − 621355968000000000) × 100`. `monotonic` (1): `Time.realtimeSinceStartupAsDouble × 10⁹`. CPU-time clocks: `inval`. |
| `random_get(buf, len)` | One `UnityEngine.Random.Range(0, 256)` per byte. Not cryptographic. |
| `fd_fdstat_get(fd, stat)` | fds 0–2: a zeroed `fdstat` with file type `character_device` (2) and no rights. Others: `badf`. |
| `fd_seek(fd, offset, whence, newoffset)` | `*newoffset = 0`, `spipe`. |

The line buffering exists because the Unity console has no notion of a
partial line: `printf("a"); printf("b\n");` must be one entry, and a
`println!` that libc delivers as two buffers must not be two. A last line
without a newline appears when the program calls `proc_exit`; a program
that simply returns from `main` should end its output with a newline.

The `fdstat` answer matters more than it looks: "character device without
seek rights" is what makes wasi-libc treat stdout as a terminal and flush
it at every newline instead of at exit.

### Answered without doing anything

| Result | Functions | Why |
|---|---|---|
| `success` | `fd_close`, `fd_sync`, `fd_datasync`, `fd_fdstat_set_flags`, `sched_yield` | harmless |
| `badf` | `fd_prestat_get`, `fd_prestat_dir_name`, `fd_filestat_get` | "no such descriptor" is how libc learns there are no preopened directories |
| `spipe` | `fd_tell`, `fd_pread`, `fd_pwrite` | "cannot seek": callers that try positional I/O first (Zig's `std` does) fall back to `fd_read` / `fd_write` |
| `nosys` | every other function of the interface: `path_*`, `sock_*`, `poll_oneoff`, `fd_readdir`, `clock_res_get`, `proc_raise`, … | there are no files, sockets or signals |

A stub ignores its arguments and writes nothing through its pointers.

### Unknown names

An import from `wasi_snapshot_preview1` that the interface does not define
is an error with `--strict` (or `options.strict`); otherwise it becomes a
`nosys` stub like the others. An import of a function the translator
implements with a different type than the interface's is always an error.

## 4. Events and lifetime

A WASI command exports `_start`, which the translator binds to Udon's
`_start` event like any exported function without parameters
(`docs/spec_call_return_conversion.md` §7). `main` therefore runs once,
inside the behaviour's Start event — and under its limit: **ten seconds**,
after which Udon halts the behaviour. A long computation in `main` does not
fit; see `docs/producer_guide.md` §7 for cutting work into frames, which a
WASI program can do by exporting further functions.

After `proc_exit` or the return of `_start` the memory and all state remain
as they are. Nothing runs again unless the module exports other events.

## 5. What works

| Language feature | Through |
|---|---|
| `println!`, `print!`, `eprintln!`; C `printf`, `puts`; Zig `File.stdout()` writers | `fd_write` (after `fd_fdstat_get`, and for Zig a refused `fd_pwrite`) |
| `String`, `Vec`, `Box`, `format!`; `malloc` | the module's own allocator over `memory.grow` (`docs/spec_linear_memory.md` §7) |
| `std::time::Instant`, `SystemTime`; `clock_gettime` | `clock_time_get` |
| `getrandom`, `HashMap`'s seed | `random_get` |
| `std::process::exit`; returning from `main` | `proc_exit` |
| panics | the message goes to stderr (a warning in the console), then `unreachable` traps |

What does not: anything that opens a file, a socket, or a thread. The
calls fail with an error the program can handle; they do not stop the
translation.

Measured examples: `examples/wasi-hello` (Zig `std`),
`examples/bench/wasi-rs` (Rust `std`), `examples/rhai-bench` — the Rhai
scripting engine, 3 360 functions, interpreting a script and printing its
results — and `examples/mruby-bench` — mruby, C on wasi-libc —
`docs/benchmarks.md`.

## 6. Producer notes

- **Rust**: `cargo build --release --target wasm32-wasip1`. The standard
  library is built with features the translator reads (bulk memory, sign
  extension, the LEB-encoded table index of `call_indirect`). Use
  `panic = "abort"`.
- **Zig**: `-target wasm32-wasi`, CPU `mvp` plus `bulk_memory_opt`,
  `sign_ext`, `nontrapping_fptoint`, `mutable_globals`. Set a small stack
  (`exe.stack_size`): the default of several megabytes becomes the initial
  size of the Udon `byte[]`.
- **C**: wasi-sdk. A library that insists on a filesystem at startup
  (CRuby's `ruby.wasm`, for one) gets `badf` / `nosys` and decides for
  itself whether it can go on.
- Metadata is optional. To set options — the memory limit, say — without
  touching the program, pass a JSON file: `wasdon-zig translate app.wasm
  --meta app.udon_meta.json`.
- `wasdon-zig inspect app.wasm` lists which WASI functions a module
  imports and how each will be answered.
- The cost of a portable runtime is real: `println!` of an integer is a few
  thousand externs of formatting and buffering before the one that logs.
  For code that only ever runs on Udon, calling Udon directly is cheaper
  (`examples/bench/rs` against `examples/bench/wasi-rs`).

## 7. Differences from the earlier draft

An earlier branch specified WASI support for the previous translator. This
one differs where that draft was wrong or the new design made something
better possible:

| | Earlier draft | Now |
|---|---|---|
| Mechanism | inline Udon Assembly emitted per call site by `lower_wasi.zig` | functions linked into the module as WebAssembly |
| stdout | one log entry per iovec | one per line |
| `fd_seek` result | 29 (`io`) | 70 (`spipe`) |
| `fdstat.fs_filetype` | 6 (`socket_stream`) | 2 (`character_device`) |
| `fd_read` on stdin | `badf` | end of input |
| positional I/O | `nosys` | `spipe`, so callers fall back |
| metadata | sidecar JSON only | in the module, or `--meta` |

## 8. Limits

- stdout and stderr only; no standard input, files, directories, sockets,
  polling, signals or threads.
- No arguments and no environment variables.
- Output is decoded per buffer: a multi-byte UTF-8 character split across
  two `fd_write` buffers is decoded as two invalid sequences.
- The wall clock has the resolution of `DateTime.UtcNow`; the monotonic
  clock that of Unity's frame-independent timer.
