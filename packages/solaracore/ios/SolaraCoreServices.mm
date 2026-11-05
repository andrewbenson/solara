#import "SolaraCoreServices.h"
#import "SolaraCore-Swift.h"

#import "SolaraCoreEarlyWindow.h"
#import "SolaraCoreEngineBridge.h"
#import "SolaraCoreInternal.h"
#import "ACExtensionPackage.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <string.h>

#include <cmath>

bool SolaraPrivateDownloadSourceFenceAvailable() {
  return false;
}

namespace {

NSDictionary *Parse(NSString *json) {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [value isKindOfClass:NSDictionary.class] ? value : @{@"error" : @"bad reply from the engine"};
}

NSString *JSON(NSDictionary *value) {
  NSData *data = value ? [NSJSONSerialization dataWithJSONObject:value options:0 error:nil] : nil;
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

void Wipe(NSMutableData *data) {
  volatile unsigned char *bytes = (volatile unsigned char *)data.mutableBytes;
  for (NSUInteger i = 0; i < data.length; i++) bytes[i] = 0;
}

char *AppendHex(char *out, NSString *text) {
  const NSUInteger capacity = [text maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  NSMutableData *raw = [NSMutableData dataWithLength:capacity];
  NSUInteger used = 0;
  [text getBytes:raw.mutableBytes maxLength:capacity usedLength:&used encoding:NSUTF8StringEncoding
         options:0 range:NSMakeRange(0, text.length) remainingRange:nullptr];
  const unsigned char *bytes = (const unsigned char *)raw.bytes;
  static const char hex[] = "0123456789abcdef";
  for (NSUInteger i = 0; i < used; i++) {
    *out++ = hex[bytes[i] >> 4];
    *out++ = hex[bytes[i] & 15];
  }
  Wipe(raw);
  return out;
}

NSMutableData *WithSecrets(NSDictionary *plain, NSDictionary<NSString *, NSString *> *secrets) {
  NSData *open = plain.count ? [NSJSONSerialization dataWithJSONObject:plain options:0 error:nil] : [NSData dataWithBytes:"{}" length:2];
  if (open.length < 2) return [NSMutableData data];
  NSUInteger capacity = open.length + 1;
  for (NSString *key in secrets)
    capacity += key.length + 3 + 2 * [secrets[key] maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 6;
  NSMutableData *data = [NSMutableData dataWithLength:capacity];
  char *start = (char *)data.mutableBytes;
  char *out = start;
  memcpy(out, open.bytes, open.length - 1);
  out += open.length - 1;
  bool first = !plain.count;
  for (NSString *key in secrets) {
    if (!first) *out++ = ',';
    first = false;
    NSString *name = [NSString stringWithFormat:@"\"%@Hex\":\"", key];
    memcpy(out, name.UTF8String, strlen(name.UTF8String));
    out += strlen(name.UTF8String);
    out = AppendHex(out, secrets[key]);
    *out++ = '"';
  }
  *out++ = '}';
  *out++ = 0;
  data.length = (NSUInteger)(out - start);
  return data;
}

NSString *OriginOf(NSString *url) {
  NSURLComponents *c = [NSURLComponents componentsWithString:url ?: @""];
  if (!c.scheme.length || !c.host.length) return url ?: @"";
  return c.port ? [NSString stringWithFormat:@"%@://%@:%@", c.scheme, c.host, c.port] : [NSString stringWithFormat:@"%@://%@", c.scheme, c.host];
}

NSDictionary *Login(NSString *origin, NSString *username) {
  return @{@"origin" : OriginOf(origin), @"username" : username ?: @""};
}

SolaraCoreResult Dated(NSString *key, SolaraCoreResult completion) {
  return ^(NSDictionary *result) {
    NSArray *list = result[key];
    if (![list isKindOfClass:NSArray.class]) return completion(result);
    NSMutableArray *dated = [NSMutableArray array];
    for (NSDictionary *entry in list) {
      if (![entry isKindOfClass:NSDictionary.class]) continue;
      NSMutableDictionary *item = [entry mutableCopy];
      item[@"created"] = @0;
      item[@"modified"] = @0;
      [dated addObject:item];
    }
    completion(@{key : dated});
  };
}

void (^gExtensionsHandler)(NSString *, NSDictionary *);

void Changed(NSString *profile, NSString *extensionId, NSString *event) {
  if (gExtensionsHandler && extensionId.length)
    gExtensionsHandler(@"changed", @{@"profile" : solaracore_host::OriginalProfileName(profile), @"id" : extensionId, @"event" : event});
}

NSString *ProfileDirectory(NSString *profile) {
  NSString *name = solaracore_host::OriginalProfileName(profile);
  NSString *dir = name.length ? [@"Profile " stringByAppendingString:name] : @"Default";
  return [SolaraCoreHost.dataDirectory stringByAppendingPathComponent:dir];
}

NSString *StoreFolder(NSString *profile, NSString *extensionId, id version) {
  if (!ac::ext::IsExtensionId(extensionId) || ![version isKindOfClass:NSString.class] || ![version length]) return nil;
  NSString *dir = [[ProfileDirectory(profile) stringByAppendingPathComponent:@"Extensions"] stringByAppendingPathComponent:extensionId];
  NSString *prefix = [version stringByAppendingString:@"_"];
  for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
    if ([name hasPrefix:prefix]) return [dir stringByAppendingPathComponent:name];
  return nil;
}

}

@implementation SolaraCoreServices

+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:(SolaraCoreResult)completion {
  [SolaraCoreEngineBridge call:name profile:profile args:JSON(args) completion:^(NSString *json) { completion(Parse(json)); }];
}

+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args secrets:(NSDictionary<NSString *, NSString *> *)secrets
    completion:(SolaraCoreResult)completion {
  [SolaraCoreEngineBridge callWithSecret:name
                                profile:solaracore_host::OriginalProfileName(profile)
                                   args:WithSecrets(args, secrets)
                             completion:^(NSString *json) { completion(Parse(json)); }];
}

+ (void)listPasswords:(NSString *)profile completion:(SolaraCoreResult)completion {
  NSAssert(NSThread.isMainThread, @"listPasswords off main");
  [self call:@"ac_passwords_list" profile:profile args:nil completion:^(NSDictionary *result) {
    NSArray *list = result[@"passwords"];
    if (![list isKindOfClass:NSArray.class]) return completion(result);
    NSMutableArray *passwords = [NSMutableArray array];
    for (NSDictionary *entry in list)
      [passwords addObject:@{@"origin" : entry[@"origin"] ?: @"", @"username" : entry[@"username"] ?: @"", @"created" : @0, @"modified" : @0}];
    completion(@{@"passwords" : passwords});
  }];
}

+ (void)unlockPasswords:(NSString *)profile completion:(SolaraCoreResult)completion {
  NSAssert(NSThread.isMainThread, @"unlockPasswords off main");
  [self call:@"ac_passwords_unlock" profile:profile args:nil completion:completion];
}

+ (void)password:(NSString *)profile origin:(NSString *)origin username:(NSString *)username completion:(SolaraCoreResult)completion {
  NSAssert(NSThread.isMainThread, @"password off main");
  [self call:@"ac_passwords_reveal" profile:profile args:Login(origin, username) completion:completion];
}

+ (void)savePassword:(NSString *)profile origin:(NSString *)origin username:(NSString *)username password:(NSString *)password
          completion:(SolaraCoreResult)completion {
  NSAssert(NSThread.isMainThread, @"savePassword off main");
  [self call:@"ac_passwords_add" profile:profile args:Login(origin, username) secrets:@{@"password" : password ?: @""}
      completion:completion];
}

+ (void)updatePassword:(NSString *)profile origin:(NSString *)origin username:(NSString *)username
           newUsername:(NSString *)newUsername newPassword:(NSString *)newPassword completion:(SolaraCoreResult)completion {
  NSAssert(NSThread.isMainThread, @"updatePassword off main");
  NSMutableDictionary *args = [Login(origin, username) mutableCopy];
  if (newUsername) args[@"newUsername"] = newUsername;
  [self call:@"ac_passwords_update" profile:profile args:args secrets:newPassword ? @{@"newPassword" : newPassword} : @{}
      completion:completion];
}

+ (void)deletePassword:(NSString *)profile origin:(NSString *)origin username:(NSString *)username completion:(SolaraCoreResult)completion {
  NSAssert(NSThread.isMainThread, @"deletePassword off main");
  [self call:@"ac_passwords_remove" profile:profile args:Login(origin, username) completion:completion];
}

+ (void)neverSaveOrigins:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_passwords_exceptions" profile:profile args:nil completion:completion];
}

+ (void)allowSaving:(NSString *)profile origin:(NSString *)origin completion:(SolaraCoreResult)completion {
  [self call:@"ac_passwords_allow" profile:profile args:@{@"origin" : OriginOf(origin)} completion:completion];
}

+ (void)exportPasswords:(NSString *)profile path:(NSString *)path completion:(SolaraCoreResult)completion {
  NSAssert(NSThread.isMainThread, @"exportPasswords off main");
  void (^run)(NSString *) = ^(NSString *target) {
    if (!target) return completion(@{@"status" : @"cancelled"});
    [self call:@"ac_passwords_export" profile:profile args:@{@"path" : target} completion:^(NSDictionary *result) {
      NSMutableDictionary *answer = [result mutableCopy];
      if ([result[@"status"] isEqual:@"succeeded"]) answer[@"path"] = target;
      completion(answer);
    }];
  };
  if (path.length) return run(path);
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.nameFieldStringValue = [NSString stringWithFormat:@"%@ Passwords.csv", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"Solara"];
  panel.allowedContentTypes = @[ UTTypeCommaSeparatedText ];
  panel.canCreateDirectories = YES;
  panel.message = @"Anyone who can open this file can read your passwords.";
  [panel beginWithCompletionHandler:^(NSModalResponse response) { run(response == NSModalResponseOK ? panel.URL.path : nil); }];
}

+ (BOOL)boolPreference:(NSString *)name profile:(NSString *)profile {
  SolaraCoreProfile *p = solaracore_host::LoadedProfile(solaracore_host::OriginalProfileName(profile));
  if (![p respondsToSelector:@selector(boolPreference:)]) return YES;
  NSNumber *value = [p boolPreference:name];
  return value ? value.boolValue : YES;
}

+ (void)setBoolPreference:(NSString *)name value:(BOOL)value profile:(NSString *)profile {
  SolaraCoreProfile *p = solaracore_host::LoadedProfile(solaracore_host::OriginalProfileName(profile));
  if ([p respondsToSelector:@selector(setBoolPreference:value:)]) [p setBoolPreference:name value:value];
}

+ (NSArray<NSString *> *)sleepExceptionsForProfile:(NSString *)profile {
  SolaraCoreProfile *p = solaracore_host::LoadedProfile(solaracore_host::OriginalProfileName(profile));
  if (![p respondsToSelector:@selector(sleepExceptions)]) return nil;
  return p.sleepExceptions;
}

+ (BOOL)setSleepExceptions:(NSArray<NSString *> *)patterns profile:(NSString *)profile {
  SolaraCoreProfile *p = solaracore_host::LoadedProfile(solaracore_host::OriginalProfileName(profile));
  if (![p respondsToSelector:@selector(setSleepExceptions:)]) return NO;
  p.sleepExceptions = patterns;
  return YES;
}

static NSArray<NSString *> *gKeepAwakeSites;
static NSSet<NSString *> *gKeepAwakeAdopted;
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gKeepAwakeWritten;
static NSString *_Nullable (^gKeepAwakeNormalize)(NSString *);
static void (^gKeepAwakeAdopt)(NSString *, NSArray<NSString *> *);

+ (void)setKeepAwakeSites:(NSArray<NSString *> *)sites adopted:(NSArray<NSString *> *)adopted {
  gKeepAwakeSites = [sites copy];
  gKeepAwakeAdopted = [NSSet setWithArray:adopted];
  for (SolaraCoreProfile *profile in solaracore_host::LoadedProfiles()) solaracore_host::ApplyKeepAwakeSites(profile);
}

+ (void)setKeepAwakeAdoption:(void (^)(NSString *, NSArray<NSString *> *))adopt {
  gKeepAwakeAdopt = [adopt copy];
}

static void (^gKeepAwakeRecord)(NSString *, NSArray<NSString *> *);

+ (void)setKeepAwakeRecord:(void (^)(NSString *, NSArray<NSString *> *))record written:(NSDictionary<NSString *, NSArray<NSString *> *> *)written normalize:(NSString *_Nullable (^)(NSString *))normalize {
  gKeepAwakeRecord = [record copy];
  gKeepAwakeNormalize = [normalize copy];
  if (!gKeepAwakeWritten) gKeepAwakeWritten = [NSMutableDictionary dictionary];
  [written enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSArray<NSString *> *patterns, BOOL *) {
    NSString *key = [@"profile:" stringByAppendingString:name];
    if (!gKeepAwakeWritten[key]) gKeepAwakeWritten[key] = [patterns copy];
  }];
}

static bool KeepAwakeOffTheRecord(SolaraCoreProfile *profile) {
  return [profile respondsToSelector:@selector(offTheRecord)] && profile.offTheRecord;
}

static NSString *KeepAwakeWrittenKey(SolaraCoreProfile *profile) {
  return [(KeepAwakeOffTheRecord(profile) ? @"otr:" : @"profile:") stringByAppendingString:profile.name ?: @""];
}

static NSArray<NSString *> *KeepAwakeAddedInChrome(NSArray<NSString *> *current, NSArray<NSString *> *written) {
  NSMutableArray<NSString *> *added = [NSMutableArray array];
  for (NSString *pattern in current) {
    if ([written containsObject:pattern] || [gKeepAwakeSites containsObject:pattern]) continue;
    NSString *site = gKeepAwakeNormalize ? gKeepAwakeNormalize(pattern) : nil;
    if (site && [gKeepAwakeSites containsObject:site]) continue;
    [added addObject:pattern];
  }
  return added;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)keepAwakeAdditions {
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *additions = [NSMutableDictionary dictionary];
  for (SolaraCoreProfile *profile in solaracore_host::LoadedProfiles()) {
    if (!profile || profile.destroyed || KeepAwakeOffTheRecord(profile) || !profile.name) continue;
    if (![profile respondsToSelector:@selector(sleepExceptions)]) continue;
    NSArray<NSString *> *written = gKeepAwakeWritten[KeepAwakeWrittenKey(profile)];
    if (!written) continue;
    NSArray<NSString *> *added = KeepAwakeAddedInChrome(profile.sleepExceptions ?: @[], written);
    if (added.count) additions[profile.name] = added;
  }
  return additions;
}

void solaracore_host::ApplyKeepAwakeSites(SolaraCoreProfile *profile) {
  if (!gKeepAwakeSites || !profile || profile.destroyed || ![profile respondsToSelector:@selector(setSleepExceptions:)]) return;
  const bool offTheRecord = KeepAwakeOffTheRecord(profile);
  NSArray<NSString *> *current = profile.sleepExceptions ?: @[];
  if (!offTheRecord && profile.name && ![gKeepAwakeAdopted containsObject:profile.name]) {
    if (gKeepAwakeAdopt) gKeepAwakeAdopt(profile.name, current);
    return;
  }
  if (!gKeepAwakeWritten) gKeepAwakeWritten = [NSMutableDictionary dictionary];
  NSString *key = KeepAwakeWrittenKey(profile);
  NSArray<NSString *> *previous = gKeepAwakeWritten[key] ?: current;
  NSArray<NSString *> *addedInChrome = KeepAwakeAddedInChrome(current, previous);
  const bool records = !offTheRecord && profile.name && gKeepAwakeRecord;
  if (addedInChrome.count && !offTheRecord && profile.name && gKeepAwakeAdopt) gKeepAwakeAdopt(profile.name, addedInChrome);
  NSArray<NSString *> *next = [gKeepAwakeSites arrayByAddingObjectsFromArray:addedInChrome];
  if (![current isEqualToArray:next]) {
    NSMutableOrderedSet<NSString *> *writing = [NSMutableOrderedSet orderedSetWithArray:previous];
    [writing addObjectsFromArray:gKeepAwakeSites];
    if (records) gKeepAwakeRecord(profile.name, writing.array);
    profile.sleepExceptions = next;
  }
  gKeepAwakeWritten[key] = gKeepAwakeSites;
  if (records) gKeepAwakeRecord(profile.name, gKeepAwakeSites);
}

+ (void)addresses:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_autofill_addresses" profile:profile args:nil completion:Dated(@"addresses", completion)];
}

