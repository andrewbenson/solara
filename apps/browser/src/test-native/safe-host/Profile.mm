#import <Foundation/Foundation.h>

static BOOL gSafeMode = NO;
static NSString *gDataDirectory;
static int engineLookups = 0;
static int profileLookups = 0;
static int engineCalls = 0;
static int fenceCalls = 0;
static BOOL loaded = NO;
static NSArray *gChromeProfiles = @[];

@interface SolaraCoreProfile : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL destroyed;
@end
@implementation SolaraCoreProfile
@end

@interface SolaraCoreEngine : NSObject
@property(class, readonly) SolaraCoreEngine *sharedEngine;
@property(readonly) NSArray<SolaraCoreProfile *> *loadedProfiles;
- (void)deleteProfile:(SolaraCoreProfile *)profile completion:(void (^)(BOOL))done;
- (void)fenceNotificationsForProfileDeletionAtPath:(NSString *)path completion:(void (^)(BOOL))done;
@end
@implementation SolaraCoreEngine
+ (SolaraCoreEngine *)sharedEngine { engineLookups++; return [SolaraCoreEngine new]; }
- (NSArray<SolaraCoreProfile *> *)loadedProfiles { return gChromeProfiles; }
- (void)deleteProfile:(SolaraCoreProfile *)profile completion:(void (^)(BOOL))done { engineCalls++; done(YES); }
- (void)fenceNotificationsForProfileDeletionAtPath:(NSString *)path completion:(void (^)(BOOL))done { fenceCalls++; done(YES); }
@end

namespace solaracore_host {
BOOL IsIncognito(NSString *) { return NO; }
SolaraCoreProfile *LoadedProfile(NSString *name) {
  profileLookups++;
  if (!loaded) return nil;
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.path = [gDataDirectory stringByAppendingPathComponent:[@"Profile " stringByAppendingString:name]];
  return profile;
}
}
NSMutableSet *DeletedProfiles() { static NSMutableSet *value = [NSMutableSet set]; return value; }
NSMutableDictionary *Profiles() { static NSMutableDictionary *value = [NSMutableDictionary dictionary]; return value; }
NSMutableDictionary *ProfileWaiters() { static NSMutableDictionary *value = [NSMutableDictionary dictionary]; return value; }
NSMutableDictionary *DeletionsAfterLoad() { static NSMutableDictionary *value = [NSMutableDictionary dictionary]; return value; }

@interface SolaraCoreHost : NSObject
+ (void)deleteProfileData:(NSString *)profile deletionAllowed:(BOOL (^)(void))deletionAllowed completion:(void (^)(NSArray<NSString *> *))completion;
@end
__PRODUCTION__

int main() {
  @autoreleasepool {
    gDataDirectory = @(getenv("TMPDIR"));
    NSMutableArray *results = [NSMutableArray array];
    for (NSNumber *mode in @[ @YES, @NO ]) {
      for (NSNumber *isLoaded in @[ @YES, @NO ]) {
        gSafeMode = mode.boolValue;
        loaded = isLoaded.boolValue;
        NSString *dir = [gDataDirectory stringByAppendingPathComponent:@"Profile 1"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *bookmarks = [@"bookmarks-preserve-me" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *history = [@"history-preserve-me" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *bookmarkPath = [dir stringByAppendingPathComponent:@"Bookmarks"];
        NSString *historyPath = [dir stringByAppendingPathComponent:@"History"];
        [bookmarks writeToFile:bookmarkPath atomically:YES];
        [history writeToFile:historyPath atomically:YES];
        [DeletedProfiles() removeAllObjects];
        [ScheduledProfileDeletions() removeAllObjects];
        engineLookups = profileLookups = engineCalls = fenceCalls = 0;
        __block int callbacks = 0;
        __block NSArray *remaining;
        [SolaraCoreHost deleteProfileData:@"1" deletionAllowed:^BOOL { return YES; } completion:^(NSArray *value) { callbacks++; remaining = value; }];
        [results addObject:@{ @"safe": mode, @"loaded": isLoaded, @"remaining": remaining ?: @[], @"callbacks": @(callbacks),
                             @"engineLookups": @(engineLookups), @"profileLookups": @(profileLookups), @"engineCalls": @(engineCalls), @"fenceCalls": @(fenceCalls),
                             @"bookmarksKept": @([[NSData dataWithContentsOfFile:bookmarkPath] isEqualToData:bookmarks]),
                             @"historyKept": @([[NSData dataWithContentsOfFile:historyPath] isEqualToData:history]),
                             @"directoryExists": @([NSFileManager.defaultManager fileExistsAtPath:dir]),
                             @"deletedProfiles": @(DeletedProfiles().count) }];
      }
    }
    for (NSNumber *deferred in @[ @NO, @YES ]) {
      gSafeMode = NO;
      loaded = NO;
      [ScheduledProfileDeletions() removeAllObjects];
      NSString *dir = [gDataDirectory stringByAppendingPathComponent:@"Profile guarded"];
      [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
      NSString *sentinel = [dir stringByAppendingPathComponent:@"sentinel"];
      [@"untouched" writeToFile:sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil];
      if (deferred.boolValue) ProfileWaiters()[@"guarded"] = @[];
      __block BOOL allowed = deferred.boolValue;
      __block int callbacks = 0;
      __block NSArray *remaining;
      [SolaraCoreHost deleteProfileData:@"guarded" deletionAllowed:^BOOL { return allowed; } completion:^(NSArray *value) { callbacks++; remaining = value; }];
      if (deferred.boolValue) {
        allowed = NO;
        void (^remove)(SolaraCoreProfile *) = DeletionsAfterLoad()[@"guarded"];
        remove(nil);
        [DeletionsAfterLoad() removeAllObjects];
        [ProfileWaiters() removeAllObjects];
      }
      [results addObject:@{ @"guarded": @YES, @"deferred": deferred, @"callbacks": @(callbacks), @"remaining": remaining ?: @[],
                           @"sentinelKept": @([[NSString stringWithContentsOfFile:sentinel encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"untouched"]) }];
    }
    {
      gSafeMode = NO;
      loaded = NO;
      [DeletedProfiles() removeAllObjects];
      [ScheduledProfileDeletions() removeAllObjects];
      NSString *dir = [gDataDirectory stringByAppendingPathComponent:@"Profile chrome"];
      [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
      NSString *sentinel = [dir stringByAppendingPathComponent:@"sentinel"];
      [@"untouched" writeToFile:sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil];
      SolaraCoreProfile *live = [SolaraCoreProfile new];
      live.path = dir;
      gChromeProfiles = @[ live ];
      engineCalls = 0;
      __block int callbacks = 0;
      __block NSArray *remaining;
      [SolaraCoreHost deleteProfileData:@"chrome" deletionAllowed:^BOOL { return YES; } completion:^(NSArray *value) { callbacks++; remaining = value; }];
      gChromeProfiles = @[];
      [results addObject:@{ @"chromeHeld": @YES, @"callbacks": @(callbacks), @"remaining": remaining ?: @[], @"engineCalls": @(engineCalls),
                           @"sentinelKept": @([[NSString stringWithContentsOfFile:sentinel encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"untouched"]) }];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
