const w = @import("wasdon");
const gameObject = w.field(i32, "gameObject");
const behaviour = w.field(i32, "behaviour");
const target = w.field(i32, "target");
const switchOn = w.field(i32, "switchOn");
const setSwitch = w.setter(i32, "set_switchOn");

fn apply() void {
    const object = target();
    if (w.raw.VRCSDKBaseUtilities_IsValid__SystemObject__SystemBoolean(object) != 0)
        w.raw.UnityEngineGameObject_SetActive__SystemBoolean__SystemVoid(object, switchOn());
}
export fn _start() void {
    w.log("Hello from Wasdon");
    apply();
}
export fn _interact() void {
    w.takeOwnership(gameObject());
    if (w.raw.VRCSDKBaseNetworking_IsOwner__UnityEngineGameObject__SystemBoolean(gameObject()) != 0) {
        setSwitch(@intFromBool(switchOn() == 0));
        apply();
        w.serialize(behaviour());
    }
}
export fn _onDeserialization() void {
    apply();
}
export fn _onPlayerJoined() void {
    const player = w.field(i32, "onPlayerJoinedPlayer")();
    if (w.raw.VRCSDKBaseUtilities_IsValid__SystemObject__SystemBoolean(player) != 0)
        w.raw.UnityEngineDebug_Log__SystemObject__SystemVoid(w.raw.VRCSDKBaseVRCPlayerApi_get_displayName__SystemString(player));
}