+ (void)saveAddress:(NSDictionary *)address profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  for (NSString *key in address)
    if ([address[key] isKindOfClass:NSString.class] || [address[key] isKindOfClass:NSNumber.class]) fields[key] = [address[key] description];
  [self call:@"ac_autofill_save_address" profile:profile args:@{@"address" : fields} completion:completion];
}

+ (void)cards:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_autofill_cards" profile:profile args:nil completion:Dated(@"cards", completion)];
}

+ (void)saveCard:(NSDictionary *)card number:(NSString *)number profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_autofill_save_card" profile:profile args:@{@"card" : card ?: @{}} secrets:number ? @{@"number" : number} : @{}
      completion:completion];
}

+ (void)deleteAutofillEntry:(NSString *)entryId profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_autofill_remove" profile:profile args:@{@"id" : entryId ?: @""} completion:completion];
}

+ (void)revealCardNumber:(NSString *)cardId profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_autofill_card_number" profile:profile args:@{@"id" : cardId ?: @""} completion:^(NSDictionary *result) {
    completion([result[@"number"] isKindOfClass:NSString.class] ? @{@"number" : result[@"number"]} : @{});
  }];
}

+ (void)zoomLevels:(NSString *)profile completion:(void (^)(NSDictionary<NSString *, NSNumber *> *))completion {
  if (solaracore_host::IsIncognito(profile)) return completion(@{});
  [self call:@"ac_zoom_list" profile:profile args:nil completion:^(NSDictionary *result) {
    NSMutableDictionary *levels = [NSMutableDictionary dictionary];
    NSDictionary *hosts = [result[@"levels"] isKindOfClass:NSDictionary.class] ? result[@"levels"] : @{};
    for (NSString *host in hosts) levels[host] = @(round(pow(1.2, [hosts[host] doubleValue]) * 100) / 100);
    completion(levels);
  }];
}

