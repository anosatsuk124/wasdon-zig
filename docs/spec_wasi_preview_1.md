# WASI Preview 1 Subset Lowering

## 1. Purpose & Status

This document defines which subset of [`wasi_snapshot_preview1`](./wasi-preview-1.md)
the `wasdon-zig` translator MUST recognise and how each supported import lowers
to Udon Assembly under the constraints catalogued in `docs/udon_specs.md`,
`docs/spec_variable_conversion.md`, `docs/spec_linear_memory.md`, and
`docs/spec_call_return_conversion.md`.

The translator's emission target is the Udon VM running inside VRChat. The Udon
VM has **no filesystem, no sockets, no threads, no signals, no polling**, and
no host syscall surface for any of those concepts. The supported subset is
therefore deliberately small: just enough to let a Rust or Zig program built
for `wasm32-wasip1` link, run a `main` that prints to stdout, exit cleanly, and
optionally pull a clock value or some random bytes.

`wasdon-zig` is **not** a WASI runtime. It is a static translator that, when it
encounters an `(import "wasi_snapshot_preview1" ...)`, synthesises an
Udon-Assembly block that emulates that function on top of Udon externs. Every
unsupported import is rejected at translate time (strict mode) or emitted as a
stub returning `errno.nosys` (lenient mode); see §7.

The raw upstream reference for every WASI signature lives in
`docs/wasi-preview-1.md`. **Do not edit that file** — this spec cites section
names from it instead of inlining the signatures.

---

## 2. Scope & Non-Goals

### 2.1 In scope (MVP)

The translator MUST recognise the import module name `wasi_snapshot_preview1`
and provide synthesised lowerings for the following functions (the §
references point into `docs/wasi-preview-1.md`):

| Function | Reference | Behaviour |
|---|---|---|
| `proc_exit` | §`proc_exit` | Halt program. |
| `fd_write` | §`fd_write` | Stdout/stderr → host log extern. |
| `fd_read` | §`fd_read` | Stub returning `errno.badf`. |
| `environ_get` / `environ_sizes_get` | §`environ_get`, §`environ_sizes_get` | Return zero env vars. |
| `args_get` / `args_sizes_get` | §`args_get`, §`args_sizes_get` | Return zero args. |
| `clock_time_get` | §`clock_time_get` | `realtime` / `monotonic` only. |
| `random_get` | §`random_get` | Fill via Udon RNG extern. |
| `fd_close` | §`fd_close` | `errno.success`. |
| `fd_seek` | §`fd_seek` | Stub returning `errno.spipe` (writes 0 to result-out). |
| `fd_fdstat_get` | §`fd_fdstat_get` | Minimal stub for fd 1 / 2; `errno.badf` otherwise. |

This subset is sufficient to lower a typical Rust or Zig "hello world" linked
against `wasm32-wasip1` — toolchain glue commonly imports
`fd_write`, `fd_close`, `fd_seek`, `environ_*`, `proc_exit` even when only one
of them is actually called.

### 2.2 Deferred (recognised, but emitted as `errno.nosys` stubs)

The translator MUST recognise — and stub with `errno.nosys` — every other
function listed under §`wasi_snapshot_preview1` →
"Functions" in `docs/wasi-preview-1.md`. This keeps toolchain glue linkable
without giving the program a working call.

Examples (non-exhaustive): `fd_advise`, `fd_allocate`, `fd_datasync`,
`fd_fdstat_set_flags`, `fd_filestat_get`, `fd_pread`, `fd_prestat_get`,
`fd_prestat_dir_name`, `fd_pwrite`, `fd_readdir`, `fd_renumber`, `fd_sync`,
`fd_tell`, all `path_*`, `poll_oneoff`, `proc_raise`, `sched_yield`, all
`sock_*`, `clock_res_get`.

### 2.3 Non-goals

- No filesystem. `path_*`, `fd_pread`, `fd_pwrite`, `fd_readdir`, `fd_*stat*`
  beyond the `fd_fdstat_get` stub, etc.
