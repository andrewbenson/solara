#import "SolaraCoreNotifications.h"
#import "SolaraCoreInternal.h"
#import <dlfcn.h>
#import <objc/message.h>
#include <stdio.h>
#include <string>
#include <cctype>
#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"

@interface SolaraNotificationReply : NSObject
@property(nonatomic, copy) void (^completion)(NSDictionary *);
@property(nonatomic) BOOL completed;
@property(nonatomic, copy) NSDictionary *arguments;
- (void)finish:(NSDictionary *)result;
@end

@implementation SolaraNotificationReply
- (void)finish:(NSDictionary *)result {
  if (_completed) return;
  _completed = YES;
  void (^done)(NSDictionary *) = _completion;
  _completion = nil;
  if (done) done(result);
}
@end

@interface SolaraNotificationNativeReply : NSObject
@property(nonatomic) ac_engine_reply_t reply;
@property(nonatomic) void *context;
@property(nonatomic) BOOL completed;
@end
@implementation SolaraNotificationNativeReply
@end

@interface SolaraNotificationTransport : NSObject
@property(nonatomic) BOOL retired;
@property(nonatomic, copy) void (^handler)(NSDictionary *);
@property(nonatomic, strong) NSMutableSet<SolaraNotificationReply *> *replies;
@property(nonatomic, strong) NSMutableSet<SolaraNotificationNativeReply *> *nativeReplies;
@property(nonatomic, copy) NSDictionary *finalSnapshot;
@property(nonatomic, strong) id ingress;
@property(nonatomic, strong) id watchIngress;
@property(nonatomic, copy) NSString *handlerOwner;
@end
@implementation SolaraNotificationTransport
@end

