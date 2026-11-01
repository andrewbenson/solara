#import <Security/Security.h>
#import <objc/runtime.h>

#import "SolaraCoreEarlyWindow.h"
#import "SolaraCoreInternal.h"
#import "SolaraCoreServices.h"
#import "SolaraCoreNavigationDownloads.h"
#import "SolaraCoreStartup.h"
#import "SolaraCoreTabParking.h"
#import "SolaraCoreWebView.h"
#import "SolaraCoreWebViewInternal.h"

#include <crt_externs.h>

#include <cctype>
#include <cstring>
#include <set>
#include <string>
#include <vector>

namespace {

id<NSApplicationDelegate> (^gMakeDelegate)(void);
id<NSApplicationDelegate> gAppDelegate;
BOOL gStarted;
NSString *gDataDirectory;

BOOL gMenuShortcutsReady;

void SendReservedShortcuts() {
  if (!gStarted || !gMenuShortcutsReady || ![SolaraCoreEngine respondsToSelector:@selector(reservedShortcutsChanged)]) return;
  [SolaraCoreEngine reservedShortcutsChanged];
}

void WatchReservedShortcuts() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:@"SolaraMenuShortcutsChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
      gMenuShortcutsReady = YES;
      SendReservedShortcuts();
    }];
    [center addObserverForName:NSTextInputContextKeyboardSelectionDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *) { SendReservedShortcuts(); }];
  });
  SendReservedShortcuts();
}

NSMutableDictionary<NSString *, SolaraCoreProfile *> *Profiles() {
  static NSMutableDictionary *profiles = [NSMutableDictionary dictionary];
  return profiles;
}

NSMutableDictionary<NSString *, NSMutableArray *> *ProfileWaiters() {
  static NSMutableDictionary *waiters = [NSMutableDictionary dictionary];
  return waiters;
}

NSMutableSet<NSString *> *DeletedProfiles() {
  static NSMutableSet *deleted = [NSMutableSet set];
  return deleted;
}

NSMutableSet<NSString *> *ScheduledProfileDeletions() {
  static NSMutableSet *scheduled = [NSMutableSet set];
  return scheduled;
}

NSMutableSet<NSString *> *ReleasedPrivateNames() {
  static NSMutableSet *released = [NSMutableSet set];
  return released;
}

NSMutableDictionary<NSString *, void (^)(SolaraCoreProfile *)> *DeletionsAfterLoad() {
  static NSMutableDictionary *deletions = [NSMutableDictionary dictionary];
  return deletions;
}

NSString *DirectoryName(NSString *name) {
  if (!name.length) return @"Default";
  if ([name isEqualToString:@"Default"] || [name hasPrefix:@"Profile "]) return nil;
  return [@"Profile " stringByAppendingString:name];
}

NSDictionary *DeletionLocation(NSString *profile) {
  if (!gDataDirectory.length || !profile || [profile isEqualToString:@"."] || [profile isEqualToString:@".."] ||
      [profile containsString:@"/"] || [profile containsString:@"\\"] ||
      [profile rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound ||
      [profile hasPrefix:@"incognito:"]) return nil;
  NSFileManager *files = NSFileManager.defaultManager;
  NSDictionary *initial = [files attributesOfItemAtPath:gDataDirectory error:nil];
  if (![initial[NSFileType] isEqual:NSFileTypeDirectory]) return nil;
  NSString *root = gDataDirectory.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSDictionary *rootAttributes = [files attributesOfItemAtPath:root error:nil];
  if (![rootAttributes[NSFileType] isEqual:NSFileTypeDirectory] || !rootAttributes[NSFileSystemNumber] || !rootAttributes[NSFileSystemFileNumber] ||
      ![initial[NSFileSystemNumber] isEqual:rootAttributes[NSFileSystemNumber]] ||
      ![initial[NSFileSystemFileNumber] isEqual:rootAttributes[NSFileSystemFileNumber]]) return nil;
  NSString *name = profile.length ? [@"Profile " stringByAppendingString:profile] : @"Default";
  NSString *path = [root stringByAppendingPathComponent:name];
  NSError *error = nil;
  NSDictionary *attributes = [files attributesOfItemAtPath:path error:&error];
  if (attributes && (![attributes[NSFileType] isEqual:NSFileTypeDirectory] || ![[files contentsOfDirectoryAtPath:root error:nil] containsObject:name])) return nil;
  if (!attributes && (![error.domain isEqual:NSCocoaErrorDomain] || (error.code != NSFileNoSuchFileError && error.code != NSFileReadNoSuchFileError))) return nil;
  NSString *resolved = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
  if (![resolved.stringByDeletingLastPathComponent isEqualToString:root] || ![resolved.lastPathComponent isEqualToString:name]) return nil;
  return @{
    @"root": root, @"path": resolved, @"rootDevice": rootAttributes[NSFileSystemNumber], @"rootInode": rootAttributes[NSFileSystemFileNumber],
    @"targetDevice": attributes[NSFileSystemNumber] ?: NSNull.null, @"targetInode": attributes[NSFileSystemFileNumber] ?: NSNull.null,
  };
}

NSString *InstalledDataDirectory() {
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"com.hill.solara.unbundled";
  return [[support stringByAppendingPathComponent:bundleId] stringByAppendingPathComponent:@"Chromium"];
}

bool IsDevBuild() {
  return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"ACDevBuild"] isEqual:@"YES"];
}

bool IsTeamSigned() {
  if (IsDevBuild()) return false;
  SecCodeRef code = nullptr;
  if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess) return false;
  CFDictionaryRef info = nullptr;
  OSStatus status = SecCodeCopySigningInformation((SecStaticCodeRef)code, kSecCSSigningInformation, &info);
  CFRelease(code);
  if (status != errSecSuccess || !info) return false;
  bool team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier) != nullptr;
  CFRelease(info);
  return team;
}

bool ChromeUsesRealKeychain() {
  static const bool real = [] {
    const char *scratch = getenv("SOLARA_DATA_DIR");
    return !(scratch && *scratch) && IsTeamSigned();
  }();
  return real;
}

}

@interface SolaraCoreBootstrapDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, readonly) NSMutableArray<NSURL *> *urls;
@end

static void TryEarlyLittleWindow();

@implementation SolaraCoreBootstrapDelegate
- (instancetype)init {
  if ((self = [super init])) _urls = [NSMutableArray array];
  return self;
}
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  [_urls addObjectsFromArray:urls];
  TryEarlyLittleWindow();
}
@end

namespace {
SolaraCoreBootstrapDelegate *gBootstrap;
bool gScratchDataDir = false;
bool gAppKitWillFinish = false;
bool gAppKitDidFinish = false;
NSArray<NSURL *> *gPendingLaunchURLs;
NSArray<NSURL *> *gLaunchLinks;
NSArray<NSURL *> *gEarlyLittleLinks;
bool gLinksHandled = false;
bool gJSStarted = false;
void (^gEventHandler)(NSString *, NSDictionary *);
void (^gChromeUIHandler)(NSString *, NSDictionary *);
void (^gExtensionsEventHandler)(NSString *, NSDictionary *);
NSMutableDictionary<NSString *, NSDictionary *> *gInstallPrompts = [NSMutableDictionary dictionary];
}

