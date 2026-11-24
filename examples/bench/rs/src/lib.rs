//! The benchmark's three workloads in Rust — the same ones as
//! `../usharp/UdonBench.cs`, with the same inputs and the same results in
//! the same Udon variables.
//!
//! Each exported function is one workload and one Udon event.

#![no_std]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

/// A .NET string held by Udon; never a number.
#[repr(transparent)]
#[derive(Clone, Copy)]
pub struct UdonString(i32);

#[link(wasm_import_module = "env")]
unsafe extern "C" {
    // Udon variables, bound by the metadata below.
    #[link_name = "bench.fib_n"]
    fn fib_n() -> i32;
    #[link_name = "bench.set_fib"]
    fn set_fib(v: i32);
    #[link_name = "bench.set_mandel"]
    fn set_mandel(v: i32);
    #[link_name = "bench.set_str"]
    fn set_str(v: i32);

    #[link_name = "SystemString.__Copy__SystemString__SystemString"]
    fn string_from(ptr: *const u8, len: usize) -> UdonString;
    #[link_name = "SystemString.__Concat__SystemString_SystemString__SystemString"]
    fn string_concat(a: UdonString, b: UdonString) -> UdonString;
    #[link_name = "SystemString.__get_Length__SystemInt32"]
    fn string_len(s: UdonString) -> i32;
}

fn fib(n: i32) -> i32 {
    if n < 2 {
        return n;
    }
    fib(n - 1) + fib(n - 2)
}

#[unsafe(no_mangle)]
pub extern "C" fn Fib() {
    unsafe { set_fib(fib(fib_n())) }
}

/// Escape iterations summed over a 16 x 8 grid, in fixed point (scale 1024).
fn mandel() -> i32 {
    let (h, w, max_iter) = (8, 16, 24);
    let mut total = 0;
    let mut py = 0;
    while py < h {
        let mut px = 0;
        while px < w {
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
            px += 1;
        }
        py += 1;
    }
    total
}

#[unsafe(no_mangle)]
pub extern "C" fn Mandel() {
    unsafe { set_mandel(mandel()) }
}

/// "abc" appended 64 times, as a .NET string: U# builds it that way too.
#[unsafe(no_mangle)]
pub extern "C" fn Str() {
    unsafe {
        let mut s = string_from("".as_ptr(), 0);
        let abc = string_from("abc".as_ptr(), 3);
        let mut i = 0;
        while i < 64 {
            s = string_concat(s, abc);
            i += 1;
        }
        set_str(string_len(s));
    }
}

const UDON_META_JSON: &[u8] = br#"{
  "version": 1,
  "fields": {
    "fibN":   { "source": {"kind":"import","name":"bench.fib_n"}, "udonName":"fibN", "type":"int", "export": true, "default": 20 },
    "fib":    { "source": {"kind":"import","name":"bench.fib","setter":"bench.set_fib"}, "udonName":"fibResult", "type":"int", "export": true },
    "mandel": { "source": {"kind":"import","name":"bench.mandel","setter":"bench.set_mandel"}, "udonName":"mandelResult", "type":"int", "export": true },
    "str":    { "source": {"kind":"import","name":"bench.str","setter":"bench.set_str"}, "udonName":"strResult", "type":"int", "export": true }
  }
}"#;

#[unsafe(no_mangle)]
pub extern "C" fn __udon_meta_ptr() -> *const u8 {
    UDON_META_JSON.as_ptr()
}

#[unsafe(no_mangle)]
pub extern "C" fn __udon_meta_len() -> u32 {
    UDON_META_JSON.len() as u32
}
