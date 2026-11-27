//! Rhai (Rust embedded scripting) benchmark for `wasdon-zig`.
//!
//! Compiled for `wasm32-wasip1`. The benchmark embeds a Rhai engine and
//! runs four workloads from a literal script string:
//!
//! 1. `fib(20)`         — recursion
//! 2. `mandel()`        — integer arithmetic loop
//! 3. `str_bench()`     — string concat (exercises the heap allocator)
//! 4. wall-time around the above via `now_ns` (Rust-registered fn → `clock_time_get`)
//!
//! Output goes through `print` → wasi-libc → `fd_write`. Exit is via the
//! normal `_start` return path → `proc_exit`. No filesystem, no env, no args.
//! That keeps the import set inside `docs/spec_wasi_preview_1.md` §2.1.

use std::time::Instant;

use rhai::{Engine, INT};

fn main() {
    let mut engine = Engine::new();

    // Expose a monotonic-nanosecond clock to Rhai. Internally this calls
    // `clock_time_get(CLOCK_MONOTONIC)` through std, which is the only
    // clock the translator's WASI lowering accepts (realtime/monotonic).
    let started = Instant::now();
    engine.register_fn("now_ns", move || -> INT {
        started.elapsed().as_nanos() as INT
    });

    let script = r#"
        fn fib(n) { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }

        // Integer mandelbrot-ish workload: counts escape iterations on a
        // small grid. Pure i32, no Float, so Rhai's `only_i32` build runs it.
        fn mandel() {
            let total = 0;
            let h = 8;
            let w = 16;
            let max_iter = 24;
            let py = 0;
            while py < h {
                let px = 0;
                while px < w {
                    // Map pixel to fixed-point in -2..1 / -1..1 (scale 1024).
                    let x0 = (px * 3072 / w) - 2048;
                    let y0 = (py * 2048 / h) - 1024;
                    let x = 0;
                    let y = 0;
                    let it = 0;
                    while it < max_iter {
                        let xx = (x * x) / 1024;
                        let yy = (y * y) / 1024;
                        if xx + yy > 4096 { break; }
                        let xy = (x * y) / 1024;
                        x = xx - yy + x0;
                        y = 2 * xy + y0;
                        it += 1;
                    }
                    total += it;
                    px += 1;
                }
                py += 1;
            }
            total
        }

        fn str_bench() {
            let s = "";
            let i = 0;
            while i < 64 {
                s += "abc";
                i += 1;
            }
            s.len
        }

        let t0 = now_ns();
        let f = fib(20);
        let t1 = now_ns();
        let m = mandel();
        let t2 = now_ns();
        let n = str_bench();
        let t3 = now_ns();

        print(`fib(20) = ${f}        (${t1 - t0} ns)`);
        print(`mandel  = ${m}        (${t2 - t1} ns)`);
        print(`str.len = ${n}        (${t3 - t2} ns)`);
        print(`total   = ${t3 - t0} ns`);
    "#;

    if let Err(e) = engine.run(script) {
        eprintln!("rhai error: {e}");
        std::process::exit(1);
    }
}