- No sockets (`sock_*`).
- No threads, no `sched_yield`, no `poll_oneoff`.
- No signals (`proc_raise`).
- No preopens. `fd_prestat_get` always returns `errno.badf`.
- No CPU-time clocks. `clock_time_get` rejects `process_cputime_id` and
  `thread_cputime_id` with `errno.inval`.
- No `clock_res_get`. (Stubbed `nosys`; producers MUST NOT depend on a
  resolution value.)

---

## 3. Lowering Strategy

### 3.1 Dispatcher placement

`src/translator/lower_import.zig` SHOULD, before the existing signature-grammar
parse (`spec_host_import_conversion.md` §5), check the import module name. If
`imp.module == "wasi_snapshot_preview1"`, dispatch to a new
`src/translator/lower_wasi.zig` module rather than the generic extern shim.

The dispatcher MUST:

1. Look up `imp.name` in a static table of supported functions (§2.1).
2. If found, validate the WASM `func` signature against the WASI signature
   (e.g. `proc_exit: (i32) -> ()`, `fd_write: (i32, i32, i32, i32) -> i32`).
   A mismatch is a translate-time error (`WasiSignatureMismatch`).
3. If the name is in the deferred set (§2.2), emit a "nosys stub" body
   (§4.10).
4. Otherwise, fall through to `emitUnsupported` with diagnostic
   `unknown wasi_snapshot_preview1 import "<name>"`. Strict mode (per
   `__udon_meta.options.strict`) elevates this to an error.

### 3.2 Emission shape

The MVP implementation lowers each WASI import **inline at the call site**,
mirroring how `spec_host_import_conversion.md` §5 emits non-WASI host
externs today. The lowering reads the WASI parameters straight from the
caller's stack-typed slots (`__caller_S{d}_i32__` etc.), executes its body,
optionally writes one of the shared `__c_errno_*__` constants into the
caller's result slot, and then returns control to the next instruction.
This reuses the existing call-site stack-update machinery and keeps every
WASI lowering localised to `src/translator/lower_wasi.zig`.

> **Earlier draft.** A previous version of this spec described WASI
> lowerings as separate translator-generated callees with
> `__wasi_<fn>_entry__` / `__wasi_<fn>_exit__` labels, dedicated `P_i` /
> `R0` / `RA` slots, and a `JUMP` / `JUMP_INDIRECT` ABI on top of the
> existing `spec_call_return_conversion.md` §3 contract. That shape works
> but pays for an extra indirection on every WASI call without benefit on
> the MVP set — none of these functions recurse, none save / restore stack
> frames beyond the caller's own, and the `_marshal_str_*` scratch is
> single-use anyway. The inline emission produces the same observable
> Udon-Assembly contents (the JUMP-end sentinel for `proc_exit`, the
> errno literals, the iovec walk + sink extern for `fd_write`, the
> out-pointer stores) without the extra label overhead.

If a future feature requires re-entry into a WASI body — for example, a
`fd_write` that reads its own iovecs from a sink it wrote earlier — the
inline shape can be promoted to a synthesized callee without changing the
producer-visible contract; only `lower_wasi.zig`'s emission shape changes.

### 3.3 Memory access

WASI functions read and write the caller's linear memory through pointer
arguments. Every byte-level access MUST go through the helpers documented in
`docs/spec_linear_memory.md`:

- A WASM byte address `addr` decomposes to
  `(page = addr >> 16, word = (addr & 0xFFFF) >> 2, byte = addr & 3)`.
- Loads / stores use the existing `i32.load8_u`, `i32.load`, `i32.store8`,
  `i32.store` lowerings synthesised over the two-level page array
  (`__G__memory : SystemObjectArray` of `SystemUInt32Array`).
- The `__G__memory_size_pages` scalar bounds-checks every access. An
  out-of-range WASI pointer MUST cause the synthesised callee to set its
  return slot to `errno.fault` (21) and `JUMP, __wasi_<fn>_exit__`.

### 3.4 String materialisation

When a WASI body must hand a string to a `SystemString`-taking extern
(notably `fd_write` → log sink), it reuses the `SystemString` marshaling
helper documented in `spec_host_import_conversion.md` §3. The byte-copy loop
that the helper requires reads from the two-level memory model exactly as
described above, so no new shared scratch needs to be introduced — the WASI
lowering reuses `_marshal_str_*` and the cached `_marshal_encoding_utf8`.

