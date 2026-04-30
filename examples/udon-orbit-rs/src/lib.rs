//! VRChat Udon sample (Rust port of `examples/udon-orbit`):
//! orbit own GameObject around its spawn point and clone it on interact.
//!
//! Target language is Udon Assembly. Every Udon object type flows through
//! the WASM boundary as an opaque `i32` heap-handle — never do arithmetic
//! on those values.
//!
//! Built with `wasm32v1-none` (MVP-only). Mutable Rust statics live in
//! linear memory (the MVP target lacks the `mutable-globals` feature), so
//! `__udon_meta` only exposes the `udon.self` slot — the orbit parameters
//! stay private to wasm-side state.

#![no_std]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}

// ---------- Raw externs (verbatim names from docs/udon_nodes.txt) ----------

#[link(wasm_import_module = "env")]
unsafe extern "C" {
    #[link_name = "UnityEngineDebug.__Log__SystemString__SystemVoid"]
    fn debug_log(ptr: *const u8, len: usize);

    #[link_name = "UnityEngineComponent.__get_gameObject__UnityEngineGameObject"]
    fn component_get_game_object(self_arg: i32) -> i32;

    #[link_name = "UnityEngineTransform.__get_position__UnityEngineVector3"]
    fn transform_get_position(self_arg: i32) -> i32;
    #[link_name = "UnityEngineTransform.__set_position__UnityEngineVector3__SystemVoid"]
    fn transform_set_position(self_arg: i32, pos: i32);

    #[link_name = "UnityEngineVector3.__ctor__SystemSingle_SystemSingle_SystemSingle__UnityEngineVector3"]
    fn vector3_ctor(x: f32, y: f32, z: f32) -> i32;
    #[link_name = "UnityEngineVector3.__op_Addition__UnityEngineVector3_UnityEngineVector3__UnityEngineVector3"]
    fn vector3_add(a: i32, b: i32) -> i32;

    #[link_name = "UnityEngineTime.__get_deltaTime__SystemSingle"]
    fn time_delta_time() -> f32;

    #[link_name = "UnityEngineMathf.__Sin__SystemSingle__SystemSingle"]
    fn mathf_sin(x: f32) -> f32;
    #[link_name = "UnityEngineMathf.__Cos__SystemSingle__SystemSingle"]
    fn mathf_cos(x: f32) -> f32;

    // Falsified Udon type name — docs/udon_specs.md §7.4.
    #[link_name = "VRCInstantiate.__Instantiate__UnityEngineGameObject__UnityEngineGameObject"]
    fn vrc_instantiate(go: i32) -> i32;

    // `self` is a Udon-only singleton bound through a WASM **function** import
    // (see the matching note in the Zig version). The translator turns it into
    // a pure read of the data slot `__G__self` rather than a real EXTERN.
    #[link_name = "udon.self"]
    fn udon_self() -> i32;
}

fn log(s: &str) {
    unsafe { debug_log(s.as_ptr(), s.len()) }
}

// ---------- State (linear-memory backed) ----------

static mut RADIUS: f32 = 1.5;
static mut ANGULAR_SPEED: f32 = 2.0;
static mut PHASE: f32 = 0.0;
static mut CLONE_COUNT: i32 = 0;

// ---------- Events ----------

#[unsafe(no_mangle)]
pub extern "C" fn on_start() {
    log("udon-orbit-rs: _start");
    unsafe {
        PHASE = 0.0;
        CLONE_COUNT = 0;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn on_update() {
    unsafe {
        PHASE += ANGULAR_SPEED * time_delta_time();

        let t = udon_self();
        let center = transform_get_position(t);
        let dx = RADIUS * mathf_cos(PHASE);
        let dz = RADIUS * mathf_sin(PHASE);
        let delta = vector3_ctor(dx, 0.0, dz);
        let new_pos = vector3_add(center, delta);
        transform_set_position(t, new_pos);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn on_interact() {
    unsafe {
        let go = component_get_game_object(udon_self());
        let _ = vrc_instantiate(go);
        CLONE_COUNT = CLONE_COUNT.wrapping_add(1);
    }
    log("udon-orbit-rs: cloned");
}

// `__udon_meta` is supplied as a sidecar file (`udon_orbit_rs.udon_meta.json`)
// alongside the compiled `.wasm` — see docs/spec_udonmeta_conversion.md.