+ (void)setZoom:(double)zoom profile:(NSString *)profile host:(NSString *)host {
  host = host.lowercaseString;
  if (!host.length || zoom <= 0) return;
  const double level = fabs(zoom - 1) < 1e-6 ? 0 : log(zoom) / log(1.2);
  [self call:@"ac_zoom_set" profile:profile args:@{@"host" : host, @"level" : @(level)} completion:^(NSDictionary *) {}];
}

+ (void (^)(NSString *, NSDictionary *))extensionsHandler {
  return gExtensionsHandler;
}

+ (void)setExtensionsHandler:(void (^)(NSString *, NSDictionary *))handler {
  gExtensionsHandler = [handler copy];
}

+ (void)listExtensions:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_extensions_list" profile:profile args:nil completion:^(NSDictionary *result) {
    if (result[@"error"]) return completion(result);
    NSArray *infos = result[@"extensions"];
    if (![infos isKindOfClass:NSArray.class]) return completion(@{@"error" : @"Unexpected extension list"});
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *info in infos) {
      if (![info isKindOfClass:NSDictionary.class]) continue;
      NSMutableDictionary *item = [info mutableCopy];
      for (NSString *key in item.allKeys)
        if (item[key] == NSNull.null) item[key] = nil;
      NSString *path = [info[@"path"] isKindOfClass:NSString.class] ? info[@"path"] : nil;
      NSString *folder = path ?: StoreFolder(profile, info[@"id"], info[@"version"]);
      NSDictionary *manifest = folder ? ac::ext::ReadManifest(folder) : nil;
      for (NSString *key in @[ @"popup", @"actionTitle", @"actionIcon", @"sidePanel", @"hasAction" ])
        if (manifest[key]) item[key] = manifest[key];
      item[@"incognitoSplit"] = @([manifest[@"incognitoSplit"] boolValue]);
      for (NSString *key in @[ @"siteAccess", @"optionsUrl", @"path", @"homepageUrl" ])
        if (!item[key]) item[key] = NSNull.null;
      const BOOL fromStore = [info[@"location"] isEqual:@"FROM_STORE"];
      item[@"fromWebStore"] = @(fromStore);
      item[@"webStoreUrl"] = fromStore ? [@"https://chromewebstore.google.com/detail/" stringByAppendingString:info[@"id"]] : NSNull.null;
      [list addObject:item];
    }
    completion(@{@"extensions" : list});
  }];
}

