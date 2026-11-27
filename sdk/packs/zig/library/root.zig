pub const raw = @import("raw.zig");

const copyString = @extern(*const fn ([*]const u8, usize) callconv(.c) i32, .{ .library_name = "udon.static", .name = "SystemString.__Copy__SystemString__SystemString" });

pub fn string(text: []const u8) i32 {
    return copyString(text.ptr, text.len);
}
pub fn log(text: []const u8) void {
    raw.UnityEngineDebug_Log__SystemObject__SystemVoid(string(text));
}
pub fn field(comptime T: type, comptime name: []const u8) *const fn () callconv(.c) T {
    return @extern(*const fn () callconv(.c) T, .{ .library_name = "wasdon.field", .name = name });
}
pub fn setter(comptime T: type, comptime name: []const u8) *const fn (T) callconv(.c) void {
    return @extern(*const fn (T) callconv(.c) void, .{ .library_name = "wasdon.field", .name = name });
}
pub const position = raw.UnityEngineTransform_get_position__UnityEngineVector3;
pub const localPlayer = raw.VRCSDKBaseNetworking_get_LocalPlayer__VRCSDKBaseVRCPlayerApi;
pub const serialize = raw.VRCUdonCommonInterfacesIUdonEventReceiver_RequestSerialization__SystemVoid;
pub const sendEvent = raw.VRCUdonCommonInterfacesIUdonEventReceiver_SendCustomEvent__SystemString__SystemVoid;
pub fn takeOwnership(object: i32) void {
    raw.VRCSDKBaseNetworking_SetOwner__VRCSDKBaseVRCPlayerApi_UnityEngineGameObject__SystemVoid(localPlayer(), object);
}
