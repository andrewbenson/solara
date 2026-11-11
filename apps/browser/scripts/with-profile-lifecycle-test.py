import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[3] / "packages/solaracore/ios/SolaraCoreHost.mm")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("void WithProfile(NSString *name, void (^completion)(SolaraCoreProfile *)) {")
end = source.index("\nSolaraCoreProfile *PersonalIfLoaded", start)
body = source[start:end]
harness = r'''
#import <Foundation/Foundation.h>

static BOOL gStarted = NO;
static BOOL engineAvailable = YES;
static int stateAccesses = 0;
static int defaultAccesses = 0;

@interface SolaraCoreProfile : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL destroyed;
@end
@implementation SolaraCoreProfile
@end

@interface SolaraCoreEngine : NSObject
+ (instancetype)sharedEngine;
@property(nonatomic, readonly) SolaraCoreProfile *defaultProfile;
- (void)loadProfile:(NSString *)directory completion:(void (^)(SolaraCoreProfile *))completion;
@end
@implementation SolaraCoreEngine
+ (instancetype)sharedEngine {
  stateAccesses += 1;
  static SolaraCoreEngine *engine;
  if (!engine) engine = [SolaraCoreEngine new];
  return engineAvailable ? engine : nil;
}
- (SolaraCoreProfile *)defaultProfile {
  defaultAccesses += 1;
  if (!gStarted) @throw [NSException exceptionWithName:@"EngineAfterShutdown" reason:@"defaultProfile accessed while stopped" userInfo:nil];
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.name = @"Default";
  return profile;
}
- (void)loadProfile:(NSString *)directory completion:(void (^)(SolaraCoreProfile *))completion {
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.name = directory;
  completion(profile);
}
@end

@interface SolaraCoreServices : NSObject
+ (void)watchDownloads:(NSString *)name;
@end
@implementation SolaraCoreServices
+ (void)watchDownloads:(NSString *)name {}
@end

namespace solaracore_host {
static NSMutableDictionary *profileMap = [NSMutableDictionary dictionary];
static NSMutableSet *deleted = [NSMutableSet set];
static NSMutableDictionary *waiters = [NSMutableDictionary dictionary];
static NSMutableDictionary *deletions = [NSMutableDictionary dictionary];
NSMutableDictionary *Profiles() { stateAccesses += 1; return profileMap; }
NSMutableSet *DeletedProfiles() { stateAccesses += 1; return deleted; }
NSMutableDictionary *ProfileWaiters() { stateAccesses += 1; return waiters; }
NSMutableDictionary *DeletionsAfterLoad() { stateAccesses += 1; return deletions; }
SolaraCoreProfile *LoadedProfile(NSString *name) { stateAccesses += 1; return profileMap[name]; }
bool IsIncognito(NSString *name) { return [name hasPrefix:@"incognito:"]; }
void WithPrivateProfile(NSString *name, void (^completion)(SolaraCoreProfile *)) {
  SolaraCoreProfile *profile = [SolaraCoreProfile new];
  profile.name = name;
  completion(profile);
}
SolaraCoreProfile *PersonalIfLoaded(SolaraCoreEngine *engine) { return engine.defaultProfile; }
NSString *DirectoryName(NSString *name) { return [@"Profile " stringByAppendingString:name]; }
void ApplyKeepAwakeSites(SolaraCoreProfile *profile) {}
void LoadContentBlocker(NSString *name) {}
@@BODY@@
}

int main() {
  @autoreleasepool {
    int failures = 0;
    for (NSString *name in @[@"", @"named", @"incognito:private", @"cached"]) {
      BOOL states[] = {NO, YES};
      for (BOOL started : states) {
        gStarted = started;
        engineAvailable = YES;
        [solaracore_host::profileMap removeAllObjects];
        [solaracore_host::deleted removeAllObjects];
        [solaracore_host::waiters removeAllObjects];
        SolaraCoreProfile *cached = [SolaraCoreProfile new];
        cached.name = @"cached";
        solaracore_host::profileMap[@"cached"] = cached;
        stateAccesses = 0;
        defaultAccesses = 0;
        __block int callbacks = 0;
        __block SolaraCoreProfile *result = nil;
        BOOL threw = NO;
        @try {
          solaracore_host::WithProfile(name, ^(SolaraCoreProfile *profile) { callbacks += 1; result = profile; });
        } @catch (NSException *error) {
          threw = YES;
        }
        BOOL pass = !threw && callbacks == 1 && (started ? result != nil : result == nil && stateAccesses == 0 && defaultAccesses == 0);
        printf("%s %s profile=%s callbacks=%d state_accesses=%d default_accesses=%d\n", pass ? "PASS" : "FAIL", started ? "running" : "stopped", name.UTF8String, callbacks, stateAccesses, defaultAccesses);
        if (!pass) failures += 1;
      }
    }
    gStarted = YES;
    [solaracore_host::profileMap removeAllObjects];
    [solaracore_host::deleted addObject:@"deleted"];
    __block BOOL rejectedDeleted = NO;
    solaracore_host::WithProfile(@"deleted", ^(SolaraCoreProfile *profile) { rejectedDeleted = profile == nil; });
    printf("%s deleted profile\n", rejectedDeleted ? "PASS" : "FAIL");
    if (!rejectedDeleted) failures += 1;
    engineAvailable = NO;
    __block BOOL rejectedMissingEngine = NO;
    solaracore_host::WithProfile(@"missing", ^(SolaraCoreProfile *profile) { rejectedMissingEngine = profile == nil; });
    printf("%s absent engine\n", rejectedMissingEngine ? "PASS" : "FAIL");
    if (!rejectedMissingEngine) failures += 1;
    return failures ? 1 : 0;
  }
}
'''.replace("@@BODY@@", body)
with tempfile.TemporaryDirectory(prefix="solara-profile-lifecycle-") as temporary:
    directory = Path(temporary)
    source_file = directory / "profile-lifecycle.mm"
    executable = directory / "profile-lifecycle"
    source_file.write_text(harness)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks", "-framework", "Foundation", str(source_file), "-o", str(executable)], check=True, timeout=60)
    result = subprocess.run([str(executable)], timeout=10)
    raise SystemExit(result.returncode)