+ (NSDictionary *)inspectUnpacked:(NSString *)path {
  NSMutableDictionary *info = [ac::ext::ReadManifest(path) mutableCopy];
  if (!info[@"error"]) info[@"path"] = path;
  return info;
}

+ (void)run:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args event:(NSString *)event completion:(SolaraCoreResult)completion {
  NSString *extensionId = args[@"id"];
  [self call:name profile:profile args:args completion:^(NSDictionary *result) {
    if (event && !result[@"error"]) Changed(profile, extensionId, event);
    completion(result);
  }];
}

+ (void)installExtension:(NSString *)path profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_extensions_install" profile:profile args:@{@"path" : path ?: @""} completion:^(NSDictionary *result) {
    if ([result[@"id"] isKindOfClass:NSString.class]) Changed(profile, result[@"id"], @"installed");
    completion(result);
  }];
}

+ (void)installCrx:(NSString *)path profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_extensions_install_crx" profile:profile args:@{@"path" : path ?: @""} completion:^(NSDictionary *result) {
    if ([result[@"id"] isKindOfClass:NSString.class]) Changed(profile, result[@"id"], @"installed");
    completion(result);
  }];
}

+ (void)setExtension:(NSString *)extensionId enabled:(BOOL)enabled profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self run:@"ac_extensions_set_enabled" profile:profile args:@{@"id" : extensionId, @"enabled" : @(enabled)}
      event:enabled ? @"enabled" : @"disabled" completion:completion];
}