---

## 4. Per-Function Lowering

### 4.1 `proc_exit(rval: i32)`

Reference: §`proc_exit`. The function does not return.

Emit:

```
__wasi_proc_exit_entry__:
    # rval is in __wasi_proc_exit_P0__. We currently discard it; future
    # iterations MAY copy it into a translator-defined exit-code slot.
    JUMP, 0xFFFFFFFC
```

Rationale: `0xFFFFFFFC` is the Udon program-end sentinel
(`docs/udon_specs.md` §6.2.5). There is no return label; control never falls
through. The `__wasi_proc_exit_RA__` slot is allocated but unused, which is
harmless (the slot stays zeroed).

`proc_exit` is the only supported WASI function with no `_R0__` slot.

### 4.2 `fd_write(fd: i32, iovs_ptr: i32, iovs_len: i32, nwritten_ptr: i32) -> errno`

Reference: §`fd_write`, §`ciovec`, §`ciovec_array`.

WASM call shape: `(import ... (func (param i32 i32 i32 i32) (result i32)))`.

Behaviour:

1. If `fd == 1` (stdout) → route to `wasi.stdout_extern` (§5).
2. If `fd == 2` (stderr) → route to `wasi.stderr_extern` (§5).
3. Otherwise → write `0` to `*nwritten_ptr` and return `errno.badf` (8).

Each `ciovec` is laid out in linear memory as a packed `(buf: i32, buf_len:
i32)` pair, i.e. **8 bytes per element** (§`ciovec_array`).

Pseudo-Udon body (one log emission per iovec, concatenation deferred to a
future optimisation):

```
__wasi_fd_write_entry__:
    # (a) fd == 1 ?
    PUSH, __wasi_fd_write_P0__
    PUSH, __const_1__
    PUSH, __wasi_scratch_bool__
    EXTERN, "SystemInt32.__op_Equality__SystemInt32_SystemInt32__SystemBoolean"
    PUSH, __wasi_scratch_bool__
    JUMP_IF_FALSE, __wasi_fd_write_check_stderr__
    # ... emit per-iovec loop targeting wasi.stdout_extern ...
    JUMP, __wasi_fd_write_finish_ok__

__wasi_fd_write_check_stderr__:
    # ... fd == 2 path, mirror of stdout ...

__wasi_fd_write_badfd__:
    # *nwritten_ptr = 0
    PUSH, __const_0__
    PUSH, __wasi_fd_write_P3__   # nwritten_ptr
    # ... i32.store synthesised over __G__memory ...
    PUSH, __const_errno_badf__   # 8
    PUSH, __wasi_fd_write_R0__
    COPY
    JUMP, __wasi_fd_write_exit__

__wasi_fd_write_finish_ok__:
    # *nwritten_ptr = total bytes consumed across all iovecs
    PUSH, __wasi_fd_write_total__
    # ... i32.store ...
    PUSH, __const_errno_success__   # 0
    PUSH, __wasi_fd_write_R0__
    COPY

__wasi_fd_write_exit__:
    JUMP_INDIRECT, __wasi_fd_write_RA__
```

The per-iovec loop:

1. `iov_i_ptr  = i32.load(iovs_ptr + 8*i + 0)`
2. `iov_i_len  = i32.load(iovs_ptr + 8*i + 4)`
3. Marshal `(iov_i_ptr, iov_i_len)` into `_marshal_str_tmp` per
   `spec_host_import_conversion.md` §3.
4. `EXTERN, "<wasi.{stdout,stderr}_extern>"` with `_marshal_str_tmp` PUSHed as
   the `SystemString` argument.
5. `total += iov_i_len`.

The translator MUST emit byte-accurate UTF-8 to `SystemTextEncoding.UTF8.GetString`;
the helper already handles this. Non-UTF-8 byte sequences raise whatever
exception the host-side `GetString` raises — out of scope.

### 4.3 `fd_read(fd, iovs, iovs_len, nread_ptr) -> errno`

