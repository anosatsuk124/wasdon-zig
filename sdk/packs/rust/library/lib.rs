#![no_std]
#[allow(non_snake_case)]
pub mod raw;

#[link(wasm_import_module = "udon.static")]
unsafe extern "C" {
    #[link_name = "SystemString.__Copy__SystemString__SystemString"]
    fn copy_string(ptr: *const u8, len: usize) -> i32;
}
pub fn string(text: &str) -> i32 {
    unsafe { copy_string(text.as_ptr(), text.len()) }
}
pub fn log(text: &str) {
    unsafe { raw::UnityEngineDebug_Log__SystemObject__SystemVoid(string(text)) }
}
pub use raw::{
    UnityEngineTransform_get_position__UnityEngineVector3 as position,
    VRCSDKBaseNetworking_get_LocalPlayer__VRCSDKBaseVRCPlayerApi as local_player,
    VRCUdonCommonInterfacesIUdonEventReceiver_RequestSerialization__SystemVoid as serialize,
    VRCUdonCommonInterfacesIUdonEventReceiver_SendCustomEvent__SystemString__SystemVoid as send_event,
};
pub unsafe fn take_ownership(object: i32) {
    raw::VRCSDKBaseNetworking_SetOwner__VRCSDKBaseVRCPlayerApi_UnityEngineGameObject__SystemVoid(local_player(), object);
}
#[macro_export]
macro_rules! field {
    ($name:ident, $import:literal, ($($arg:ident: $ty:ty),*) $(-> $ret:ty)?) => {
        #[link(wasm_import_module = "wasdon.field")]
        unsafe extern "C" {
            #[link_name = $import]
            fn $name($($arg: $ty),*) $(-> $ret)?;
        }
    };
}