static bool LaunchTabSwitchedOff(NSString *dir) {
  if (const char *env = getenv("SOLARA_SWITCHES")) {
    NSNumber *said = nil;
    for (NSString *part in [@(env) componentsSeparatedByString:@","]) {
      NSArray<NSString *> *pair = [part componentsSeparatedByString:@"="];
      if (pair.count != 2) continue;
      NSString *name = [pair[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      NSString *value = [pair[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (![name isEqualToString:@"launchTab"]) continue;
      if ([@[ @"off", @"0", @"false" ] containsObject:value]) said = @NO;
      else if ([@[ @"on", @"1", @"true" ] containsObject:value]) said = @YES;
    }
    if (said) return !said.boolValue;
  }
  NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"switches-cache.json"]];
  NSDictionary *cache = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSDictionary *switches = [cache isKindOfClass:NSDictionary.class] && [cache[@"switches"] isKindOfClass:NSDictionary.class] ? cache[@"switches"] : nil;
  return [switches[@"launchTab"] isEqual:@NO];
}

static NSString *AppDataDirectory() {
  NSString *dir = gScratchDataDir ? [gDataDirectory stringByDeletingLastPathComponent] : nil;
  if (dir) return dir;
  NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
  return [support URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"Solara"].path;
}

static BOOL gSafeMode = NO;

static NSDictionary *SavedSession(NSString *dir) {
  if (gSafeMode) return nil;
  NSData *data = dir ? [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"session.json"]] : nil;
  NSDictionary *session = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [session isKindOfClass:NSDictionary.class] ? session : nil;
}

static void ParkLaunchLinks(NSArray<NSURL *> *links, NSString *dir, NSDictionary *session) {
  NSString *linkProfile = [session[@"linkProfile"] isKindOfClass:NSString.class] ? session[@"linkProfile"] : nil;
  if (!links.count || !linkProfile || LaunchTabSwitchedOff(dir)) return;
  NSMutableArray<NSString *> *urls = [NSMutableArray array];
  for (NSURL *link in links)
    if (!link.isFileURL && link.absoluteString.length) [urls addObject:link.absoluteString];
  [SolaraCoreWebView startLinkTabs:urls profile:linkProfile];
}

static bool OutsideLinksForwarded() {
  static const bool forwarded = [NSProcessInfo.processInfo.environment[@"SOLARA_BACKGROUND"] isEqualToString:@"1"] &&
                                ![NSProcessInfo.processInfo.environment[@"SOLARA_ACCEPT_EXTERNAL_URLS"] isEqualToString:@"1"];
  return forwarded;
}

static void LinksArrived(NSArray<NSURL *> *urls) {
  if (gLinksHandled || !urls.count || OutsideLinksForwarded()) return;
  gLinksHandled = true;
  gEarlyLittleLinks = [urls copy];
  if (!gJSStarted) {
    gLaunchLinks = [urls copy];
    return TryEarlyLittleWindow();
  }
  NSString *dir = AppDataDirectory();
  ParkLaunchLinks(urls, dir, SavedSession(dir));
  TryEarlyLittleWindow();
}

static std::string FeatureEntryName(const std::string &entry) {
  const size_t start = !entry.empty() && entry[0] == '*' ? 1 : 0;
  const size_t end = entry.find_first_of("<:", start);
  return entry.substr(start, end == std::string::npos ? std::string::npos : end - start);
}

static std::vector<std::string> MergeFeatureLists(const std::vector<const char *> &args) {
  std::vector<std::string> switches, positional;
  std::vector<std::pair<bool, std::string>> entries;
  bool terminated = false;
  for (size_t i = 1; i < args.size(); i++) {
    const char *arg = args[i];
    if (terminated || !strcmp(arg, "--")) {
      terminated = true;
      positional.push_back(arg);
      continue;
    }
    const bool enable = !strncmp(arg, "--enable-features=", 18);
    if (!enable && strncmp(arg, "--disable-features=", 19)) {
      switches.push_back(arg);
      continue;
    }
    std::string list(arg + (enable ? 18 : 19));
    for (size_t from = 0; from <= list.size();) {
      size_t comma = list.find(',', from);
      if (comma == std::string::npos) comma = list.size();
      if (comma > from) entries.emplace_back(enable, list.substr(from, comma - from));
      from = comma + 1;
    }
  }
  std::set<std::string> decided;
  std::string enabled, disabled;
  for (auto entry = entries.rbegin(); entry != entries.rend(); ++entry) {
    if (!decided.insert(FeatureEntryName(entry->second)).second) continue;
    std::string &list = entry->first ? enabled : disabled;
    list = list.empty() ? entry->second : entry->second + "," + list;
  }
  if (!enabled.empty()) switches.push_back("--enable-features=" + enabled);
  if (!disabled.empty()) switches.push_back("--disable-features=" + disabled);
  switches.insert(switches.end(), positional.begin(), positional.end());
  return switches;
}

static void ReportLoweredWindowOcclusion() {
  void (^report)(NSWindow *) = ^(NSWindow *window) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidChangeOcclusionStateNotification object:window];
    });
  };
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  for (NSNotificationName name in @[ NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification ])
    [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { report(note.object); }];
}

static bool TestBuild() {
  static const bool testBuild = [] {
    const char *scratch = getenv("SOLARA_DATA_DIR");
    return IsDevBuild() || (scratch && *scratch && !IsTeamSigned());
  }();
  return testBuild;
}

static const char *TestSwitch(const char *name) { return TestBuild() ? getenv(name) : nullptr; }

static void StartLaunchTab() {
  gJSStarted = true;
  NSString *dir = AppDataDirectory();
  NSDictionary *session = SavedSession(dir);
  NSArray<NSURL *> *links = gLaunchLinks;
  gLaunchLinks = nil;
  ParkLaunchLinks(links, dir, session);
  if (TestSwitch("SOLARA_TEST_EARLY_LINK_AFTER_JS")) TryEarlyLittleWindow();
  NSDictionary *hint = session[@"launchTab"];
  if (![hint isKindOfClass:NSDictionary.class]) return;
  NSString *key = hint[@"id"], *url = hint[@"url"], *profile = hint[@"profile"];
  if (![key isKindOfClass:NSString.class] || ![url isKindOfClass:NSString.class] || ![profile isKindOfClass:NSString.class]) return;
  [SolaraCoreWebView startLaunchTab:key url:url profile:profile];
  if (SolaraCoreTab *tab = SolaraCoreTabParking.launchTab) [SolaraCoreEarlyWindow attachPage:tab key:key];
}

static bool gLaunchedHidden;
static bool gEarlyWindowPending;
static bool gLaunchedForDocuments;

static bool OnboardingPending(NSString *dir) {
  NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"onboarding.json"]];
  NSDictionary *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![saved isKindOfClass:NSDictionary.class]) return false;
  const bool completed = [saved[@"completedAt"] isKindOfClass:NSNumber.class] && [saved[@"completedAt"] doubleValue] > 0;
  return !completed && [saved[@"startedAt"] isKindOfClass:NSNumber.class];
}

static void TryEarlyWindow() {
  if (SolaraCoreEarlyWindow.switchedOff) return;
  NSString *dir = AppDataDirectory();
  if (gLaunchedHidden || gLaunchedForDocuments || NSApp.isHidden || gBootstrap.urls.count || LaunchTabSwitchedOff(dir) || OnboardingPending(dir)) return;
  NSDictionary *session = SavedSession(dir);
  NSDictionary *hint = session[@"launchTab"];
  NSString *focused = session[@"focusedWindowId"];
  if (![hint isKindOfClass:NSDictionary.class] || ![focused isKindOfClass:NSString.class]) return;
  NSString *key = hint[@"id"], *url = hint[@"url"], *profile = hint[@"profile"];
  if (![key isKindOfClass:NSString.class] || ![url isKindOfClass:NSString.class] || ![profile isKindOfClass:NSString.class]) return;
  NSDictionary *window = nil;
  for (NSDictionary *w in [session[@"windows"] isKindOfClass:NSArray.class] ? session[@"windows"] : @[])
    if ([w isKindOfClass:NSDictionary.class] && [w[@"id"] isEqual:focused]) window = w;
  if (!window || [window[@"incognito"] boolValue] || window[@"kind"] || ![window[@"frame"] isKindOfClass:NSArray.class]) return;
  if (![window[@"tabIds"] isKindOfClass:NSArray.class] || ![window[@"tabIds"] containsObject:key]) return;
  for (NSDictionary *split in [session[@"splits"] isKindOfClass:NSArray.class] ? session[@"splits"] : @[])
    if ([split isKindOfClass:NSDictionary.class] && [split[@"tabIds"] isKindOfClass:NSArray.class] && [split[@"tabIds"] containsObject:key]) return;
  NSDictionary *backdrop = [session[@"launchBackdrop"] isKindOfClass:NSDictionary.class] ? session[@"launchBackdrop"] : nil;
  const bool dark = [[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua ]]
      isEqualToString:NSAppearanceNameDarkAqua];
  if (!backdrop || ![backdrop[@"dark"] isKindOfClass:NSNumber.class] || [backdrop[@"dark"] boolValue] != dark) return;
  if (![SolaraCoreEarlyWindow canShowWindow:focused session:session]) return;
  SolaraCoreProfile *loaded = solaracore_host::LoadedProfile(profile);
  if (!loaded) return;
  const char *spare = getenv("SOLARA_LAUNCH_SPARE_RENDERER");
  if (!(spare && !strcmp(spare, "off")) && [loaded respondsToSelector:@selector(warmSpareRenderer)]) [loaded warmSpareRenderer];
  const char *windowFirst = getenv("SOLARA_EARLY_WINDOW_FIRST");
  if (windowFirst && !strcmp(windowFirst, "off")) {
    [SolaraCoreWebView startLaunchTab:key url:url profile:profile];
    if (![SolaraCoreEarlyWindow showWindow:focused frame:window[@"frame"] key:key profile:profile backdrop:backdrop]) return;
  } else {
    const BOOL shown = [SolaraCoreEarlyWindow showWindow:focused frame:window[@"frame"] key:key profile:profile backdrop:backdrop];
    [SolaraCoreWebView startLaunchTab:key url:url profile:profile];
    if (!shown) return;
  }
  if (SolaraCoreTab *tab = SolaraCoreTabParking.launchTab) [SolaraCoreEarlyWindow attachPage:tab key:key];
}