Reference: §`fd_read`. Stdin is unavailable.

Body: store `0` into `*nread_ptr`, return `errno.badf` (8). Always.

### 4.4 `environ_sizes_get(count_ptr, buf_size_ptr) -> errno`

Reference: §`environ_sizes_get`.

Body: `*count_ptr = 0`, `*buf_size_ptr = 0`, return `errno.success` (0).

### 4.5 `environ_get(env_ptr, env_buf_ptr) -> errno`

Reference: §`environ_get`. The companion of §4.4.

Body: write nothing (count is zero), return `errno.success`.

A future extension MAY honour `__udon_meta.wasi.environ` — see §5. The MVP
ignores any such field; it is documented as a `nosys` extension point.

### 4.6 `args_sizes_get` / `args_get`

References: §`args_sizes_get`, §`args_get`. Same shape as §4.4 / §4.5,
returning zero args.

A future `__udon_meta.wasi.argv` field MAY supply a fixed argv vector. The MVP
ignores it.

### 4.7 `clock_time_get(id: i32, precision: i64, time_out_ptr: i32) -> errno`

Reference: §`clock_time_get`, §`clockid`.

Branching:

- `id == 0` (`realtime`): write nanoseconds-since-1970 to `*time_out_ptr` via
  `wasi.clock_realtime_extern` (§5). Default: read
  `SystemDateTime.__get_UtcNow__SystemDateTime`, subtract the unix-epoch
  `SystemDateTime`, convert `SystemTimeSpan.__get_Ticks__SystemInt64` to
  nanoseconds (`ticks * 100`).
- `id == 1` (`monotonic`): write a monotonic ns value to `*time_out_ptr` via
  `wasi.clock_monotonic_extern`. Default: `UnityEngineTime.__get_realtimeSinceStartupAsDouble__SystemDouble`,
  convert seconds → ns (`x * 1_000_000_000`), cast to `SystemInt64`.
- `id == 2` (`process_cputime_id`) / `id == 3` (`thread_cputime_id`): return
  `errno.inval` (28) without touching `*time_out_ptr`.

`precision` is ignored; WASI permits any precision the implementation can
deliver.

`*time_out_ptr` is a `u64` — written via two `i32.store` halves (little-endian
low word first), the same pattern the linear-memory spec already uses for
`i64.store` in §`spec_linear_memory.md`.

### 4.8 `random_get(buf: i32, buf_len: i32) -> errno`

Reference: §`random_get`.

Body: for `i in 0..buf_len`, write a random byte at `buf + i` via
`wasi.random_extern` (§5). Default extern:
`UnityEngineRandom.__Range__SystemInt32_SystemInt32__SystemInt32` with the
range `[0, 256)`, masked to `0xFF`. Return `errno.success`.

The Udon `UnityEngine.Random.Range(int, int)` overload's upper bound is
exclusive, matching the desired `[0, 256)` (`docs/udon_specs.md` §7.5 implies
producers SHOULD verify against the Class Exposure Tree; the alternative
`SystemRandom` ctor + `NextBytes` requires a one-shot heap allocation and is
documented as a fallback).

`buf_len == 0` is a no-op returning `errno.success`.

### 4.9 `fd_close` / `fd_seek` / `fd_fdstat_get`

These are stubs intentionally tuned so that the most common `wasi-libc` glue
links and runs:

- `fd_close(fd) -> errno`. Body: return `errno.success` (libc closes stdout on
  exit; failing here would obscure real bugs).