+ (void)uninstallExtension:(NSString *)extensionId profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self run:@"ac_extensions_uninstall" profile:profile args:@{@"id" : extensionId} event:@"uninstalled" completion:completion];
}

+ (void)reloadExtension:(NSString *)extensionId profile:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self run:@"ac_extensions_reload" profile:profile args:@{@"id" : extensionId} event:@"reloaded" completion:completion];
}

+ (void)configureExtension:(NSString *)extensionId profile:(NSString *)profile options:(NSDictionary *)options completion:(SolaraCoreResult)completion {
  NSMutableDictionary *args = [NSMutableDictionary dictionaryWithObject:extensionId forKey:@"id"];
  for (NSString *key in @[ @"pinned", @"incognito", @"fileAccess", @"siteAccess" ])
    if (options[key]) args[key] = options[key];
  [self run:@"ac_extensions_configure" profile:profile args:args event:@"configured" completion:completion];
}

+ (void)searchEngineList:(NSString *)profile completion:(SolaraCoreResult)completion {
  [self call:@"ac_search_engines_list" profile:profile args:nil completion:^(NSDictionary *result) {
    if (result[@"error"]) return completion(result);
    completion(@{@"list" : @{@"engines" : result[@"engines"] ?: @[]}});
  }];
}

void (^gDownloadsHandler)(NSDictionary *);
void DeliverDownload(NSDictionary *download, NSString *profile, NSInteger epoch) {
  NSDictionary *forwarded = [NativePrivateDownloadRoutes.shared forwardedDownload:download profile:profile ?: @"" epoch:epoch
                                                       privateDownloadsSupported:SolaraPrivateDownloadSourceFenceAvailable()];
  if (forwarded && gDownloadsHandler) gDownloadsHandler(forwarded);
}