namespace {
SolaraNotificationTransport *gTransport;
ac_notifications_abort_transport_t gAbort;
ac_notifications_authorization_eligible_t gAuthorizationEligible;
ac_notifications_call_t gWatch;
ac_notifications_call_t gControl;
ac_notifications_call_t gSnapshot;
NSDictionary *gEpoch;
NSUInteger gWatchRetries;
BOOL gWatchRetryPending;
NSUInteger gWatchRetryGeneration;

void RequireMainThread() { if (!NSThread.isMainThread) __builtin_trap(); }

NSDictionary *Parse(const char *json) {
  if (!json) return @{};
  NSData *bytes = [@(json) dataUsingEncoding:NSUTF8StringEncoding];
  id value = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
NSString *Encode(id value) {
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
  return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : @"{}";
}
void Retain(void *context) { CFRetain(context); }
void Release(void *context) { CFRelease(context); }
void Replied(void *context, const char *json) {
  RequireMainThread();
  SolaraNotificationReply *reply = (__bridge SolaraNotificationReply *)context;
  NSDictionary *result = Parse(json);
  if (!gTransport.retired && [reply.arguments[@"op"] isEqual:@"replayAck"] && [result[@"ok"] boolValue] &&
      [result[@"B"] isEqual:gEpoch[@"B"]] && [result[@"W"] isEqual:gEpoch[@"W"]]) gWatchRetries = 0;
  [reply finish:result];
  [gTransport.replies removeObject:reply];
}
void Invoke(ac_notifications_call_t call, NSDictionary *args, void (^completion)(NSDictionary *)) {
  RequireMainThread();
  if (!call) return completion(@{@"ok": @NO, @"error": @"notification export unavailable"});
  SolaraNotificationReply *reply = [SolaraNotificationReply new];
  reply.completion = completion;
  reply.arguments = args;
  [gTransport.replies addObject:reply];
  call(nullptr, Encode(args).UTF8String, Replied, (__bridge void *)reply, Retain, Release);
}
void Hub(NSDictionary *payload, void (^completion)(NSDictionary *)) {
  RequireMainThread();
  [NSNotificationCenter.defaultCenter postNotificationName:@"SolaraNotificationControl" object:nil
      userInfo:@{@"payload": payload, @"completion": [completion copy]}];
}
void NativeControl(void *context, const char *json, ac_engine_reply_t completion, void *completionContext) {
  RequireMainThread();
  SolaraNotificationTransport *transport = (__bridge SolaraNotificationTransport *)context;
  if (transport.retired) return;
  SolaraNotificationNativeReply *reply = [SolaraNotificationNativeReply new];
  reply.reply = completion;
  reply.context = completionContext;
  [transport.nativeReplies addObject:reply];
  Hub(Parse(json), ^(NSDictionary *result) {
    if (reply.completed) return;
    reply.completed = YES;
    [transport.nativeReplies removeObject:reply];
    if (!transport.retired && reply.reply) reply.reply(reply.context, Encode(result).UTF8String);
    reply.reply = nullptr;
    reply.context = nullptr;
  });
}
NSString *EntryJSON(const char *json) {
  std::string raw = json ?: "";
  size_t begin = raw.find("\"entry\":");
  if (begin == std::string::npos) return nil;
  begin += 8;
  while (begin < raw.size() && isspace(static_cast<unsigned char>(raw[begin]))) ++begin;
  if (begin == raw.size() || raw[begin] != '{') return nil;
  int depth = 0;
  bool quoted = false;
  bool escaped = false;
  for (size_t i = begin; i < raw.size(); ++i) {
    const char c = raw[i];
    if (quoted) {
      if (escaped) escaped = false;
      else if (c == '\\') escaped = true;
      else if (c == '"') quoted = false;
    } else if (c == '"') quoted = true;
    else if (c == '{' || c == '[') ++depth;
    else if ((c == '}' || c == ']') && --depth == 0)
      return [[NSString alloc] initWithBytes:raw.data() + begin length:i - begin + 1 encoding:NSUTF8StringEncoding];
  }
  return nil;
}
void Event(void *context, const char *, const char *json) {
  RequireMainThread();
  SolaraNotificationTransport *transport = (__bridge SolaraNotificationTransport *)context;
  if (transport.retired || !transport.handler) return;
  NSMutableDictionary *event = [Parse(json) mutableCopy];
  if (!gEpoch || ![event[@"B"] isEqual:gEpoch[@"B"]] || ![event[@"W"] isEqual:gEpoch[@"W"]]) return;
  if ([event[@"kind"] isEqual:@"replayEntry"]) {
    NSString *entry = EntryJSON(json);
    if (entry) event[@"_entryJSON"] = entry;
  }
  transport.handler(event);
}
void Retire(void *context) {
  RequireMainThread();
  SolaraNotificationTransport *transport = (__bridge SolaraNotificationTransport *)context;
  if (transport.retired) return;
  __block NSDictionary *engine;
  Invoke(gSnapshot, @{}, ^(NSDictionary *value) { engine = [value copy]; });
  __block NSDictionary *hub;
  Hub(@{@"control": @"debugSnapshot"}, ^(NSDictionary *value) { hub = [value copy]; });
  NSMutableDictionary *snapshot = [engine mutableCopy] ?: [NSMutableDictionary dictionary];
  snapshot[@"hub"] = hub ?: @{@"complete": @NO};
  snapshot[@"retired"] = @YES;
  transport.finalSnapshot = [snapshot copy];
  Hub(@{@"control": @"retire"}, ^(NSDictionary *) {});
  transport.retired = YES;
  ++gWatchRetryGeneration;
  gWatchRetryPending = NO;
  transport.handler = nil;
  transport.handlerOwner = nil;
  [NSNotificationCenter.defaultCenter removeObserver:transport.ingress];
  [NSNotificationCenter.defaultCenter removeObserver:transport.watchIngress];
  transport.ingress = nil;
  transport.watchIngress = nil;
  gEpoch = nil;
  for (SolaraNotificationNativeReply *reply in transport.nativeReplies) {
    reply.completed = YES;
    reply.reply = nullptr;
    reply.context = nullptr;
  }
  [transport.nativeReplies removeAllObjects];
  for (SolaraNotificationReply *reply in [transport.replies copy])
    [reply finish:@{@"ok": @NO, @"error": @"notification transport retired"}];
  [transport.replies removeAllObjects];
  if (SolaraCoreTestHooksAllowed()) {
    fprintf(stderr, "SOLARA_NOTIFICATION_RETIRED %s\n", Encode(transport.finalSnapshot).UTF8String);
    fflush(stderr);
  }
}
}

@implementation SolaraCoreNotifications
+ (BOOL)install {
  RequireMainThread();
  if (gTransport) return !gTransport.retired;
  auto capabilities = (ac_notifications_capabilities_t)dlsym(RTLD_DEFAULT, "ac_notifications_capabilities");
  auto registration = (ac_notifications_register_transport_t)dlsym(RTLD_DEFAULT, "ac_notifications_register_transport");
  gAbort = (ac_notifications_abort_transport_t)dlsym(RTLD_DEFAULT, "ac_notifications_abort_transport");
  gAuthorizationEligible = (ac_notifications_authorization_eligible_t)dlsym(RTLD_DEFAULT, "ac_notifications_authorization_eligible");
  gWatch = (ac_notifications_call_t)dlsym(RTLD_DEFAULT, "ac_notifications_watch");
  gControl = (ac_notifications_call_t)dlsym(RTLD_DEFAULT, "ac_notifications_control");
  gSnapshot = (ac_notifications_call_t)dlsym(RTLD_DEFAULT, "ac_notifications_debug_snapshot");
  NSDictionary *values = capabilities ? Parse(capabilities()) : @{};
  NSArray *requirements = @[@"customBridge", @"allHandlerTypes", @"featureFlagIndependent", @"childRefusal", @"directControls",
      @"directDrain", @"scopeFences", @"profileFree", @"processLifetimeOnly", @"contextLifetime", @"startupAbort", @"trustedAuthorizationEligibility", @"synchronousAuthorizationEligibility"];
  if (!registration || !gAbort || !gAuthorizationEligible || !gWatch || !gControl || !gSnapshot ||
      !dlsym(RTLD_DEFAULT, "ac_notifications_debug_displayed") ||
      ![SolaraCoreEngine instancesRespondToSelector:@selector(fenceNotificationsForProfileDeletionAtPath:completion:)] ||
      ![SolaraCoreEngine instancesRespondToSelector:@selector(fenceNotificationsForPrivateProfile:)] ||
      [values[@"abi"] intValue] != 2 ||
      [values[@"notifications"] intValue] != 2 || [values[@"nativeApi"] intValue] != 37) return NO;
  for (NSString *key in requirements) if (![values[key] isEqual:@YES]) return NO;
  Class hub = NSClassFromString(@"SolaraNotificationHub");
  SEL install = NSSelectorFromString(@"installTransportWithAuthorizationQuery:");
  if (!hub || ![hub respondsToSelector:install]) return NO;
  BOOL (^authorizationQuery)(NSDictionary *) = ^BOOL(NSDictionary *route) {
    RequireMainThread();
    if (!gTransport || gTransport.retired) return NO;
    return gAuthorizationEligible(Encode(route).UTF8String, (__bridge void *)gTransport) != 0;
  };
  ((void (*)(id, SEL, BOOL (^)(NSDictionary *)))objc_msgSend)(hub, install, authorizationQuery);
  gTransport = [SolaraNotificationTransport new];
  gTransport.replies = [NSMutableSet set];
  gTransport.nativeReplies = [NSMutableSet set];
  gTransport.ingress = [NSNotificationCenter.defaultCenter addObserverForName:@"SolaraNotificationEngineControl" object:nil queue:nil
      usingBlock:^(NSNotification *note) {
        RequireMainThread();
        void (^done)(NSDictionary *) = note.userInfo[@"completion"];
        if (!done) done = ^(NSDictionary *) {};
        if (gTransport.retired) return done(@{@"ok": @NO, @"error": @"notification transport retired"});
        Invoke(gControl, note.userInfo[@"payload"] ?: @{}, done);
      }];
  gTransport.watchIngress = [NSNotificationCenter.defaultCenter addObserverForName:@"SolaraNotificationWatchRequest" object:nil queue:nil
      usingBlock:^(NSNotification *) {
        RequireMainThread();
        if (gWatchRetryPending || gWatchRetries >= 3 || gTransport.retired || !gTransport.handler) return;
        gWatchRetryPending = YES;
        NSString *owner = gTransport.handlerOwner;
        const NSUInteger generation = gWatchRetryGeneration;
        const NSTimeInterval delay = 0.1 * (1 << gWatchRetries++);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          if (generation != gWatchRetryGeneration || gTransport.retired) return;
          gWatchRetryPending = NO;
          if (!gTransport.retired && gTransport.handler && [gTransport.handlerOwner isEqual:owner])
            [SolaraCoreNotifications watch:^(NSDictionary *) {}];
        });
      }];
  if (!registration(2, NativeControl, Event, (__bridge void *)gTransport, Retain, Release, Retire)) {
    Retire((__bridge void *)gTransport);
    gTransport = nil;
    return NO;
  }
  return YES;
}
+ (void)abortStartup {
  RequireMainThread();
  if (gTransport && !gTransport.retired) gAbort((__bridge void *)gTransport);
}
+ (BOOL)configureRoot:(NSString *)path {
  RequireMainThread();
  if (!gTransport || gTransport.retired) return NO;
  NSString *root = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  if (!root.absolutePath) return NO;
  __block BOOL configured = NO;
  Invoke(gSnapshot, @{}, ^(NSDictionary *snapshot) {
    NSString *bridge = snapshot[@"B"];
    if (![bridge isKindOfClass:NSString.class] || !bridge.length) return;
    Hub(@{@"control": @"initializeIdentity", @"B": bridge, @"canonicalRoot": root}, ^(NSDictionary *answer) {
      configured = [answer[@"ok"] boolValue];
    });
  });
  return configured;
}
+ (void)setEventHandler:(void (^)(NSDictionary *))handler owner:(NSString *)owner {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self setEventHandler:handler owner:owner]; });
    return;
  }
  ++gWatchRetryGeneration;
  gWatchRetryPending = NO;
  gWatchRetries = 0;
  gTransport.handlerOwner = owner;
  gTransport.handler = handler;
}
+ (void)clearEventHandler:(NSString *)owner {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self clearEventHandler:owner]; });
    return;
  }
  if (![gTransport.handlerOwner isEqual:owner]) return;
  ++gWatchRetryGeneration;
  gWatchRetryPending = NO;
  gTransport.handlerOwner = nil;
  gTransport.handler = nil;
  if (!gTransport.retired && gEpoch) {
    NSMutableDictionary *lost = [gEpoch mutableCopy];
    lost[@"op"] = @"observerLost";
    Invoke(gControl, lost, ^(NSDictionary *) {});
  }
}
+ (void)watch:(void (^)(NSDictionary *))completion {
  RequireMainThread();
  if (!gTransport || gTransport.retired || !gTransport.handler)
    return completion(@{@"ok": @NO, @"error": @"notification observer unavailable"});
  Invoke(gWatch, @{@"consumerNonce": NSUUID.UUID.UUIDString, @"ready": @YES}, ^(NSDictionary *result) {
    if ([result[@"ok"] boolValue]) gEpoch = @{@"B": result[@"B"] ?: @"", @"W": result[@"W"] ?: @""};
    completion(result);
  });
}
+ (void)consume:(NSDictionary *)event completion:(void (^)(NSDictionary *))completion {
  RequireMainThread();
  if (gTransport.retired || !gEpoch || ![event[@"B"] isEqual:gEpoch[@"B"]] || ![event[@"W"] isEqual:gEpoch[@"W"]])
    return completion(@{@"ok": @NO, @"error": @"stale notification envelope"});
  Hub(@{@"control": @"consume", @"event": event}, completion);
}
+ (void)control:(NSDictionary *)payload completion:(void (^)(NSDictionary *))completion {
  RequireMainThread();
  if (gTransport.retired) return completion(@{@"ok": @NO});
  Invoke(gControl, payload, completion);
}
+ (void)debugSnapshot:(void (^)(NSDictionary *))completion {
  RequireMainThread();
  if (!SolaraCoreTestHooksAllowed()) return completion(@{@"error": @"test hooks disabled"});
  if (gTransport.retired) return completion(gTransport.finalSnapshot ?: @{});
  Invoke(gSnapshot, @{}, ^(NSDictionary *engine) {
    Hub(@{@"control": @"debugSnapshot"}, ^(NSDictionary *hub) {
      NSMutableDictionary *value = [engine mutableCopy];
      value[@"hub"] = hub;
      completion(value);
    });
  });
}
+ (void)debugDisplayed:(NSString *)profile origin:(NSString *)origin completion:(void (^)(NSDictionary *))completion {
  RequireMainThread();
  if (!SolaraCoreTestHooksAllowed()) return completion(@{@"error": @"test hooks disabled"});
  auto call = (ac_notifications_call_t)dlsym(RTLD_DEFAULT, "ac_notifications_debug_displayed");
  if (!call) return completion(@{@"completed": @NO, @"error": @"engine lacks display-service debug export"});
  SolaraCoreProfile *loaded = solaracore_host::LoadedProfile(profile);
  if (!loaded || loaded.offTheRecord) return completion(@{@"completed": @NO, @"error": @"regular loaded profile required"});
  Invoke(call, @{@"profile": loaded.path, @"origin": origin}, completion);
}
@end
