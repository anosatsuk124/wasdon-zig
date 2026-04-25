//! WASM `alloc` bench — heap-using sibling of `examples/wasm-bench-rs`.
//!
//! Built with `wasm32v1-none` (MVP-only). Registers a tiny bump allocator
//! over a `static mut` arena as `#[global_allocator]` so `alloc` types
//! (`Vec`, `Box`, `String`, `BTreeMap`) work without dragging in
//! `dlmalloc`/`talc`. The allocator is reset at the top of each event
//! entrypoint, matching the per-event 10 s Udon VM budget.
//!
//! Coverage: `Vec` push + realloc, `Box` linked list, `String` concat,
//! nested `Vec<Vec<u32>>`, `BTreeMap` insert/iter, `memory.grow` probe.

#![no_std]

extern crate alloc;

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};
use core::panic::PanicInfo;

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}

// ---------- Extern + log helpers (mirrors wasm-bench-rs) ----------

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

// Shared scratch buffers — manual base-10/hex formatting avoids pulling
// in `core::fmt`'s machinery, which would inflate the binary.
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

static mut KV_BUF: [u8; 192] = [0; 192];

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

// ---------- Bump allocator ----------

// 256 KiB arena lives in linear memory as a `static mut` byte array, so
// it sits in one of the initial pages declared by `__udon_meta` rather
// than coming from `memory.grow`. Keeping the hot allocation path off
// `memory.grow` makes the lowered code provably MVP-clean — no
// `memory.copy`/`memory.fill` paths to worry about.
const ARENA_SIZE: usize = 256 * 1024;
static mut ARENA: [u8; ARENA_SIZE] = [0; ARENA_SIZE];
static mut BUMP: usize = 0;
static mut PEAK: usize = 0;

struct BumpAlloc;

unsafe impl GlobalAlloc for BumpAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let cur = unsafe { *(&raw const BUMP) };
        let align = layout.align();
        let aligned = (cur + align - 1) & !(align - 1);
        let new = match aligned.checked_add(layout.size()) {
            Some(n) => n,
            None => return core::ptr::null_mut(),
        };
        if new > ARENA_SIZE {
            return core::ptr::null_mut();
        }
        unsafe {
            *(&raw mut BUMP) = new;
            if new > *(&raw const PEAK) {
                *(&raw mut PEAK) = new;
            }
        }
        let arena = &raw mut ARENA as *mut u8;
        unsafe { arena.add(aligned) }
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: Layout) {
        // Bump allocator: free is a no-op. The arena is reset wholesale
        // at the top of every event entrypoint via `bump_reset`.
    }
}

#[global_allocator]
static GLOBAL: BumpAlloc = BumpAlloc;

fn bump_reset() {
    unsafe {
        *(&raw mut BUMP) = 0;
        *(&raw mut PEAK) = 0;
    }
}

fn bump_used() -> i32 {
    unsafe { *(&raw const BUMP) as i32 }
}

fn bump_peak() -> i32 {
    unsafe { *(&raw const PEAK) as i32 }
}

// ---------- __udon_meta ----------

