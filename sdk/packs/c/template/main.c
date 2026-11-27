#include "wasdon.h"

WASDON_FIELD(int32_t, game_object, "gameObject");
WASDON_FIELD(int32_t, behaviour, "behaviour");
WASDON_FIELD(int32_t, target, "target");
WASDON_FIELD(int32_t, switch_on, "switchOn");
WASDON_SETTER(int32_t, set_switch, "set_switchOn");
WASDON_FIELD(int32_t, joined_player, "onPlayerJoinedPlayer");

static void apply(void) {
    int32_t object = target();
    if (VRCSDKBaseUtilities_IsValid__SystemObject__SystemBoolean(object))
        UnityEngineGameObject_SetActive__SystemBoolean__SystemVoid(object, switch_on());
}
WASDON_EVENT(_start) {
    const char message[] = "Hello from Wasdon";
    wasdon_log(message, sizeof(message) - 1);
    apply();
}
WASDON_EVENT(_interact) {
    wasdon_take_ownership(game_object());
    if (VRCSDKBaseNetworking_IsOwner__UnityEngineGameObject__SystemBoolean(game_object())) {
        set_switch(!switch_on());
        apply();
        wasdon_serialize(behaviour());
    }
}
WASDON_EVENT(_onDeserialization) { apply(); }
WASDON_EVENT(_onPlayerJoined) {
    int32_t player = joined_player();
    if (VRCSDKBaseUtilities_IsValid__SystemObject__SystemBoolean(player))
        UnityEngineDebug_Log__SystemObject__SystemVoid(VRCSDKBaseVRCPlayerApi_get_displayName__SystemString(player));
}
