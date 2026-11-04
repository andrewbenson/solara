// Copyright 2026 Solara. Apache-2.0.

#ifndef CHROME_BROWSER_SOLARA_PUBLIC_AC_ENGINE_H_
#define CHROME_BROWSER_SOLARA_PUBLIC_AC_ENGINE_H_

#ifdef __cplusplus
extern "C" {
#endif

#define AC_ENGINE_EXPORT __attribute__((visibility("default")))

#define AC_ENGINE_ABI_VERSION 2
#define AC_NOTIFICATIONS_PROTOCOL_VERSION 2
#define AC_NOTIFICATIONS_NATIVE_API_VERSION 37

typedef void (*ac_engine_reply_t)(void* context, const char* json);
typedef void (*ac_engine_call_t)(const char* profile_dir,
                                 const char* args_json,
                                 ac_engine_reply_t reply,
                                 void* context);
typedef void (*ac_engine_event_t)(void* context,
                                  const char* topic,
                                  const char* json);

typedef void (*ac_notifications_context_lifetime_t)(void* context);
typedef void (*ac_notifications_control_t)(void* context,
                                           const char* json,
                                           ac_engine_reply_t completion,
                                           void* completion_context);
typedef const char* (*ac_notifications_capabilities_t)(void);
typedef int (*ac_notifications_register_transport_t)(
    int protocol,
    ac_notifications_control_t control,
    ac_engine_event_t event,
    void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release,
    ac_notifications_context_lifetime_t retire);
typedef void (*ac_notifications_abort_transport_t)(void* context);
typedef int (*ac_notifications_authorization_eligible_t)(
    const char* route_json, void* context);
typedef void (*ac_notifications_call_t)(
    const char* ignored_profile,
    const char* args_json,
    ac_engine_reply_t reply,
    void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release);

AC_ENGINE_EXPORT const char* ac_notifications_capabilities(void);
AC_ENGINE_EXPORT int ac_notifications_register_transport(
    int protocol,
    ac_notifications_control_t control,
    ac_engine_event_t event,
    void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release,
    ac_notifications_context_lifetime_t retire);
AC_ENGINE_EXPORT void ac_notifications_abort_transport(void* context);
AC_ENGINE_EXPORT int ac_notifications_authorization_eligible(
    const char* route_json, void* context);
AC_ENGINE_EXPORT void ac_notifications_watch(
    const char* ignored_profile,
    const char* args_json,
    ac_engine_reply_t reply,
    void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release);
AC_ENGINE_EXPORT void ac_notifications_control(
    const char* ignored_profile,
    const char* args_json,
    ac_engine_reply_t reply,
    void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release);
AC_ENGINE_EXPORT void ac_notifications_debug_snapshot(
    const char* ignored_profile,
    const char* args_json,
    ac_engine_reply_t reply,
    void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release);

AC_ENGINE_EXPORT void ac_notifications_debug_displayed(
    const char* ignored_profile,
    const char* args_json,
    ac_engine_reply_t reply,
    void* context,
    ac_notifications_context_lifetime_t retain,
    ac_notifications_context_lifetime_t release);

typedef int (*ac_engine_abi_version_t)(void);
typedef void (*ac_engine_set_event_sink_t)(ac_engine_event_t sink,
                                           void* context);

#ifdef __cplusplus
}
#endif

#endif
