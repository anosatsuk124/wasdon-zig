//! The benchmark as an ordinary Rust program: `std`, `println!`, `String`,
//! `Instant` — built for `wasm32-wasip1` and translated like any other
//! module. It is the Rust counterpart of the mruby and Rhai benchmarks,
//! without an interpreter in between.
//!
//! Compare `../rs`, which runs the same workloads against Udon directly:
//! this version pays for a portable runtime (formatting, the allocator,
//! strings in linear memory); that one does not.

use std::time::Instant;

fn fib(n: i32) -> i32 {
    if n < 2 {
        return n;
    }
    fib(n - 1) + fib(n - 2)
}

fn mandel() -> i32 {
    let (h, w, max_iter) = (8, 16, 24);
    let mut total = 0;
    for py in 0..h {
        for px in 0..w {
            let x0 = (px * 3072 / w) - 2048;
            let y0 = (py * 2048 / h) - 1024;
            let (mut x, mut y, mut it) = (0i32, 0i32, 0);
            while it < max_iter {
                let xx = x.wrapping_mul(x) / 1024;
                let yy = y.wrapping_mul(y) / 1024;
                if xx + yy > 4096 {
                    break;
                }
                let xy = x.wrapping_mul(y) / 1024;
                x = xx - yy + x0;
                y = 2 * xy + y0;
                it += 1;
            }
            total += it;
        }
    }
    total
}

fn str_bench() -> usize {
    let mut s = String::new();
    for _ in 0..64 {
        s += "abc";
    }
    s.len()
}

fn main() {
    let started = Instant::now();
    // The argument is opaque to the compiler, as it would be if it came
    // from the command line.
    println!("fib(20) = {}", fib(std::hint::black_box(20)));
    println!("mandel  = {}", mandel());
    println!("str.len = {}", str_bench());
    println!("elapsed = {} ms", started.elapsed().as_millis());
}
