#import "SolaraCoreEngineBridge.h"
#import "SolaraCoreBookmarkURL.h"

#import "SolaraCoreInternal.h"
#import "SolaraCore-Swift.h"

#import <dlfcn.h>
#include <stdlib.h>

#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"

bool SolaraPrivateDownloadSourceFenceAvailable();

namespace {

bool RefusesSafeModeCall(NSString *name) {
  if (!SolaraCoreHost.safeMode) return false;
  static NSSet<NSString *> *mutations = [NSSet setWithArray:@[
    @"ac_favicons_set", @"ac_passwords_mark",
    @"ac_extensions_configure", @"ac_extensions_install", @"ac_extensions_install_crx", @"ac_extensions_reload",
    @"ac_extensions_set_enabled", @"ac_extensions_sync_apply", @"ac_extensions_sync_state", @"ac_extensions_uninstall",
    @"ac_tab_restore_tag", @"ac_tab_restore_take", @"ac_tab_restore_load"
  ]];
  return [mutations containsObject:name];
}

void (^gEventHandler)(NSString *, NSString *);
NSSet<NSString *> *gForwardedTopics;
NSMutableArray<NSArray *> *gPendingForwards;

void *Symbol(const char *name) {
  return dlsym(RTLD_DEFAULT, name);
}

NSString *JSON(id value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

void Replied(void *context, const char *json) {
  void (^completion)(NSString *) = (__bridge_transfer void (^)(NSString *))context;
  completion(json ? @(json) : JSON(@{@"error" : @"bad reply from the engine"}));
}

NSString *RealPath(NSString *path) {
  char resolved[PATH_MAX];
  return realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : path;
}

NSString *ProfileNamed(NSString *dir) {
  NSString *real = RealPath(dir);
  for (SolaraCoreProfile *profile in solaracore_host::LoadedProfiles())
    if (!([profile respondsToSelector:@selector(offTheRecord)] && profile.offTheRecord) && [RealPath(profile.path) isEqualToString:real]) return solaracore_host::ProfileName(profile);
  NSString *name = real.lastPathComponent;
  return [name hasPrefix:@"Profile "] ? [name substringFromIndex:8] : @"";
}

int EngineABI() {
  static int abi = [] {
    auto version = (ac_engine_abi_version_t)Symbol("ac_engine_abi_version");
    return version ? version() : 0;
  }();
  return abi;
}

NSMutableDictionary<NSString *, NSMutableArray *> *Observers() {
  static NSMutableDictionary *observers = [NSMutableDictionary dictionary];
  return observers;
}

bool ForwardsEveryEngineEvent() {
  static const bool every = [] {
    const char *value = getenv("SOLARA_ENGINE_EVENT_FORWARD");
    return value && !strcmp(value, "all");
  }();
  return every;
}

bool Forwarded(NSString *topic) {
  return gEventHandler && (ForwardsEveryEngineEvent() || !gForwardedTopics || [gForwardedTopics containsObject:topic]);
}

bool CurrentForward(NSArray *event) {
  if (event.count < 3) return true;
  NSDictionary *payload = event[1];
  NSNumber *epoch = event[2];
  return [NativePrivateDownloadRoutes.shared isCurrentPrivateEvent:payload[@"profile"] epoch:epoch.integerValue
                                          privateDownloadsSupported:SolaraPrivateDownloadSourceFenceAvailable()];
}

void FlushForwards() {
  NSArray<NSArray *> *events = gPendingForwards;
  gPendingForwards = nil;
  for (NSArray *event in events)
    if (gEventHandler && CurrentForward(event)) gEventHandler(event[0], JSON(event[1]));
}

void Forward(NSString *topic, NSDictionary *payload) {
  NSNumber *epoch = [NativePrivateDownloadRoutes.shared privateEventEpoch:topic payload:payload];
  NSArray *event = epoch ? @[ topic, [payload copy], epoch ] : @[ topic, [payload copy] ];
  if (ForwardsEveryEngineEvent()) {
    if (CurrentForward(event)) gEventHandler(topic, JSON(payload));
    return;
  }
  if (gPendingForwards) {
    if (![gPendingForwards.lastObject isEqualToArray:event]) [gPendingForwards addObject:event];
    return;
  }
  gPendingForwards = [NSMutableArray arrayWithObject:event];
  dispatch_async(dispatch_get_main_queue(), ^{
    FlushForwards();
  });
}

void Dispatch(void *, const char *topic, const char *json) {
  if (!topic) return;
  NSString *name = @(topic);
  NSArray *observers = [Observers()[name] copy];
  bool forwarded = Forwarded(name);
  if (!observers.count && !forwarded) return;
  NSData *data = [@(json ?: "{}") dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableDictionary *payload = [[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy] ?: [NSMutableDictionary dictionary];
  if ([payload[@"profile"] isKindOfClass:NSString.class]) payload[@"profile"] = ProfileNamed(payload[@"profile"]);
  for (void (^observer)(NSDictionary *) in observers) observer(payload);
  if (forwarded) Forward(name, payload);
}

void InstallSink() {
  static bool installed = false;
  if (installed) return;
  auto sink = (ac_engine_set_event_sink_t)Symbol("ac_engine_set_event_sink");
  if (!sink) return;
  installed = true;
  sink(Dispatch, nullptr);
}

}

@implementation SolaraCoreEngineBridge

+ (NSString *)canonicalBookmarkURL:(NSString *)url error:(NSError **)error {
  return SolaraCanonicalBookmarkURL(url, error);
}

+ (NSString *)canonicalBookmarkURLUTF16:(NSData *)units error:(NSError **)error {
  return SolaraCanonicalBookmarkURLUTF16(units, error);
}

+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSString *)args completion:(void (^)(NSString *))completion {
  if ([name isEqualToString:@"ac_bookmarks_canonicalize_url_v1"])
    return completion(JSON(@{@"error" : @"use canonicalBookmarkURL for this synchronous utility"}));
  if (RefusesSafeModeCall(name)) return completion(JSON(@{@"error" : @"disabled in safe mode"}));
  auto call = (ac_engine_call_t)Symbol(name.UTF8String);
  if (!call) return completion(JSON(@{@"error" : [NSString stringWithFormat:@"the engine has no %@", name]}));
  static NSSet<NSString *> *processCalls = [NSSet setWithArray:@[
    @"ac_tabs_memory", @"ac_tabs_cpu", @"ac_tasks_list", @"ac_components_list", @"ac_task_manager_open", @"ac_battery_saver"
  ]];
  if ([processCalls containsObject:name]) {
    if (!SolaraCoreHost.isStarted) return completion(JSON(@{@"error" : @"engine not started"}));
    if (profile.length) return completion(JSON(@{@"error" : [NSString stringWithFormat:@"%@ requires an empty profile", name]}));
    void (^done)(NSString *) = [completion copy];
    NSString *argsCopy = [args copy];
    call("", argsCopy.UTF8String, Replied, (__bridge_retained void *)done);
    return;
  }
  if (solaracore_host::IsIncognito(profile)) {
    static NSSet<NSString *> *session = [NSSet setWithArray:@[
      @"ac_site_settings_get", @"ac_site_settings_origins", @"ac_site_settings_set", @"ac_site_settings_reset",
      @"ac_site_data_clear", @"ac_zoom_list", @"ac_zoom_set"
    ]];
    static NSSet<NSString *> *changes = [NSSet setWithArray:@[
      @"ac_site_settings_set", @"ac_site_settings_reset", @"ac_site_data_clear", @"ac_zoom_set", @"ac_external_apps_remove",
      @"ac_browsing_data_clear"
    ]];
    if ([session containsObject:name] && EngineABI() >= 2) {
      NSData *bytes = [(args.length ? args : @"{}") dataUsingEncoding:NSUTF8StringEncoding];
      NSMutableDictionary *parsed = [[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] mutableCopy];
      if (![parsed isKindOfClass:NSMutableDictionary.class]) return completion(JSON(@{@"error" : @"bad arguments"}));
      parsed[@"offTheRecord"] = @YES;
      args = JSON(parsed);
    } else if ([changes containsObject:name]) {
      return completion(JSON(@{@"error" : @"private profile"}));
    }
  }
  NSString *data = solaracore_host::OriginalProfileName(profile);
  void (^done)(NSString *) = [completion copy];
  NSString *argsCopy = [args copy];
  solaracore_host::WithProfile(data, ^(SolaraCoreProfile *p) {
    if (!p || !SolaraCoreHost.isStarted) return done(JSON(@{@"error" : @"profile not loaded"}));
    call(p.path.UTF8String, argsCopy.UTF8String, Replied, (__bridge_retained void *)done);
  });
}

+ (void)callWithSecret:(NSString *)name profile:(NSString *)profile args:(NSMutableData *)args completion:(void (^)(NSString *))completion {
  NSMutableData *secret = args;
  void (^wipe)(void) = ^{
    volatile unsigned char *bytes = (volatile unsigned char *)secret.mutableBytes;
    for (NSUInteger i = 0; i < secret.length; i++) bytes[i] = 0;
  };
  if ([name isEqualToString:@"ac_bookmarks_canonicalize_url_v1"]) {
    wipe();
    return completion(JSON(@{@"error" : @"use canonicalBookmarkURL for this synchronous utility"}));
  }
  if (RefusesSafeModeCall(name)) {
    wipe();
    return completion(JSON(@{@"error" : @"disabled in safe mode"}));
  }
  auto call = (ac_engine_call_t)Symbol(name.UTF8String);
  const char *bytes = (const char *)secret.bytes;
  if (!call || solaracore_host::IsIncognito(profile) || !secret.length || bytes[secret.length - 1] != 0) {
    wipe();
    return completion(JSON(@{@"error" : !call ? [NSString stringWithFormat:@"the engine has no %@", name]
                                     : solaracore_host::IsIncognito(profile) ? @"private profile" : @"bad arguments"}));
  }
  void (^done)(NSString *) = [completion copy];
  solaracore_host::WithProfile(profile ?: @"", ^(SolaraCoreProfile *p) {
    if (!p || !SolaraCoreHost.isStarted || ([p respondsToSelector:@selector(offTheRecord)] && p.offTheRecord)) {
      wipe();
      return done(JSON(@{@"error" : @"profile not loaded"}));
    }
    call(p.path.UTF8String, (const char *)secret.mutableBytes, Replied, (__bridge_retained void *)done);
    wipe();
  });
}

+ (void)setEventHandler:(void (^)(NSString *, NSString *))handler {
  gEventHandler = [handler copy];
  InstallSink();
}

+ (void)forwardTopics:(NSArray<NSString *> *)topics {
  gForwardedTopics = [NSSet setWithArray:topics];
}

+ (void)observe:(NSString *)topic handler:(void (^)(NSDictionary<NSString *, id> *))handler {
  if (!Observers()[topic]) Observers()[topic] = [NSMutableArray array];
  [Observers()[topic] addObject:[handler copy]];
  InstallSink();
}

+ (NSDictionary<NSString *, id> *)configureHooks:(NSString *)json {
  auto configure = (ac_hooks_configure_v1_t)Symbol("ac_hooks_configure_v1");
  if (!configure || !NSThread.isMainThread) return nil;
  __block NSString *reply = nil;
  void (^done)(NSString *) = ^(NSString *text) { reply = text; };
  configure(json.UTF8String, Replied, (__bridge_retained void *)[done copy]);
  NSDictionary *parsed = reply ? [NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
  return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}

+ (NSDictionary<NSString *, id> *)matchHooks:(NSString *)url {
  auto match = (ac_hooks_match_v1_t)Symbol("ac_hooks_match_v1");
  if (!match || !NSThread.isMainThread) return nil;
  __block NSString *reply = nil;
  void (^done)(NSString *) = ^(NSString *text) { reply = text; };
  match(url.UTF8String, Replied, (__bridge_retained void *)[done copy]);
  NSDictionary *parsed = reply ? [NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
  return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
}

+ (BOOL)exports:(NSString *)name {
  return Symbol(name.UTF8String) != nullptr;
}

@end