static NSArray<NSNumber *> *LittleSolaraFrame(id size) {
  const NSPoint mouse = NSEvent.mouseLocation;
  NSScreen *screen = nil;
  for (NSScreen *each in NSScreen.screens)
    if (NSMouseInRect(mouse, each.frame, NO)) {
      screen = each;
      break;
    }
  screen = screen ?: NSScreen.mainScreen;
  if (!screen) return nil;
  const NSRect visible = screen.visibleFrame;
  double width = 900, height = 640;
  if ([size isKindOfClass:NSArray.class] && [size count] == 2 && [size[0] isKindOfClass:NSNumber.class] && [size[1] isKindOfClass:NSNumber.class]) {
    width = [size[0] doubleValue];
    height = [size[1] doubleValue];
  }
  width = MIN(MAX(width, 420), NSWidth(visible));
  height = MIN(MAX(height, 300), NSHeight(visible));
  const double lift = MIN(NSHeight(visible) * 0.05, (NSHeight(visible) - height) / 2);
  return @[ @(round(NSMidX(visible) - width / 2)), @(round(NSMidY(visible) - height / 2 + lift)), @(round(width)), @(round(height)) ];
}

static bool EarlyLittleWindowOff() {
  const char *env = getenv("SOLARA_EARLY_LINK_WINDOW");
  return env && (!strcmp(env, "off") || !strcmp(env, "0") || !strcmp(env, "false"));
}

static bool gEarlyLittleTried;
static NSString *gEarlyLittleOutcome = @"notTried";

static void SkipEarlyLittle(NSString *reason) { gEarlyLittleOutcome = reason; }

static bool HiddenByTheUser() {
  if (!NSApp.isHidden) return false;
  return !(solaracore_host::TestHooksAllowed() && NSApp.activationPolicy == NSApplicationActivationPolicyProhibited);
}

static void TryEarlyLittleWindow() {
  if (gEarlyLittleTried || !gStarted) return;
  if (!gJSStarted && TestSwitch("SOLARA_TEST_EARLY_LINK_AFTER_JS")) return SkipEarlyLittle(@"waitingForJS");
  if (SolaraCoreTabParking.linkTabsRouted) return SkipEarlyLittle(@"jsRoutedFirst");
  NSArray<NSURL *> *links = gBootstrap ? gBootstrap.urls : gEarlyLittleLinks;
  if (links.count != 1) return SkipEarlyLittle(@"links");
  gEarlyLittleTried = true;
  if (EarlyLittleWindowOff() || SolaraCoreEarlyWindow.switchedOff || OutsideLinksForwarded()) return SkipEarlyLittle(@"switchedOff");
  NSURL *link = links.firstObject;
  NSString *scheme = link.scheme.lowercaseString;
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return SkipEarlyLittle(@"scheme");
  NSString *dir = AppDataDirectory();
  if (gLaunchedHidden || HiddenByTheUser()) return SkipEarlyLittle(@"hidden");
  if (LaunchTabSwitchedOff(dir) || OnboardingPending(dir)) return SkipEarlyLittle(@"launchTabOrOnboarding");
  NSDictionary *session = SavedSession(dir);
  NSDictionary *settings = [session[@"settings"] isKindOfClass:NSDictionary.class] ? session[@"settings"] : @{};
  if ([settings[@"openLinksInLittleSolara"] isEqual:@NO] && !TestSwitch("SOLARA_TEST_EARLY_LINK_IGNORE_SETTING")) return SkipEarlyLittle(@"setting");
  NSString *profile = SolaraCoreTabParking.linkProfile ?: ([session[@"linkProfile"] isKindOfClass:NSString.class] ? session[@"linkProfile"] : nil);
  NSDictionary *backdrop = [session[@"launchBackdrop"] isKindOfClass:NSDictionary.class] ? session[@"launchBackdrop"] : nil;
  const bool dark = [[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua ]]
      isEqualToString:NSAppearanceNameDarkAqua];
  if (!profile || !backdrop || ![backdrop[@"dark"] isKindOfClass:NSNumber.class] || [backdrop[@"dark"] boolValue] != dark) return SkipEarlyLittle(@"backdrop");
  if (!solaracore_host::LoadedProfile(profile)) return SkipEarlyLittle(@"profile");
  NSArray<NSNumber *> *frame = LittleSolaraFrame(settings[@"littleSolaraSize"]);
  if (!frame) return SkipEarlyLittle(@"frame");
  NSString *url = link.absoluteString;
  [SolaraCoreWebView startLinkTabs:@[ url ] profile:profile];
  if (![SolaraCoreTabParking.linkProfile isEqualToString:profile] || ![SolaraCoreTabParking.soleLinkURL isEqualToString:url]) return SkipEarlyLittle(@"tab");
  SolaraCoreTab *tab = SolaraCoreTabParking.firstLinkTab;
  NSString *mark = tab ? [SolaraCoreTabParking linkMarkForTab:tab] : nil;
  NSString *focused = [session[@"focusedWindowId"] isKindOfClass:NSString.class] ? session[@"focusedWindowId"] : nil;
  if (!mark) return SkipEarlyLittle(@"tab");
  if (TestSwitch("SOLARA_TEST_EARLY_LINK_FAILS")) return SkipEarlyLittle(@"showFailed");
  if (![SolaraCoreEarlyWindow showLittleWindowForLink:tab mark:mark url:url frame:frame profile:profile backdrop:backdrop like:focused])
    return SkipEarlyLittle(@"showFailed");
  gEarlyLittleOutcome = gJSStarted ? @"shownAfterJS" : @"shown";
}

static void StartEarlyWindow() {
  @autoreleasepool {
    TryEarlyWindow();
    TryEarlyLittleWindow();
    [SolaraCoreEarlyWindow discardPrefetch];
  }
}

@interface SolaraCoreHostEngineDelegate : NSObject <SolaraCoreEngineDelegate>
@end

@implementation SolaraCoreHostEngineDelegate

- (void)engineDidStart {
  NSLog(@"[solaracore] engine started (Chromium %@)", SolaraCoreEngine.sharedEngine.chromiumVersion);
  gStarted = YES;
  WatchReservedShortcuts();
  solaracore_host::InstallActivationGuardsLate();
  if (gScratchDataDir && solaracore_host::Background())
    solaracore_host::InstallTestCrashGuard([gDataDirectory stringByDeletingLastPathComponent]);
  SolaraCoreEngine *engine = SolaraCoreEngine.sharedEngine;
  if (SolaraCoreProfile *profile = solaracore_host::PersonalIfLoaded(engine)) Profiles()[@""] = profile;
  solaracore_host::LoadContentBlocker(@"");
  [SolaraCoreWebView installSwitchPrewarm];
  [SolaraCoreWebView installOutgoingFocusSnapshots];
  [SolaraCoreServices watchDownloads:@""];

  NSBundle *bundle = [NSBundle bundleForClass:SolaraCoreHostEngineDelegate.class];
  NSString *path = [bundle pathForResource:@"page_script" ofType:@"js"];
  NSString *script = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
  if (script && [engine respondsToSelector:@selector(setPageScript:)]) engine.pageScript = script;
  if (gAppKitDidFinish) StartEarlyWindow();
  else gEarlyWindowPending = true;

  CFRunLoopObserverRef idle = CFRunLoopObserverCreateWithHandler(
      nullptr, kCFRunLoopBeforeWaiting, false, 0, ^(CFRunLoopObserverRef observer, CFRunLoopActivity) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        __block id started = [NSNotificationCenter.defaultCenter
            addObserverForName:@"RCTJavaScriptWillStartExecutingNotification"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *) {
                      [NSNotificationCenter.defaultCenter removeObserver:started];
                      started = nil;
                      dispatch_async(dispatch_get_main_queue(), ^{ StartLaunchTab(); });
                    }];
        [self launchApp];
      });
  CFRunLoopAddObserver(CFRunLoopGetMain(), idle, kCFRunLoopCommonModes);
  CFRelease(idle);
}

