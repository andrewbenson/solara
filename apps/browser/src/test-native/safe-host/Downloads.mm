#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdlib.h>

@interface SolaraCoreHost : NSObject
@property(class) BOOL safeMode;
@property(class, readonly) BOOL isStarted;
@end
@implementation SolaraCoreHost
static BOOL safe = NO;
+ (BOOL)safeMode { return safe; }
+ (void)setSafeMode:(BOOL)value { safe = value; }
+ (BOOL)isStarted { return YES; }
@end

@interface SolaraCoreProfile : NSObject
@property(copy) NSString *path;
@property BOOL offTheRecord;
@end
@implementation SolaraCoreProfile
@end

typedef void (^SolaraCoreResult)(NSDictionary *);
@interface SolaraCoreServices : NSObject
+ (void)call:(NSString *)name profile:(NSString *)profile args:(NSDictionary *)args completion:(SolaraCoreResult)completion;
+ (void)downloadCommand:(NSString *)command id:(NSString *)downloadId;
@end

static int profileCalls = 0;
static int engineCalls = 0;
static NSMutableArray *received;
static NSMutableArray *symbols;
namespace solaracore_host {
BOOL IsIncognito(NSString *) { return NO; }
NSArray<SolaraCoreProfile *> *LoadedProfiles() { return @[]; }
NSString *ProfileName(SolaraCoreProfile *) { return @""; }
NSString *OriginalProfileName(NSString *profile) { return profile; }
void WithProfile(NSString *name, void (^done)(SolaraCoreProfile *)) {
  if (![name isEqualToString:@"fixture-profile-id"]) abort();
  profileCalls++;
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.path = @"fixture-profile";
  done(profile);
}
}

void FakeEngine(const char *profile, const char *args, void (*reply)(void *, const char *), void *context) {
  engineCalls++;
  NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:[@(args) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  [received addObject:@{ @"profile": @(profile), @"args": parsed }];
  reply(context, "{\"ok\":true}");
}
void *FakeSymbolLookup(void *, const char *name) {
  [symbols addObject:@(name)];
  return (void *)&FakeEngine;
}
#define dlsym FakeSymbolLookup

__PRODUCTION__

int main() {
  @autoreleasepool {
    received = [NSMutableArray array];
    symbols = [NSMutableArray array];
    [NativePrivateDownloadRoutes.shared forwardedDownload:@{ @"id": @"download-42", @"offTheRecord": @NO }
                                                profile:@"fixture-profile-id" epoch:0 privateDownloadsSupported:NO];
    NSMutableArray *results = [NSMutableArray array];
    for (NSNumber *mode in @[ @YES, @NO ]) {
      SolaraCoreHost.safeMode = mode.boolValue;
      for (NSString *command in @[ @"remove", @"cancel" ]) {
        profileCalls = engineCalls = 0;
        [received removeAllObjects];
        [symbols removeAllObjects];
        [SolaraCoreServices downloadCommand:command id:@"download-42"];
        [results addObject:@{ @"safe": mode, @"command": command, @"engineCalls": @(engineCalls), @"profileCalls": @(profileCalls),
                             @"symbols": [symbols copy], @"received": [received copy] }];
      }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  }
}