+ (void)setPrivateSessionGeneration:(NSString *)engineProfile generation:(NSString *)generation {
  engineProfile = engineProfile ?: @"";
  if ([[NativePrivateDownloadRoutes.shared generation:engineProfile] isEqualToString:generation]) return;
  [NativePrivateDownloadRoutes.shared setGeneration:engineProfile generation:generation];
  if (!SolaraPrivateDownloadSourceFenceAvailable()) return;
  [self call:@"ac_downloads_begin_private" profile:engineProfile
        args:@{@"privateSessionEpoch" : @([NativePrivateDownloadRoutes.shared epoch:engineProfile])} completion:^(NSDictionary *) {}];
}

+ (void)endPrivateSession:(NSString *)engineProfile {
  engineProfile = engineProfile ?: @"";
  [NativePrivateDownloadRoutes.shared endSession:engineProfile privateDownloadsSupported:SolaraPrivateDownloadSourceFenceAvailable()];
  if (!SolaraPrivateDownloadSourceFenceAvailable()) return;
  [self call:@"ac_downloads_end_private" profile:engineProfile
        args:@{@"privateSessionEpoch" : @([NativePrivateDownloadRoutes.shared epoch:engineProfile])} completion:^(NSDictionary *) {}];
}

+ (void (^)(NSDictionary *))downloadsHandler {
  return gDownloadsHandler;
}

