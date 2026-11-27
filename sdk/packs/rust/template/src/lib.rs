#![no_std]
use wasdon::{self as w, raw};

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { loop {} }

w::field!(game_object, "gameObject", () -> i32);
w::field!(behaviour, "behaviour", () -> i32);
w::field!(target, "target", () -> i32);
w::field!(switch_on, "switchOn", () -> i32);
w::field!(set_switch, "set_switchOn", (value: i32));
w::field!(joined_player, "onPlayerJoinedPlayer", () -> i32);

unsafe fn apply() {
    let object = target();
    if raw::VRCSDKBaseUtilities_IsValid__SystemObject__SystemBoolean(object) != 0 {
        raw::UnityEngineGameObject_SetActive__SystemBoolean__SystemVoid(object, switch_on());
    }
}
#[no_mangle]
pub unsafe extern "C" fn _start() {
    w::log("Hello from Wasdon");
    apply();
}
#[no_mangle]
pub unsafe extern "C" fn _interact() {
    w::take_ownership(game_object());
    if raw::VRCSDKBaseNetworking_IsOwner__UnityEngineGameObject__SystemBoolean(game_object()) != 0 {
        set_switch((switch_on() == 0) as i32);
        apply();
        w::serialize(behaviour());
    }
}
#[no_mangle]
pub unsafe extern "C" fn _onDeserialization() { apply(); }
#[no_mangle]
pub unsafe extern "C" fn _onPlayerJoined() {
    let player = joined_player();
    if raw::VRCSDKBaseUtilities_IsValid__SystemObject__SystemBoolean(player) != 0 {
        raw::UnityEngineDebug_Log__SystemObject__SystemVoid(raw::VRCSDKBaseVRCPlayerApi_get_displayName__SystemString(player));
    }
}