- (void)launchApp {
  NSArray<NSURL *> *launchURLs = gBootstrap.urls.copy;
  LinksArrived(launchURLs);
  gAppDelegate = gMakeDelegate();
  const SEL openURLs = @selector(application:openURLs:);
  if (Method open = class_getInstanceMethod([gAppDelegate class], openURLs)) {
    IMP original = method_getImplementation(open);
    method_setImplementation(open, imp_implementationWithBlock(^(id delegate, NSApplication *app, NSArray<NSURL *> *urls) {
      LinksArrived(urls);
      ((void (*)(id, SEL, NSApplication *, NSArray<NSURL *> *))original)(delegate, openURLs, app, urls);
    }));
  }
  NSApp.delegate = gAppDelegate;
  gBootstrap = nil;
  NSNotification *note = [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp];
  if (gAppKitWillFinish && [gAppDelegate respondsToSelector:@selector(applicationWillFinishLaunching:)])
    [gAppDelegate applicationWillFinishLaunching:note];
  if (!gAppKitDidFinish) {
    NSLog(@"[solaracore] app delegate %@ set before AppKit finished launching", NSStringFromClass([gAppDelegate class]));
    gPendingLaunchURLs = launchURLs;
    return;
  }
  note = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp];
  if ([gAppDelegate respondsToSelector:@selector(applicationDidFinishLaunching:)])
    [gAppDelegate applicationDidFinishLaunching:note];
  NSLog(@"[solaracore] app delegate %@ launched", NSStringFromClass([gAppDelegate class]));
  if (launchURLs.count && [gAppDelegate respondsToSelector:@selector(application:openURLs:)])
    [gAppDelegate application:NSApp openURLs:launchURLs];
}

- (void)engineWillShutDown {
  gStarted = NO;
}

- (void)engineQuitCancelled {
  NSLog(@"[solaracore] quit cancelled");
  [NSNotificationCenter.defaultCenter postNotificationName:@"SolaraCoreQuitCancelled" object:nil];
}

- (void)engine:(SolaraCoreEngine *)engine permissionRequest:(NSDictionary *)request tab:(SolaraCoreTab *)tab {
  if (tab && solaracore_host::AskPermissionInPopupWindow(tab, request)) return;
  NSMutableDictionary *payload = [request mutableCopy];
  payload[@"browserId"] = @(tab ? solaracore_host::BrowserId(tab) : 0);
  if (gEventHandler) gEventHandler(@"permission", payload);
}

- (void)engine:(SolaraCoreEngine *)engine deviceChooser:(NSDictionary *)chooser tab:(SolaraCoreTab *)tab {
  NSMutableDictionary *payload = [chooser mutableCopy];
  payload[@"browserId"] = @(tab ? solaracore_host::BrowserId(tab) : 0);
  if (auto handler = SolaraCoreHost.chromeUIHandler) handler(@"deviceChooser", payload);
  else if ([payload[@"open"] boolValue] && [SolaraCoreEngine respondsToSelector:@selector(cancelDeviceChooser:)])
    [SolaraCoreEngine cancelDeviceChooser:[payload[@"id"] intValue]];
}

- (void)engine:(SolaraCoreEngine *)engine castDialog:(NSDictionary *)dialog tab:(SolaraCoreTab *)tab {
  NSMutableDictionary *payload = [dialog mutableCopy];
  payload[@"browserId"] = @(tab ? solaracore_host::BrowserId(tab) : 0);
  if (gChromeUIHandler) gChromeUIHandler(@"castDialog", payload);
  else if ([payload[@"open"] boolValue] && [SolaraCoreEngine respondsToSelector:@selector(closeCastDialog:)])
    [SolaraCoreEngine closeCastDialog:[payload[@"id"] intValue]];
}

- (void)engine:(SolaraCoreEngine *)engine castRoutes:(NSArray *)routes profile:(SolaraCoreProfile *)profile {
  if (!gChromeUIHandler) return;
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  if (profile.offTheRecord)
    for (NSString *name in solaracore_host::LoadedProfileNames())
      if (solaracore_host::LoadedProfile(name) == profile) [names addObject:name];
  if (!names.count) [names addObject:solaracore_host::ProfileName(profile)];
  for (NSString *name in names) gChromeUIHandler(@"castRoutes", @{@"profile" : name, @"routes" : routes ?: @[]});
}

- (void)engine:(SolaraCoreEngine *)engine extensionSidePanel:(NSDictionary *)panel tab:(SolaraCoreTab *)tab {
  NSMutableDictionary *payload = [panel mutableCopy];
  payload[@"browserId"] = @(tab ? solaracore_host::BrowserId(tab) : 0);
  if (gChromeUIHandler) gChromeUIHandler(@"sidePanel", payload);
}

- (BOOL)engine:(SolaraCoreEngine *)engine extensionActionPopup:(NSDictionary *)popup tab:(SolaraCoreTab *)tab {
  if (!gChromeUIHandler || !tab) {
    NSLog(@"[solaracore] action.openPopup for %@: %@", popup[@"extensionId"], tab ? @"the app isn't listening yet" : @"no tab");
    return NO;
  }
  NSMutableDictionary *payload = [popup mutableCopy];
  payload[@"browserId"] = @(solaracore_host::BrowserId(tab));
  gChromeUIHandler(@"actionPopup", payload);
  return YES;
}

- (BOOL)engineIsReservedKey:(NSString *)key unshiftedKey:(NSString *)unshiftedKey modifiers:(NSEventModifierFlags)modifiers {
  return solaracore_host::IsReservedBinding(key, unshiftedKey, modifiers);
}

- (BOOL)engineIsReservedKeyEvent:(NSEvent *)event {
  return event.type == NSEventTypeKeyDown && solaracore_host::IsReservedKeyEvent(event);
}

- (BOOL)engine:(SolaraCoreEngine *)engine extensionActionShortcut:(NSDictionary *)shortcut tab:(SolaraCoreTab *)tab {
  if (!gChromeUIHandler || !tab) return NO;
  NSMutableDictionary *payload = [shortcut mutableCopy];
  payload[@"browserId"] = @(solaracore_host::BrowserId(tab));
  gChromeUIHandler(@"actionShortcut", payload);
  return YES;
}

- (void)engine:(SolaraCoreEngine *)engine extensionInstallPrompt:(NSDictionary *)prompt tab:(SolaraCoreTab *)tab {
  NSMutableDictionary *payload = [prompt mutableCopy];
  payload[@"browserId"] = @(tab ? solaracore_host::BrowserId(tab) : 0);
  if ([prompt[@"profile"] isKindOfClass:NSString.class]) payload[@"profile"] = solaracore_host::ProfileNameOfDirectory(prompt[@"profile"]);
  gInstallPrompts[payload[@"requestId"] ?: @""] = payload;
  if (gExtensionsEventHandler) gExtensionsEventHandler(@"installPrompt", payload);
}

- (void)engine:(SolaraCoreEngine *)engine permissionRequestDismissed:(NSString *)requestId {
  solaracore_host::DropPopupWindowPermission(requestId ?: @"");
  if (gEventHandler) gEventHandler(@"permissionDismissed", @{@"id" : requestId ?: @""});
}

- (SolaraCoreWindow *)engineWindowForNewBrowserOfProfile:(SolaraCoreProfile *)profile type:(NSString *)type {
  if (![type isEqualToString:@"normal"] && ![type isEqualToString:@"popup"]) return nil;
  if ([type isEqualToString:@"normal"] && !profile.offTheRecord)
    if (SolaraCoreWindowController *made = [SolaraCoreWindowController chromeMadeWindowForProfile:profile]) return made.coreWindow;
  return [SolaraCoreWindowController strayWindowForProfile:profile].coreWindow;
}

@end

@implementation SolaraCoreHost

+ (BOOL)safeMode { return gSafeMode; }
+ (void)setSafeMode:(BOOL)safeMode { gSafeMode = safeMode; }