+ (void)setDownloadsHandler:(void (^)(NSDictionary *))handler {
  gDownloadsHandler = [handler copy];
  static bool observing = false;
  if (observing) return;
  observing = true;
  [SolaraCoreEngineBridge observe:@"downloads.changed"
                      handler:^(NSDictionary *payload) {
                        NSDictionary *download = [payload[@"download"] isKindOfClass:NSDictionary.class] ? payload[@"download"] : nil;
                        if (!download) return;
                        NSString *profile = [payload[@"profile"] isKindOfClass:NSString.class] ? payload[@"profile"] : @"";
                        DeliverDownload(download, profile, [NativePrivateDownloadRoutes.shared epoch:profile]);
                      }];
}

+ (void)watchDownloads:(NSString *)profile {
  profile = profile ?: @"";
  const NSInteger epoch = [NativePrivateDownloadRoutes.shared epoch:profile];
  [self call:@"ac_downloads_list" profile:profile args:nil completion:^(NSDictionary *result) {
    for (NSDictionary *download in [result[@"downloads"] isKindOfClass:NSArray.class] ? result[@"downloads"] : @[]) {
      if (![download isKindOfClass:NSDictionary.class]) continue;
      DeliverDownload(download, profile, epoch);
    }
  }];
}

+ (void)downloadCommand:(NSString *)command id:(NSString *)downloadId {
  NSString *profile = [NativePrivateDownloadRoutes.shared profile:downloadId ?: @""];
  if (!profile && SolaraPrivateDownloadSourceFenceAvailable()) return;
  [self call:[@"ac_downloads_" stringByAppendingString:command] profile:profile ?: @"" args:@{@"id" : downloadId ?: @""}
      completion:^(NSDictionary *) {}];
}

+ (void)siteSettings:(NSString *)profile origin:(NSString *)origin completion:(SolaraCoreResult)completion {
  [self call:@"ac_site_settings_get" profile:profile args:@{@"origin" : origin ?: @""} completion:^(NSDictionary *result) {
    completion([result[@"settings"] isKindOfClass:NSDictionary.class] ? result[@"settings"] : @{});
  }];
}

