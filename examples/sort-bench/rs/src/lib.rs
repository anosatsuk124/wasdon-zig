//! Same sort and Udon event interface as ../zig/main.zig.
#![no_std]

use core::{panic::PanicInfo, ptr};

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

#[repr(transparent)]
#[derive(Clone, Copy)]
struct ByteArray(i32);

#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "sort.data"]
    fn data() -> ByteArray;
    #[link_name = "udon.memory"]
    fn memory() -> ByteArray;
    #[link_name = "SystemByteArray.__get_Length__SystemInt32"]
    fn byte_length(array: ByteArray) -> usize;
    #[link_name = "SystemBuffer.__BlockCopy__SystemArray_SystemInt32_SystemArray_SystemInt32_SystemInt32__SystemVoid"]
    fn block_copy(src: ByteArray, src_at: usize, dst: ByteArray, dst_at: usize, count: usize);
}

const CAPACITY: usize = 65_536;
static mut FRONT: [u8; CAPACITY] = [0; CAPACITY];
static mut BACK: [u8; CAPACITY] = [0; CAPACITY];
static mut COUNT: usize = 0;
static mut WIDTH: usize = 1;
static mut IN_FRONT: bool = true;

#[unsafe(no_mangle)]
pub extern "C" fn Load() {
    unsafe {
        let input = data();
        COUNT = byte_length(input).min(CAPACITY);
        block_copy(input, 0, memory(), ptr::addr_of_mut!(FRONT) as usize, COUNT);
        WIDTH = 1;
        IN_FRONT = true;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn Sort() {
    unsafe {
        while WIDTH < COUNT {
            merge();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn Step() {
    unsafe {
        if WIDTH < COUNT {
            merge();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn Read() {
    unsafe {
        let src = if IN_FRONT {
            ptr::addr_of!(FRONT)
        } else {
            ptr::addr_of!(BACK)
        };
        block_copy(memory(), src as usize, data(), 0, COUNT);
    }
}

// The two fixed buffers never alias. Load caps COUNT to their capacity,
// and each arm only reads an element still inside its half-open run.
unsafe fn merge() {
    let front = ptr::addr_of_mut!(FRONT).cast::<u8>();
    let back = ptr::addr_of_mut!(BACK).cast::<u8>();
    let (src, dst) = if IN_FRONT {
        (front, back)
    } else {
        (back, front)
    };
    let mut start = 0;
    while start < COUNT {
        let mid = (start + WIDTH).min(COUNT);
        let end = (mid + WIDTH).min(COUNT);
        let mut left = start;
        let mut right = mid;
        for i in start..end {
            if left < mid && (right == end || *src.add(left) <= *src.add(right)) {
                *dst.add(i) = *src.add(left);
                left += 1;
            } else {
                *dst.add(i) = *src.add(right);
                right += 1;
            }
        }
        start = end;
    }
    IN_FRONT = !IN_FRONT;
    WIDTH *= 2;
}

const UDON_META_JSON: &[u8] = br#"{
  "version": 1,
  "fields": {
    "memory": { "source": {"kind":"import","name":"udon.memory"}, "udonName":"__G__memory", "type":"SystemByteArray" },
    "data": { "source": {"kind":"import","name":"sort.data"}, "udonName":"data", "type":"SystemByteArray", "export":true }
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