+ (void)prepareEnvironment {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (TestBuild()) {
      unsetenv("SOLARA_RELEASE_LAUNCH");
      return;
    }
    const std::set<std::string> runtime = {
        "SOLARA_ACCEPT_EXTERNAL_URLS", "SOLARA_BACKGROUND", "SOLARA_CLI_BIN_DIR",
        "SOLARA_CLI_HOME", "SOLARA_DATA_DIR", "SOLARA_PREWARM",
    };
    std::vector<std::string> remove;
    for (char **entry = *_NSGetEnviron(); entry && *entry; ++entry) {
      std::string name(*entry, strcspn(*entry, "="));
      if ((name.compare(0, 7, "SOLARA_") == 0 && !runtime.count(name)) || name == "AC_BENCH_OMNIBOX" || name == "SSLKEYLOGFILE" || name == "IS_TESTING")
        remove.push_back(name);
    }
    for (const std::string &name : remove) {
      if (unsetenv(name.c_str()) != 0) {
        fprintf(stderr, "[solaracore] could not clear test environment override\n");
        exit(1);
      }
    }
    if (setenv("SOLARA_RELEASE_LAUNCH", "1", 1) != 0) {
      fprintf(stderr, "[solaracore] could not mark a release launch\n");
      exit(1);
    }
    if (!remove.empty()) fprintf(stderr, "[solaracore] ignored test environment overrides\n");
  });
}

+ (BOOL)testBuild {
  return TestBuild();
}

+ (BOOL)chromeUsesRealKeychain {
  return ChromeUsesRealKeychain();
}

+ (NSString *)installedDataDirectory {
  return InstalledDataDirectory();
}

+ (int)runWithArgc:(int)argc argv:(char **)argv delegate:(id<NSApplicationDelegate> (^)(void))makeDelegate {
  [self prepareEnvironment];
  const char *dataDir = getenv("SOLARA_DATA_DIR");
  gScratchDataDir = dataDir && *dataDir;
#if DEBUG
  if (!gScratchDataDir) {
    fprintf(stderr, "[solaracore] set SOLARA_DATA_DIR to a scratch directory\n");
    return 1;
  }
#endif
  gMakeDelegate = [makeDelegate copy];
  NSString *scratch = gScratchDataDir ? @(dataDir) : nil;
  if (scratch && !scratch.absolutePath)
    scratch = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:scratch];
  gDataDirectory = scratch ? [scratch.stringByStandardizingPath stringByAppendingPathComponent:@"Chromium"] : InstalledDataDirectory();
  NSError *dirError;
  if (![NSFileManager.defaultManager createDirectoryAtPath:gDataDirectory withIntermediateDirectories:YES attributes:nil error:&dirError]) {
    fprintf(stderr, "[solaracore] can't use the data dir %s: %s\n", gDataDirectory.fileSystemRepresentation,
            dirError.localizedDescription.UTF8String ?: "");
    return 1;
  }
  solaracore_host::InstallTestCrashGuard(scratch && solaracore_host::Background() ? scratch.stringByStandardizingPath : nil);
  solaracore_host::InstallActivationGuardsEarly();
  if (!gSafeMode) solaracore_host::PrepareContentBlocker();
  Method finishLaunching = class_getInstanceMethod(NSApplication.class, @selector(finishLaunching));
  IMP appKitFinishLaunching = method_getImplementation(finishLaunching);
  method_setImplementation(finishLaunching, imp_implementationWithBlock(^(NSApplication *app) {
    if (!gAppDelegate && !app.delegate) {
      gBootstrap = [SolaraCoreBootstrapDelegate new];
      app.delegate = gBootstrap;
    }
    ((void (*)(id, SEL))appKitFinishLaunching)(app, @selector(finishLaunching));
  }));
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillFinishLaunchingNotification
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification *) {
                                                gAppKitWillFinish = true;
                                              }];
  if (getenv("SOLARA_TRACE_VISIBILITY")) {
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeOcclusionStateNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                  NSWindow *w = note.object;
                                                  id chrome = [w respondsToSelector:NSSelectorFromString(@"isOccluded")]
                                                                  ? [w valueForKey:@"occluded"] : nil;
                                                  NSLog(@"[solaracore-vis] window %ld occlusion macOSVisible=%d chromeOccluded=%@ fromChecker=%d",
                                                        (long)w.windowNumber, (w.occlusionState & NSWindowOcclusionStateVisible) != 0,
                                                        chrome, note.userInfo.count > 0);
                                                }];
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[ NSWorkspaceScreensDidSleepNotification, NSWorkspaceScreensDidWakeNotification,
                                        NSWorkspaceSessionDidResignActiveNotification, NSWorkspaceSessionDidBecomeActiveNotification ])
      [workspace addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSLog(@"[solaracore-vis] workspace %@", note.name);
      }];
  }
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification *) {
                                                gAppKitDidFinish = true;
                                                NSAppleEventDescriptor *event = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
                                                if (event.eventID == kAEOpenApplication &&
                                                    [event paramDescriptorForKeyword:keyAEPropData].enumCodeValue == keyAELaunchedAsLogInItem)
                                                  gLaunchedHidden = true;
                                                if (event && !(event.eventClass == kCoreEventClass && event.eventID == kAEOpenApplication))
                                                  gLaunchedForDocuments = true;
                                                if (gEarlyWindowPending) {
                                                  gEarlyWindowPending = false;
                                                  StartEarlyWindow();
                                                }
                                                if (!gPendingLaunchURLs.count) return;
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                  NSArray<NSURL *> *urls = gPendingLaunchURLs;
                                                  gPendingLaunchURLs = nil;
                                                  if (urls.count && [gAppDelegate respondsToSelector:@selector(application:openURLs:)])
                                                    [gAppDelegate application:NSApp openURLs:urls];
                                                });
                                              }];

  const char *tabFreezing = getenv("SOLARA_TAB_FREEZING");
  const bool freezeLeastRecentTabs = !(tabFreezing && !strcmp(tabFreezing, "off"));
  const char *slowTabThaw = getenv("SOLARA_SLOW_TAB_THAW");
  const bool thawFrozenTabsRarely = !(slowTabThaw && !strcmp(slowTabThaw, "off"));
  const char *mainFrameThrottle = getenv("SOLARA_MAIN_FRAME_THROTTLE");
  const bool throttleMainFramesTo60Hz = !(mainFrameThrottle && !strcmp(mainFrameThrottle, "off"));
  const char *scrollFullRate = getenv("SOLARA_SCROLL_FULL_RATE");
  const bool fullRateAfterInput = !(scrollFullRate && !strcmp(scrollFullRate, "off"));
  const char *walletPasses = getenv("SOLARA_WALLET_PASSES");
  const bool biometricsCheckPerTab = walletPasses && !strcmp(walletPasses, "on");
  std::vector<std::string> extra = {
      "--user-data-dir=" + std::string(gDataDirectory.UTF8String),
      "--enable-smooth-scrolling",
      "--disable-stack-profiler",
      std::string("--disable-features=MacAppCodeSignClone,DevToolsAcceptDebuggingConnections") +
          (biometricsCheckPerTab ? "" : ",AutofillAiWalletPrivatePasses") +
          (freezeLeastRecentTabs ? "" : ",InfiniteTabsFreezing"),
      std::string("--enable-features=WebContentsDiscard,BrowserInitiatedAutomaticPictureInPicture,ImprovedStartupBestEffortDelay:StartupDelayStopOnLoadingTimedOut/true,"
                  "CPUMeasurementInFreezingPolicy:freezing_visible_protection_time/0s") +
          (freezeLeastRecentTabs ? (thawFrozenTabsRarely ? ",InfiniteTabsFreezing:solara_unconnected_unfreeze_interval/600s" : ",InfiniteTabsFreezing") : "") + (throttleMainFramesTo60Hz ? (fullRateAfterInput ? ",ThrottleMainFrameTo60Hz,UrgentMainFrameForInput" : ",ThrottleMainFrameTo60Hz:solara_full_rate_after_input/0s,UrgentMainFrameForInput") : ""),
      "--profile-directory=Default",
      "--js-flags=--no-memory-reducer",
  };
  if (gSafeMode) extra.push_back("--disable-extensions");
  const bool mockKeychain = !ChromeUsesRealKeychain();
  if (mockKeychain) extra.push_back("--use-mock-keychain");
  if (!TestBuild()) extra.push_back("--solara-apply-profile-gate");
  solaracore_host::PrepareStartup(gDataDirectory, extra);
  @autoreleasepool {
    [SolaraCoreEarlyWindow setDataDirectory:AppDataDirectory()];
    if (!gSafeMode) [SolaraCoreEarlyWindow prefetchForSession:SavedSession(AppDataDirectory()) ?: @{}];
  }
  if (getenv("SOLARA_BACKGROUND") && !getenv("SOLARA_ALLOW_OCCLUSION")) {
    extra.push_back("--disable-backgrounding-occluded-windows");
    if (Method occluded = class_getInstanceMethod(NSWindow.class, NSSelectorFromString(@"isOccluded")))
      method_setImplementation(occluded, imp_implementationWithBlock(^BOOL(id) { return NO; }));
  }
  if (getenv("SOLARA_BACKGROUND") && getenv("SOLARA_ALLOW_OCCLUSION")) ReportLoweredWindowOcclusion();
  if (getenv("SOLARA_BACKGROUND") && !getenv("SOLARA_ALLOW_AUDIO")) extra.push_back("--mute-audio");
  if (getenv("SOLARA_BACKGROUND")) extra.push_back("--use-fake-device-for-media-stream");
  if (getenv("SOLARA_BACKGROUND")) extra.push_back("--disable-modal-animations");
  auto autoAccepts = [](const char *sw) {
    return getenv("SOLARA_BACKGROUND") && (!strncmp(sw, "--use-fake-ui-for-media-stream", 30) ||
                                              !strncmp(sw, "--auto-accept-camera-and-microphone-capture", 43));
  };
  if (const char *port = getenv("SOLARA_REMOTE_DEBUGGING_PORT"); port && TestBuild()) {
    extra.push_back(std::string("--remote-debugging-port=") + port);
    extra.push_back("--remote-allow-origins=*");
  }
  if (const char *switches = getenv("SOLARA_CHROMIUM_SWITCHES"); switches && TestBuild()) {
    NSString *all = [@" " stringByAppendingString:@(switches)];
    for (NSString *item in [all componentsSeparatedByString:@" --"]) {
      NSString *sw = [item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      std::string full = std::string("--") + sw.UTF8String;
      if (sw.length && !autoAccepts(full.c_str())) extra.push_back(full);
    }
  }
  std::vector<const char *> args = {argc > 0 && argv[0] ? argv[0] : "Solara"};
  for (const std::string &s : extra) args.push_back(s.c_str());
  for (int i = 1; TestBuild() && i < argc; i++) {
    const char *arg = argv[i];
    if (!arg) break;
    const bool cocoaDefault = arg[0] == '-' && arg[1] != '-' && isalpha((unsigned char)arg[1]) &&
                              strncmp(arg, "-psn_", 5) != 0 && i + 1 < argc;
    if (cocoaDefault) {
      i++;
      continue;
    }
    if (autoAccepts(arg)) continue;
    args.push_back(arg);
  }
  static std::vector<std::string> merged;
  merged = MergeFeatureLists(args);
  args.resize(1);
  for (const std::string &s : merged) args.push_back(s.c_str());
  static SolaraCoreHostEngineDelegate *engineDelegate = [SolaraCoreHostEngineDelegate new];
  return [SolaraCoreEngine runWithArgc:(int)args.size() argv:args.data() delegate:engineDelegate];
}

