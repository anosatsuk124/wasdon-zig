# rhai-bench

WASI benchmark fixture for `wasdon-zig` that embeds the
[Rhai](https://rhai.rs/) scripting engine and runs four workloads
(recursion, integer-loop "mandelbrot", string concat, wall-time
measurement) from a literal Rhai script.

The point of this example is **not** to measure Rhai itself — it is to
exercise the translator's WASI Preview 1 lowering on a non-trivial Rust
program that drags in `wasi-libc`, a heap allocator, and `std::time`.

## Producer choice: Rust + `wasm32-wasip1`

Unlike `examples/wasi-hello/` (hand-written WAT) and `examples/wasm-bench-rs/`
(Rust + `wasm32v1-none`, no WASI), this example uses
`wasm32-wasip1` because Rhai requires `std`. The workspace-wide
`.cargo/config.toml` pins `wasm32v1-none`, so this crate ships its own
`.cargo/config.toml` to override the target.

The `wasm32-wasip1` target enables several post-MVP wasm features by
default. The translator already supports bulk-memory, mutable-globals,
sign-ext, and nontrapping-fptoint (commits `c82461a`, `6e00fbc`), but
**multivalue / reference-types / simd128** are not yet handled. The
local `.cargo/config.toml` therefore disables them via `RUSTFLAGS`.

## Files

| File | Purpose |
|---|---|
| `Cargo.toml` | Crate manifest. `[[bin]] name = "rhai_bench"` so wasi-libc emits `_start`. |
| `.cargo/config.toml` | Per-package override: `target = "wasm32-wasip1"` plus `target-feature` strip. |
| `src/main.rs` | Driver. Embeds a Rhai engine, registers `now_ns`, runs the script. |
| `rhai_bench.udon_meta.json` | `__udon_meta` sidecar — committed. |
| `README.md` | This file. |

## Build

```sh
# One-time toolchain setup
rustup target add wasm32-wasip1

# From this directory (the per-package .cargo/config.toml takes effect):
cd examples/rhai-bench
cargo build --release
# Output: <workspace>/target/wasm32-wasip1/release/rhai_bench.wasm
# (cargo workspaces share the workspace root's target/ regardless of cwd)
```

If you build from the workspace root, pass the target explicitly so the
root `.cargo/config.toml` does not override:

```sh
cargo build --release -p rhai-bench --target wasm32-wasip1
```

## Translate

```sh
# The .wasm lands in the workspace target dir; pass --meta explicitly
# because the auto-discovered name next to the .wasm would be
# "rhai_bench.udon_meta.json" inside target/, which is gitignored and
# never written there.
zig build run -- translate \
    target/wasm32-wasip1/release/rhai_bench.wasm \
    --meta examples/rhai-bench/rhai_bench.udon_meta.json \
    -o /tmp/rhai_bench.uasm
```

## Expected WASI imports

`wasm-objdump -x` should show only entries from `wasi_snapshot_preview1`
that are in the MVP supported set per
[`docs/spec_wasi_preview_1.md`](../../docs/spec_wasi_preview_1.md) §2.1:

- `fd_write` — `print` / `eprintln!` output
- `proc_exit` — exit at end of `_start`
- `clock_time_get` — `Instant::now()` / `Instant::elapsed`
- `random_get` — Rust's `HashMap` random seed (Rhai uses `BTreeMap`
  internally for symbol tables, but `wasi-libc` initialisers may still
  reference this)
- `environ_get` / `environ_sizes_get`, `args_get` / `args_sizes_get`,
  `fd_close`, `fd_seek`, `fd_fdstat_get` — wasi-libc `_start` glue

If a non-MVP import (`fd_prestat_get`, `path_open`, …) appears, the
translator (with `strict: false`) will lower it as an `errno.nosys`
stub, but the program may still misbehave at startup. Inspect with:

```sh
wasm-objdump -x target/wasm32-wasip1/release/rhai_bench.wasm \
    | grep -E '(Import\[|wasi_snapshot_preview1)'
```

Or, simpler if you have the translator running, grep the produced
`.uasm` for `# wasi:` comments — the translator labels each WASI import
either as a real lowering (`# wasi: fd_write`) or as a deferred stub
(`# wasi: nosys stub for path_open`).

### Expected import classification

The translator routes each import to one of two places:

| Import | Disposition |
|---|---|
| `fd_write`, `proc_exit`, `fd_close`, `fd_seek`, `fd_fdstat_get`, `fd_read`, `environ_get`, `environ_sizes_get`, `args_get`, `args_sizes_get`, `clock_time_get`, `random_get` | Real lowering per `docs/spec_wasi_preview_1.md` §4. |
| `fd_prestat_get`, `fd_prestat_dir_name`, `fd_filestat_get`, `path_open`, `poll_oneoff`, … | `nosys` stub (deferred by spec §2.2). |

## Memory sizing

`__udon_meta.options.memory` is set to `initialPages: 8, maxPages: 64`
(512 KiB initial, 4 MiB max). Rhai itself is small; the bulk of the
allocation is `wasi-libc`'s static init plus Rhai's parsed AST and
symbol tables. Bump `maxPages` if you grow the embedded script.

## Recursion

`__udon_meta.options.recursion = "stack"` is required because Rhai's
function dispatcher and the embedded `fib` call form recursive
strongly-connected components. Without this, the translator's recursion
detection (Tarjan-SCC) will fail at translate time.