const UDON_META_JSON: &[u8] = br#"{
  "version": 1,
  "behaviour": { "syncMode": "manual" },
  "functions": {
    "start":    { "source": {"kind":"export","name":"on_start"},    "label":"_start",    "export": true, "event":"Start"    },
    "update":   { "source": {"kind":"export","name":"on_update"},   "label":"_update",   "export": true, "event":"Update"   },
    "interact": { "source": {"kind":"export","name":"on_interact"}, "label":"_interact", "export": true, "event":"Interact" }
  },
  "options": {
    "strict": false,
    "recursion": "stack",
    "memory": { "initialPages": 8, "maxPages": 32, "udonName": "_memory" }
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

// ---------- Bench scenarios ----------

fn bench_vec_push_sum() {
    log("== vec_push_sum ==");
    let n: i32 = 1000;
    let mut v: Vec<i32> = Vec::new();
    let mut i: i32 = 1;
    while i <= n {
        v.push(i);
        i += 1;
    }
    let mut sum: i64 = 0;
    let mut k = 0usize;
    while k < v.len() {
        sum += v[k] as i64;
        k += 1;
    }
    log_kv("len", fmt_i32(v.len() as i32));
    log_kv("cap", fmt_i32(v.capacity() as i32));
    // sum of 1..=1000 = 500500
    log_kv("sum lo32", fmt_i32(sum as i32));
    log_kv("bump used (bytes)", fmt_i32(bump_used()));
}

struct Node {
    value: i32,
    next: Option<Box<Node>>,
}

fn bench_box_chain() {
    log("== box_chain ==");
    let n: i32 = 200;
    let mut head: Option<Box<Node>> = None;
    let mut i: i32 = 1;
    while i <= n {
        head = Some(Box::new(Node {
            value: i,
            next: head.take(),
        }));
        i += 1;
    }
    let mut sum: i64 = 0;
    let mut count: i32 = 0;
    let mut cur = head.as_deref();
    while let Some(node) = cur {
        sum += node.value as i64;
        count += 1;
        cur = node.next.as_deref();
    }
    log_kv("nodes", fmt_i32(count));
    // sum of 1..=200 = 20100
    log_kv("sum lo32", fmt_i32(sum as i32));
    log_kv("bump used (bytes)", fmt_i32(bump_used()));
}

fn bench_string_concat() {
    log("== string_concat ==");
    let mut s = String::new();
    let n: i32 = 256;
    let mut i: i32 = 0;
    while i < n {
        // Push one ASCII byte per iteration. 'A' + (i % 26).
        let ch = (b'A' + ((i as u32) % 26) as u8) as char;
        s.push(ch);
        i += 1;
    }
    let mut checksum: u32 = 0;
    for &b in s.as_bytes() {
        checksum = checksum.wrapping_mul(31).wrapping_add(b as u32);
    }
    log_kv("len", fmt_i32(s.len() as i32));
    log_kv("checksum", fmt_u32_hex(checksum));
    log_kv("bump used (bytes)", fmt_i32(bump_used()));
}

#[inline(never)]
fn build_row(width: u32) -> Vec<u32> {
    let mut row: Vec<u32> = Vec::new();
    let mut k: u32 = 0;
    while k < width {
        row.push(k * k);
        k += 1;
    }
    row
}

fn bench_nested_vec() {
    log("== nested_vec ==");
    let rows: u32 = 32;
    let mut grid: Vec<Vec<u32>> = Vec::new();
    let mut i: u32 = 0;
    while i < rows {
        grid.push(build_row(i + 1));
        i += 1;
    }
    let mut total: u64 = 0;
    let mut total_len: u32 = 0;
    let mut r = 0usize;
    while r < grid.len() {
        total_len += grid[r].len() as u32;
        let mut c = 0usize;
        while c < grid[r].len() {
            total += grid[r][c] as u64;
            c += 1;
        }
        r += 1;
    }
    log_kv("rows", fmt_i32(grid.len() as i32));
    // sum of row lengths = 1+2+..+32 = 528
    log_kv("total len", fmt_i32(total_len as i32));
    log_kv("total lo32", fmt_i32(total as i32));
    log_kv("bump used (bytes)", fmt_i32(bump_used()));
}

fn bench_btree_sum() {
    log("== btree_sum ==");
    let mut map: BTreeMap<i32, i32> = BTreeMap::new();
    let n: i32 = 100;
    let mut i: i32 = 0;
    while i < n {
        // Reverse insert order to exercise the tree's rebalancing.
        let key = n - 1 - i;
        map.insert(key, key * key);
        i += 1;
    }
    let mut sum: i64 = 0;
    let mut count: i32 = 0;
    for (_k, v) in map.iter() {
        sum += *v as i64;
        count += 1;
    }
    log_kv("entries", fmt_i32(count));
    // sum of 0^2 + 1^2 + .. + 99^2 = 328350
    log_kv("sum lo32", fmt_i32(sum as i32));
    log_kv("bump used (bytes)", fmt_i32(bump_used()));
}

fn bench_grow_probe() {
    log("== grow_probe ==");
    let before = core::arch::wasm32::memory_size(0) as i32;
    let prev = core::arch::wasm32::memory_grow(0, 1) as i32;
    let after = core::arch::wasm32::memory_size(0) as i32;
    log_kv("memory.size before pages", fmt_i32(before));
    log_kv("memory.grow returned", fmt_i32(prev));
    log_kv("memory.size after  pages", fmt_i32(after));
    log_kv("peak bump (bytes)", fmt_i32(bump_peak()));
}

// ---------- Events ----------

// Smoke-test bisection harness for `on_start`. Each step logs a sentinel
// before doing its work so a halt without an exception message can be
// localized: whichever sentinel is the LAST one in the Unity log
// identifies the line that crashed the VM. Steps escalate in
// complexity — log only → bump alloc → Vec::push 1 → Vec::push N — so
// you can tell whether the issue is the allocator setup, single-elt
// alloc, or the realloc/grow path.
#[unsafe(no_mangle)]
pub extern "C" fn on_start() {
    log("S0: alive");

    bump_reset();
    log("S1: bump_reset ok");

    // Direct allocator probe — no Rust heap type involved yet.
    let layout = unsafe { core::alloc::Layout::from_size_align_unchecked(16, 4) };
    let p = unsafe { GLOBAL.alloc(layout) };
    if p.is_null() {
        log("S2: alloc returned null");
        return;
    }
    log("S2: alloc 16/4 ok");
    unsafe {
        // Touch the memory to force a real i32.store path.
        *(p as *mut u32) = 0xCAFEBABE;
    }
    log("S3: store ok");
    let read = unsafe { *(p as *const u32) };
    log_kv("S4: read back hex", fmt_u32_hex(read));

    bump_reset();
    log("S5: bump_reset ok (#2)");

    // Single Vec push — exercises Rust's RawVec::reserve_for_push
    // path without growing past the first capacity bucket.
    let mut v: Vec<i32> = Vec::new();
    log("S6: Vec::new ok");
    v.push(42);
    log_kv("S7: push(42) ok; v[0]", fmt_i32(v[0]));

    // Multi-push that forces at least one realloc.
    let mut k: i32 = 0;
    while k < 64 {
        v.push(k);
        k += 1;
    }
    log_kv("S8: pushed 64 more; len", fmt_i32(v.len() as i32));

    log("=== on_start end ===");
}

static mut UPDATE_TICK: i32 = 0;

#[unsafe(no_mangle)]
pub extern "C" fn on_update() {
    unsafe {
        let t = &raw mut UPDATE_TICK;
        *t = (*t).wrapping_add(1);
    }
}

static mut INTERACT_STEP: i32 = 0;

#[unsafe(no_mangle)]
pub extern "C" fn on_interact() {
    bump_reset();
    let step = unsafe { *(&raw const INTERACT_STEP) };
    unsafe {
        let s = &raw mut INTERACT_STEP;
        *s = (*s).wrapping_add(1);
    }
    match step {
        0 => bench_vec_push_sum(),
        1 => bench_box_chain(),
        2 => bench_string_concat(),
        3 => bench_nested_vec(),
        4 => bench_btree_sum(),
        5 => bench_grow_probe(),
        _ => log("(no more steps)"),
    }
}
