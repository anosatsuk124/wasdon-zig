//! WASM test bench (Rust port of `examples/wasm-bench`).
//!
//! Built with `wasm32v1-none` (MVP-only). Mutable Rust statics live in
//! linear memory because the MVP target lacks the `mutable-globals` feature,
//! so `__udon_meta` does not expose them as Udon-side fields — the bench
//! only logs through the single `UnityEngineDebug.Log` extern.
//!
//! Coverage: arithmetic, control flow, globals, recursion, linear-memory
//! load/store + `memory.grow`, `call_indirect`, structs, 64-bit + float.
//! The Zig version's `std.fmt`/`std.Io.Writer` staging tests are
//! intentionally skipped — those exercise Zig stdlib internals, not
//! translator behavior.

#![no_std]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}

// ---------- Extern + log helpers ----------

#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "UnityEngineDebug.__Log__SystemString__SystemVoid"]
    fn debug_log(ptr: *const u8, len: usize);
}

fn log(s: &str) {
    unsafe { debug_log(s.as_ptr(), s.len()) }
}

fn log_bytes(b: &[u8]) {
    unsafe { debug_log(b.as_ptr(), b.len()) }
}

// Manual base-10 / base-16 formatting — no `core::fmt` so we avoid the
// formatter-machinery WASM bloat that pure-no_std + ReleaseSmall would still
// emit. Each formatter writes into `FMT_BUF` and returns a slice of it.
static mut FMT_BUF: [u8; 64] = [0; 64];

fn fmt_i32(value: i32) -> &'static [u8] {
    let buf = &raw mut FMT_BUF;
    let buf = unsafe { &mut *buf };
    let mut v: u32 = if value < 0 {
        (-(value as i64)) as u32
    } else {
        value as u32
    };
    let mut i = buf.len();
    if v == 0 {
        i -= 1;
        buf[i] = b'0';
    }
    while v != 0 {
        i -= 1;
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    if value < 0 {
        i -= 1;
        buf[i] = b'-';
    }
    &buf[i..]
}

fn fmt_u32_hex(mut v: u32) -> &'static [u8] {
    let buf = &raw mut FMT_BUF;
    let buf = unsafe { &mut *buf };
    let mut i = buf.len();
    if v == 0 {
        i -= 1;
        buf[i] = b'0';
    }
    while v != 0 {
        let nib = (v & 0xF) as u8;
        i -= 1;
        buf[i] = if nib < 10 { b'0' + nib } else { b'a' + (nib - 10) };
        v >>= 4;
    }
    &buf[i..]
}

// `log_kv(label, value_bytes)` writes "label = <value>" into a separate
// scratch buffer and logs it. Avoids `core::fmt`.
static mut KV_BUF: [u8; 128] = [0; 128];

fn log_kv(label: &str, value: &[u8]) {
    let dst = &raw mut KV_BUF;
    let dst = unsafe { &mut *dst };
    let mut n = 0usize;
    for &b in label.as_bytes() {
        if n >= dst.len() {
            break;
        }
        dst[n] = b;
        n += 1;
    }
    for &b in b" = " {
        if n >= dst.len() {
            break;
        }
        dst[n] = b;
        n += 1;
    }
    for &b in value {
        if n >= dst.len() {
            break;
        }
        dst[n] = b;
        n += 1;
    }
    log_bytes(&dst[..n]);
}

// ---------- Globals ----------

static mut COUNTER: i32 = 0;
static mut ACCUM: i64 = 0;
static mut UPDATE_TICK: i32 = 0;

static mut SCRATCH: [u32; 256] = [0; 256];

// `__udon_meta` is supplied as a sidecar file (`wasm_bench_rs.udon_meta.json`)
// alongside the compiled `.wasm` — see docs/spec_udonmeta_conversion.md.

// ---------- Tests ----------

fn test_arithmetic() {
    log("== arithmetic ==");
    log_kv("1 + 2", fmt_i32(1 + 2));
    log_kv("100 * 200", fmt_i32(100 * 200));
    log_kv("-50 / 7", fmt_i32(-50i32 / 7));
    log_kv("17 % 5", fmt_i32(17i32 % 5));
    log_kv("1 << 10", fmt_i32(1i32 << 10));
    log_kv("0x7F00 | 0x00FF", fmt_u32_hex(0x7F00u32 | 0x00FF));
    log_kv("0xABCD ^ 0x00FF", fmt_u32_hex(0xABCDu32 ^ 0x00FF));
}

