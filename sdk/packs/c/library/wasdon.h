#pragma once
#include "raw.h"
#include <stddef.h>

#define WASDON_FIELD(type, local, name) \
    __attribute__((import_module("wasdon.field"), import_name(name))) extern type local(void)
#define WASDON_SETTER(type, local, name) \
    __attribute__((import_module("wasdon.field"), import_name(name))) extern void local(type)
#define WASDON_EVENT(name) __attribute__((export_name(#name))) void name(void)

__attribute__((import_module("udon.static"), import_name("SystemString.__Copy__SystemString__SystemString")))
extern int32_t wasdon_string(const char *utf8, size_t length);

static inline void wasdon_log(const char *text, size_t length) {
    UnityEngineDebug_Log__SystemObject__SystemVoid(wasdon_string(text, length));
}
static inline int32_t wasdon_position(int32_t transform) {
    return UnityEngineTransform_get_position__UnityEngineVector3(transform);
}
static inline int32_t wasdon_local_player(void) {
    return VRCSDKBaseNetworking_get_LocalPlayer__VRCSDKBaseVRCPlayerApi();
}
static inline void wasdon_take_ownership(int32_t object) {
    VRCSDKBaseNetworking_SetOwner__VRCSDKBaseVRCPlayerApi_UnityEngineGameObject__SystemVoid(wasdon_local_player(), object);
}
static inline void wasdon_serialize(int32_t behaviour) {
    VRCUdonCommonInterfacesIUdonEventReceiver_RequestSerialization__SystemVoid(behaviour);
}
static inline void wasdon_send_event(int32_t behaviour, int32_t name) {
    VRCUdonCommonInterfacesIUdonEventReceiver_SendCustomEvent__SystemString__SystemVoid(behaviour, name);
}
