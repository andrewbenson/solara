#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

@interface SolaraCoreProfile : NSObject
@property(copy) NSString *name;
@property(copy) NSString *path;
@property BOOL offTheRecord;
@property BOOL destroyed;
@end
@implementation SolaraCoreProfile
@end

static NSMutableArray<NSString *> *steps;
static NSArray<SolaraCoreProfile *> *gEngineProfiles = @[];
static SolaraCoreProfile *gPersonal;
static NSMutableSet<NSString *> *gDeleted;

@interface SolaraCoreEngine : NSObject
@property(class, readonly) SolaraCoreEngine *sharedEngine;
@property(readonly) NSArray<SolaraCoreProfile *> *loadedProfiles;
@end
@implementation SolaraCoreEngine
+ (SolaraCoreEngine *)sharedEngine { static SolaraCoreEngine *engine = [SolaraCoreEngine new]; return engine; }
- (NSArray<SolaraCoreProfile *> *)loadedProfiles { return gEngineProfiles; }
@end

@interface SolaraCoreServices : NSObject
+ (void)watchDownloads:(NSString *)profile;
@end
@implementation SolaraCoreServices
+ (void)watchDownloads:(NSString *)profile { [steps addObject:[@"downloads:" stringByAppendingString:profile]]; }
@end

@interface SolaraCoreWindow : NSObject
@end
@implementation SolaraCoreWindow
@end

static NSString *Prepared(SolaraCoreProfile *profile) {
  for (NSString *step in steps)
    if ([step hasPrefix:@"blocker:"] && [step containsString:[profile.name stringByReplacingOccurrencesOfString:@"Profile " withString:@""]]) return @"after-blocker";
  return @"before-blocker";
}

@interface SolaraCoreWindowController : NSObject
@property(readonly) SolaraCoreWindow *coreWindow;
+ (SolaraCoreWindowController *)chromeMadeWindowForProfile:(SolaraCoreProfile *)profile;
+ (SolaraCoreWindowController *)strayWindowForProfile:(SolaraCoreProfile *)profile;
@end
@implementation SolaraCoreWindowController
- (SolaraCoreWindow *)coreWindow { return [SolaraCoreWindow new]; }
+ (SolaraCoreWindowController *)chromeMadeWindowForProfile:(SolaraCoreProfile *)profile {
  [steps addObject:[NSString stringWithFormat:@"window:%@:%@", profile.name, Prepared(profile)]];
  return [SolaraCoreWindowController new];
}
+ (SolaraCoreWindowController *)strayWindowForProfile:(SolaraCoreProfile *)profile {
  [steps addObject:[NSString stringWithFormat:@"stray:%@:%@", profile.offTheRecord ? @"private" : profile.name, Prepared(profile)]];
  return [SolaraCoreWindowController new];
}
@end

static NSMutableDictionary<NSString *, SolaraCoreProfile *> *Profiles() {
  static NSMutableDictionary *profiles = [NSMutableDictionary dictionary];
  return profiles;
}
static NSString *DirectoryName(NSString *name) { return name.length ? [@"Profile " stringByAppendingString:name] : @"Default"; }

namespace solaracore_host {
BOOL IsIncognito(NSString *) { return NO; }
bool IsDeletedProfile(NSString *name) { return [gDeleted containsObject:name]; }
void LoadContentBlocker(NSString *name) {
  [steps addObject:[NSString stringWithFormat:@"blocker:%@:%@", name, Profiles()[name] ? @"registered" : @"unregistered"]];
}
void ApplyKeepAwakeSites(SolaraCoreProfile *profile) { [steps addObject:@"keepAwake"]; }
SolaraCoreProfile *PersonalIfLoaded(SolaraCoreEngine *) { return gPersonal; }
}

bool gStarted = true;
void (^gEventHandler)(NSString *, NSDictionary *);

__PRODUCTION__

static SolaraCoreProfile *Make(NSString *directory) {
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.name = directory;
  return profile;
}

static void Drain() {
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

int main() {
  @autoreleasepool {
    steps = [NSMutableArray array];
    gDeleted = [NSMutableSet set];
    gEventHandler = ^(NSString *event, NSDictionary *payload) {
      [steps addObject:[NSString stringWithFormat:@"%@:%@", event, payload[@"profile"]]];
    };
    [NSNotificationCenter.defaultCenter addObserverForName:@"SolaraCoreProfileDidLoad" object:nil queue:nil usingBlock:^(NSNotification *note) {
      [steps addObject:[@"notification:" stringByAppendingString:note.userInfo[@"profile"]]];
    }];
    NSMutableDictionary *results = [NSMutableDictionary dictionary];

    SolaraCoreProfile *work = Make(@"Profile work");
    PrepareLoadedProfile(work);
    NSArray *synchronous = [steps copy];
    Drain();
    PrepareLoadedProfile(work);
    Drain();
    results[@"didLoad"] = @{ @"synchronous": synchronous, @"all": [steps copy] };

    [steps removeAllObjects];
    gPersonal = Make(@"Default");
    gEngineProfiles = @[ work, Make(@"Profile side") ];
    RememberLoadedProfiles();
    synchronous = [steps copy];
    Drain();
    results[@"remember"] = @{ @"synchronous": synchronous, @"all": [steps copy] };

    [steps removeAllObjects];
    SolaraCoreProfile *gone = Make(@"Profile gone");
    PrepareLoadedProfile(gone);
    gone.destroyed = YES;
    Drain();
    [gDeleted addObject:@"cut"];
    PrepareLoadedProfile(Make(@"Profile cut"));
    Drain();
    results[@"dropped"] = [steps copy];

    [steps removeAllObjects];
    SolaraCoreProfile *dormant = Make(@"Profile dormant");
    dormant.path = @"/data/Chromium/Profile dormant";
    [[EngineDelegate new] engineWindowForNewBrowserOfProfile:dormant type:@"normal"];
    [[EngineDelegate new] engineWindowForNewBrowserOfProfile:dormant type:@"normal"];
    SolaraCoreProfile *quiet = Make(@"Profile quiet");
    quiet.path = @"/data/Chromium/Profile quiet";
    SolaraCoreProfile *privateQuiet = Make(@"Profile quiet");
    privateQuiet.path = quiet.path;
    privateQuiet.offTheRecord = YES;
    gEngineProfiles = @[ quiet ];
    [[EngineDelegate new] engineWindowForNewBrowserOfProfile:privateQuiet type:@"normal"];
    Drain();
    results[@"newBrowser"] = [steps copy];

    NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
  }
  return 0;
}
