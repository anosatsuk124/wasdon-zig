//! Rust producer for the same grid events and byte images as the Zig worker.
#![no_std]

mod kernels;
use core::{panic::PanicInfo, ptr};
use kernels::{Grid, MAX_SIDE};

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

#[repr(transparent)]
#[derive(Clone, Copy)]
struct ByteArray(i32);

#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "grid.data"]
    fn data() -> ByteArray;
    #[link_name = "grid.side"]
    fn side() -> i32;
    #[link_name = "grid.kind"]
    fn kind() -> i32;
    #[link_name = "grid.set_finished"]
    fn set_finished(value: i32);
    #[link_name = "udon.memory"]
    fn memory() -> ByteArray;
    #[link_name = "SystemByteArray.__get_Length__SystemInt32"]
    fn byte_length(array: ByteArray) -> usize;
    #[link_name = "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid"]
    fn block_copy(src: ByteArray, from: usize, dst: ByteArray, to: usize, count: usize);
}

static mut WORK: Grid = Grid::new(0, 0);
static mut PIXELS: [u8; MAX_SIDE * MAX_SIDE] = [0; MAX_SIDE * MAX_SIDE];
static mut COLUMNS: [usize; MAX_SIDE] = [0; MAX_SIDE];

#[unsafe(no_mangle)]
pub extern "C" fn Load() {
    unsafe {
        WORK = Grid::new(0, 0);
        let n = side() as usize;
        let k = kind();
        let input = data();
        if !(1..=MAX_SIDE).contains(&n) || !(0..=2).contains(&k) || byte_length(input) != n * n {
            return;
        }
        block_copy(
            input,
            0,
            memory(),
            ptr::addr_of_mut!(PIXELS) as usize,
            n * n,
        );
        WORK = Grid::new(k, n);
    }
}

// The Udon VM executes these events serially. No guest references escape
// the event, and none of the kernels makes a re-entrant host call.
fn compute(full: bool) {
    unsafe {
        let work = &mut *ptr::addr_of_mut!(WORK);
        let pixels = &mut (&mut *ptr::addr_of_mut!(PIXELS))[..work.side * work.side];
        let columns = &mut *ptr::addr_of_mut!(COLUMNS);
        while !work.done() {
            work.step(pixels, columns);
            if !full {
                break;
            }
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn Run() {
    compute(true);
}

#[unsafe(no_mangle)]
pub extern "C" fn Step() {
    compute(false);
}

#[unsafe(no_mangle)]
pub extern "C" fn Read() {
    unsafe {
        let n = WORK.side;
        block_copy(memory(), ptr::addr_of!(PIXELS) as usize, data(), 0, n * n);
    }
    Poll();
}

#[unsafe(no_mangle)]
pub extern "C" fn Poll() {
    unsafe {
        set_finished((&*ptr::addr_of!(WORK)).done() as i32);
    }
}

const META: &[u8] = br#"{"version":1,"fields":{
    "memory":{"source":{"kind":"import","name":"udon.memory"},"udonName":"__G__memory","type":"SystemByteArray"},
    "data":{"source":{"kind":"import","name":"grid.data"},"udonName":"data","type":"SystemByteArray","export":true},
    "side":{"source":{"kind":"import","name":"grid.side"},"udonName":"side","type":"int","export":true},
    "kind":{"source":{"kind":"import","name":"grid.kind"},"udonName":"kind","type":"int","export":true},
    "finished":{"source":{"kind":"import","name":"grid.finished","setter":"grid.set_finished"},"udonName":"finished","type":"int","export":true}
}}"#;

#[unsafe(no_mangle)]
pub extern "C" fn __udon_meta_ptr() -> *const u8 {
    META.as_ptr()
}

#[unsafe(no_mangle)]
pub extern "C" fn __udon_meta_len() -> usize {
    META.len()
}