+ (void (^)(NSString *, NSDictionary *))eventHandler {
  return gEventHandler;
}

+ (void)setEventHandler:(void (^)(NSString *, NSDictionary *))handler {
  gEventHandler = [handler copy];
}

+ (void (^)(NSString *, NSDictionary *))extensionsEventHandler {
  return gExtensionsEventHandler;
}

+ (void)setExtensionsEventHandler:(void (^)(NSString *, NSDictionary *))handler {
  gExtensionsEventHandler = [handler copy];
  if (handler)
    for (NSDictionary *prompt in gInstallPrompts.allValues) handler(@"installPrompt", prompt);
}

+ (void)resolveExtensionInstallPrompt:(NSString *)requestId accepted:(BOOL)accepted {
  [gInstallPrompts removeObjectForKey:requestId ?: @""];
  if ([SolaraCoreEngine respondsToSelector:@selector(resolveExtensionInstallPrompt:accepted:)])
    [SolaraCoreEngine resolveExtensionInstallPrompt:requestId accepted:accepted];
}

+ (void)beginTracing:(void (^)(BOOL))completion {
  if (![SolaraCoreEngine respondsToSelector:@selector(beginTracing:)]) return completion(NO);
  [SolaraCoreEngine beginTracing:completion];
}

+ (void)endTracing:(BOOL)keep completion:(void (^)(NSString *))completion {
  if (![SolaraCoreEngine respondsToSelector:@selector(endTracing:completion:)]) return completion(nil);
  [SolaraCoreEngine endTracing:keep completion:completion];
}

+ (BOOL)isTracing {
  return [SolaraCoreEngine respondsToSelector:@selector(isTracing)] && SolaraCoreEngine.isTracing;
}

+ (void)deleteProfileData:(NSString *)profile deletionAllowed:(BOOL (^)(void))deletionAllowed completion:(void (^)(NSArray<NSString *> *))completion {
  if (gSafeMode) return completion(@[ @"safe mode" ]);
  if ([ScheduledProfileDeletions() containsObject:profile]) return completion(@[ @"Chromium deletion pending restart" ]);
  NSDictionary *location = DeletionLocation(profile);
  if (!location) {
    NSLog(@"[solaracore] refusing profile data deletion for invalid path: %@", profile);
    return completion(@[ @"refused profile path" ]);
  }
  SolaraCoreEngine *engine = SolaraCoreEngine.sharedEngine;
  SolaraCoreProfile *p = solaracore_host::LoadedProfile(profile);
  if (!profile.length || ![engine respondsToSelector:@selector(deleteProfile:completion:)]) return completion(@[ @"data" ]);
  [DeletedProfiles() addObject:profile];
  void (^remove)(SolaraCoreProfile *) = ^(SolaraCoreProfile *loaded) {
    NSDictionary *current = DeletionLocation(profile);
    if (![current isEqualToDictionary:location]) {
      [DeletedProfiles() removeObject:profile];
      NSLog(@"[solaracore] refusing profile data deletion for invalid path: %@", profile);
      return completion(@[ @"refused profile path" ]);
    }
    if (!deletionAllowed()) {
      [DeletedProfiles() removeObject:profile];
      return completion(@[ @"live profile filesystem identity" ]);
    }
    NSString *path = location[@"path"];
    if (!loaded) {
      [NSFileManager.defaultManager removeItemAtPath:path error:nil];
      NSError *inspectionError = nil;
      NSDictionary *remaining = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&inspectionError];
      BOOL removed = !remaining && [inspectionError.domain isEqual:NSCocoaErrorDomain] &&
          (inspectionError.code == NSFileNoSuchFileError || inspectionError.code == NSFileReadNoSuchFileError);
      if (removed) [DeletedProfiles() removeObject:profile];
      return completion(removed ? @[] : @[ @"files" ]);
    }
    if (![loaded.path.stringByStandardizingPath.stringByResolvingSymlinksInPath isEqualToString:path]) {
      [DeletedProfiles() removeObject:profile];
      NSLog(@"[solaracore] refusing profile deletion for unexpected loaded path: %@", loaded.path);
      return completion(@[ @"refused profile path" ]);
    }
    [ScheduledProfileDeletions() addObject:profile];
    [engine deleteProfile:loaded completion:^(BOOL deleted) {
      if (deleted) {
        [Profiles() removeObjectForKey:profile];
        completion(@[ @"Chromium deletion pending restart" ]);
      } else {
        [ScheduledProfileDeletions() removeObject:profile];
        [DeletedProfiles() removeObject:profile];
        completion(@[ @"data" ]);
      }
    }];
  };
  if (!p && ProfileWaiters()[profile]) {
    DeletionsAfterLoad()[profile] = [remove copy];
    return;
  }
  remove(p);
}

+ (void)releaseProfile:(NSString *)profile {
  SolaraCoreEngine *engine = SolaraCoreEngine.sharedEngine;
  SolaraCoreProfile *p = solaracore_host::LoadedProfile(profile);
  if (solaracore_host::IsIncognito(profile)) {
    if (profile) [ReleasedPrivateNames() addObject:profile];
    [Profiles() removeObjectForKey:profile];
    NSArray *waiting = ProfileWaiters()[profile];
    [ProfileWaiters() removeObjectForKey:profile];
    for (void (^waiter)(SolaraCoreProfile *) in waiting) waiter(nil);
    solaracore_host::ForgetPrivateNavigationDownloads(profile);
    if ([Profiles().allValues containsObject:p]) return;
  }
  if (p && [engine respondsToSelector:@selector(releaseProfile:)]) [engine releaseProfile:p];
}

+ (int)chromeTabId:(int)browserId {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  return [tab respondsToSelector:@selector(tabId)] ? tab.tabId : -1;
}