- `fd_seek(fd, offset: i64, whence: i32, newoffset_ptr: i32) -> errno`. Body:
  store `0` to `*newoffset_ptr`, return `errno.spipe` (29). `spipe` ("invalid
  seek") is what POSIX returns when seeking on a pipe and is what real WASI
  runtimes return for stdout/stderr; it lets `printf`-style buffering routines
  fall through to a write-without-seek path.
- `fd_fdstat_get(fd, stat_ptr: i32) -> errno`. For `fd == 1` or `fd == 2`,
  zero-fill the 24-byte `fdstat` record at `*stat_ptr` and set
  `fs_filetype = 6` (`character_device`, §`filetype`); return
  `errno.success`. Other fds → `errno.badf` (8). The `fdstat` record layout
  (24 bytes, fields at offsets 0/2/8/16) is in §`fdstat`.

### 4.10 `nosys` stub shape (deferred set)

Every function in §2.2 lowers to:

```
__wasi_<fn>_entry__:
    PUSH, __const_errno_nosys__   # 52
    PUSH, __wasi_<fn>_R0__
    COPY
__wasi_<fn>_exit__:
    JUMP_INDIRECT, __wasi_<fn>_RA__
```

`proc_raise` and `sched_yield` follow the same shape because they have
`errno`-shaped returns. The translator MUST NOT touch any pointer arguments in
a `nosys` stub — the caller's memory is left unchanged.

---

## 5. `__udon_meta` Integration

This spec extends `docs/spec_udonmeta_conversion.md` with an OPTIONAL `wasi`
top-level object. The decoder is `src/wasm/udon_meta.zig`'s `Wasi` record,
populated from JSON keys spelled exactly as below (snake_case, matching the
WASI ABI naming convention rather than the surrounding camelCase used by
`fields` / `functions` / `options`):

```json
{
  "wasi": {
    "stdout_extern":          "UnityEngineDebug.__Log__SystemObject__SystemVoid",
    "stderr_extern":          "UnityEngineDebug.__LogWarning__SystemObject__SystemVoid",
    "random_extern":          "UnityEngineRandom.__Range__SystemInt32_SystemInt32__SystemInt32",
    "clock_realtime_extern":  "SystemDateTime.__get_UtcNow__SystemDateTime",
    "clock_monotonic_extern": "UnityEngineTime.__get_realtimeSinceStartupAsDouble__SystemDouble"
  }
}
```

Every field is OPTIONAL. The translator MUST fall back to the defaults shown
above when a field is missing. Each value MUST parse as a valid Udon signature
per `spec_host_import_conversion.md` §`Signature Grammar`; otherwise the
translator emits `WasiInvalidExternSignature`.

Producers MAY override these to point at game-specific log sinks
(`VRChatUdonChatBoxNetworking.…`, etc.). Any extern named here is invoked from
inside the synthesised WASI body; the translator MUST NOT also emit a
top-level extern import for it.

Future fields (declared here, NOT in the MVP):

- `wasi.argv: [string]` — fixed argv exposed via `args_sizes_get` / `args_get`.
- `wasi.environ: { [string]: string }` — fixed environ exposed via
  `environ_sizes_get` / `environ_get`.

---

## 6. Errno Encoding

WASI `errno` is a 16-bit enum (§`errno`, "Size: 2"). WASI imports return it
zero-extended into the WASM `i32` result slot. The translator MUST emit
`i32.const` literals for the small set actually returned by §4:

| Name | Value | Used by |
|---|---|---|
| `errno.success` | `0` | All success paths. |
| `errno.badf` | `8` | `fd_read`, `fd_write` non-1/2, `fd_fdstat_get`, `fd_close`. |
| `errno.fault` | `21` | Out-of-bounds linear-memory access. |
| `errno.inval` | `28` | `clock_time_get` for `process_cputime_id` / `thread_cputime_id`. |
| `errno.spipe` | `29` | `fd_seek`. |
| `errno.nosys` | `52` | All deferred functions (§2.2 / §4.10). |

These constants live in the data section as e.g.
`__const_errno_success__: %SystemInt32, 0`. The translator SHOULD share them
across all WASI bodies.

The numeric values are taken from `docs/wasi-preview-1.md` §`errno` "Variant
cases" (the cases are listed in declaration order; their numeric values are
their list index, per the WASI ABI). Implementers MUST NOT invent new errno
values.

---

## 7. Strict / lenient policy

The existing `__udon_meta.options.strict` toggle (see
`spec_host_import_conversion.md` §5) extends naturally:

- **strict (default for this subset)**: any unknown
  `wasi_snapshot_preview1` import is a translation error
  (`WasiUnknownImport`).
- **lenient**: an unknown WASI import is treated like the §2.2 deferred set —
  emit a `nosys` stub. This lets producers that pull in `wasi-libc`'s full
  surface still translate, at the cost of silent failure if anything other
  than the §2.1 set is actually called at runtime.