fn test_control_flow() {
    log("== control_flow ==");

    let mut i: i32 = 0;
    while i < 5 {
        log_kv("i", fmt_i32(i));
        i += 1;
    }

    let x: i32 = 7;
    if x > 5 {
        log("x > 5");
    } else {
        log("x <= 5");
    }

    let tag: i32 = 2;
    match tag {
        0 => log("tag=0"),
        1 => log("tag=1"),
        2 => log("tag=2"),
        3 => log("tag=3"),
        _ => log("tag=other"),
    }

    let mut sum: i32 = 0;
    let mut j: i32 = 1;
    while j <= 10 {
        if j % 2 == 0 {
            j += 1;
            continue;
        }
        sum += j;
        j += 1;
    }
    log_kv("sum of odd 1..10", fmt_i32(sum)); // 25
}

fn test_globals() {
    log("== globals ==");
    unsafe {
        COUNTER = 0;
        let mut i: i32 = 0;
        while i < 4 {
            COUNTER += i;
            i += 1;
        }
        log_kv("counter", fmt_i32(COUNTER)); // 6

        ACCUM = 0;
        let mut k: i64 = 1;
        while k <= 5 {
            ACCUM += k;
            k += 1;
        }
        // Print just the low 32 bits of ACCUM — fmt_i32 takes i32.
        log_kv("accum", fmt_i32(ACCUM as i32)); // 15
    }
}

#[inline(never)]
fn factorial(n: i32) -> i32 {
    if n <= 1 {
        1
    } else {
        n * factorial(n - 1)
    }
}

#[inline(never)]
fn fib(n: i32) -> i32 {
    if n < 2 {
        n
    } else {
        fib(n - 1) + fib(n - 2)
    }
}

fn test_recursion() {
    log("== recursion ==");
    log_kv("factorial(5)", fmt_i32(factorial(5))); // 120
    log_kv("fib(10)", fmt_i32(fib(10))); // 55
}

fn test_memory() {
    log("== memory ==");

    unsafe {
        let scratch = &raw mut SCRATCH;
        let scratch = &mut *scratch;
        scratch[0] = 0xDEADBEEF;
        scratch[1] = 42;
        log_kv("scratch[0]", fmt_u32_hex(scratch[0])); // DEADBEEF
        log_kv("scratch[1]", fmt_i32(scratch[1] as i32)); // 42

        let bytes = scratch.as_mut_ptr() as *mut u8;
        bytes.add(8).write(0x11);
        bytes.add(9).write(0x22);
        bytes.add(10).write(0x33);
        bytes.add(11).write(0x44);
        log_kv("scratch[2] (LE byte assemble)", fmt_u32_hex(scratch[2])); // 44332211
    }

    let before = core::arch::wasm32::memory_size(0) as i32;
    let grew = core::arch::wasm32::memory_grow(0, 1) as i32;
    let after = core::arch::wasm32::memory_size(0) as i32;
    log_kv("memory.size before pages", fmt_i32(before));
    log_kv("memory.grow returned", fmt_i32(grew));
    log_kv("memory.size after  pages", fmt_i32(after));
}

#[inline(never)]
fn double_it(x: i32) -> i32 {
    x * 2
}
#[inline(never)]
fn negate_it(x: i32) -> i32 {
    -x
}
#[inline(never)]
fn add_one(x: i32) -> i32 {
    x + 1
}

type FnPtr = fn(i32) -> i32;
static OPS: [FnPtr; 3] = [double_it, negate_it, add_one];

fn test_indirect_call() {
    log("== call_indirect ==");
    log_kv("double_it(21)", fmt_i32(OPS[0](21))); // 42
    log_kv("negate_it(7)", fmt_i32(OPS[1](7))); // -7
    log_kv("add_one(99)", fmt_i32(OPS[2](99))); // 100
}

#[derive(Clone, Copy)]
#[repr(C)]
struct Point {
    x: i32,
    y: i32,
}