+ (BOOL)stopCapture:(int)browserId {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  return [tab respondsToSelector:@selector(stopCapture)] && [tab stopCapture];
}

+ (BOOL)showAutofillSuggestions:(int)browserId passwords:(BOOL)passwords {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  return [tab respondsToSelector:@selector(showAutofillSuggestions:)] && [tab showAutofillSuggestions:passwords];
}

+ (void (^)(NSString *, NSDictionary *))chromeUIHandler {
  return gChromeUIHandler;
}

+ (void)setChromeUIHandler:(void (^)(NSString *, NSDictionary *))handler {
  gChromeUIHandler = [handler copy];
}

+ (void)deviceChooser:(int)chooserId select:(int)index {
  if ([SolaraCoreEngine respondsToSelector:@selector(selectDevice:index:)]) [SolaraCoreEngine selectDevice:chooserId index:index];
}

+ (void)deviceChooser:(int)chooserId action:(NSString *)action {
  if ([action isEqualToString:@"cancel"] && [SolaraCoreEngine respondsToSelector:@selector(cancelDeviceChooser:)])
    [SolaraCoreEngine cancelDeviceChooser:chooserId];
  else if ([action isEqualToString:@"refresh"] && [SolaraCoreEngine respondsToSelector:@selector(refreshDeviceChooser:)])
    [SolaraCoreEngine refreshDeviceChooser:chooserId];
  else if ([action isEqualToString:@"settings"] && [SolaraCoreEngine respondsToSelector:@selector(openDeviceChooserSettings:)])
    [SolaraCoreEngine openDeviceChooserSettings:chooserId];
}

+ (NSArray<NSDictionary *> *)testExternalLaunches {
  return SolaraCoreEngine.testExternalLaunches ?: @[];
}

+ (BOOL)devShowBluetoothChooser:(int)browserId unauthorized:(BOOL)unauthorized {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  return [tab respondsToSelector:@selector(devShowBluetoothChooser:)] && [tab devShowBluetoothChooser:unauthorized];
}

+ (NSArray<NSDictionary *> *)testChooserEvents {
  return [SolaraCoreEngine respondsToSelector:@selector(testChooserEvents)] ? SolaraCoreEngine.testChooserEvents ?: @[] : @[];
}

+ (BOOL)shareTabInstead:(int)capturerBrowserId target:(int)targetBrowserId {
  SolaraCoreTab *capturer = solaracore_host::TabWithBrowserId(capturerBrowserId);
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(targetBrowserId);
  return capturer && [tab respondsToSelector:@selector(shareThisTabInsteadFor:)] && [tab shareThisTabInsteadFor:capturer];
}

+ (BOOL)showCastDialog:(int)browserId {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  return [tab respondsToSelector:@selector(showCastDialog)] && [tab showCastDialog];
}

+ (void)castDialog:(int)dialogId start:(NSString *)sink mode:(int)mode {
  if ([SolaraCoreEngine respondsToSelector:@selector(startCasting:sink:mode:)]) [SolaraCoreEngine startCasting:dialogId sink:sink mode:mode];
}

+ (void)castDialog:(int)dialogId stop:(NSString *)route {
  if ([SolaraCoreEngine respondsToSelector:@selector(stopCasting:route:)]) [SolaraCoreEngine stopCasting:dialogId route:route];
}

+ (void)closeCastDialog:(int)dialogId {
  if ([SolaraCoreEngine respondsToSelector:@selector(closeCastDialog:)]) [SolaraCoreEngine closeCastDialog:dialogId];
}

+ (void)watchCastRoutes:(NSString *)profileName {
  solaracore_host::WithProfile(profileName, ^(SolaraCoreProfile *profile) {
    if ([profile respondsToSelector:@selector(watchCastRoutes)]) [profile watchCastRoutes];
  });
}

+ (void)terminateCastRoute:(NSString *)route {
  if ([SolaraCoreEngine respondsToSelector:@selector(terminateCastRoute:)]) [SolaraCoreEngine terminateCastRoute:route];
}

+ (void)resolveExternalApp:(NSString *)requestId open:(BOOL)open remember:(BOOL)remember {
  if ([SolaraCoreEngine respondsToSelector:@selector(resolveExternalApp:open:remember:)])
    [SolaraCoreEngine resolveExternalApp:requestId open:open remember:remember];
}

+ (NSDictionary *)actionStates:(int)browserId extensions:(NSArray<NSString *> *)ids {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  return [tab respondsToSelector:@selector(actionStatesForExtensions:)] ? [tab actionStatesForExtensions:ids] ?: @{} : @{};
}

+ (NSString *)sidePanelURL:(int)browserId extension:(NSString *)extensionId {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  return [tab respondsToSelector:@selector(sidePanelURLForExtension:)] ? [tab sidePanelURLForExtension:extensionId] : nil;
}