+ (void)setSiteSetting:(NSString *)value profile:(NSString *)profile origin:(NSString *)origin type:(NSString *)type {
  [self call:@"ac_site_settings_set" profile:profile args:@{@"origin" : origin ?: @"", @"type" : type ?: @"", @"value" : value ?: @""}
      completion:^(NSDictionary *) {}];
}

+ (void)siteSettingsOrigins:(NSString *)profile completion:(void (^)(NSArray<NSString *> *))completion {
  [self call:@"ac_site_settings_origins" profile:profile args:nil completion:^(NSDictionary *result) {
    completion([result[@"origins"] isKindOfClass:NSArray.class] ? result[@"origins"] : @[]);
  }];
}

+ (void)resetSiteSettings:(NSString *)profile origin:(NSString *)origin {
  [self call:@"ac_site_settings_reset" profile:profile args:@{@"origin" : origin ?: @""} completion:^(NSDictionary *) {}];
}

+ (void)clearSiteData:(NSString *)profile origin:(NSString *)origin completion:(SolaraCoreResult)completion {
  [self call:@"ac_site_data_clear" profile:profile args:@{@"origin" : origin ?: @""} completion:^(NSDictionary *result) {
    completion(result[@"error"] ? @{@"cookies" : @NO, @"storage" : @NO} : result);
  }];
}

+ (void)externalAppAllowances:(NSString *)profile completion:(void (^)(NSArray *))completion {
  [self call:@"ac_external_apps_allowances" profile:profile args:nil completion:^(NSDictionary *result) {
    completion([result[@"allowances"] isKindOfClass:NSArray.class] ? result[@"allowances"] : @[]);
  }];
}

+ (void)removeExternalAppAllowance:(NSString *)profile origin:(NSString *)origin scheme:(NSString *)scheme {
  [self call:@"ac_external_apps_remove" profile:profile args:@{@"origin" : origin ?: @"", @"scheme" : scheme ?: @""}
      completion:^(NSDictionary *) {}];
}

+ (void)tasks:(void (^)(NSArray *))completion {
  [self call:@"ac_tasks_list" profile:@"" args:nil completion:^(NSDictionary *result) {
    NSMutableArray *tasks = [NSMutableArray array];
    for (NSDictionary *task in [result[@"tasks"] isKindOfClass:NSArray.class] ? result[@"tasks"] : @[]) {
      if (![task isKindOfClass:NSDictionary.class]) continue;
      NSMutableDictionary *t = [task mutableCopy];
      NSMutableArray *browserIds = [NSMutableArray array];
      for (NSNumber *tabId in [task[@"tabIds"] isKindOfClass:NSArray.class] ? task[@"tabIds"] : @[])
        for (SolaraCoreWindowController *c in SolaraCoreWindowController.all)
          for (SolaraCoreProfile *p in solaracore_host::LoadedProfiles())
            for (SolaraCoreTab *tab in [c.coreWindow tabsForProfile:p])
              if (tab.tabId == tabId.intValue) [browserIds addObject:@(solaracore_host::BrowserId(tab))];
      t[@"browserIds"] = browserIds;
      [tasks addObject:t];
    }
    completion(tasks);
  }];
}

+ (void)components:(void (^)(NSArray *))completion {
  [self call:@"ac_components_list" profile:@"" args:nil completion:^(NSDictionary *result) {
    completion([result[@"components"] isKindOfClass:NSArray.class] ? result[@"components"] : @[]);
  }];
}

+ (void)clearBrowsingData:(NSString *)profile types:(NSArray<NSString *> *)types since:(double)sinceMs completion:(void (^)(void))completion {
  if ([types containsObject:@"history"]) [SolaraCoreEarlyWindow forgetPictures];
  SolaraCoreProfile *p = solaracore_host::LoadedProfile(profile);
  if ([p respondsToSelector:@selector(clearBrowsingData:since:completion:)]) {
    [p clearBrowsingData:types since:[NSDate dateWithTimeIntervalSince1970:sinceMs / 1000] completion:completion];
    return;
  }
  completion();
}

@end