#[repr(C)]
struct Rect {
    tl: Point,
    br: Point,
    tag: i32,
}

#[inline(never)]
fn point_area(p: Point) -> i32 {
    p.x * p.y
}

#[inline(never)]
fn point_translate(p: &mut Point, dx: i32, dy: i32) {
    p.x += dx;
    p.y += dy;
}

#[inline(never)]
fn rect_width(r: &Rect) -> i32 {
    r.br.x - r.tl.x
}

static mut G_RECT: Rect = Rect {
    tl: Point { x: 1, y: 2 },
    br: Point { x: 11, y: 22 },
    tag: 0x1234,
};

fn test_struct() {
    log("== struct ==");

    let p = Point { x: 6, y: 7 };
    log_kv("point_area(6,7)", fmt_i32(point_area(p))); // 42

    let mut q = Point { x: 10, y: 20 };
    point_translate(&mut q, 3, 4);
    log_kv("q.x after translate", fmt_i32(q.x)); // 13
    log_kv("q.y after translate", fmt_i32(q.y)); // 24

    unsafe {
        let r = &raw mut G_RECT;
        log_kv("rect_width(g_rect)", fmt_i32(rect_width(&*r))); // 10
        log_kv("g_rect.tag", fmt_u32_hex((*r).tag as u32)); // 1234
        (*r).tag += 1;
        log_kv("g_rect.tag after inc", fmt_u32_hex((*r).tag as u32)); // 1235
    }

    let mut points = [
        Point { x: 1, y: 1 },
        Point { x: 2, y: 4 },
        Point { x: 3, y: 9 },
    ];
    let mut sum: i32 = 0;
    let mut i = 0;
    while i < points.len() {
        sum += point_area(points[i]);
        i += 1;
    }
    log_kv("sum of areas", fmt_i32(sum)); // 36

    point_translate(&mut points[1], 100, 200);
    log_kv("points[1].x after", fmt_i32(points[1].x)); // 102
    log_kv("points[1].y after", fmt_i32(points[1].y)); // 204
}

fn test_64bit_and_float() {
    log("== 64bit_and_float ==");
    let a: i64 = 0x1_0000_0000;
    let b: i64 = 5;
    let r = a + b;
    log_kv("(0x100000000 + 5) hi32", fmt_i32((r >> 32) as i32)); // 1
    log_kv("(0x100000000 + 5) lo32", fmt_i32((r & 0xFFFFFFFF) as i32)); // 5

    let x: f64 = 3.14;
    let y: f64 = 2.0;
    let m = x * y; // 6.28
    // Print 100 * m floored — avoids needing a float formatter.
    let scaled = (m * 100.0) as i32; // ~628
    log_kv("floor(3.14 * 2.0 * 100)", fmt_i32(scaled));
}

// ---------- Events ----------

#[unsafe(no_mangle)]
pub extern "C" fn on_start() {
    // Stay within Udon's 10 s per-event VM budget; heavier tests run one
    // per click via `on_interact`.
    log("=== on_start begin ===");
    test_arithmetic();
    test_control_flow();
    log("=== on_start end ===");
}

#[unsafe(no_mangle)]
pub extern "C" fn on_update() {
    unsafe {
        UPDATE_TICK = UPDATE_TICK.wrapping_add(1);
        // Touch COUNTER so the global isn't dead-code-eliminated.
        let _ = core::ptr::read_volatile(&raw const COUNTER);
    }
}

static mut INTERACT_STEP: i32 = 0;

#[unsafe(no_mangle)]
pub extern "C" fn on_interact() {
    // One click = one step = one test. Each invocation gets its own 10 s
    // VM budget, so heavy tests finish as long as they run solo.
    let step = unsafe { INTERACT_STEP };
    unsafe { INTERACT_STEP = INTERACT_STEP.wrapping_add(1) };
    match step {
        0 => test_globals(),
        1 => test_recursion(),
        2 => test_memory(),
        3 => test_indirect_call(),
        4 => test_struct(),
        5 => test_64bit_and_float(),
        _ => log("(no more steps)"),
    }
    unsafe { COUNTER = COUNTER.wrapping_add(1) };
}