+ (void)resolvePermission:(NSString *)requestId result:(NSString *)result remember:(BOOL)remember {
  SolaraCoreEngine *engine = SolaraCoreEngine.sharedEngine;
  if ([engine respondsToSelector:@selector(resolvePermission:result:remember:)])
    [engine resolvePermission:requestId result:result remember:remember];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)displayMediaSources {
  NSMutableArray *sources = [NSMutableArray array];
  NSUInteger index = 0;
  for (NSScreen *screen in NSScreen.screens) {
    NSNumber *display = screen.deviceDescription[@"NSScreenNumber"];
    index++;
    [sources addObject:@{
      @"id" : [NSString stringWithFormat:@"screen:%u:0", display.unsignedIntValue],
      @"kind" : @"screen",
      @"name" : screen.localizedName ?: [NSString stringWithFormat:@"Screen %lu", (unsigned long)index],
      @"width" : @(screen.frame.size.width),
      @"height" : @(screen.frame.size.height),
    }];
  }
  NSArray *windows = CFBridgingRelease(
      CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  const pid_t me = getpid();
  for (NSDictionary *w in windows) {
    if ([w[(id)kCGWindowLayer] intValue] != 0 || [w[(id)kCGWindowOwnerPID] intValue] == me) continue;
    NSDictionary *bounds = w[(id)kCGWindowBounds];
    const CGFloat width = [bounds[@"Width"] doubleValue], height = [bounds[@"Height"] doubleValue];
    if (width < 50 || height < 50) continue;
    NSString *app = w[(id)kCGWindowOwnerName] ?: @"";
    NSString *title = w[(id)kCGWindowName];
    [sources addObject:@{
      @"id" : [NSString stringWithFormat:@"window:%u:0", [w[(id)kCGWindowNumber] unsignedIntValue]],
      @"kind" : @"window",
      @"name" : title.length ? title : app,
      @"app" : app,
      @"pid" : w[(id)kCGWindowOwnerPID] ?: @0,
      @"width" : @(width),
      @"height" : @(height),
    }];
  }
  return sources;
}

+ (BOOL)isStarted {
  return gStarted;
}

+ (NSString *)dataDirectory {
  return gDataDirectory ?: @"";
}

+ (NSDictionary<NSString *, id> *)engineInfo {
  SolaraCoreEngine *engine = SolaraCoreEngine.sharedEngine;
  NSInteger chromeWindows = 0;
  for (SolaraCoreWindowController *c in SolaraCoreWindowController.all) chromeWindows += c.coreWindow ? 1 : 0;
  NSMutableDictionary<NSString *, id> *info = [@{
    @"pid" : @(NSProcessInfo.processInfo.processIdentifier),
    @"dataDirectory" : gDataDirectory ?: @"",
    @"engine" : @"solaracore",
    @"chromiumVersion" : engine.chromiumVersion ?: @"",
    @"liveBrowsers" : @0,
    @"popupWindows" : @(solaracore_host::PopupWindowCount()),
    @"popupOrigins" : solaracore_host::PopupOrigins(),
    @"chromeWindows" : @(chromeWindows),
    @"keepAlive" : engine.keepAliveState ?: @"",
    @"lastUsedProfile" : engine.defaultProfile.name ?: @"",
  } mutableCopy];
  if (TestBuild()) {
    info[@"earlyLinkWindow"] = gEarlyLittleOutcome;
    info[@"unclaimedEarlyLinkWindows"] = @(SolaraCoreEarlyWindow.unclaimedLittleWindows);
  }
  return info;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)chromeWindows {
  NSMutableArray *list = [NSMutableArray array];
  for (SolaraCoreWindowController *c in SolaraCoreWindowController.all) {
    NSWindow *w = c.coreWindow.window;
    if (!w) continue;
    SolaraCoreProfile *active = c.coreWindow.activeProfile;
    [list addObject:@{
      @"profile" : solaracore_host::ProfileName(active),
      @"window" : @(w.windowNumber),
      @"frame" : NSStringFromRect(w.frame),
      @"alpha" : @(w.alphaValue),
      @"key" : @(w.isKeyWindow),
      @"canBecomeKey" : @(w.canBecomeKeyWindow),
      @"visible" : @(w.isVisible),
      @"occlusionVisible" : @((w.occlusionState & NSWindowOcclusionStateVisible) != 0),
      @"chromeOccluded" : [w respondsToSelector:NSSelectorFromString(@"isOccluded")] ? [w valueForKey:@"occluded"] : NSNull.null,
      @"parentWindow" : @(w.parentWindow.windowNumber),
      @"chromeWindows" : @1,
      @"anchorBrowserId" : @0,
      @"anyTabBrowserId" : @0,
      @"ready" : @YES,
      @"active" : @(w.isMainWindow),
      @"pageInsets" : @[ @0, @0, @0, @0 ],
      @"hosting" : @(c.root != nil),
      @"group" : @"",
      @"hasRoot" : @(c.root != nil),
      @"translucent" : @(!w.opaque),
      @"stray" : @(c.stray),
    }];
  }
  return list;
}

@end

namespace solaracore_host {

void ForgetDestroyedProfiles() {
  for (NSString *name in Profiles().allKeys)
    if (Profiles()[name].destroyed) [Profiles() removeObjectForKey:name];
}

NSArray<NSString *> *LoadedProfileNames() {
  ForgetDestroyedProfiles();
  return Profiles().allKeys;
}

NSArray<SolaraCoreProfile *> *LoadedProfiles() {
  ForgetDestroyedProfiles();
  NSMutableArray *profiles = [NSMutableArray array];
  for (SolaraCoreProfile *profile in Profiles().allValues)
    if (![profiles containsObject:profile]) [profiles addObject:profile];
  return profiles;
}

bool IsIncognito(NSString *name) {
  return [name hasPrefix:@"incognito"];
}

NSString *OriginalProfileName(NSString *name) {
  if (!IsIncognito(name)) return name ?: @"";
  NSRange at = [name rangeOfString:@"@"];
  return at.location == NSNotFound ? @"" : [name substringFromIndex:NSMaxRange(at)];
}

NSString *OriginalProfileNameOf(SolaraCoreProfile *profile) {
  if (!profile.offTheRecord) return ProfileName(profile);
  NSString *dir = profile.name;
  return [dir hasPrefix:@"Profile "] ? [dir substringFromIndex:8] : @"";
}

bool IsOffTheRecordOf(SolaraCoreProfile *profile, NSString *name) {
  return profile.offTheRecord && IsIncognito(name) &&
         [profile.name isEqualToString:DirectoryName(OriginalProfileName(name))];
}

bool IsDeletedProfile(NSString *name) {
  return [DeletedProfiles() containsObject:name ?: @""];
}

SolaraCoreProfile *LoadedProfile(NSString *name) {
  SolaraCoreProfile *profile = Profiles()[name ?: @""];
  if (!profile.destroyed) return profile;
  [Profiles() removeObjectForKey:name ?: @""];
  return nil;
}

namespace {

void WithPrivateProfile(NSString *name, void (^completion)(SolaraCoreProfile *)) {
  if ([ReleasedPrivateNames() containsObject:name]) return completion(nil);
  if (NSMutableArray *waiters = ProfileWaiters()[name]) return (void)[waiters addObject:completion];
  ProfileWaiters()[name] = [NSMutableArray arrayWithObject:completion];
  NSString *original = OriginalProfileName(name);
  WithProfile(original, ^(SolaraCoreProfile *base) {
    SolaraCoreEngine *engine = SolaraCoreEngine.sharedEngine;
    void (^answer)(SolaraCoreProfile *, NSString *) = ^(SolaraCoreProfile *otr, NSString *error) {
      NSArray *pending = ProfileWaiters()[name];
      [ProfileWaiters() removeObjectForKey:name];
      if (IsDeletedProfile(original)) {
        if (otr && ![Profiles().allValues containsObject:otr]) [engine releaseProfile:otr];
        if (pending) NSLog(@"[solaracore] no private profile for %@: its profile was deleted", name);
        for (void (^waiter)(SolaraCoreProfile *) in pending) waiter(nil);
        return;
      }
      if (!pending) {
        if (otr && ![Profiles().allValues containsObject:otr]) [engine releaseProfile:otr];
        return;
      }
      if (otr && !otr.destroyed) Profiles()[name] = otr;
      else NSLog(@"[solaracore] no private profile for %@: %@", name, error ?: @"it went");
      for (void (^waiter)(SolaraCoreProfile *) in pending) waiter(Profiles()[name]);
    };
    if (!base) return answer(nil, [NSString stringWithFormat:@"profile \"%@\" isn't loaded", original]);
    if (![engine respondsToSelector:@selector(offTheRecordProfileFor:completion:)]) return answer(nil, @"the engine is too old");
    [engine offTheRecordProfileFor:base completion:answer];
  });
}

}

void WithProfile(NSString *name, void (^completion)(SolaraCoreProfile *)) {
  name = name ?: @"";
  if ([DeletedProfiles() containsObject:name]) return completion(nil);
  if (SolaraCoreProfile *profile = LoadedProfile(name)) return completion(profile);
  SolaraCoreEngine *engine = SolaraCoreEngine.sharedEngine;
  if (!engine) return completion(nil);
  if (IsIncognito(name)) return WithPrivateProfile(name, [completion copy]);
  if (name.length == 0) {
    if (SolaraCoreProfile *personal = PersonalIfLoaded(engine)) {
      Profiles()[@""] = personal;
      return completion(personal);
    }
  }
  NSString *directory = DirectoryName(name);
  if (!directory) {
    NSLog(@"[solaracore] no profile named \"%@\": that's a Chromium folder name, not a profile", name);
    return completion(nil);
  }
  NSMutableArray *waiters = ProfileWaiters()[name];
  if (waiters) return (void)[waiters addObject:[completion copy]];
  ProfileWaiters()[name] = [NSMutableArray arrayWithObject:[completion copy]];
  [engine loadProfile:directory
           completion:^(SolaraCoreProfile *loaded) {
             NSArray *pending = ProfileWaiters()[name];
             [ProfileWaiters() removeObjectForKey:name];
             if (void (^deletion)(SolaraCoreProfile *) = DeletionsAfterLoad()[name]) {
               [DeletionsAfterLoad() removeObjectForKey:name];
               deletion(loaded);
             }
             SolaraCoreProfile *profile = [DeletedProfiles() containsObject:name] ? nil : loaded;
             if (profile) Profiles()[name] = profile;
             if (profile) solaracore_host::LoadContentBlocker(name);
             if (profile) [SolaraCoreServices watchDownloads:name];
             for (void (^waiter)(SolaraCoreProfile *) in pending) waiter(profile);
           }];
}

SolaraCoreProfile *PersonalIfLoaded(SolaraCoreEngine *engine) {
  SolaraCoreProfile *profile = engine.defaultProfile;
  return [profile.name isEqualToString:@"Default"] ? profile : nil;
}

NSString *ProfileNameOfDirectory(NSString *directory) {
  for (SolaraCoreProfile *profile in LoadedProfiles())
    if (!([profile respondsToSelector:@selector(offTheRecord)] && profile.offTheRecord) && [profile.name isEqualToString:directory])
      return ProfileName(profile);
  return [directory hasPrefix:@"Profile "] ? [directory substringFromIndex:8] : @"";
}

NSString *ProfileName(SolaraCoreProfile *profile) {
  if (!profile) return @"";
  for (NSString *name in Profiles())
    if (Profiles()[name] == profile) return name;
  NSString *dir = profile.name;
  if ([dir hasPrefix:@"Profile "]) return [dir substringFromIndex:8];
  return @"";
}

NSString *AppDisposition(NSString *chrome) {
  static NSDictionary *map = @{
    @"foreground_tab" : @"foreground",
    @"background_tab" : @"background",
    @"popup" : @"popup",
    @"window" : @"window",
    @"off_the_record" : @"incognito",
    @"current_tab" : @"current",
    @"split_view" : @"split",
    @"singleton_tab" : @"foreground",
  };
  return map[chrome] ?: @"foreground";
}

}