The `nosys` stub list will live in
`src/translator/lower_wasi.zig` (proposed module name) so a single edit
updates both the recogniser and the stub generator.

---

## 8. Producer Guidance

Cross-reference `docs/producer_guide.md`. The producer guide will gain a
"WASI Preview 1 subset" section after this spec lands; until then, producers
SHOULD follow the rules below.

### 8.1 Rust (`wasm32-wasip1`)

- `Cargo.toml`: `[profile.release] opt-level = "z"`, `lto = true`,
  `panic = "abort"`. These keep the binary small and freestanding; they
  are no longer load-bearing for `__udon_meta` discovery, which now uses
  a sidecar JSON file (see `docs/spec_udonmeta_conversion.md`).
- Avoid `std::fs`, `std::net`, `std::thread`, `std::process::Command`. The
  translator will reject any of those at translate time once the linker pulls
  in their imports — they cannot be compiled out at the LLVM layer.
- `eprintln!` / `println!` work because they bottom out in `fd_write`.
- `std::time::SystemTime::now()` works because `clock_time_get(realtime)` is
  supported. `Instant::now()` works through `clock_time_get(monotonic)`.
- `std::process::exit(code)` lowers to `proc_exit`.
- `getrandom` / the `rand` family works through `random_get`.

### 8.2 Zig (`wasm32-wasi`)

- Use `std.io.getStdOut().writer()`-style APIs. They lower to `fd_write`.
- `std.os.exit(rval)` lowers to `proc_exit`.
- Avoid `std.fs`, `std.net`, `std.Thread`. Same translator-time rejection
  applies.

### 8.3 Hand-rolled WAT

Producers MAY also import `wasi_snapshot_preview1` functions directly:

```wat
(import "wasi_snapshot_preview1" "fd_write"
        (func $fd_write (param i32 i32 i32 i32) (result i32)))
(import "wasi_snapshot_preview1" "proc_exit"
        (func $proc_exit (param i32)))
```

— and `(call $fd_write …)` from any WASM function. The translator's call-site
ABI takes care of the rest.

---

## 9. Test Fixtures

A new example `examples/wasi-hello/` (created by the next implementation
task) demonstrates end-to-end:

- A `wasm32-wasip1` Rust binary that calls `println!("hello, udon")` and
  `std::process::exit(0)`.
- The translator MUST translate it without errors and the resulting Udon
  Assembly MUST contain at least one `EXTERN, "<wasi.stdout_extern>"` plus a
  `JUMP, 0xFFFFFFFC` derived from `proc_exit`.

`src/translator/testdata/` SHOULD gain hand-written WAT fixtures targeting
each MVP function in isolation, in TDD style:

- `wasi_proc_exit.wat` — calls `proc_exit(0)` from `_start`.
- `wasi_fd_write_stdout.wat` — writes one iovec to fd 1.
- `wasi_fd_write_badfd.wat` — writes to fd 99, expects `errno.badf` in the
  caller's S slot.
- `wasi_clock_time_get_realtime.wat` — reads realtime, stores ns.
- `wasi_random_get.wat` — fills an 8-byte buffer.
- `wasi_nosys_path_open.wat` — confirms `path_open` lowers as the `nosys`
  stub and the caller observes `errno == 52`.

These fixtures double as regression tests against the address-layout
sensitivity called out in `spec_call_return_conversion.md` §5: every WASI
callee body adds 4-byte instructions, so any change to its emission disturbs
RAC literals downstream.

---

## 10. Constraints and Cautions

- **`fd_write` and `proc_exit` are the only entries `wasi-libc`'s `_start`
  actually calls in a trivial program.** The deferred-stub list still has to
  exist because `wasi-libc`'s static initialisers reference (but do not call)
  several of the others; without `nosys` stubs the `call` instruction would
  not validate.
- **Atomicity around `*nwritten_ptr`.** The translator MUST write
  `*nwritten_ptr` only after every iovec has been logged successfully. An
  out-of-bounds iovec entry MUST set `*nwritten_ptr = bytes_written_so_far`
  and return `errno.fault`.
- **Endianness.** WASI explicitly specifies little-endian for all pointer /
  size fields. The two-level memory model in `spec_linear_memory.md` is also
  little-endian for byte access; no extra swap is required.
- **Address aliasing.** Each synthesised WASI body is an additional code
  region; if it abuts another label without an intervening instruction, a
  `NOP` MUST be inserted (`spec_call_return_conversion.md` §12).
- **Re-entrancy.** Udon does not preempt; the synthesised WASI bodies share
  the `_marshal_str_*` scratch with normal extern calls. The translator MUST
  NOT marshal a string while another marshal is mid-flight. The single-thread
  Udon execution model guarantees this naturally as long as no WASI body
  calls back into user WASM (none of the §4 lowerings do).
- **Recursion.** No WASI lowering recurses. They never participate in the
  recursion analysis of `spec_call_return_conversion.md` §8.

---

## 11. MVP implementation status

All §2.1 functions are now implemented end-to-end:

- §4.1 `proc_exit` — `JUMP, 0xFFFFFFFC` halt.
- §4.2 `fd_write` — full iovec walk + UTF-8 marshalling + per-iovec sink
  extern call. Default sink: `UnityEngine.Debug.Log` for fd 1,
  `Debug.LogWarning` for fd 2; both overridable via §5.
- §4.3 `fd_read` — `errno.badf` stub with `*nread_ptr = 0`.
- §4.4 / §4.5 `environ_*` — zero-result `errno.success`.
- §4.6 `args_*` — zero-result `errno.success`.
- §4.7 `clock_time_get` — branches on `clockid`. `realtime` (id 0) calls
  the configured realtime extern (default `SystemDateTime.UtcNow`),
  subtracts a runtime-built `DateTime(1970,1,1)` epoch, takes
  `SystemTimeSpan.Ticks`, and multiplies by 100 to get nanoseconds.
  `monotonic` (id 1) calls the configured monotonic extern (default
  `UnityEngine.Time.realtimeSinceStartupAsDouble`) and scales seconds →
  nanoseconds via three `× 1000.0` multiplies (Udon Assembly cannot
  declare `SystemDouble` literals — see §4.7 implementation comment for
  the runtime-init pattern). Invalid clockids return `errno.inval`
  without touching `*time_out_ptr`. The 8-byte `u64` result is written
  through the new `Host.storeI64` helper as two little-endian i32
  halves at offsets 0 and 4.
- §4.8 `random_get` — per-byte loop calling the configured RNG extern
  (default `UnityEngine.Random.Range(0, 256)`), masking the result to
  `0xFF` defensively, and storing through the new
  `Host.storeByteToMemory` helper. `buf_len == 0` falls through cleanly.
- §4.9 `fd_close` / `fd_seek` / `fd_fdstat_get` — stubs as documented.
- §4.10 `nosys` — every name in the deferred set, plus every unknown WASI
  import in lenient mode.

The translator's `lower_wasi.mvp_specs` table is now in 1-to-1
correspondence with this section's "in scope (MVP)" list, and
`deferred_names` matches the §2.2 deferred set with `clock_time_get` /
`random_get` removed.

The §12 open issues below remain open; none of them blocked the MVP
completion.

## 12. Open Issues

- Confirming the exact Udon extern signature for `SystemTimeSpan.Ticks` /
  `SystemDateTime - SystemDateTime`. The defaults in §5 are the most likely
  candidates from the UdonSharp Class Exposure Tree but MUST be cross-checked
  before implementation lands.
- Whether `wasi.stdout_extern` should default to `Debug.Log` or to a
  wasdon-defined sink that can be wired to a Unity `Text` component. Pending
  user feedback.
- Whether `clock_time_get(monotonic)` should be backed by
  `UnityEngine.Time.realtimeSinceStartupAsDouble` (which resets on Play) or by
  a translator-managed counter incremented in `_update`. The default chosen
  here matches the most common host runtime expectation.
- The `__udon_meta.wasi.argv` / `wasi.environ` extension is sketched but not
  implemented; concrete schema validation rules are deferred.
