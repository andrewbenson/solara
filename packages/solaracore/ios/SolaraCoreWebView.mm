#import "SolaraCoreWebView.h"
#import "ACChromeWindow.h"
#import "SolaraCoreWebViewInternal.h"
#import "SolaraCoreEarlyWindow.h"
#import "SolaraCorePictureInPicture.h"
#import "SolaraCoreServices.h"
#import "SolaraCoreTabParking.h"

#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "SolaraCoreFieldTiming.h"
#import "SolaraCoreNavigationDownloads.h"

#include <climits>
#include <cmath>

namespace {

bool TraceVisibility() {
  static const bool on = getenv("SOLARA_TRACE_VISIBILITY") != nullptr;
  return on;
}

constexpr CFTimeInterval kLeaveScreenDelay = 0.1;
constexpr CFTimeInterval kRevealBackstopSeconds = 5;
constexpr CFTimeInterval kNeighbourPagesAwakeSeconds = 10;

bool NeighbourPagesAlwaysLive() {
  static const bool on = [@(getenv("SOLARA_WARM_NEIGHBOURS") ?: "") isEqualToString:@"1"];
  return on;
}

}

@interface ACNeighbourWake : NSObject
@property(nonatomic) CFTimeInterval committedUntil;
@property(nonatomic) CFTimeInterval speculativeUntil;
@property(nonatomic, readonly) CFTimeInterval until;
@end

@implementation ACNeighbourWake
- (CFTimeInterval)until {
  return MAX(_committedUntil, _speculativeUntil);
}
@end

namespace {

NSMapTable<NSWindow *, ACNeighbourWake *> *NeighbourPagesAwake() {
  static NSMapTable *windows = [NSMapTable weakToStrongObjectsMapTable];
  return windows;
}

NSHashTable<SolaraCoreWebView *> *LiveViews() {
  static NSHashTable *views = [NSHashTable weakObjectsHashTable];
  return views;
}

#if DEBUG
NSInteger gDevKeepOnClose = 0;
NSInteger gDevFailKeptMoves = 0;
NSMutableSet<NSNumber *> *DevKeptBrowsers() {
  static NSMutableSet *ids = [NSMutableSet set];
  return ids;
}
NSMutableSet<NSNumber *> *DevFailingBrowsers() {
  static NSMutableSet *ids = [NSMutableSet set];
  return ids;
}
#endif

enum class ACPageFocus { Unknown, Page, DevTools, Elsewhere };

constexpr CFTimeInterval kFocusRestoreWindow = 1;

NSHashTable<SolaraCoreWebView *> *PendingPainting() {
  static NSHashTable *views = [NSHashTable weakObjectsHashTable];
  return views;
}
bool gPaintingScheduled = false;

void OnMain(void (^block)(void)) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

bool SamePage(NSString *a, NSString *b) {
  auto strip = [](NSString *url) {
    NSRange hash = [url rangeOfString:@"#"];
    return hash.location == NSNotFound ? url : [url substringToIndex:hash.location];
  };
  return a && b && [strip(a) isEqualToString:strip(b)];
}

bool IsRendererDebugURL(NSString *url) {
  NSURLComponents *c = [NSURLComponents componentsWithString:url];
  static NSArray *schemes = @[ @"chrome", @"solara", ((NSString *)[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"solara").lowercaseString ];
  if (![schemes containsObject:c.scheme.lowercaseString ?: @""]) return false;
  static NSSet *hosts = [NSSet setWithArray:@[
    @"badcastcrash", @"crash", @"crashdump", @"kill", @"hang", @"shorthang", @"memory-exhaust", @"memory-pressure-critical",
    @"memory-pressure-moderate", @"gpuclean", @"gpucrash", @"gpuhang", @"inducebrowsercrashforrealz",
    @"inducebrowserdcheckforrealz", @"cfi-crash", @"heap-corruption-crash"
  ]];
  return [hosts containsObject:c.host.lowercaseString ?: @""];
}

NSString *ReportedTitle(NSString *title, NSString *url, BOOL loading) {
  if (!loading || !title.length) return title ?: @"";
  NSURLComponents *c = [NSURLComponents componentsWithString:url];
  NSString *scheme = c.scheme.lowercaseString;
  if ((![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) || ![[url substringWithRange:NSMakeRange(scheme.length, MIN(3, url.length - scheme.length))] isEqualToString:@"://"])
    return title;
  NSString *shown = [url substringFromIndex:scheme.length + 3];
  if ([shown.lowercaseString hasPrefix:@"www."]) shown = [shown substringFromIndex:4];
  if ([c.path isEqualToString:@"/"] && !c.query && !c.fragment && [shown hasSuffix:@"/"]) shown = [shown substringToIndex:shown.length - 1];
  shown = [shown stringByReplacingOccurrencesOfString:@"%20" withString:@" "];
  return [title isEqualToString:shown] ? @"" : title;
}

NSString *PNGDataURL(NSImage *image) {
  CGImageRef cg = [image CGImageForProposedRect:nil context:nil hints:nil];
  if (!cg) return nil;
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
  NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return png.length ? [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]] : nil;
}

id JSONValue(NSString *json) {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
}

template <typename T>
T *Field(NSDictionary *d, NSString *key) {
  id value = d[key];
  return [value isKindOfClass:[T class]] ? value : nil;
}

NSString *Text(NSDictionary *d, NSString *key, NSUInteger max) {
  NSString *s = Field<NSString>(d, key);
  if (s.length <= max) return s;
  return [s substringToIndex:[s rangeOfComposedCharacterSequenceAtIndex:max].location];
}

bool Flag(NSDictionary *d, NSString *key) {
  return Field<NSNumber>(d, key).boolValue;
}

bool Finite(NSDictionary *d, NSString *key, double *out) {
  NSNumber *n = Field<NSNumber>(d, key);
  if (!n || !std::isfinite(n.doubleValue)) return false;
  *out = n.doubleValue;
  return true;
}

NSString *OriginOf(NSString *url) {
  NSURLComponents *c = [NSURLComponents componentsWithString:url ?: @""];
  if (!c.scheme.length || !c.host.length) return nil;
  return c.port ? [NSString stringWithFormat:@"%@://%@:%@", c.scheme, c.host, c.port] : [NSString stringWithFormat:@"%@://%@", c.scheme, c.host];
}

NSDictionary *NowPlayingState(NSDictionary *d, BOOL main) {
  NSString *state = Field<NSString>(d, @"playbackState");
  if (![@[ @"none", @"paused", @"playing" ] containsObject:state]) state = @"none";
  NSMutableArray *actions = [NSMutableArray array];
  for (id action in Field<NSArray>(d, @"actions"))
    if ([action isKindOfClass:NSString.class] && [action length] <= 64 && actions.count < 32) [actions addObject:action];
  double position = 0, duration = 0, rate = 1, timestamp = 0;
  Finite(d, @"position", &position);
  const bool hasDuration = Finite(d, @"duration", &duration) && duration >= 0;
  Finite(d, @"playbackRate", &rate);
  Finite(d, @"timestamp", &timestamp);
  return @{
    @"frame" : Text(d, @"frame", 64) ?: @"",
    @"title" : Text(d, @"title", 1024) ?: @"",
    @"artist" : Text(d, @"artist", 1024) ?: @"",
    @"album" : Text(d, @"album", 1024) ?: @"",
    @"artwork" : Text(d, @"artwork", 1 << 20) ?: NSNull.null,
    @"playbackState" : state,
    @"position" : @(MAX(position, 0)),
    @"duration" : hasDuration ? @(duration) : NSNull.null,
    @"playbackRate" : @(rate),
    @"timestamp" : @(timestamp),
    @"hasVideo" : @(Flag(d, @"hasVideo")),
    @"actions" : actions,
    @"controllable" : @(Flag(d, @"controllable")),
    @"main" : @(main),
  };
}

NSDictionary *SelectionState(NSDictionary *d) {
  NSString *text = Text(d, @"text", 4000);
  NSDictionary *rect = Field<NSDictionary>(d, @"rect");
  double x, y, width, height;
  if (!text || !Finite(rect, @"x", &x) || !Finite(rect, @"y", &y) || !Finite(rect, @"width", &width) ||
      !Finite(rect, @"height", &height))
    return nil;
  return @{@"text" : text, @"rect" : @{@"x" : @(x), @"y" : @(y), @"width" : @(width), @"height" : @(height)}};
}

NSMutableDictionary<NSNumber *, NSMutableArray *> *RecentEvents() {
  static NSMutableDictionary *events = [NSMutableDictionary dictionary];
  return events;
}

void NoteEvent(int browserId, NSString *name, NSDictionary *payload) {
#if DEBUG
  NSMutableArray *list = RecentEvents()[@(browserId)];
  if (!list) RecentEvents()[@(browserId)] = list = [NSMutableArray array];
  NSMutableDictionary *brief = [NSMutableDictionary dictionary];
  for (NSString *key in payload) {
    id value = payload[key];
    brief[key] = [value isKindOfClass:NSString.class] && [value length] > 200 ? [value substringToIndex:200] : value;
  }
  [list addObject:@{@"name" : name, @"payload" : brief, @"t" : @(round(CACurrentMediaTime() * 1000))}];
  if (list.count > 80) [list removeObjectAtIndex:0];
#endif
}

NSString *gSearchEngineName = @"Google";
BOOL gDisplayMediaPicker = NO;
NSString *gPeekModifier = @"shift";
NSString *gSplitLinkModifier = @"altShift";
static BOOL gSelectionPopover = YES;
static BOOL (^gOwnedTabStillWanted)(SolaraCoreWebView *);
static const NSEventModifierFlags kPeekKeyMask = NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagCommand | NSEventModifierFlagControl;
static NSEventModifierFlags gPeekUpKeys = 0;
static CFTimeInterval gPeekUpAt = -1;
static __weak SolaraCoreWebView *gPeekUpView;
static NSUInteger gPeekUpSeq = 0;
static NSUInteger gPeekUsedSeq = 0;
static BOOL gPeekPressedSinceUp = NO;
static const CFTimeInterval kPeekGestureLifetime = 10;
static const CFTimeInterval kPeekFallbackLifetime = 60;
static char kScriptFramesKey;

static SolaraCoreWebView *PageViewUnder(NSEvent *event) {
  NSView *content = event.window.contentView;
  NSView *root = content.superview ?: content;
  NSView *hit = root ? [root hitTest:[root convertPoint:event.locationInWindow fromView:nil]] : nil;
  for (NSView *view = hit; view; view = view.superview)
    if ([view isKindOfClass:SolaraCoreWebView.class]) return (SolaraCoreWebView *)view;
  return nil;
}

static const NSUInteger kControlPressesKept = 8;
static const NSTimeInterval kControlClickLifetime = 10;
static const NSTimeInterval kControlKeyLifetime = 2;
static const double kControlClickMatchMs = 1;

static NSMutableArray<NSDictionary *> *ControlPresses() {
  static NSMutableArray<NSDictionary *> *presses = [NSMutableArray array];
  return presses;
}

static BOOL InWebContent(NSView *view) {
  for (; view; view = view.superview)
    if ([view isKindOfClass:SolaraCoreWebView.class] || [NSStringFromClass(view.class) hasPrefix:@"RenderWidgetHostView"]) return YES;
  return NO;
}

static BOOL LandsInWebContent(NSEvent *event) {
  NSView *frame = event.window.contentView.superview ?: event.window.contentView;
  NSView *hit = [frame hitTest:event.locationInWindow];
  return !hit || InWebContent(hit);
}

static NSNumber *ControlTag(NSResponder *responder) {
  if (![responder isKindOfClass:NSView.class] || !((NSView *)responder).window || InWebContent((NSView *)responder)) return nil;
  if (![responder respondsToSelector:NSSelectorFromString(@"reactTag")]) return nil;
  id tag = [responder valueForKey:@"reactTag"];
  return [tag isKindOfClass:NSNumber.class] && [tag integerValue] > 0 ? tag : nil;
}

static NSNumber *ControlKeyTarget(NSEvent *event) {
  const NSEventModifierFlags chord = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
  if (event.isARepeat || (event.keyCode != 49 && event.keyCode != 36 && event.keyCode != 76) || (event.modifierFlags & chord)) return nil;
  return ControlTag(event.window.firstResponder);
}

static void RecordControlPress(NSTimeInterval at, NSInteger window, NSNumber *target) {
  NSMutableArray<NSDictionary *> *presses = ControlPresses();
  NSMutableDictionary *press = [@{@"at" : @(at), @"window" : @(window)} mutableCopy];
  if (target) press[@"target"] = target;
  [presses addObject:press];
  if (presses.count > kControlPressesKept) [presses removeObjectAtIndex:0];
}

static BOOL (*gReactPerformPress)(id, SEL);

static void InstallAccessibilityPressRecord() {
  Class reactView = NSClassFromString(@"RCTView");
  Method method = reactView ? class_getInstanceMethod(reactView, @selector(accessibilityPerformPress)) : nil;
  if (!method || gReactPerformPress) return;
  IMP recording = imp_implementationWithBlock(^BOOL(NSView *view) {
    if (NSNumber *target = ControlTag(view)) RecordControlPress(NSProcessInfo.processInfo.systemUptime, view.window.windowNumber, target);
    return gReactPerformPress(view, @selector(accessibilityPerformPress));
  });
  gReactPerformPress = (BOOL (*)(id, SEL))method_setImplementation(method, recording);
}

static void InstallControlPressMonitor() {
  static id monitor;
  if (monitor) return;
  InstallAccessibilityPressRecord();
  monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskKeyDown
                                                  handler:^NSEvent *(NSEvent *event) {
                                                    if (!event.window) return event;
                                                    if (event.type == NSEventTypeKeyDown) {
                                                      if (NSNumber *target = ControlKeyTarget(event)) RecordControlPress(event.timestamp, event.windowNumber, target);
                                                    } else if (!LandsInWebContent(event)) {
                                                      RecordControlPress(event.timestamp, event.windowNumber, nil);
                                                    }
                                                    return event;
                                                  }];
}

static NSTimeInterval TakeControlPress(double clickMs, NSInteger target, NSWindow *window) {
  if (!window || (!(clickMs > 0) && target <= 0)) return 0;
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  NSMutableArray<NSDictionary *> *presses = ControlPresses();
  for (NSDictionary *press in presses) {
    const NSTimeInterval at = [press[@"at"] doubleValue];
    if ([press[@"window"] integerValue] != window.windowNumber) continue;
    const BOOL matches = clickMs > 0 ? !press[@"target"] && fabs(at * 1000 - clickMs) <= kControlClickMatchMs && now - at <= kControlClickLifetime
                                     : [press[@"target"] integerValue] == target && now - at <= kControlKeyLifetime;
    if (!matches) continue;
    [presses removeObject:press];
    return at;
  }
  return 0;
}

static void InstallPeekMonitor() {
  static id monitor;
  if (monitor) return;
  monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
                                                  handler:^NSEvent *(NSEvent *event) {
                                                    if (event.type == NSEventTypeLeftMouseDown) {
                                                      gPeekPressedSinceUp = YES;
                                                      return event;
                                                    }
                                                    gPeekUpKeys = event.modifierFlags & kPeekKeyMask;
                                                    gPeekUpAt = CACurrentMediaTime();
                                                    gPeekUpView = PageViewUnder(event);
                                                    gPeekPressedSinceUp = NO;
                                                    gPeekUpSeq++;
                                                    return event;
                                                  }];
}

static BOOL SignedForDistribution() {
  static const BOOL distribution = [] {
    SecCodeRef code = nullptr;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess) return YES;
    SecRequirementRef requirement = nullptr;
    OSStatus made = SecRequirementCreateWithString(CFSTR("anchor apple generic and "
                                                         "(certificate leaf[field.1.2.840.113635.100.6.1.9] exists or "
                                                         "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
                                                         "certificate leaf[field.1.2.840.113635.100.6.1.13] exists)"),
                                                   kSecCSDefaultFlags, &requirement);
    const BOOL signedFor = made != errSecSuccess || SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    CFRelease(code);
    return signedFor;
  }();
  return distribution;
}

static BOOL PeekTestHooks() {
  static const BOOL on = [] {
    const char *dir = getenv("SOLARA_DATA_DIR");
    return solaracore_host::Background() && dir && *dir && !SignedForDistribution();
  }();
  return on;
}

static BOOL PeekTracing() {
#if DEBUG
  return YES;
#else
  return PeekTestHooks();
#endif
}

static NSString *PeekKeyNames(NSEventModifierFlags flags) {
  NSMutableString *names = [NSMutableString string];
  if (flags & NSEventModifierFlagControl) [names appendString:@"⌃"];
  if (flags & NSEventModifierFlagOption) [names appendString:@"⌥"];
  if (flags & NSEventModifierFlagShift) [names appendString:@"⇧"];
  if (flags & NSEventModifierFlagCommand) [names appendString:@"⌘"];
  return names;
}

BOOL TracingPictureInPicture() {
  static const BOOL tracing = getenv("SOLARA_TRACE_PIP") != nullptr;
  return tracing;
}

NSString *SelectionLabel(NSString *text) {
  NSArray *words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString *collapsed = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
      componentsJoinedByString:@" "];
  if (collapsed.length <= 50) return collapsed;
  NSRange space = [collapsed rangeOfString:@" " options:NSBackwardsSearch range:NSMakeRange(0, 50)];
  NSUInteger end = space.location != NSNotFound && space.location > 25 ? space.location : 50;
  end = [collapsed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, end)].length;
  return [[collapsed substringToIndex:end] stringByAppendingString:@"…"];
}

constexpr int kMenuSeparator = 3;

int MenuItemType(NSDictionary *item) {
  if (NSNumber *type = Field<NSNumber>(item, @"type")) return type.intValue;
  return Flag(item, @"separator") ? kMenuSeparator : 0;
}

NSString *MenuTitle(NSString *label);

NSArray *DescribeMenu(NSArray *items) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *item in items) {
    if (![item isKindOfClass:NSDictionary.class]) continue;
    static const int kCefTypes[] = {1, 2, 3, 4, 0, 5, 5};
    const int type = MenuItemType(item);
    NSMutableDictionary *described = [@{
      @"id" : Field<NSNumber>(item, @"id") ?: @0,
      @"label" : MenuTitle(Field<NSString>(item, @"label") ?: @""),
      @"type" : @(type >= 0 && type < 7 ? kCefTypes[type] : 0),
      @"enabled" : @(Flag(item, @"enabled")),
      @"visible" : @(Field<NSNumber>(item, @"visible") ? Flag(item, @"visible") : YES),
    } mutableCopy];
    if (NSArray *submenu = Field<NSArray>(item, @"submenu")) described[@"submenu"] = DescribeMenu(submenu);
    [out addObject:described];
  }
  return out;
}

NSString *MenuTitle(NSString *label) {
  NSMutableString *title = [NSMutableString stringWithCapacity:label.length];
  for (NSUInteger i = 0; i < label.length; i++) {
    const unichar c = [label characterAtIndex:i];
    if (c != '&') {
      [title appendFormat:@"%C", c];
    } else if (i + 1 < label.length && [label characterAtIndex:i + 1] == '&') {
      [title appendString:@"&"];
      i++;
    }
  }
  return title;
}

NSDictionary *FindMenuItem(NSArray *items, NSString *label) {
  for (NSUInteger i = 0; i < items.count; i++) {
    NSDictionary *item = items[i];
    if (![item isKindOfClass:NSDictionary.class]) continue;
    if ([MenuTitle(Field<NSString>(item, @"label") ?: @"") isEqualToString:label]) {
      NSNumber *command = Field<NSNumber>(item, @"id");
      return command ? @{@"command" : command, @"path" : @[ @(i) ]} : nil;
    }
    if (NSDictionary *found = FindMenuItem(Field<NSArray>(item, @"submenu"), label))
      return @{@"command" : found[@"command"], @"path" : [@[ @(i) ] arrayByAddingObjectsFromArray:found[@"path"]]};
  }
  return nil;
}

NSString *JSONString(id value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value ?: NSNull.null options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
}

static void PeekTrace(NSDictionary *entry) {
  const char *dir = getenv("SOLARA_DATA_DIR");
  if (!PeekTracing() || !dir) return;
  NSString *path = [[NSString stringWithUTF8String:dir] stringByAppendingPathComponent:@"peek.log"];
  NSData *line = [[NSString stringWithFormat:@"%@ %@\n", NSDate.date, JSONString(entry)] dataUsingEncoding:NSUTF8StringEncoding];
  NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!file) return (void)[line writeToFile:path atomically:NO];
  if ([file seekToEndOfFile] < (2 << 20)) [file writeData:line];
  [file closeFile];
}

static NSString *SplitLinkModifier() {
  return [gSplitLinkModifier isEqualToString:@"alt"] && ![gPeekModifier isEqualToString:@"alt"] ? @"alt" : @"altShift";
}

static NSString *PeekConfigJSON() {
  return JSONString(@{@"modifier" : gPeekModifier, @"split" : SplitLinkModifier(), @"trace" : @(PeekTracing())});
}

const char kPageReportsKey = 0;

const char kDropTypesKey = 0;

void AcceptDrops(NSView *root, BOOL accept) {
  if (!root) return;
  NSArray<NSPasteboardType> *held = objc_getAssociatedObject(root, &kDropTypesKey);
  if (accept && held) {
    objc_setAssociatedObject(root, &kDropTypesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [root registerForDraggedTypes:held];
  } else if (!accept && !held && root.registeredDraggedTypes.count) {
    objc_setAssociatedObject(root, &kDropTypesKey, root.registeredDraggedTypes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [root unregisterDraggedTypes];
  }
  for (NSView *sub in root.subviews) AcceptDrops(sub, accept);
}

}

@interface SolaraCoreWebView () <SolaraCoreTabDelegate>
@end

static NSDictionary *DisplayMediaAudioOffer(NSDictionary *message) {
  if (!Flag(message, @"audio")) return nil;
  NSDictionary *support = [SolaraCoreEngine respondsToSelector:@selector(desktopCaptureAudio)] ? SolaraCoreEngine.desktopCaptureAudio : @{};
  const bool system = Flag(support, @"system"), application = Flag(support, @"application");
  NSString *preference = Text(message, @"windowAudio", 16);
  NSString *window = nil;
  if ([preference isEqualToString:@"window"])
    window = application ? @"application" : system ? @"system" : nil;
  else if ([preference isEqualToString:@"system"])
    window = system ? @"system" : nil;
  return @{@"tab" : @YES, @"screen" : @(system && Flag(message, @"systemAudio")), @"window" : window ?: NSNull.null};
}

static NSString *DisplayMediaAudioFor(NSDictionary *offer, NSString *sourceId) {
  if ([sourceId hasPrefix:@"screen:"]) return Flag(offer, @"screen") ? @"system" : nil;
  if ([sourceId hasPrefix:@"window:"]) return Field<NSString>(offer, @"window");
  if ([sourceId hasPrefix:@"web-contents-media-stream://"]) return Flag(offer, @"tab") ? @"tab" : nil;
  return nil;
}

static void AnswerHello(SolaraCoreTab *tab, NSString *profile, NSString *frameId, BOOL main, NSString *verifiedOrigin) {
  const BOOL verified = verifiedOrigin.length && ![verifiedOrigin isEqualToString:@"null"];
  NSString *origin = main && verified ? verifiedOrigin : OriginOf(tab.url);
  __weak SolaraCoreTab *weakTab = tab;
  void (^answer)(BOOL) = ^(BOOL blockAutoplay) {
    SolaraCoreTab *to = weakTab;
    if (!frameId.length || !to) return;
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    if (blockAutoplay) config[@"blockAutoplay"] = @YES;
    if (gDisplayMediaPicker && [SolaraCoreEngine respondsToSelector:@selector(allowDesktopCapture:tab:frame:origin:audio:)])
      config[@"displayMediaPicker"] = @YES;
    if (main && ACFieldTimingEnabled()) config[@"fieldTiming"] = @YES;
    if (main) config[@"selectionPopover"] = @(gSelectionPopover);
    config[@"peek"] = gPeekModifier;
    config[@"split"] = SplitLinkModifier();
    if (PeekTracing()) config[@"peekTrace"] = @YES;
    if (TracingPictureInPicture()) config[@"pipTrace"] = @YES;
    static const BOOL broadThemeObserver = [@(getenv("SOLARA_THEME_OBSERVER") ?: "") isEqualToString:@"broad"];
    if (broadThemeObserver) config[@"broadThemeObserver"] = @YES;
    [to callFrame:frameId kind:@"config" json:JSONString(config)];
  };
  if (origin && [origin hasPrefix:@"http"])
    [SolaraCoreServices siteSettings:profile ?: @"" origin:origin completion:^(NSDictionary *settings) {
      NSDictionary *autoplay = [settings[@"autoplay"] isKindOfClass:NSDictionary.class] ? settings[@"autoplay"] : nil;
      answer([autoplay[@"value"] isEqual:@"block"]);
    }];
  else
    answer(NO);
}

@interface SolaraCoreLaunchTabHolder : NSObject <SolaraCoreParkedPageHolder>
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *profile;
@property (nonatomic, readonly) BOOL closedByChrome;
@property (nonatomic, readonly) BOOL closedWithWindow;
- (void)replayTo:(SolaraCoreWebView *)view tab:(SolaraCoreTab *)tab;
@end

@implementation SolaraCoreLaunchTabHolder {
  NSMutableArray<NSInvocation *> *_calls;
  NSMutableArray<NSNumber *> *_callOrder;
  NSMutableDictionary<NSString *, NSDictionary *> *_pageState;
  NSUInteger _pageStateBytes;
  NSUInteger _pageStateOrder;
}

static const NSUInteger kHeldPageStateEntries = 64;
static const NSUInteger kHeldPageStateBytes = 16 * 1024;
static const NSUInteger kHeldPageStateTotalBytes = 256 * 1024;

- (void)forgetHeldPageStateWhere:(BOOL (^)(NSDictionary *held))matches {
  for (NSString *key in _pageState.allKeys)
    if (matches(_pageState[key])) {
      _pageStateBytes -= [_pageState[key][@"bytes"] unsignedIntegerValue];
      [_pageState removeObjectForKey:key];
    }
}

- (void)holdPageMessage:(NSString *)kind json:(NSString *)json frame:(NSString *)frame main:(BOOL)main origin:(NSString *)origin {
  if (![@[ @"hello", @"theme", @"media", @"nowPlaying" ] containsObject:kind ?: @""]) return;
  if ([kind isEqualToString:@"hello"]) {
    NSString *from = frame ?: @"";
    [self forgetHeldPageStateWhere:^BOOL(NSDictionary *held) { return main || [held[@"frame"] isEqualToString:from]; }];
  }
  const NSUInteger bytes = [json lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  if (bytes > kHeldPageStateBytes) return;
  NSString *key = [NSString stringWithFormat:@"%@|%@", frame ?: @"", kind];
  if ([kind isEqualToString:@"media"]) {
    id value = JSONValue(json);
    NSString *mediaFrame = [value isKindOfClass:NSDictionary.class] ? Text(value, @"frame", 64) : nil;
    if (!mediaFrame) return;
    key = [key stringByAppendingFormat:@"|%@", mediaFrame];
  }
  if ([kind isEqualToString:@"nowPlaying"] && [json isEqualToString:@"null"]) {
    _pageStateBytes -= [_pageState[key][@"bytes"] unsignedIntegerValue];
    [_pageState removeObjectForKey:key];
    return;
  }
  const NSUInteger replaced = [_pageState[key][@"bytes"] unsignedIntegerValue];
  if (!_pageState[key] && _pageState.count >= kHeldPageStateEntries) return;
  if (_pageStateBytes - replaced + bytes > kHeldPageStateTotalBytes) return;
  if (!_pageState) _pageState = [NSMutableDictionary dictionary];
  _pageStateBytes = _pageStateBytes - replaced + bytes;
  _pageState[key] = @{
    @"kind" : kind,
    @"json" : json ?: @"null",
    @"frame" : frame ?: @"",
    @"main" : @(main),
    @"origin" : origin ?: @"",
    @"bytes" : @(bytes),
    @"order" : @(++_pageStateOrder)
  };
}

static BOOL HeldSelector(SEL selector) {
  struct objc_method_description d = protocol_getMethodDescription(@protocol(SolaraCoreTabDelegate), selector, NO, YES);
  if (!d.name || ![SolaraCoreWebView instancesRespondToSelector:selector]) return NO;
  NSMethodSignature *signature = [SolaraCoreWebView instanceMethodSignatureForSelector:selector];
  return signature && strcmp(signature.methodReturnType, @encode(void)) == 0;
}

- (BOOL)respondsToSelector:(SEL)selector {
  return [super respondsToSelector:selector] || HeldSelector(selector);
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
  return HeldSelector(selector) ? [SolaraCoreWebView instanceMethodSignatureForSelector:selector] : [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
  if (!HeldSelector(invocation.selector) || invocation.methodSignature.numberOfArguments < 3) return [super forwardInvocation:invocation];
  if (invocation.selector == @selector(tab:didReceivePageMessage:json:frame:main:) ||
      invocation.selector == @selector(tab:didReceivePageMessage:json:frame:main:origin:)) {
    __unsafe_unretained SolaraCoreTab *tab = nil;
    __unsafe_unretained NSString *kind = nil;
    __unsafe_unretained NSString *json = nil;
    __unsafe_unretained NSString *frame = nil;
    BOOL main = NO;
    [invocation getArgument:&tab atIndex:2];
    [invocation getArgument:&kind atIndex:3];
    [invocation getArgument:&json atIndex:4];
    [invocation getArgument:&frame atIndex:5];
    [invocation getArgument:&main atIndex:6];
    __unsafe_unretained NSString *origin = nil;
    if (invocation.methodSignature.numberOfArguments > 7) [invocation getArgument:&origin atIndex:7];
    if ([kind isEqualToString:@"hello"]) AnswerHello(tab, _profile, frame ?: @"", main, origin);
    [self holdPageMessage:kind json:json frame:frame main:main origin:origin];
    return;
  }
  if (invocation.selector == @selector(tab:navigationBecameDownload:)) {
    __unsafe_unretained NSString *url = nil;
    [invocation getArgument:&url atIndex:3];
    if (url.length) solaracore_host::NoteNavigationDownload(url, _profile ?: @"");
    if (_url.length && ![_url isEqualToString:url ?: @""]) solaracore_host::NoteNavigationDownload(_url, _profile ?: @"");
  }
  if (invocation.selector == @selector(tabDidCommitDocument:) || invocation.selector == @selector(tab:rendererGone:code:))
    [self forgetHeldPageStateWhere:^BOOL(NSDictionary *held) { return YES; }];
  if (invocation.selector == @selector(tabDidChangeURL:) || invocation.selector == @selector(tabDidCommitDocument:) ||
      invocation.selector == @selector(tabDidChangeSecurity:)) {
    __unsafe_unretained SolaraCoreTab *tab = nil;
    [invocation getArgument:&tab atIndex:2];
    [SolaraCoreEarlyWindow pageNavigated:tab launchURL:_url];
  }
  if (!_calls) _calls = [NSMutableArray array];
  if (!_callOrder) _callOrder = [NSMutableArray array];
  if (_calls.count >= 2000) return;
  __unsafe_unretained id none = nil;
  [invocation setArgument:&none atIndex:2];
  invocation.target = nil;
  [invocation retainArguments];
  [_calls addObject:invocation];
  [_callOrder addObject:@(++_pageStateOrder)];
}

- (void)tabWillClose:(SolaraCoreTab *)tab {
  _closedByChrome = YES;
  _closedWithWindow = [tab respondsToSelector:@selector(closingWithWindow)] && tab.closingWithWindow;
  [SolaraCoreEarlyWindow dropPage:tab];
}

- (void)replayTo:(SolaraCoreWebView *)view tab:(SolaraCoreTab *)tab {
  NSArray<NSInvocation *> *calls = _calls;
  NSArray<NSNumber *> *callOrder = _callOrder;
  _calls = nil;
  _callOrder = nil;
  NSDictionary<NSString *, NSDictionary *> *state = _pageState;
  _pageState = nil;
  _pageStateBytes = 0;
  NSArray<NSDictionary *> *ordered = [state.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"order"] compare:b[@"order"]];
  }];
  __unsafe_unretained SolaraCoreTab *named = tab;
  NSUInteger next = 0;
  auto replayHeldBefore = [&](NSUInteger order) {
    for (; next < ordered.count && [ordered[next][@"order"] unsignedIntegerValue] < order; next++) {
      NSDictionary *held = ordered[next];
      NSString *frame = held[@"frame"];
      if (frame.length && [tab respondsToSelector:@selector(hasLiveFrame:)] && ![tab hasLiveFrame:frame]) continue;
      [view tab:tab
          didReceivePageMessage:held[@"kind"]
                           json:held[@"json"]
                          frame:frame
                           main:[held[@"main"] boolValue]
                         origin:[held[@"origin"] length] ? held[@"origin"] : nil];
    }
  };
  for (NSUInteger i = 0; i < calls.count; i++) {
    replayHeldBefore(callOrder[i].unsignedIntegerValue);
    [calls[i] setArgument:&named atIndex:2];
    [calls[i] invokeWithTarget:view];
  }
  replayHeldBefore(NSUIntegerMax);
}

@end

@implementation SolaraCoreWebView {
  SolaraCoreTab *_tab;
  BOOL _loadedOnce;
  BOOL _pendingUserInitiated;
  NSString *_requestedURL;
  BOOL _creating;
  BOOL _closing;
  BOOL _launchCloseSent;
  BOOL _offerClosed;
  BOOL _moving;
  NSString *_pendingURL;
  NSString *_creatingURL;
  CFTimeInterval _creatingAt;
  NSString *_transferredURL;
  BOOL _muted;
  NSInteger _tabIndex;
  BOOL _pinned;
  NSView *_devtoolsView;
  NSString *_devToolsPanel;
  NSString *_devToolsReopen;
  BOOL _navigationQueued;
  NSString *_pageTheme;
  BOOL _pageScriptGreeted;
  NSString *_pageThemeSource;
  NSUInteger _createGeneration;
  NSUInteger _blockedGeneration;
  NSInteger _blockedCount;
  NSString *_lastBlocked;
  BOOL _blockedEmitQueued;
  NSDictionary *_sentNavigation;
  NSString *_lastFavicon;
  CFTimeInterval _sentProgressAt;
  double _sentProgress;
  BOOL _progressQueued;
  CFTimeInterval _linkDropAt;
  NSMutableDictionary<NSString *, NSDictionary *> *_nowPlaying;
  NSString *_nowPlayingFrame;
  NSMutableDictionary<NSString *, NSString *> *_notificationFrames;
  NSMutableDictionary<NSString *, NSDictionary *> *_displayRequests;
  double _pinchScale;
  BOOL _autoPictureInPictureActive;
  BOOL _inPictureInPicture;
  BOOL _seenByUser;
  id _sightObserver;
  BOOL _capturing;
  BOOL _crashed;
  BOOL _leaving;
  NSUInteger _leaveGeneration;
  BOOL _handingOff;
  BOOL _devKeptOnClose;
  BOOL _revealed;
  BOOL _littlePageHeld;
  BOOL _littlePageSettled;
  float _littlePageOpacity;
  NSUInteger _littlePageGeneration;
  NSUInteger _revealGeneration;
  __weak NSView *_loweredPane;
  CGFloat _loweredPaneZ;
  __weak NSView *_frontedPage;
  NSUInteger _frontGeneration;
  ACPageFocus _pageFocus;
  __weak NSView *_focusedDevTools;
  __weak NSView *_focusedElsewhere;
  BOOL _focusOnActivate;
  BOOL _keepsOutgoingFocus;
  CFTimeInterval _focusActivatedAt;
  __weak NSWindow *_focusActivatedIn;
}

+ (void)prepareTransfer:(NSString *)transferKey {
  if (!transferKey.length) return;
  NSString *key = [transferKey copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    for (SolaraCoreWebView *view in LiveViews().allObjects)
      if (view->_tab && !view.owned && [view->_transferKey isEqualToString:key]) view->_handingOff = YES;
  });
}

+ (void)releaseTransfer:(NSString *)transferKey {
  if (!transferKey.length) return;
  NSString *key = [transferKey copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    for (SolaraCoreWebView *view in LiveViews().allObjects)
      if ([view->_transferKey isEqualToString:key]) view->_handingOff = NO;
    [SolaraCoreTabParking releaseTransfer:key];
  });
}

static NSMutableSet<NSString *> *BoundRestoreKeys() {
  static NSMutableSet *keys = [NSMutableSet set];
  return keys;
}

static const NSUInteger kMaxSavedHistoryBytes = 32 * 1024 * 1024;

static NSString *SavedHistoryGeneration(SolaraCoreProfile *profile) {
  __block NSString *generation = nil;
  [SolaraCoreServices call:@"ac_tab_history_generation" profile:solaracore_host::ProfileName(profile) args:nil
               completion:^(NSDictionary *result) {
                 if (result[@"error"]) return;
                 if ([result[@"generation"] isKindOfClass:NSString.class]) {
                   generation = result[@"generation"];
                 } else if ([result[@"fromMarker"] isEqual:@YES]) {
                   NSString *marker = [profile.path stringByAppendingPathComponent:@"Solara Tab History Cleared"];
                   NSString *saved = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
                   if (saved || ![NSFileManager.defaultManager fileExistsAtPath:marker])
                     generation = [saved ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                 }
               }];
  return generation;
}

static SolaraCoreTab *RestoreSavedHistory(SolaraCoreWindowController *controller, SolaraCoreProfile *profile, NSString *key, NSString *url) {
  if (!key.length || !url.length || [BoundRestoreKeys() containsObject:key] || !profile.path.length ||
      profile.offTheRecord || !controller.coreWindow)
    return nil;
  NSData *keyBytes = [key dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *raw = (const unsigned char *)keyBytes.bytes;
  NSMutableString *name = [NSMutableString stringWithCapacity:keyBytes.length * 2];
  for (NSUInteger i = 0; i < keyBytes.length; i++) [name appendFormat:@"%02X", raw[i]];
  NSString *file = [[profile.path stringByAppendingPathComponent:@"Solara Tab History"] stringByAppendingPathComponent:name];
  NSData *data = [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil];
  if (!data.length || data.length > kMaxSavedHistoryBytes) return nil;
  NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![saved isKindOfClass:NSDictionary.class] || ![saved[@"version"] isEqual:@1]) return nil;
  NSString *state = [saved[@"state"] isKindOfClass:NSString.class] ? saved[@"state"] : nil;
  NSString *committed = [saved[@"url"] isKindOfClass:NSString.class] ? saved[@"url"] : nil;
  NSString *shown = [saved[@"virtualUrl"] isKindOfClass:NSString.class] ? saved[@"virtualUrl"] : nil;
  if (!state.length || !(SamePage(committed, url) || SamePage(shown, url))) return nil;
  NSString *generation = SavedHistoryGeneration(profile);
  if (!generation || ![saved[@"generation"] isEqual:generation]) return nil;
  controller.hostChanges++;
  SolaraCoreTab *tab = [controller.coreWindow restoreTab:state profile:profile foreground:NO];
  controller.hostChanges--;
  if ([tab respondsToSelector:@selector(loadIfNeeded)]) [tab loadIfNeeded];
  return tab;
}

static SolaraCoreTab *StartParkedPage(NSString *url, NSString *profileName, NSString *key) {
  if (!url.length || !SolaraCoreHost.isStarted) return nil;
  NSString *scheme = [NSURLComponents componentsWithString:url].scheme.lowercaseString;
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
  profileName = profileName ?: @"";
  if (solaracore_host::IsIncognito(profileName) || solaracore_host::IsDeletedProfile(profileName)) return nil;
  SolaraCoreProfile *profile = solaracore_host::LoadedProfile(profileName);
  if (!profile || solaracore_host::WasNavigationDownload(url, profileName)) return nil;
  SolaraCoreWindowController *keeper = [SolaraCoreWindowController strayWindowForProfile:profile];
  if (!keeper) return nil;
  SolaraCoreTab *tab = RestoreSavedHistory(keeper, profile, key, url);
  keeper.hostChanges++;
  if (!tab) tab = [keeper.coreWindow openTab:url profile:profile foreground:NO];
  keeper.hostChanges--;
  if (!tab) {
    [keeper.coreWindow close];
    return nil;
  }
  SolaraCoreLaunchTabHolder *holder = [SolaraCoreLaunchTabHolder new];
  holder.url = url;
  holder.profile = profileName;
  [SolaraCoreTabParking keepOffscreen:tab holder:holder];
  return tab;
}

+ (void)startLaunchTab:(NSString *)transferKey url:(NSString *)url profile:(NSString *)profileName {
  [SolaraCoreTabParking holdLaunchTab:transferKey url:url profile:profileName opening:^SolaraCoreTab * {
    return StartParkedPage(url, profileName, transferKey);
  }];
}

+ (void)claimLaunchTab:(NSString *)transferKey url:(NSString *)url profile:(NSString *)profile {
  [SolaraCoreTabParking claimLaunchTab:transferKey url:url profile:profile];
}

+ (void)startLinkTabs:(NSArray<NSString *> *)urls profile:(NSString *)profileName {
  NSString *profile = [profileName copy] ?: @"";
  [SolaraCoreTabParking holdLinkTabs:urls profile:profile opening:^SolaraCoreTab *(NSString *url) {
    return StartParkedPage(url, profile, nil);
  }];
}

+ (NSDictionary<NSString *, id> *)routeLinkTabs:(NSArray<NSString *> *)urls {
  return [SolaraCoreTabParking routeLinkTabs:urls];
}

- (BOOL)takeLinkTab:(NSString *)adoptId {
  SolaraCoreTab *tab = [SolaraCoreTabParking parkLinkTab:adoptId forKey:_transferKey];
  if (!tab) return NO;
  if ([self takeTransferredTab]) return YES;
  [SolaraCoreTabParking discardTab:tab forKey:_transferKey];
  return NO;
}

+ (void)initialize {
  if (self != SolaraCoreWebView.class) return;
  [NSNotificationCenter.defaultCenter addObserverForName:@"SolaraPagerActivity"
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification *note) {
                                                if (![note.object isKindOfClass:NSWindow.class]) return;
                                                if ([note.userInfo[@"release"] boolValue]) return [SolaraCoreWebView releaseNeighbourPagesIn:note.object];
                                                const double seconds = [note.userInfo[@"seconds"] doubleValue];
                                                [SolaraCoreWebView wakeNeighbourPagesIn:note.object
                                                                               seconds:seconds > 0 ? seconds : kNeighbourPagesAwakeSeconds
                                                                             committed:![note.userInfo[@"speculative"] boolValue]];
                                              }];
  [NSNotificationCenter.defaultCenter addObserverForName:@"RCTBridgeWillReloadNotification"
                                                  object:nil
                                                   queue:nil
                                              usingBlock:^(NSNotification *) {
                                                void (^park)(void) = ^{
                                                  NSMapTable<NSString *, SolaraCoreWebView *> *views = [NSMapTable strongToWeakObjectsMapTable];
                                                  NSMutableDictionary<NSString *, SolaraCoreTab *> *handed = [NSMutableDictionary dictionary];
                                                  for (SolaraCoreWebView *view in LiveViews().allObjects) {
                                                    if (!view->_tab || view->_tab.closed || !view->_transferKey.length || view.owned) continue;
                                                    view->_handingOff = YES;
                                                    [views setObject:view forKey:view->_transferKey];
                                                    handed[view->_transferKey] = view->_tab;
                                                  }
                                                  [SolaraCoreTabParking holdAcrossReload:handed
                                                                                expired:^(NSString *key, SolaraCoreTab *tab) {
                                                                                  if (SolaraCoreWebView *view = [views objectForKey:key]; view && view->_tab == tab)
                                                                                    view->_handingOff = NO;
                                                                                }];
                                                };
                                                if (NSThread.isMainThread) park();
                                                else dispatch_async(dispatch_get_main_queue(), park);
                                              }];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  if ((self = [super initWithFrame:frameRect])) {
    _profile = @"";
    _visible = YES;
    _seenByUser = YES;
    _tabIndex = -1;
    self.wantsLayer = YES;
  }
  return self;
}

- (void)dealloc {
  if (_sightObserver) [NSNotificationCenter.defaultCenter removeObserver:_sightObserver];
  [self closeBrowser];
}

- (BOOL)isFlipped {
  return YES;
}

- (int)browserId {
  return _tab ? solaracore_host::BrowserId(_tab) : 0;
}

- (SolaraCoreWindowController *)controller {
  SolaraCoreWindowController *controller = [SolaraCoreWindowController forNSWindow:self.window];
  if (!controller && self.owned && self.window.parentWindow) controller = [SolaraCoreWindowController forNSWindow:self.window.parentWindow];
  return controller;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (TraceVisibility()) NSLog(@"[solaracore-vis] %@ window=%ld tab=%d", _transferKey, (long)self.window.windowNumber, _tab ? (int)_tab.tabId : -1);
  if (_sightObserver) [NSNotificationCenter.defaultCenter removeObserver:_sightObserver];
  _sightObserver = nil;
  if (!self.window) return;
  if (_visible) [SolaraCoreEarlyWindow noteLayoutChangeIn:self.window];
  __weak SolaraCoreWebView *weakSelf = self;
  _sightObserver = [NSNotificationCenter.defaultCenter addObserverForName:SolaraCoreWindowSeenDidChange object:self.window queue:nil
                                                               usingBlock:^(NSNotification *) { [weakSelf userSightChanged]; }];
  [self userSightChanged];
  [self placeInWindow];
  if (self.owned && !self.controller) {
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf parentWindowDidChange]; });
  }
}

- (void)placeInWindow {
  if (_tab) [self adoptIntoWindow];
  else [self ensureTab];
}

- (void)parentWindowDidChange {
  if (self.window && self.controller) [self placeInWindow];
}

- (void)setExtensionHost:(NSString *)extensionHost {
  _extensionHost = [extensionHost copy];
  if (_extensionHost.length) _standalone = YES;
}

- (void)setAdoptId:(NSString *)adoptId {
  _adoptId = [adoptId copy];
  if (self.window) [self ensureTab];
}

- (void)ensureTab {
  if (_tab || _creating || _offerClosed || !self.window || !SolaraCoreHost.isStarted || !self.controller) return;
  if ([self takeTransferredTab]) return;
  if ([_adoptId hasPrefix:@"link:"]) {
    NSString *link = _adoptId;
    _adoptId = nil;
    if ([SolaraCoreTabParking takeDismissedLinkMark:link]) {
      _offerClosed = YES;
      __weak SolaraCoreWebView *weakSelf = self;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf emit:@"windowClose" payload:@{}];
      });
      return;
    }
    if (!_standalone && !_extensionHost.length && [self takeLinkTab:link]) return;
  }
  if ([_adoptId hasPrefix:@"solaracore:"] || [_adoptId hasPrefix:@"tab:"]) {
    SolaraCoreTab *offered = [SolaraCoreTabs takeOffered:_adoptId];
    _adoptId = nil;
    if (offered.closed) {
      _offerClosed = YES;
      __weak SolaraCoreWebView *weakSelf = self;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf emit:@"windowClose" payload:@{}];
      });
      return;
    }
    if (offered && ![self canTake:offered]) {
      if (!offered.closed) [offered closeNow];
      offered = nil;
    }
    if (offered && !offered.closed) return [self attach:offered];
  }
  NSString *kind = nil, *key = nil;
  NSRange colon = _adoptId ? [_adoptId rangeOfString:@":"] : NSMakeRange(NSNotFound, 0);
  if (colon.location != NSNotFound) {
    kind = [_adoptId substringToIndex:colon.location];
    key = [_adoptId substringFromIndex:NSMaxRange(colon)];
  }
  _adoptId = nil;
  _creating = YES;
  const NSUInteger generation = ++_createGeneration;
  __weak SolaraCoreWebView *weakSelf = self;
  solaracore_host::WithProfile(_profile, ^(SolaraCoreProfile *profile) {
    SolaraCoreWebView *view = weakSelf;
    if (!view || view->_createGeneration != generation) return;
    view->_creating = NO;
    SolaraCoreWindowController *controller = view.controller;
    if (!profile || view->_tab || !controller) return;
    const BOOL standalone = view->_standalone;
    NSString *url = view->_pendingURL ?: view->_initialURL;
    view->_pendingURL = nil;
    view->_creatingURL = url;
    view->_creatingAt = CACurrentMediaTime();
    if (view->_extensionHost.length && url.length && controller.coreWindow) {
      if (SolaraCoreTab *tab = [controller.coreWindow openExtensionView:url profile:profile kind:view->_extensionHost])
        return [view attach:tab];
    }
    if (standalone) controller = [SolaraCoreWindowController standaloneWindowForProfile:profile] ?: controller;
    if (!standalone && [kind isEqualToString:@"clone"] && [view cloneTab:key profile:profile]) return;
    if (!standalone && [kind isEqualToString:@"restore"] && url.length && !solaracore_host::IsIncognito(view->_profile) && controller.coreWindow) {
      view->_creating = YES;
      [SolaraCoreServices call:@"ac_tab_restore_take" profile:view->_profile args:@{@"key" : key}
                completion:^(NSDictionary *result) {
                  SolaraCoreWebView *later = weakSelf;
                  if (!later || later->_createGeneration != generation) return;
                  later->_creating = NO;
                  SolaraCoreWindowController *now = later.controller;
                  if (later->_tab || !now) return;
                  NSString *state = [result[@"state"] isKindOfClass:NSString.class] ? result[@"state"] : nil;
                  SolaraCoreTab *tab = nil;
                  now.hostChanges++;
                  if (state.length) tab = [now.coreWindow restoreTab:state profile:profile foreground:NO];
                  if (!tab) tab = [now.coreWindow openTab:url profile:profile foreground:NO];
                  now.hostChanges--;
                  if (tab) [later attach:tab];
                }];
      return;
    }
    const BOOL userInitiated = view->_pendingUserInitiated;
    if (url.length && [view skipsNavigationDownload:url userInitiated:userInitiated]) url = nil;
    if (url.length) ACFieldMarkNow(view->_transferKey, @"request");
    SolaraCoreTab *tab = !standalone && !userInitiated && !solaracore_host::IsIncognito(view->_profile)
                            ? RestoreSavedHistory(controller, profile, view->_transferKey, url)
                            : nil;
    controller.hostChanges++;
    if (!tab) tab = [controller.coreWindow openTab:url.length ? url : @"" profile:profile foreground:NO];
    controller.hostChanges--;
    if (url.length && tab.loading) ACFieldMarkNow(view->_transferKey, @"start");
    if (tab) [view attach:tab];
    if (tab && url.length) [view focusAfterLoad];
  });
}

- (BOOL)cloneTab:(NSString *)sourceKey profile:(SolaraCoreProfile *)profile {
  SolaraCoreWindowController *controller = self.controller;
  if (!controller.coreWindow) return NO;
  SolaraCoreTab *source = nil;
  for (SolaraCoreWebView *other in LiveViews())
    if (other != self && [other.transferKey isEqualToString:sourceKey] && other->_tab && !other->_tab.closed) source = other->_tab;
  if (!source || source.profile != profile) return NO;
  SolaraCoreWindowController *holder = [SolaraCoreWindowController holding:source];
  _pendingURL = nil;
  controller.hostChanges++;
  holder.hostChanges++;
  SolaraCoreTab *tab = [controller.coreWindow duplicateTab:source profile:profile foreground:NO];
  holder.hostChanges--;
  controller.hostChanges--;
  if (!tab) return NO;
  [self attach:tab];
  return YES;
}

+ (void)keepTransfersOfWindow:(NSWindow *)window {
  SolaraCoreWindowController *closing = [SolaraCoreWindowController forNSWindow:window];
  if (!closing.coreWindow) return;
  for (SolaraCoreWebView *view in LiveViews().allObjects)
    if (view->_handingOff && view->_tab && !view->_tab.closed && [SolaraCoreWindowController holding:view->_tab] == closing)
      [view closeBrowser];
  [SolaraCoreTabParking rehomeFromWindow:closing];
}

+ (void)setOwnedTabStillWanted:(BOOL (^)(SolaraCoreWebView *))handler {
  gOwnedTabStillWanted = [handler copy];
}

+ (NSArray<SolaraCoreTab *> *)tabsToKeep:(NSArray<SolaraCoreTab *> *)tabs closingWindow:(NSWindow *)window closedByChrome:(BOOL)closedByChrome {
  NSAssert(NSThread.isMainThread, @"tabsToKeep off main");
  NSMutableArray<SolaraCoreTab *> *keep = [NSMutableArray array];
  for (SolaraCoreTab *tab in tabs) {
    if (tab.closed || !tab.profile) continue;
    SolaraCoreWebView *owner = [SolaraCoreTabs viewForTab:tab];
    BOOL kept = owner.owned && !closedByChrome && (!gOwnedTabStillWanted || gOwnedTabStillWanted(owner));
#if DEBUG
    BOOL forced = NO;
    if (!kept && [DevKeptBrowsers() containsObject:@(solaracore_host::BrowserId(tab))]) {
      [DevKeptBrowsers() removeObject:@(solaracore_host::BrowserId(tab))];
      forced = YES;
    }
    if (!kept && !forced && gDevKeepOnClose > 0) {
      gDevKeepOnClose--;
      forced = YES;
    }
    SolaraCoreWebView *view = [SolaraCoreTabs viewForTab:tab];
    if (forced && view) view->_devKeptOnClose = YES;
    kept = kept || forced;
#endif
    if (kept) [keep addObject:tab];
  }
  return keep;
}

+ (void)moveKeptTabs:(NSArray<SolaraCoreTab *> *)tabs closingWindow:(NSWindow *)window {
  NSAssert(NSThread.isMainThread, @"moveKeptTabs off main");
  SolaraCoreWindowController *closing = [SolaraCoreWindowController forNSWindow:window];
  for (SolaraCoreTab *tab in tabs) {
    if (tab.closed || !tab.profile) continue;
    SolaraCoreWebView *view = [SolaraCoreTabs viewForTab:tab];
    SolaraCoreWindowController *keeper = [SolaraCoreWindowController keeperWindowForProfile:tab.profile];
    if (!keeper.coreWindow || keeper == closing) continue;
#if DEBUG
    BOOL failing = [DevFailingBrowsers() containsObject:@(solaracore_host::BrowserId(tab))];
    if (failing) [DevFailingBrowsers() removeObject:@(solaracore_host::BrowserId(tab))];
    if (failing || (gDevFailKeptMoves > 0 && gDevFailKeptMoves--)) {
      NSLog(@"[solaracore] a tab kept on close did not move (forced); it gets its beforeunload and closes with the window");
      continue;
    }
#endif
    keeper.hostChanges++;
    closing.hostChanges++;
    [keeper.coreWindow adoptTab:tab];
    closing.hostChanges--;
    keeper.hostChanges--;
    if ([SolaraCoreWindowController holding:tab] != keeper) {
      NSAssert(NO, @"moveKeptTabs: adoptTab deferred, so the tab would move later, mid-prompt");
      NSLog(@"[solaracore] a tab kept on close did not move (adoptTab deferred); it gets its beforeunload and closes with the window");
      continue;
    }
#if DEBUG
    NSLog(@"[solaracore-close] moved kept tab %d at %.3f", solaracore_host::BrowserId(tab), CACurrentMediaTime());
#endif
    if (view.owned) {
      __weak SolaraCoreWebView *rehomed = view;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (SolaraCoreWebView *page = rehomed) [NSNotificationCenter.defaultCenter postNotificationName:@"SolaraCoreOwnedPageRehomed" object:page];
      });
    }
  }
}

+ (NSInteger)devKeepBrowsersOnClose:(NSArray<NSNumber *> *)keep failing:(NSArray<NSNumber *> *)failing {
#if DEBUG
  NSAssert(NSThread.isMainThread, @"devKeepBrowsersOnClose off main");
  NSInteger left = DevKeptBrowsers().count + DevFailingBrowsers().count;
  [DevKeptBrowsers() setSet:[NSSet setWithArray:keep]];
  [DevFailingBrowsers() setSet:[NSSet setWithArray:failing]];
  return left;
#else
  return -1;
#endif
}

+ (NSInteger)devKeptOnCloseForBrowser:(int)browserId {
#if DEBUG
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  SolaraCoreWindowController *controller = tab ? [SolaraCoreWindowController holding:tab] : nil;
  return controller.coreWindow && tab.profile ? [controller.coreWindow keptOnCloseCountForProfile:tab.profile] : -1;
#else
  return -1;
#endif
}

+ (NSInteger)devFailKeptMoves:(NSInteger)count {
#if DEBUG
  NSAssert(NSThread.isMainThread, @"devFailKeptMoves off main");
  NSInteger left = gDevFailKeptMoves;
  gDevFailKeptMoves = MAX(count, 0);
  return left;
#else
  return -1;
#endif
}

+ (NSInteger)devKeepTabsOnClose:(NSInteger)count {
#if DEBUG
  NSAssert(NSThread.isMainThread, @"devKeepTabsOnClose off main");
  NSInteger left = gDevKeepOnClose;
  gDevKeepOnClose = MAX(count, 0);
  return left;
#else
  return -1;
#endif
}

- (BOOL)canTake:(SolaraCoreTab *)tab {
  SolaraCoreProfile *profile = tab.profile;
  if (!profile || tab.closed || profile.offTheRecord != solaracore_host::IsIncognito(_profile)) return NO;
  if (profile.offTheRecord) return solaracore_host::IsOffTheRecordOf(profile, _profile);
  return [solaracore_host::ProfileName(profile) isEqualToString:_profile ?: @""];
}

- (BOOL)takeTransferredTab {
  if (!_transferKey.length) return NO;
  if ([SolaraCoreTabParking launchWasClosed:_transferKey]) {
    if (!_launchCloseSent) {
      _launchCloseSent = YES;
      const BOOL withWindow = [SolaraCoreTabParking launchClosedWithWindow:_transferKey];
      __weak SolaraCoreWebView *weakSelf = self;
      dispatch_async(dispatch_get_main_queue(), ^{
        SolaraCoreWebView *view = weakSelf;
        if (view && !view->_tab) [view emit:@"windowClose" payload:withWindow ? @{@"withWindow" : @YES} : @{}];
      });
    }
    return YES;
  }
  SolaraCoreTab *tab = [SolaraCoreTabParking parkedTabForKey:_transferKey];
  if (tab && ![self canTake:tab]) return NO;
  if (tab) [SolaraCoreTabParking unpark:_transferKey];
  if (!tab) {
    for (SolaraCoreWebView *other in LiveViews().allObjects) {
      if (other == self || ![other.transferKey isEqualToString:_transferKey] || !other->_tab) continue;
      if (![self canTake:other->_tab]) return NO;
      tab = other->_tab;
      [other detach];
      break;
    }
  }
  if (!tab || tab.closed) return NO;
  [SolaraCoreTabParking tookTransfer:_transferKey];
  _adoptId = nil;
  SolaraCoreLaunchTabHolder *launch = (SolaraCoreLaunchTabHolder *)[SolaraCoreTabParking takeHolderOfTab:tab];
  _transferredURL = launch.url ?: tab.url;
  if (SamePage(_pendingURL, _transferredURL)) _pendingURL = nil;
  [self attach:tab];
  if (launch) {
    _loadedOnce = YES;
    _requestedURL = launch.url;
    [launch replayTo:self tab:tab];
    [self focusAfterLoad];
  }
  return YES;
}

- (void)adoptIntoWindow {
  if (_standalone) return;
  SolaraCoreWindowController *controller = self.controller;
  if (!controller.coreWindow) return;
  if ([[controller.coreWindow tabsForProfile:_tab.profile] containsObject:_tab]) return;
  SolaraCoreWindowController *source = [SolaraCoreWindowController holding:_tab];
  _moving = YES;
  controller.hostChanges++;
  source.hostChanges++;
  [controller.coreWindow adoptTab:_tab];
  source.hostChanges--;
  controller.hostChanges--;
  _moving = NO;
  if (_tabIndex >= 0) [self placeTab];
}

- (void)attach:(SolaraCoreTab *)tab {
  if (TraceVisibility()) NSLog(@"[solaracore-vis] %@ attach tab=%d visible=%d", _transferKey, (int)tab.tabId, _visible);
  const BOOL shownEarly = [SolaraCoreEarlyWindow holdsPage:tab];
  [LiveViews() addObject:self];
  InstallControlPressMonitor();
  _tab = tab;
  tab.delegate = self;
  [SolaraCoreTabs setView:self forTab:tab];
  [self markTemporary];
  [self pushPeekModifier];
  [self pushSelectionPopover];
  [self bindRestoreKey];
  [self takePageReports];
  if ([tab respondsToSelector:@selector(deliverHeldPageMessages)]) [tab deliverHeldPageMessages];
  [self userSightChanged];
  [self adoptIntoWindow];
  NSView *page = tab.view;
  if (page.superview != self) {
    if (!page.window || page.window != self.window) [page removeFromSuperview];
    [self addSubview:page];
    [SolaraCoreEarlyWindow pageMoved:tab];
  }
  if (NSView *devtools = tab.devToolsView) [self devToolsChanged:devtools];
  [self layoutPage];
  [self applyPainting];
  if (!shownEarly && (_creatingURL.length || tab.loading)) [self holdLittlePage];
  if (_muted) tab.muted = YES;
  if (_pageBackgroundColor) tab.pageBackgroundColor = _pageBackgroundColor;
  if (_contentsBackgroundColor && [tab respondsToSelector:@selector(setContentsBackgroundColor:)]) tab.contentsBackgroundColor = _contentsBackgroundColor;
  if (_pageColor) tab.pageColor = _pageColor;
  if (_pendingURL) {
    [self loadNow:_pendingURL userInitiated:_pendingUserInitiated];
    _pendingURL = nil;
  }
  [self emit:@"ready" payload:@{@"browserId" : @(solaracore_host::BrowserId(tab)), @"tabId" : @(tab.tabId)}];
  [self emitNavigation];
  if (_extensionHost.length && tab && tab.preferredSize.width > 0)
    [self tab:tab preferredSizeDidChange:tab.preferredSize];
  [self emitMedia];
  [self tabDidChangeFavicon:tab];
  if (_tabIndex >= 0) [self placeTab];
  if (SolaraCoreWindowController *controller = self.controller)
    [SolaraCoreTabStrip changedInWindow:controller profile:tab.profile cause:NSNull.null];
}

- (void)bindRestoreKey {
  if (!_tab || !_transferKey.length || solaracore_host::IsIncognito(_profile) || !SolaraCoreHost.isStarted) return;
  [BoundRestoreKeys() addObject:_transferKey];
  [SolaraCoreServices call:@"ac_tab_restore_tag" profile:_profile args:@{@"tab" : @(_tab.tabId), @"key" : _transferKey}
            completion:^(NSDictionary *) {}];
}

- (void)detach {
  if (!_tab) return;
  if (TraceVisibility()) NSLog(@"[solaracore-vis] %@ detach tab=%d", _transferKey, (int)_tab.tabId);
  [self revealLittlePage:NO];
  if (_tab.delegate == self) _tab.delegate = nil;
  [SolaraCoreTabs setView:nil forTab:_tab];
  [SolaraCoreWebView noteShown:_tab];
  [self stashPageReports];
  AcceptDrops(_tab.view, YES);
  if (_tab.view.superview == self) [_tab.view removeFromSuperview];
  [self dropDevTools];
  [self resetBlocked:NO];
  [self endReveal];
  [self dropFront];
  _tab = nil;
  _focusOnActivate = NO;
  _pageFocus = ACPageFocus::Unknown;
  _focusedDevTools = nil;
  _focusedElsewhere = nil;
  _handingOff = NO;
  _leaving = NO;
  _leaveGeneration++;
}

- (void)stashPageReports {
  NSMutableDictionary *reports = [NSMutableDictionary dictionary];
  reports[@"url"] = _tab.url ?: @"";
  reports[@"theme"] = _pageTheme;
  reports[@"themeSource"] = _pageThemeSource;
  reports[@"greeted"] = @(_pageScriptGreeted);
  reports[@"blocked"] = @(_blockedCount);
  reports[@"lastBlocked"] = _lastBlocked;
  reports[@"nowPlaying"] = _nowPlaying;
  reports[@"nowPlayingFrame"] = _nowPlayingFrame;
  reports[@"notifications"] = _notificationFrames;
  reports[@"displayRequests"] = _displayRequests;
  reports[@"pinch"] = @(_pinchScale);
  reports[@"capturing"] = @(_capturing);
  reports[@"crashed"] = @(_crashed);
  reports[@"seen"] = @(_seenByUser);
  reports[@"pip"] = @(_inPictureInPicture);
  reports[@"autoPip"] = @(_autoPictureInPictureActive);
  if (!_tab.closed) objc_setAssociatedObject(_tab, &kPageReportsKey, reports, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self takeReports:nil];
}

- (void)takePageReports {
  NSDictionary *reports = objc_getAssociatedObject(_tab, &kPageReportsKey);
  objc_setAssociatedObject(_tab, &kPageReportsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self takeReports:[reports[@"url"] isEqual:_tab.url ?: @""] ? reports : nil];
}

- (void)takeReports:(NSDictionary *)reports {
  _pageTheme = reports[@"theme"];
  _pageThemeSource = reports[@"themeSource"];
  _pageScriptGreeted = [reports[@"greeted"] boolValue];
  _blockedCount = [reports[@"blocked"] integerValue];
  _lastBlocked = reports[@"lastBlocked"];
  _nowPlaying = reports[@"nowPlaying"];
  _nowPlayingFrame = reports[@"nowPlayingFrame"];
  _notificationFrames = reports[@"notifications"];
  _displayRequests = reports[@"displayRequests"];
  _pinchScale = [reports[@"pinch"] doubleValue];
  _capturing = [reports[@"capturing"] boolValue];
  _crashed = [reports[@"crashed"] boolValue];
  if (reports[@"seen"]) _seenByUser = [reports[@"seen"] boolValue];
  _inPictureInPicture = [reports[@"pip"] boolValue];
  _autoPictureInPictureActive = [reports[@"autoPip"] boolValue];
}

- (void)closeBrowser {
  _createGeneration++;
  _creating = NO;
  if (!_tab) return;
#if DEBUG
  if (_devKeptOnClose) {
    _devKeptOnClose = NO;
    [self detach];
    return;
  }
#endif
  SolaraCoreTab *tab = _tab;
  if (_handingOff && _transferKey.length && !tab.closed) {
    [self detach];
    [SolaraCoreTabParking park:tab forKey:_transferKey];
    return;
  }
  _closing = YES;
  if (_transferKey.length && !solaracore_host::IsIncognito(_profile) && SolaraCoreHost.isStarted)
    [SolaraCoreServices call:@"ac_tab_restore_tag" profile:_profile args:@{@"tab" : @(tab.tabId), @"key" : _transferKey}
              completion:^(NSDictionary *) {}];
  [[SolaraCoreWindowController holding:tab] noteClosing:tab];
  [self detach];
  [tab closeNow];
}

- (void)placeTab {
  SolaraCoreWindowController *controller = self.controller;
  if (!_tab || !controller.coreWindow) return;
  controller.hostChanges++;
  [controller.coreWindow placeTab:_tab index:(int)_tabIndex pinned:_pinned];
  controller.hostChanges--;
}

- (void)openedTab:(SolaraCoreTab *)tab adoptId:(NSString *)adoptId disposition:(NSString *)disposition {
  [self announceOpenedTab:tab adoptId:adoptId disposition:disposition tries:0];
}

- (void)announceOpenedTab:(SolaraCoreTab *)tab adoptId:(NSString *)adoptId disposition:(NSString *)disposition tries:(int)tries {
  if (tab.closed) return;
  NSString *url = tab.url;
  if ((!url.length || [url isEqualToString:@"about:blank"]) && tries < 20) {
    __weak SolaraCoreWebView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [weakSelf announceOpenedTab:tab adoptId:adoptId disposition:disposition tries:tries + 1];
    });
    return;
  }
  NSMutableDictionary *payload = [@{
    @"url" : url ?: @"",
    @"disposition" : disposition,
    @"adoptId" : adoptId,
    @"userGesture" : @YES,
    @"postBody" : @NO,
  } mutableCopy];
  if (tab.profile.offTheRecord) payload[@"profile"] = solaracore_host::OriginalProfileNameOf(tab.profile);
  [self emit:@"openWindow" payload:payload];
}

- (void)tabRemovedFromWindow:(SolaraCoreWindow *)window {
  if (_moving || _closing || !_tab) return;
  {
    SolaraCoreTab *removed = _tab;
    __weak SolaraCoreWebView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      SolaraCoreWebView *view = weakSelf;
      if (view && view->_tab == removed && removed.closed) [view detach];
    });
  }
  if (solaracore_host::EngineHasTabModel()) return;
  [self detach];
  [self emit:@"windowClose" payload:@{}];
}

- (void)tabActivatedByChrome:(BOOL)chromes {
  if (TraceVisibility()) NSLog(@"[solaracore-vis] %@ chrome-activated tab=%d byChrome=%d", _transferKey, _tab ? (int)_tab.tabId : -1, chromes);
  if (_standalone) return;
  [self requestFocusRestore];
  [self emit:@"tabStrip"
      payload:@{
        @"index" : @(MAX(_tabIndex, 0)),
        @"active" : @YES,
        @"pinned" : @(_pinned),
        @"activated" : @YES,
        @"byApp" : @(!chromes),
      }];
}

- (NSView *)dockedDevToolsView {
  return _devtoolsView;
}

- (void)devToolsChanged:(NSView *)devToolsView {
  if (_devtoolsView && _devtoolsView != devToolsView && _devtoolsView.superview == self) {
    AcceptDrops(_devtoolsView, YES);
    [_devtoolsView removeFromSuperview];
  }
  _devtoolsView = devToolsView;
  if (!devToolsView) {
    _devToolsPanel = nil;
    if (_devToolsReopen) {
      __weak SolaraCoreWebView *weakSelf = self;
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf reopenDevToolsPanel];
      });
    }
  }
  if (devToolsView && devToolsView.superview != self) {
    [devToolsView removeFromSuperview];
    NSView *page = _tab.view;
    if (page.superview == self) [self addSubview:devToolsView positioned:NSWindowBelow relativeTo:page];
    else [self addSubview:devToolsView];
    AcceptDrops(devToolsView, _visible);
  }
  [self layoutPage];
}

- (void)dropDevTools {
  AcceptDrops(_devtoolsView, YES);
  if (_devtoolsView.superview == self) [_devtoolsView removeFromSuperview];
  _devtoolsView = nil;
  _devToolsPanel = nil;
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self layoutPage];
  if (_visible) [SolaraCoreEarlyWindow noteLayoutChangeIn:self.window];
}

- (void)setFrameOrigin:(NSPoint)newOrigin {
  [super setFrameOrigin:newOrigin];
  if (_visible) [SolaraCoreEarlyWindow noteLayoutChangeIn:self.window];
}

- (void)layoutPage {
  if (NSView *fronted = _frontedPage; fronted.superview == self) fronted.frame = self.bounds;
  NSView *page = _tab.view;
  if (!page || page.superview != self) return;
  if (_devtoolsView) {
    NSRect devtools = NSZeroRect, pageFrame = self.bounds;
    [_tab devToolsLayoutForSize:self.bounds.size devTools:&devtools page:&pageFrame];
    _devtoolsView.frame = devtools;
    page.frame = pageFrame;
  } else {
    page.frame = self.bounds;
  }
}

- (BOOL)paints {
  return _visible || (_warm && !self.neighbourPageAsleep) || _leaving || _revealed;
}

- (BOOL)neighbourPageAsleep {
  if (!_warm || !_neighbour || _visible || NeighbourPagesAlwaysLive()) return NO;
  NSWindow *window = self.window;
  if (!window) return NO;
  return [NeighbourPagesAwake() objectForKey:window].until <= CACurrentMediaTime();
}

- (void)setNeighbour:(BOOL)neighbour {
  if (_neighbour == neighbour) return;
  _neighbour = neighbour;
  [self schedulePainting];
}

+ (void)wakeNeighbourPagesIn:(NSWindow *)window seconds:(CFTimeInterval)seconds committed:(BOOL)committed {
  const CFTimeInterval now = CACurrentMediaTime();
  ACNeighbourWake *wake = [NeighbourPagesAwake() objectForKey:window];
  const BOOL wasAwake = wake.until > now;
  if (!wake) [NeighbourPagesAwake() setObject:(wake = [ACNeighbourWake new]) forKey:window];
  if (committed) wake.committedUntil = MAX(wake.committedUntil, now + seconds);
  else wake.speculativeUntil = MAX(wake.speculativeUntil, now + seconds);
  if (wasAwake) return;
  [self repaintWarmPagesIn:window];
  [self sleepNeighbourPagesIn:window after:seconds];
}

+ (void)releaseNeighbourPagesIn:(NSWindow *)window {
  ACNeighbourWake *wake = [NeighbourPagesAwake() objectForKey:window];
  const CFTimeInterval now = CACurrentMediaTime();
  if (!wake || wake.speculativeUntil <= now) return;
  wake.speculativeUntil = 0;
  if (wake.committedUntil <= now) [self repaintWarmPagesIn:window];
}

+ (void)sleepNeighbourPagesIn:(NSWindow *)window after:(CFTimeInterval)delay {
  __weak NSWindow *weakWindow = window;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    NSWindow *window = weakWindow;
    ACNeighbourWake *wake = window ? [NeighbourPagesAwake() objectForKey:window] : nil;
    if (!wake) return;
    const CFTimeInterval left = wake.until - CACurrentMediaTime();
    if (left > 0) return [self sleepNeighbourPagesIn:window after:left];
    [NeighbourPagesAwake() removeObjectForKey:window];
    [self repaintWarmPagesIn:window];
  });
}

+ (void)repaintWarmPagesIn:(NSWindow *)window {
  for (SolaraCoreWebView *view in LiveViews().allObjects)
    if (view->_warm && view.window == window) [view schedulePainting];
}

- (void)holdLittlePage {
  NSView *page = _tab.view;
  if (_littlePageHeld || _littlePageSettled || !page || page.superview != self ||
      ![self.window.identifier isEqualToString:@"solara.window.small"])
    return;
  _littlePageHeld = YES;
  page.wantsLayer = YES;
  _littlePageOpacity = page.layer.opacity;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  page.layer.opacity = 0;
  [CATransaction commit];
  [self callFrame:@"" kind:@"firstPaint" json:@"{}"];
  const NSUInteger generation = ++_littlePageGeneration;
  __weak SolaraCoreWebView *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (view && view->_littlePageGeneration == generation) [view revealLittlePage:YES];
  });
}

- (void)revealLittlePage:(BOOL)animated {
  if (!_littlePageHeld) return;
  _littlePageHeld = NO;
  _littlePageSettled = YES;
  _littlePageGeneration++;
  CALayer *layer = _tab.view.layer;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.opacity = _littlePageOpacity;
  if (animated) {
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.toValue = @(_littlePageOpacity);
    fade.duration = 0.16;
    fade.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.23 :1 :0.32 :1];
    [layer addAnimation:fade forKey:@"solara.little.page"];
  }
  [CATransaction commit];
}

- (void)applyPainting {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.alphaValue = _visible || _revealed || !(_warm || _leaving) ? 1 : 0;
  const BOOL shown = self.paints;
  for (NSView *sub in self.subviews) {
    sub.hidden = !shown;
    AcceptDrops(sub, _visible);
  }
  [CATransaction commit];
  if (TraceVisibility())
    NSLog(@"[solaracore-vis] %@ paint visible=%d warm=%d tab=%d page=%@ inWindow=%ld hiddenAncestor=%d", _transferKey,
          _visible, _warm, _tab ? (int)_tab.tabId : -1, _tab.view.superview == self ? @"here" : @"elsewhere",
          (long)self.window.windowNumber, _tab.view.isHiddenOrHasHiddenAncestor);
}

- (void)setWarm:(BOOL)warm {
  if (_warm == warm) return;
  _warm = warm;
  [self schedulePainting];
}

+ (void)noteShown:(SolaraCoreTab *)tab {
  if (!tab) return;
  static NSMapTable<SolaraCoreTab *, NSNumber *> *changes = [NSMapTable weakToStrongObjectsMapTable];
  const NSUInteger change = [changes objectForKey:tab].unsignedIntegerValue + 1;
  [changes setObject:@(change) forKey:tab];
  SolaraCoreWebView *view = [SolaraCoreTabs viewForTab:tab];
  if (view.seenByUser) return [tab noteShownByHost:YES];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    if ([changes objectForKey:tab].unsignedIntegerValue != change) return;
    SolaraCoreWebView *now = [SolaraCoreTabs viewForTab:tab];
    if (!now.seenByUser) [tab noteShownByHost:NO];
  });
}

- (void)setTemporary:(BOOL)temporary {
  _temporary = temporary;
  [self markTemporary];
}

- (void)setTemporarySource:(NSString *)temporarySource {
  _temporarySource = [temporarySource copy];
  [self markTemporary];
}

- (void)markTemporary {
  if ([_tab respondsToSelector:@selector(setTemporary:)] && _tab.temporary != _temporary) _tab.temporary = _temporary;
  if (![_tab respondsToSelector:@selector(setTemporarySource:)]) return;
  SolaraCoreTab *source = nil;
  if (_temporary && _temporarySource.length)
    for (SolaraCoreWebView *view in LiveViews().allObjects)
      if ([view.transferKey isEqualToString:_temporarySource]) source = view->_tab;
  [_tab setTemporarySource:source];
}

- (void)setVisible:(BOOL)visible {
  if (_visible == visible) return;
  if (!visible) [self storePageFocus];
  _visible = visible;
  if (visible) [self settleRevealsInWindow];
  if (!visible) [_tab exitExclusiveAccess];
  if (visible && self.alphaValue < 1 && _tab.view.superview == self && !_tab.view.hidden) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.alphaValue = 1;
    [CATransaction commit];
  }
  [self schedulePainting];
  if (visible) ACFieldMarkAtCommit(_transferKey, @"view");
  if (visible) [SolaraCoreEarlyWindow noteLayoutChangeIn:self.window];
  [self userSightChanged];
}

- (BOOL)seenByUser {
  return _visible && [SolaraCoreWindowController userSees:self.window];
}

- (void)userSightChanged {
  if (_tab) [SolaraCoreWebView noteShown:_tab];
  const BOOL seen = self.seenByUser;
  if (seen == _seenByUser) return;
  _seenByUser = seen;
  [self traceAutoPictureInPicture:seen ? @"app: the user sees the tab" : @"app: the user left the tab"];
  [self updateAutoPictureInPicture];
}

- (void)traceManualPictureInPicture:(NSString *)what {
  if (TracingPictureInPicture()) [_tab tracePictureInPicture:[@"app: manual PiP " stringByAppendingString:what] withInputs:NO];
}

- (void)traceAutoPictureInPicture:(NSString *)what {
  if (!TracingPictureInPicture() || !_tab) return;
  NSDictionary *np = _nowPlaying[_nowPlayingFrame ?: @""];
  [_tab tracePictureInPicture:[NSString stringWithFormat:@"%@ (%@): autoPictureInPicture=%d capturing=%d nowPlaying=%@ actions=%@",
                                                         what, _tab.url, _autoPictureInPicture, _capturing,
                                                         np[@"playbackState"] ?: @"none", JSONString(np[@"actions"] ?: @[])]
                   withInputs:YES];
  SolaraCoreTab *tab = _tab;
  [_tab evaluate:@"post('result', JSON.stringify({ documentPictureInPicture: 'documentPictureInPicture' in window, "
                  "window: !!window.documentPictureInPicture?.window, videoPip: !!document.pictureInPictureElement, "
                  "brands: navigator.userAgentData?.brands?.map((b) => b.brand + '/' + b.version), visibility: document.visibilityState }))"
      completion:^(NSString *json) { [tab tracePictureInPicture:[@"page: " stringByAppendingString:json ?: @"(no answer)"] withInputs:NO]; }];
}

- (void)schedulePainting {
  [PendingPainting() addObject:self];
  if (gPaintingScheduled) return;
  gPaintingScheduled = true;
  CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(nil, kCFRunLoopBeforeWaiting | kCFRunLoopExit, false, 0, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
    [SolaraCoreWebView drainPainting];
  });
  CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
  CFRelease(observer);
}

+ (void)drainPainting {
  gPaintingScheduled = false;
  NSArray<SolaraCoreWebView *> *views = PendingPainting().allObjects;
  [PendingPainting() removeAllObjects];
  for (SolaraCoreWebView *view in views) {
    if (view->_visible) continue;
    [view leaveScreen];
    [view applyPainting];
  }
  for (SolaraCoreWebView *view in views)
    if (view->_visible) [view applyPainting];
  for (SolaraCoreWebView *view in views)
    if (view->_visible) [view restoreFocusIfDue];
}

static BOOL ShowsIn(NSView *view, NSWindow *window) {
  return view && view.window == window && !view.isHiddenOrHasHiddenAncestor;
}

static BOOL InTabPage(NSView *view) {
  for (NSView *v = view; v; v = v.superview)
    if ([v isKindOfClass:SolaraCoreWebView.class]) return !((SolaraCoreWebView *)v)->_standalone;
  return NO;
}

+ (void)installOutgoingFocusSnapshots {
  static id snapshots, ends;
  if (snapshots) return;
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  snapshots = [center addObserverForName:@"SolaraOutgoingFocus" object:nil queue:nil usingBlock:^(NSNotification *note) {
    if (SolaraCoreWebView *view = [SolaraCoreWebView holding:note.object]) {
      [view storePageFocusFrom:note.object];
      view->_keepsOutgoingFocus = YES;
    }
  }];
  ends = [center addObserverForName:@"SolaraFocusHandoffEnded" object:nil queue:nil usingBlock:^(NSNotification *note) {
    if (SolaraCoreWebView *view = [SolaraCoreWebView holding:note.object]) view->_keepsOutgoingFocus = NO;
  }];
}

+ (SolaraCoreWebView *)holding:(id)responder {
  NSView *outgoing = [responder isKindOfClass:NSView.class] ? responder : nil;
  for (SolaraCoreWebView *view in LiveViews().allObjects)
    if (outgoing && view.window == outgoing.window && [outgoing isDescendantOf:view]) return view;
  return nil;
}

- (void)storePageFocus {
  NSResponder *responder = self.window.firstResponder;
  const BOOL unfocused = !responder || responder == self.window;
  const BOOL snapshotted = _keepsOutgoingFocus;
  _keepsOutgoingFocus = NO;
  if (snapshotted && unfocused) {
    _focusOnActivate = NO;
    return;
  }
  [self storePageFocusFrom:responder];
}

- (void)storePageFocusFrom:(NSResponder *)responder {
  _focusOnActivate = NO;
  _focusedDevTools = nil;
  _focusedElsewhere = nil;
  NSWindow *window = self.window;
  if (!window || !_tab) return;
  NSView *view = [responder isKindOfClass:NSView.class] ? (NSView *)responder : nil;
  if (view && _tab.view && [view isDescendantOf:_tab.view]) {
    _pageFocus = ACPageFocus::Page;
  } else if (view && _devtoolsView && [view isDescendantOf:_devtoolsView]) {
    _pageFocus = ACPageFocus::DevTools;
    _focusedDevTools = view;
  } else if (!responder || responder == window || (view && InTabPage(view))) {
    _pageFocus = ACPageFocus::Unknown;
  } else {
    _pageFocus = ACPageFocus::Elsewhere;
    _focusedElsewhere = view;
  }
}

- (void)requestFocusRestore {
  [self requestFocusRestoreIn:self.window];
}

- (void)requestFocusRestoreIn:(NSWindow *)window {
  if (_standalone || !_tab || !window) return;
  _focusOnActivate = YES;
  _focusActivatedAt = CACurrentMediaTime();
  _focusActivatedIn = window;
  [self restoreFocusIfDue];
  if (_focusOnActivate) [self schedulePainting];
}

- (void)restoreFocusIfDue {
  if (!_focusOnActivate) return;
  NSWindow *window = self.window;
  NSView *page = _tab.view;
  if (!window || window != _focusActivatedIn || !page || _standalone || page.superview != self ||
      CACurrentMediaTime() - _focusActivatedAt > kFocusRestoreWindow) {
    _focusOnActivate = NO;
    return;
  }
  if (!_visible || page.isHiddenOrHasHiddenAncestor) return;
  _focusOnActivate = NO;
  NSResponder *responder = window.firstResponder;
  NSView *view = [responder isKindOfClass:NSView.class] ? (NSView *)responder : nil;
  if (view && [view isDescendantOf:self]) return;
  if (responder && responder != window && !(view && InTabPage(view))) return;
  NSView *devTools = _focusedDevTools;
  if (_pageFocus == ACPageFocus::DevTools && devTools.window == window && _devtoolsView && [devTools isDescendantOf:_devtoolsView]) {
    [window makeFirstResponder:devTools];
  } else if (_pageFocus != ACPageFocus::Elsewhere) {
    [self focusPage];
  } else if (!ShowsIn(_focusedElsewhere, window)) {
    BOOL (^claimedElsewhere)(NSWindow *, NSView *) = ACChromeWindowHost.focusClaimedElsewhereHandler;
    if (!claimedElsewhere || !claimedElsewhere(window, self)) [self focusPage];
  }
}

static SolaraCoreWebView *ViewForKey(NSString *key) {
  for (SolaraCoreWebView *view in LiveViews().allObjects)
    if (view->_tab && [view->_transferKey isEqualToString:key]) return view;
  return nil;
}

+ (void)revealTab:(NSString *)transferKey {
  if (!transferKey.length) return;
  NSString *key = [transferKey copy];
  OnMain(^{
    SolaraCoreWebView *view = ViewForKey(key);
    if (!view.window) return;
    [SolaraCoreWebView dropRevealsInWindow:view.window except:view];
    [view revealAhead];
  });
}

+ (void)dropTabReveals:(NSString *)transferKey {
  if (!transferKey.length) return;
  NSString *key = [transferKey copy];
  OnMain(^{
    SolaraCoreWebView *view = ViewForKey(key);
    if (view.window) [SolaraCoreWebView dropRevealsInWindow:view.window except:nil];
  });
}

+ (void)dropRevealsInWindow:(NSWindow *)window except:(SolaraCoreWebView *)keep {
  for (SolaraCoreWebView *other in LiveViews().allObjects) {
    if (other.window != window) continue;
    [other dropFront];
    if (other != keep) [other dropReveal];
  }
}

static NSView *PaneUnder(NSView *view, NSView *ancestor) {
  for (NSView *v = view; v; v = v.superview)
    if (v.superview == ancestor) return v;
  return nil;
}

static NSView *SharedAncestor(NSView *a, NSView *b) {
  NSHashTable<NSView *> *chain = [NSHashTable weakObjectsHashTable];
  for (NSView *v = a.superview; v; v = v.superview) [chain addObject:v];
  for (NSView *v = b.superview; v; v = v.superview)
    if ([chain containsObject:v]) return v;
  return nil;
}

+ (void)revealOffered:(NSString *)adoptId over:(NSString *)transferKey {
  if (!adoptId.length || !transferKey.length) return;
  NSString *offer = [adoptId copy], *key = [transferKey copy];
  OnMain(^{
    SolaraCoreWebView *view = ViewForKey(key);
    if (!view.window) return;
    [SolaraCoreWebView dropRevealsInWindow:view.window except:nil];
    SolaraCoreTab *tab = [SolaraCoreTabs offeredTab:offer];
    NSView *page = tab.view;
    if (TraceVisibility())
      NSLog(@"[solaracore-vis] %@ front %@ offered=%d closed=%d superview=%@ adopted=%d", key, offer, tab != nil, tab.closed,
            page.superview.className, [SolaraCoreTabs viewForTab:tab] != nil);
    if (!tab || tab.closed || !page || page.superview || [SolaraCoreTabs viewForTab:tab]) return;
    [view frontPage:page profile:tab.profile];
  });
}

- (BOOL)onlyShownInWindow {
  NSWindow *window = self.window;
  if (!_visible || _warm || _revealed || _standalone || _closing || !window || self.alphaValue < 1 || self.isHiddenOrHasHiddenAncestor) return NO;
  for (SolaraCoreWebView *other in LiveViews().allObjects)
    if (other != self && other.window == window && (other->_visible || other->_warm || other->_revealed)) return NO;
  return YES;
}

- (void)frontPage:(NSView *)page profile:(SolaraCoreProfile *)profile {
  NSView *mine = _tab.view;
  if (_frontedPage || _devtoolsView || !mine || mine.superview != self || mine.hidden || _tab.profile != profile || ![self onlyShownInWindow]) return;
  page.frame = self.bounds;
  page.hidden = NO;
  [self addSubview:page positioned:NSWindowAbove relativeTo:mine];
  _frontedPage = page;
  if (TraceVisibility()) NSLog(@"[solaracore-vis] %@ fronts a new tab's page", _transferKey);
  const NSUInteger generation = ++_frontGeneration;
  __weak SolaraCoreWebView *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRevealBackstopSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (view && view->_frontGeneration == generation) [view dropFront];
  });
}

- (void)dropFront {
  NSView *fronted = _frontedPage;
  _frontedPage = nil;
  _frontGeneration++;
  if (fronted.superview == self) [fronted removeFromSuperview];
}

- (void)revealAhead {
  NSWindow *window = self.window;
  NSView *page = _tab.view;
  if (_visible || _revealed || _warm || _standalone || _closing || !window || !page || page.superview != self) return;
  SolaraCoreWebView *shown = nil;
  for (SolaraCoreWebView *other in LiveViews().allObjects) {
    if (other == self || other.window != window) continue;
    if (other->_warm || other->_revealed) return;
    if (!other->_visible) continue;
    if (shown) return;
    shown = other;
  }
  if (!shown || shown.alphaValue < 1 || shown->_frontedPage) return;
  const NSRect mine = [self convertRect:self.bounds toView:nil];
  if (NSIsEmptyRect(mine) || !NSEqualRects(mine, [shown convertRect:shown.bounds toView:nil])) return;
  NSView *shared = SharedAncestor(self, shown);
  NSView *pane = PaneUnder(self, shared);
  NSView *shownPane = PaneUnder(shown, shared);
  if (!shared || !pane || !shownPane || !shownPane.layer || pane == shownPane || pane.isHiddenOrHasHiddenAncestor || pane.alphaValue < 1) return;
  if (TraceVisibility()) NSLog(@"[solaracore-vis] %@ revealed over %@", _transferKey, shown->_transferKey);
  _revealed = YES;
  _loweredPane = shownPane;
  _loweredPaneZ = shownPane.layer.zPosition;
  shownPane.layer.zPosition = _loweredPaneZ - 1;
  [self applyPainting];
  const NSUInteger generation = ++_revealGeneration;
  __weak SolaraCoreWebView *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRevealBackstopSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (view && view->_revealGeneration == generation && view->_revealed) [view dropReveal];
  });
}

- (void)endReveal {
  if (!_revealed) return;
  _revealed = NO;
  _revealGeneration++;
  if (NSView *pane = _loweredPane) pane.layer.zPosition = _loweredPaneZ;
  _loweredPane = nil;
}

- (void)dropReveal {
  if (!_revealed) return;
  [self endReveal];
  [self schedulePainting];
}

- (void)settleRevealsInWindow {
  [self endReveal];
  NSWindow *window = self.window;
  if (window) [SolaraCoreWebView dropRevealsInWindow:window except:self];
}

- (void)leaveScreen {
  const NSUInteger generation = ++_leaveGeneration;
  NSView *page = _tab.view;
  _leaving = !_visible && !_warm && !_revealed && page.superview == self && !page.hidden && self.alphaValue > 0;
  if (!_leaving) return;
  __weak SolaraCoreWebView *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLeaveScreenDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (!view || view->_leaveGeneration != generation) return;
    view->_leaving = NO;
    [view schedulePainting];
  });
}

- (void)setFrozen:(BOOL)frozen {
  _frozen = frozen;
  _tab.frozen = frozen;
}

- (void)setPageBackgroundColor:(NSColor *)color {
  _pageBackgroundColor = color;
  _tab.pageBackgroundColor = color;
}

- (void)setContentsBackgroundColor:(NSColor *)color {
  _contentsBackgroundColor = color;
  if ([_tab respondsToSelector:@selector(setContentsBackgroundColor:)]) _tab.contentsBackgroundColor = color;
}

- (void)setPageColor:(NSString *)color {
  _pageColor = [color copy];
  _tab.pageColor = color;
}

- (void)emit:(NSString *)name payload:(NSDictionary *)payload {
  if (_navigationQueued && ![name isEqualToString:@"navigation"]) [self emitNavigation];
  if (_tab) NoteEvent(solaracore_host::BrowserId(_tab), name, payload);
  [self.delegate webView:self event:name payload:payload];
}

void SolaraCoreWebViewsSetFieldTiming(BOOL on) {
  for (SolaraCoreWebView *view in LiveViews().allObjects)
    if (view->_tab) [view callFrame:@"" kind:@"fieldTiming" json:on ? @"{\"on\":true}" : @"{\"on\":false}"];
}

+ (NSArray<NSDictionary<NSString *, id> *> *)devEventsForBrowser:(int)browserId {
  return RecentEvents()[@(browserId)] ?: @[];
}

+ (void)setDisplayMediaPicker:(BOOL)enabled {
  gDisplayMediaPicker = enabled;
}

+ (BOOL)devPostPeekMouseUp:(NSString *)keys over:(NSString *)transferKey {
  if (!PeekTestHooks()) return NO;
  SolaraCoreWebView *target = nil;
  for (SolaraCoreWebView *view in LiveViews().allObjects)
    if (view->_visible && view.window && (!transferKey.length || [view.transferKey isEqualToString:transferKey])) target = view;
  NSWindow *window = target.window;
  if (!window) return NO;
  NSEventModifierFlags flags = 0;
  if ([keys containsString:@"⌥"]) flags |= NSEventModifierFlagOption;
  if ([keys containsString:@"⇧"]) flags |= NSEventModifierFlagShift;
  if ([keys containsString:@"⌘"]) flags |= NSEventModifierFlagCommand;
  if ([keys containsString:@"⌃"]) flags |= NSEventModifierFlagControl;
  const NSPoint at = [target convertPoint:NSMakePoint(NSMidX(target.bounds), NSMidY(target.bounds)) toView:nil];
  NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:at modifierFlags:flags
                                  timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                                    context:nil eventNumber:0 clickCount:1 pressure:0];
  [NSApp postEvent:up atStart:NO];
  if ([keys containsString:@"+press"]) {
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:at modifierFlags:0
                                      timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                                        context:nil eventNumber:0 clickCount:1 pressure:1];
    [NSApp postEvent:down atStart:NO];
  }
  return YES;
}

+ (void)setPeekModifier:(NSString *)modifier {
  InstallPeekMonitor();
  NSString *next = [@[ @"alt", @"shift" ] containsObject:modifier ?: @""] ? modifier : @"off";
  if ([next isEqualToString:gPeekModifier]) return;
  gPeekModifier = [next copy];
  for (SolaraCoreWebView *view in LiveViews().allObjects) [view pushPeekModifier];
}

+ (void)setSplitLinkModifier:(NSString *)modifier {
  InstallPeekMonitor();
  NSString *next = [modifier isEqualToString:@"alt"] ? @"alt" : @"altShift";
  if ([next isEqualToString:gSplitLinkModifier]) return;
  gSplitLinkModifier = [next copy];
  for (SolaraCoreWebView *view in LiveViews().allObjects) [view pushPeekModifier];
}

+ (void)setSelectionPopoverEnabled:(BOOL)enabled {
  if (enabled == gSelectionPopover) return;
  gSelectionPopover = enabled;
  for (SolaraCoreWebView *view in LiveViews().allObjects) [view pushSelectionPopover];
}

+ (void)setAutoPictureInPictureEnabled:(BOOL)enabled {
  [SolaraCoreEngine setAutoPictureInPicture:enabled];
}

+ (void)setVideoUpscalingEnabled:(BOOL)enabled {
  [SolaraCoreEngine setVideoUpscaling:enabled];
}

+ (void)setVideoUpscalingTestConditions:(NSDictionary<NSString *, NSNumber *> *)conditions {
  [SolaraCoreEngine setVideoUpscalingTestConditions:conditions];
}

+ (NSDictionary<NSString *, id> *)videoUpscalingState {
  return SolaraCoreEngine.videoUpscalingState;
}

+ (void)setSearchEngineName:(NSString *)name {
  gSearchEngineName = name.length ? [name copy] : @"Google";
}

+ (NSInteger)devWindowNumberForBrowser:(int)browserId {
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  SolaraCoreWebView *view = tab ? [SolaraCoreTabs viewForTab:tab] : nil;
  return view.window.windowNumber;
}

+ (NSInteger)devLiveExtensionViews:(NSString *)host {
  NSInteger count = 0;
  for (SolaraCoreWebView *view in LiveViews().allObjects)
    if ([view.extensionHost isEqualToString:host]) count++;
  return count;
}

+ (BOOL)devFocusPageOfBrowser:(int)browserId {
#if DEBUG
  SolaraCoreTab *tab = solaracore_host::TabWithBrowserId(browserId);
  NSWindow *window = tab.view.window;
  NSView *page = nil;
  for (NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:tab.view ?: [NSView new]]; queue.count && !page;) {
    NSView *v = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([NSStringFromClass(v.class) isEqual:@"RenderWidgetHostViewCocoa"]) page = v;
    [queue addObjectsFromArray:v.subviews];
  }
  if (!window || !page) return NO;
  [window makeKeyWindow];
  [window makeFirstResponder:nil];
  return [window makeFirstResponder:page];
#else
  return NO;
#endif
}

- (void)emitNavigation {
  _navigationQueued = NO;
  if (!_tab) return;
  NSString *theme = _pageTheme ?: (_pageScriptGreeted ? _tab.themeColor : nil);
  NSString *themeSource = _pageTheme ? _pageThemeSource : (theme ? @"meta" : nil);
  NSString *url = _tab.url ?: @"";
  if (IsRendererDebugURL(url)) url = _sentNavigation[@"url"] ?: @"";
  [SolaraCoreEarlyWindow page:_tab emitted:url];
  NSDictionary *navigation = @{
        @"url" : url,
        @"title" : ReportedTitle(_tab.title, url, _tab.loading),
        @"canGoBack" : @(_tab.canGoBack),
        @"canGoForward" : @(_tab.canGoForward),
        @"isLoading" : @(_tab.loading),
        @"themeColor" : theme ?: NSNull.null,
        @"themeColorSource" : themeSource ?: NSNull.null,
  };
  if ([_tab respondsToSelector:@selector(initialDocumentAccessed)] && [_tab respondsToSelector:@selector(committedInitial)]) {
    NSMutableDictionary *withInitial = [navigation mutableCopy];
    withInitial[@"initialDocumentAccessed"] = @(_tab.initialDocumentAccessed);
    withInitial[@"committedInitial"] = @(_tab.committedInitial);
    navigation = withInitial;
  }
  if (_crashed && _tab.loading) {
    _crashed = NO;
    NSMutableDictionary *gone = [navigation mutableCopy];
    gone[@"url"] = @"";
    _sentNavigation = gone;
    [self emit:@"navigation" payload:gone];
  }
  if ([navigation isEqualToDictionary:_sentNavigation]) return;
  _sentNavigation = navigation;
  [self emit:@"navigation" payload:navigation];
}

- (void)queueNavigation {
  if (_navigationQueued) return;
  _navigationQueued = YES;
  __weak SolaraCoreWebView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (view && view->_navigationQueued) [view emitNavigation];
  });
}

- (void)tabDidChangeTitle:(SolaraCoreTab *)tab {
  [self queueNavigation];
}

- (void)tabDidChangeURL:(SolaraCoreTab *)tab {
  [self queueNavigation];
  [SolaraCoreEarlyWindow page:tab shownURL:_shownURL];
}

- (void)setShownURL:(NSString *)shownURL {
  _shownURL = [shownURL copy];
  [SolaraCoreEarlyWindow page:_tab shownURL:_shownURL];
}

- (void)tabDidChangeLoading:(SolaraCoreTab *)tab {
  if (!tab.loading && tab.url.length && ![tab.url hasPrefix:@"about:"]) [self revealLittlePage:YES];
  if (tab.loading) [self resetBlocked:YES];
  if (tab.loading) ACFieldMarkNow(_transferKey, @"start");
  [self queueNavigation];
}

- (void)resetBlocked:(BOOL)report {
  _blockedGeneration++;
  _blockedEmitQueued = NO;
  const BOOL had = _blockedCount || _lastBlocked;
  _blockedCount = 0;
  _lastBlocked = nil;
  if (report && had) [self emit:@"contentBlocked" payload:@{@"count" : @0, @"url" : @""}];
}

- (void)tabDidChangeNavigationState:(SolaraCoreTab *)tab {
  [self queueNavigation];
}

- (void)tabDidChangeThemeColor:(SolaraCoreTab *)tab {
  [self queueNavigation];
}

- (void)tabDidCommitDocument:(SolaraCoreTab *)tab {
  ACFieldMarkNow(_transferKey, @"commit");
  [SolaraCoreEarlyWindow pageCommitted:tab shownURL:_shownURL];
  _pageTheme = nil;
  _pageThemeSource = nil;
  _pageScriptGreeted = NO;
  _lastFavicon = nil;
  [self queueNavigation];
}

- (void)tabDidChangeProgress:(SolaraCoreTab *)tab {
  const double progress = tab.progress;
  const CFTimeInterval wait = _sentProgressAt + 0.1 - CACurrentMediaTime();
  if (progress <= 0.1 || progress >= 1 || wait <= 0) return [self sendProgress];
  if (_progressQueued) return;
  _progressQueued = YES;
  __weak SolaraCoreWebView *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (view && view->_progressQueued) [view sendProgress];
  });
}

- (void)sendProgress {
  _progressQueued = NO;
  if (!_tab || _tab.progress == _sentProgress) return;
  _sentProgress = _tab.progress;
  _sentProgressAt = CACurrentMediaTime();
  [self emit:@"progress" payload:@{@"progress" : @(_sentProgress)}];
}

- (void)tab:(SolaraCoreTab *)tab didRequestAppURL:(NSString *)url userGesture:(BOOL)userGesture {
  [self emit:@"openWindow" payload:@{@"url" : url ?: @"", @"disposition" : @"current", @"userGesture" : @(userGesture)}];
}

- (void)tabDidChangeFavicon:(SolaraCoreTab *)tab {
  NSImage *image = tab.favicon;
  if (!image) return;
  NSString *url = tab.faviconURL;
  if (url.length) [SolaraCoreFavicons noteImage:image forURL:url profile:_profile];
  else url = PNGDataURL(image);
  if (!url.length || [url isEqualToString:_lastFavicon]) return;
  _lastFavicon = url;
  [self emit:@"favicon" payload:@{@"url" : url, @"urls" : @[ url ]}];
}

- (void)tab:(SolaraCoreTab *)tab didFindMatches:(int)count active:(int)active final:(BOOL)final {
  [self emit:@"find" payload:@{@"count" : @(count), @"active" : @(active), @"final" : @(final)}];
}

- (void)tab:(SolaraCoreTab *)tab didReceivePageMessage:(NSString *)kind json:(NSString *)json frame:(NSString *)frameId main:(BOOL)main {
  [self tab:tab didReceivePageMessage:kind json:json frame:frameId main:main origin:nil];
}

- (void)tab:(SolaraCoreTab *)tab
    didReceivePageMessage:(NSString *)kind
                     json:(NSString *)json
                    frame:(NSString *)frameId
                     main:(BOOL)main
                   origin:(NSString *)verifiedOrigin {
  NSString *sender = [verifiedOrigin isEqualToString:@"null"] ? nil : verifiedOrigin.length ? verifiedOrigin : main ? OriginOf(tab.url) : nil;
  id data = JSONValue(json);
  NSDictionary *dict = [data isKindOfClass:NSDictionary.class] ? data : nil;
  frameId = frameId ?: @"";
  if ([kind isEqualToString:@"hello"]) {
    PeekTrace(@{@"event" : @"hello", @"main" : @(main), @"frame" : frameId ?: @"", @"url" : Text(dict, @"url", 8192) ?: @""});
    if (main) [self resetPageMedia];
    if (main && !_pageScriptGreeted) {
      _pageScriptGreeted = YES;
      [self queueNavigation];
    }
    if (main && ![(Text(dict, @"url", 8192) ?: @"about:") hasPrefix:@"about:"]) _requestedURL = nil;
    [self noteScriptFrame:frameId main:main];
    [self callFrame:frameId kind:@"peekConfig" json:PeekConfigJSON()];
    AnswerHello(tab, _profile, frameId, main, verifiedOrigin);
    if (main && _littlePageHeld) [self callFrame:frameId kind:@"firstPaint" json:@"{}"];
  } else if ([kind isEqualToString:@"firstPaint"] && main) {
    NSString *url = Text(dict, @"url", 8192);
    if (url.length && ![url hasPrefix:@"about:"] && SamePage(url, tab.url)) [self revealLittlePage:YES];
  } else if ([kind isEqualToString:@"peek"] && dict) {
    [self peekLink:dict frame:frameId main:main];
  } else if ([kind isEqualToString:@"peekHello"]) {
    [self noteScriptFrame:frameId main:main];
    [self callFrame:frameId kind:@"peekConfig" json:PeekConfigJSON()];
  } else if ([kind isEqualToString:@"peekGone"]) {
    [self forgetScriptFrame:frameId];
  } else if ([kind isEqualToString:@"peekTrace"] && dict) {
    PeekTrace(@{@"event" : @"page", @"main" : @(main), @"page" : dict});
  } else if ([kind isEqualToString:@"selection"] && main) {
    [self emit:@"pageMessage" payload:@{@"kind" : @"selection", @"data" : SelectionState(dict) ?: NSNull.null}];
  } else if ([kind isEqualToString:@"linkDrop"] && main) {
    NSString *url = Text(dict, @"url", 8192);
    NSString *scheme = (url.length ? [NSURL URLWithString:url].scheme.lowercaseString : nil) ?: @"";
    const CFTimeInterval now = CACurrentMediaTime();
    const CGEventSourceStateID state = kCGEventSourceStateCombinedSessionState;
    const double sinceUp = CGEventSourceSecondsSinceLastEventType(state, kCGEventLeftMouseUp);
    const BOOL released = !(NSEvent.pressedMouseButtons & 1) && sinceUp < 1 &&
                          sinceUp <= CGEventSourceSecondsSinceLastEventType(state, kCGEventLeftMouseDragged);
    const NSPoint mouse = NSEvent.mouseLocation;
    NSWindow *window = self.window;
    const BOOL over = window && [NSWindow windowNumberAtPoint:mouse belowWindowWithWindowNumber:0] == window.windowNumber &&
                      NSPointInRect([self convertPoint:[window convertPointFromScreen:mouse] fromView:nil], self.bounds);
    if (_visible && [@[ @"http", @"https" ] containsObject:scheme] && released && over && now - _linkDropAt > 1) {
      _linkDropAt = now;
      [self emit:@"openWindow" payload:@{@"url" : url, @"disposition" : @"foreground", @"userGesture" : @YES}];
    }
  } else if ([kind isEqualToString:@"perf"] && main && ACFieldTimingEnabled()) {
    for (NSString *what in @[ @"fcp", @"shown" ]) {
      NSNumber *at = [dict[what] isKindOfClass:NSNumber.class] ? dict[what] : nil;
      if (at && fabs(at.doubleValue - ACFieldNow()) < 600000) ACFieldMark(_transferKey, what, at.doubleValue);
    }
  } else if ([kind isEqualToString:@"scroll"] && main) {
    NSString *state = Text(dict, @"state", 8);
    if ([@[ @"down", @"up", @"top" ] containsObject:state ?: @""])
      [self emit:@"pageMessage" payload:@{@"kind" : @"scroll", @"data" : @{@"state" : state}}];
  } else if ([kind isEqualToString:@"drm"] && dict) {
    [self emit:@"pageMessage" payload:@{@"kind" : @"drm", @"data" : @{@"keySystem" : Text(dict, @"keySystem", 64) ?: @"", @"main" : @(main)}}];
  } else if ([kind isEqualToString:@"nowPlaying"]) {
    if (!_nowPlaying) _nowPlaying = [NSMutableDictionary dictionary];
    if (dict) _nowPlaying[frameId] = NowPlayingState(dict, main);
    else [_nowPlaying removeObjectForKey:frameId];
    _nowPlayingFrame = dict ? frameId : _nowPlaying.allKeys.firstObject;
    NSDictionary<NSString *, NSDictionary *> *frames = _nowPlaying;
    NSInteger (^rank)(NSString *) = ^NSInteger(NSString *f) {
      NSDictionary *np = f ? frames[f] : nil;
      return ([np[@"controllable"] boolValue] ? 4 : 0) + ([np[@"playbackState"] isEqual:@"playing"] ? 2 : 0) + ([np[@"main"] boolValue] ? 1 : 0);
    };
    for (NSString *f in _nowPlaying)
      if (rank(f) > rank(_nowPlayingFrame)) _nowPlayingFrame = f;
    NSMutableDictionary *state = [_nowPlaying[_nowPlayingFrame ?: @""] mutableCopy];
    [state removeObjectsForKeys:@[ @"frame", @"main" ]];
    [self emit:@"nowPlaying" payload:@{@"state" : state ?: NSNull.null}];
  } else if ([kind isEqualToString:@"theme"]) {
    if (!main || !dict) return;
    NSString *color = [dict[@"color"] isKindOfClass:NSString.class] ? Text(dict, @"color", 64) : nil;
    NSString *source = [dict[@"source"] isKindOfClass:NSString.class] ? Text(dict, @"source", 32) : nil;
    _pageTheme = color;
    _pageThemeSource = source;
    [self queueNavigation];
  } else if ([kind isEqualToString:@"pinch"] && main && dict) {
    double scale;
    if (!Finite(dict, @"scale", &scale) || scale <= 0) return;
    _pinchScale = MIN(scale, 100);
    [self emitZoom];
  } else if ([kind isEqualToString:@"pipTrace"]) {
    if (TracingPictureInPicture())
      [_tab tracePictureInPicture:[NSString stringWithFormat:@"page (%@): %@", main ? @"main frame" : @"subframe", JSONString(dict ?: @{})]
                       withInputs:NO];
  } else if ([kind isEqualToString:@"notification"] && dict) {
    PeekTrace(@{@"event" : @"notification", @"bytes" : @(json.length), @"origin" : sender ?: @""});
    NSString *nid = Text(dict, @"id", 128);
    NSString *origin = sender;
    if (!nid.length || !Text(dict, @"title", 1024) || !origin) return;
    NSString *owner = _notificationFrames[nid];
    if (owner && ![owner isEqualToString:frameId]) return;
    if (!_notificationFrames || _notificationFrames.count > 500) _notificationFrames = [NSMutableDictionary dictionary];
    _notificationFrames[nid] = frameId;
    NSDictionary *notification = @{
      @"id" : nid,
      @"title" : Text(dict, @"title", 1024),
      @"body" : Text(dict, @"body", 4096) ?: @"",
      @"icon" : Text(dict, @"icon", 1 << 20) ?: NSNull.null,
      @"tag" : Text(dict, @"tag", 1024) ?: @"",
      @"silent" : @(Flag(dict, @"silent")),
      @"requireInteraction" : @(Flag(dict, @"requireInteraction")),
      @"origin" : origin,
      @"browserId" : @(solaracore_host::BrowserId(tab)),
      @"isMainFrame" : @(main),
    };
    __weak SolaraCoreWebView *weakSelf = self;
    [SolaraCoreServices siteSettings:_profile ?: @"" origin:origin completion:^(NSDictionary *settings) {
      SolaraCoreWebView *view = weakSelf;
      if (!view || ![view->_notificationFrames[nid] isEqualToString:frameId]) return;
      NSDictionary *permission = [settings[@"notifications"] isKindOfClass:NSDictionary.class] ? settings[@"notifications"] : nil;
      if ([permission[@"value"] isEqual:@"allow"]) [view emit:@"notification" payload:notification];
      else [view notificationAction:nid action:@"close"];
    }];
  } else if ([kind isEqualToString:@"notificationClose"] && dict) {
    NSString *nid = Text(dict, @"id", 128);
    if (!nid.length || ![_notificationFrames[nid] isEqualToString:frameId]) return;
    [_notificationFrames removeObjectForKey:nid];
    [self emit:@"notificationClose" payload:@{@"id" : nid}];
  } else if ([kind isEqualToString:@"displayMedia"] && dict) {
    double pageId;
    if (!Finite(dict, @"id", &pageId) || pageId < 1 || pageId > INT_MAX || pageId != floor(pageId) || !sender) return;
    if (!_displayRequests) _displayRequests = [NSMutableDictionary dictionary];
    if (_displayRequests.count >= 16) return;
    NSString *requestId = NSUUID.UUID.UUIDString;
    NSDictionary *audio = DisplayMediaAudioOffer(dict);
    _displayRequests[requestId] = @{@"frame" : frameId, @"id" : @((int)pageId), @"audio" : audio ?: NSNull.null, @"origin" : sender};
    [self emit:@"displayMediaRequest"
        payload:@{
          @"id" : requestId,
          @"origin" : OriginOf(tab.url) ?: sender,
          @"frameOrigin" : sender,
          @"audio" : audio ?: NSNull.null,
          @"sources" : SolaraCoreHost.displayMediaSources
        }];
  }
}

- (void)tab:(SolaraCoreTab *)tab didReceivePageMessage:(NSString *)kind json:(NSString *)json {
  [self tab:tab didReceivePageMessage:kind json:json frame:@"" main:YES];
}

static NSMutableOrderedSet<NSString *> *ScriptFramesOf(SolaraCoreTab *tab) {
  if (!tab) return nil;
  NSMutableOrderedSet *frames = objc_getAssociatedObject(tab, &kScriptFramesKey);
  if (!frames) {
    frames = [NSMutableOrderedSet orderedSet];
    objc_setAssociatedObject(tab, &kScriptFramesKey, frames, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return frames;
}

- (void)noteScriptFrame:(NSString *)frameId main:(BOOL)main {
  InstallPeekMonitor();
  NSMutableOrderedSet<NSString *> *frames = ScriptFramesOf(_tab);
  if (!frames || !frameId.length) return;
  [frames removeObject:frameId];
  [frames addObject:frameId];
  while (frames.count > 512) [frames removeObjectAtIndex:0];
}

- (void)forgetScriptFrame:(NSString *)frameId {
  if (frameId.length) [ScriptFramesOf(_tab) removeObject:frameId];
}

- (void)pushSelectionPopover {
  if (_tab) [self callFrame:@"" kind:@"selectionPopover" json:gSelectionPopover ? @"true" : @"false"];
}

- (void)pushPeekModifier {
  if (!_tab) return;
  NSString *json = PeekConfigJSON();
  [self callFrame:@"" kind:@"peekConfig" json:json];
  for (NSString *frameId in [ScriptFramesOf(_tab) copy]) [self callFrame:frameId kind:@"peekConfig" json:json];
}

static NSEventModifierFlags LinkKeyFlags(NSString *key) {
  static NSDictionary<NSString *, NSNumber *> *flags = @{
    @"alt" : @(NSEventModifierFlagOption),
    @"shift" : @(NSEventModifierFlagShift),
    @"altShift" : @(NSEventModifierFlagOption | NSEventModifierFlagShift),
    @"altMeta" : @(NSEventModifierFlagOption | NSEventModifierFlagCommand),
  };
  return key.length ? flags[key].unsignedIntegerValue : 0;
}

static NSString *LinkKeyAction(NSString *key) {
  if (!LinkKeyFlags(key)) return nil;
  if ([key isEqualToString:gPeekModifier]) return @"peek";
  if ([key isEqualToString:@"altShift"] || [key isEqualToString:@"altMeta"] || [key isEqualToString:SplitLinkModifier()]) return @"split";
  return nil;
}

- (void)fallBackFromPeek:(NSDictionary *)dict url:(NSString *)url frame:(NSString *)frameId reason:(NSString *)reason test:(BOOL)test {
  NSString *key = Text(dict, @"key", 8) ?: @"";
  const NSEventModifierFlags pageFlag = LinkKeyFlags(key);
  const BOOL split = [LinkKeyAction(key) isEqualToString:@"split"];
  NSString *scheme = (url.length ? [NSURL URLWithString:url].scheme.lowercaseString : nil) ?: @"";
  const BOOL fresh = gPeekUpAt >= 0 && CACurrentMediaTime() - gPeekUpAt <= kPeekFallbackLifetime && !gPeekPressedSinceUp;
  const BOOL userClicked = test || (fresh && gPeekUpSeq != gPeekUsedSeq && gPeekUpView == self && gPeekUpKeys == pageFlag);
  const BOOL fallsBack = !split && pageFlag && [@[ @"http", @"https" ] containsObject:scheme] && userClicked;
  NSString *origin = Text(dict, @"origin", 1024).lowercaseString;
  const BOOL sameOrigin = origin.length && [OriginOf(url).lowercaseString isEqualToString:origin];
  NSString *action = !fallsBack ? @"none" : pageFlag == NSEventModifierFlagShift ? @"new window" : sameOrigin ? @"page download" : @"background tab";
  PeekTrace(@{@"event" : @"fallback", @"url" : url ?: @"", @"key" : key, @"reason" : reason, @"userClicked" : @(userClicked), @"split" : @(split), @"action" : action});
  if (split && userClicked && !test) gPeekUsedSeq = gPeekUpSeq;
  if (!fallsBack) return;
  if (!test) gPeekUsedSeq = gPeekUpSeq;
  if (pageFlag == NSEventModifierFlagShift) return [self emit:@"openWindow" payload:@{@"url" : url, @"disposition" : @"window", @"userGesture" : @YES}];
  if (sameOrigin) return [self callFrame:frameId kind:@"peekRefused" json:JSONString(@{@"url" : url, @"reason" : reason, @"download" : @YES})];
  [self emit:@"openWindow" payload:@{@"url" : url, @"disposition" : @"background", @"userGesture" : @YES}];
}

- (void)peekLink:(NSDictionary *)dict frame:(NSString *)frameId main:(BOOL)main {
  NSString *url = Text(dict, @"url", 8192);
  NSString *scheme = (url.length ? [NSURL URLWithString:url].scheme.lowercaseString : nil) ?: @"";
  NSWindow *window = self.window;
  NSString *key = Text(dict, @"key", 8);
  const NSEventModifierFlags flag = LinkKeyFlags(key);
  NSString *action = LinkKeyAction(key);
  const CFTimeInterval sinceUp = gPeekUpAt < 0 ? -1 : CACurrentMediaTime() - gPeekUpAt;
  static const BOOL strict = getenv("SOLARA_PEEK_STRICT") != nullptr;
  const BOOL test = PeekTestHooks() && !strict;
  NSString *refused = nil;
  if (!action) refused = @"that key opens nothing now";
  else if (!_visible || !window) refused = @"page not shown";
  else if (![@[ @"http", @"https" ] containsObject:scheme]) refused = @"not http(s)";
  else if (!test && gPeekUpAt < 0) refused = @"no left mouse-up yet";
  else if (!test && gPeekUpSeq == gPeekUsedSeq) refused = @"that mouse-up already opened a peek";
  else if (!test && gPeekPressedSinceUp) refused = @"the mouse was pressed again since that mouse-up";
  else if (!test && sinceUp > kPeekGestureLifetime) refused = @"the last mouse-up is too old";
  else if (!test && gPeekUpView != self) refused = @"the mouse-up wasn't over this page";
  else if (!test && gPeekUpKeys != flag) refused = @"the mouse-up's keys aren't the page's key alone";
  PeekTrace(@{
    @"event" : @"peek",
    @"url" : url ?: @"",
    @"main" : @(main),
    @"chosen" : gPeekModifier,
    @"split" : SplitLinkModifier(),
    @"key" : key ?: NSNull.null,
    @"action" : action ?: NSNull.null,
    @"refused" : refused ?: NSNull.null,
    @"mouseUpKeys" : PeekKeyNames(gPeekUpKeys),
    @"sinceMouseUp" : @(sinceUp),
    @"pressedSince" : @(gPeekPressedSinceUp),
    @"mouseUpOverThisPage" : @(gPeekUpView == self),
    @"mouseUpPage" : gPeekUpView.transferKey ?: NSNull.null,
    @"thisPage" : _transferKey ?: NSNull.null,
    @"keysNow" : PeekKeyNames(NSEvent.modifierFlags & kPeekKeyMask),
    @"buttonsNow" : @(NSEvent.pressedMouseButtons),
    @"moved" : [dict[@"moved"] isKindOfClass:NSNumber.class] ? dict[@"moved"] : NSNull.null,
    @"testInstance" : @(test),
  });
  if (refused) return [self fallBackFromPeek:dict url:url frame:frameId reason:refused test:test];
  if (!test) gPeekUsedSeq = gPeekUpSeq;
  if ([action isEqualToString:@"split"]) return [self emit:@"openWindow" payload:@{@"url" : url, @"disposition" : @"split", @"userGesture" : @YES}];
  double x, y;
  NSPoint point;
  if (main && Finite(dict, @"x", &x) && Finite(dict, @"y", &y)) {
    const CGFloat scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 1;
    point = NSMakePoint(x / scale, y / scale);
  } else {
    point = [self convertPoint:[window convertPointFromScreen:NSEvent.mouseLocation] fromView:nil];
  }
  point.x = MIN(MAX(point.x, 0), NSWidth(self.bounds));
  point.y = MIN(MAX(point.y, 0), NSHeight(self.bounds));
  const NSPoint inWindow = [self convertPoint:point toView:nil];
  const CGFloat top = window.contentView.frame.size.height - inWindow.y;
  [self emit:@"openWindow"
      payload:@{@"url" : url, @"disposition" : @"peek", @"userGesture" : @YES, @"point" : @{@"x" : @(inWindow.x), @"y" : @(top)}}];
}

- (void)callFrame:(NSString *)frameId kind:(NSString *)kind json:(NSString *)json {
  if (frameId.length) [_tab callFrame:frameId kind:kind json:json];
  else [_tab callPage:kind json:json];
}

- (void)emitMedia {
  const BOOL playing = _tab.audible;
  const BOOL muted = _tab ? _tab.muted : _muted;
  [self emit:@"media" payload:@{@"playing" : @(playing), @"muted" : @(muted)}];
}

- (void)emitZoom {
  const double zoom = _tab ? _tab.zoomFactor : 1;
  [self emit:@"zoom"
      payload:@{
        @"zoom" : @(round(zoom * 100) / 100),
        @"host" : [NSURL URLWithString:_tab.url ?: @""].host.lowercaseString ?: @"",
        @"isDefault" : @(fabs(zoom - 1) < 0.001),
        @"pinchScale" : @(_pinchScale ?: 1),
      }];
}

- (void)tabDidChangeZoom:(SolaraCoreTab *)tab {
  [self emitZoom];
}

- (void)tabDidChangeSecurity:(SolaraCoreTab *)tab {
  if (NSDictionary *info = tab.securityInfo) [self emit:@"security" payload:info];
}

- (void)tabWillClose:(SolaraCoreTab *)tab {
  [SolaraCoreEarlyWindow dropPage:tab];
  if (_closing || tab != _tab) return;
  const BOOL withWindow = [tab respondsToSelector:@selector(closingWithWindow)] && tab.closingWithWindow;
  [self detach];
  [self emit:@"windowClose" payload:withWindow ? @{@"withWindow" : @YES} : @{}];
}

- (void)resetPageMedia {
  const BOOL hadNowPlaying = _nowPlaying.count > 0;
  [_nowPlaying removeAllObjects];
  _nowPlayingFrame = nil;
  if (hadNowPlaying) [self emit:@"nowPlaying" payload:@{@"state" : NSNull.null}];
}

- (void)tab:(SolaraCoreTab *)tab rendererGone:(NSString *)status code:(int)code {
  _crashed = YES;
  [self resetPageMedia];
  [self emit:@"crashed" payload:@{@"status" : @(code), @"reason" : status ?: @"unknown", @"code" : @(code)}];
}

- (void)tab:(SolaraCoreTab *)tab didFailLoad:(NSString *)url code:(int)code description:(NSString *)text {
  [self emit:@"loadError" payload:@{@"url" : url ?: @"", @"code" : @(code), @"text" : text ?: @""}];
}

- (void)tab:(SolaraCoreTab *)tab didChangeStatusText:(NSString *)text {
  [self emit:@"status" payload:@{@"text" : text ?: @""}];
}

- (void)tabDidGainFocus:(SolaraCoreTab *)tab {
  [self emit:@"focus" payload:@{}];
}

- (void)tabDidChangeAudio:(SolaraCoreTab *)tab {
  [self emitMedia];
}

- (void)loadURL:(NSString *)url {
  [self loadURL:url userInitiated:NO];
}

- (void)loadURL:(NSString *)url userInitiated:(BOOL)userInitiated {
  if (!url.length) return;
  NSString *transferred = _transferredURL;
  _transferredURL = nil;
  NSString *creating = _creatingURL;
  _creatingURL = nil;
  if (_tab && SamePage(url, transferred)) return;
  if ((_tab || _creating) && [url isEqualToString:creating] && CACurrentMediaTime() - _creatingAt < 2) return;
  if (_tab) return [self loadNow:url userInitiated:userInitiated];
  _pendingURL = url;
  _pendingUserInitiated = userInitiated;
  if (self.window) [self ensureTab];
}

- (void)loadNow:(NSString *)url userInitiated:(BOOL)userInitiated {
  if ([self skipsNavigationDownload:url userInitiated:userInitiated]) return;
  if (url.length && ![url hasPrefix:@"about:"]) [self holdLittlePage];
  ACFieldMarkNow(_transferKey, @"request");
  [_tab loadURL:url userInitiated:userInitiated];
  [self focusAfterLoad];
}

- (void)focusAfterLoad {
  if (_visible && _tab) [self focusPage];
}

- (BOOL)skipsNavigationDownload:(NSString *)url userInitiated:(BOOL)userInitiated {
  const BOOL first = !_loadedOnce;
  _loadedOnce = YES;
  _pendingUserInitiated = NO;
  if (first && !userInitiated && solaracore_host::WasNavigationDownload(url, _profile)) {
    __weak SolaraCoreWebView *weakSelf = self;
    NSDictionary *payload = @{@"url" : url ?: @"", @"committedUrl" : @"", @"skipped" : @YES};
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf emit:@"downloadNavigation" payload:payload]; });
    return YES;
  }
  _requestedURL = url;
  return NO;
}

- (void)goBack {
  [_tab goBack];
}

- (void)goForward {
  [_tab goForward];
}

- (void)goToHistoryOffset:(NSInteger)offset {
  [_tab goToOffset:(int)offset];
}

- (void)reload {
  [_tab reload];
}

- (void)reloadIgnoringCache {
  [_tab reloadIgnoringCache];
}

- (void)stopLoading {
  [_tab stop];
}

- (void)focusPage {
  if ([SolaraCoreEarlyWindow veils:_tab]) return [SolaraCoreEarlyWindow requestFocus:_tab];
  [_tab focus];
}

- (void)setMuted:(BOOL)muted {
  _muted = muted;
  _tab.muted = muted;
}

- (void)setZoomFactor:(double)factor {
  _tab.zoomFactor = factor;
}

- (void)zoomStep:(NSInteger)direction {
  [_tab zoomStep:(int)direction];
}

- (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext {
  [_tab find:text forward:forward];
}

- (void)stopFinding:(BOOL)clearSelection {
  [_tab stopFinding];
}

- (void)print {
  [self runChromeCommand:35003];
}

- (void)runChromeCommand:(int)command {
  [_tab executeChromeCommand:command];
}

- (void)showDevTools {
  [_tab showDevTools];
}

- (void)toggleDevToolsPanel:(NSString *)panel {
  const BOOL network = [panel isEqualToString:@"network"];
  if (!network && ![panel isEqualToString:@"console"] && ![panel isEqualToString:@"elements"]) return;
  if (_devtoolsView && [_devToolsPanel isEqualToString:panel]) {
    _devToolsPanel = nil;
    _devToolsReopen = nil;
    [_tab closeDevTools];
    return;
  }
  if (_devtoolsView && network) return;
  if (_devtoolsView) {
    _devToolsReopen = [panel copy];
    [_tab closeDevTools];
    __weak SolaraCoreWebView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf reopenDevToolsPanel];
    });
    return;
  }
  [self openDevToolsPanel:panel];
}

- (void)reopenDevToolsPanel {
  NSString *panel = _devToolsReopen;
  _devToolsReopen = nil;
  if (panel && !_devtoolsView) [self openDevToolsPanel:panel];
}

- (void)openDevToolsPanel:(NSString *)panel {
  _devToolsPanel = [panel copy];
  if ([panel isEqualToString:@"console"]) [self runChromeCommand:40005];
  else if ([panel isEqualToString:@"elements"]) [self runChromeCommand:40023];
  else [_tab showDevTools];
}

- (void)showDevToolsPanel:(NSString *)panel {
  if ([panel hasPrefix:@"toggle:"]) return [self toggleDevToolsPanel:[panel substringFromIndex:7]];
  const int command = [panel isEqualToString:@"console"]   ? 40005
                      : [panel isEqualToString:@"inspect"] ? 40023
                      : [panel isEqualToString:@"toggle"]  ? 40237
                                                           : 0;
  if (command && _tab) [self runChromeCommand:command];
  else [_tab showDevTools];
}

- (void)runPageCommand:(NSString *)name {
  const int command = [name isEqualToString:@"savePage"]        ? 35004
                      : [name isEqualToString:@"systemPrint"]   ? 35007
                      : [name isEqualToString:@"caretBrowsing"] ? 40260
                                                                : 0;
  if (command) [self runChromeCommand:command];
}

- (void)executeJavaScript:(NSString *)code {
  [_tab executeJavaScript:code];
}

- (void)thawHiddenPage {
  if (!_visible && !_frozen) _tab.frozen = NO;
}

- (void)evaluate:(NSString *)code completion:(void (^)(NSString *))completion {
  if (!_tab) return completion(nil);
  [self thawHiddenPage];
  [_tab evaluate:code completion:completion];
}

- (void)capturePicture:(double)scale completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  NSWindow *window = self.window;
  if (!_tab || !window || self.hidden) return completion(nil);
  NSRect inWindow = [self convertRect:self.bounds toView:nil];
  CGFloat top = NSHeight(window.contentView.frame);
  NSArray *frame = @[ @(NSMinX(inWindow)), @(top - NSMaxY(inWindow)), @(NSWidth(inWindow)), @(NSHeight(inWindow)) ];
  __block BOOL answered = NO;
  void (^answer)(NSDictionary *) = ^(NSDictionary *result) {
    if (answered) return;
    answered = YES;
    completion(result);
  };
  NSDictionary *params = @{@"format" : @"jpeg", @"quality" : @(scale < 0.5 ? 55 : 75), @"optimizeForSpeed" : @YES};
  void (^done)(NSDictionary *, NSString *) = ^(NSDictionary *shot, NSString *error) {
    NSString *data = shot[@"data"];
    answer([data isKindOfClass:NSString.class] ? @{@"data" : data, @"frame" : frame} : nil);
  };
  [_tab devToolsCall:@"Page.captureScreenshot" params:params timeout:1.0 completion:done];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ answer(nil); });
}

- (void)navigationEntries:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completion {
  completion(_tab ? _tab.navigationEntries : @[]);
}

- (void)downloadFavicon:(NSString *)url name:(NSString *)name completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [SolaraCoreFavicons fetch:url profile:_profile name:name completion:completion];
}

- (void)downloadImage:(NSString *)url maxPixels:(NSInteger)maxPixels completion:(void (^)(NSDictionary<NSString *, id> *))completion {
  [SolaraCoreFavicons fetch:url profile:_profile name:nil completion:completion];
}

- (void)mediaCommand:(NSString *)action seconds:(double)seconds {
  [self thawHiddenPage];
  [self callFrame:_nowPlayingFrame ?: @"" kind:@"media" json:JSONString(@{@"action" : action ?: @"", @"seconds" : @(seconds)})];
}

- (BOOL)takeControlPressAt:(double)clickMs control:(NSInteger)target {
  const BOOL taken = TakeControlPress(clickMs, target, self.window) > 0;
  [self traceManualPictureInPicture:[NSString stringWithFormat:@"exit press %@ (control %ld)", taken ? @"verified" : @"not verified", (long)target]];
  return taken;
}

- (void)requestPictureInPictureForClickAt:(double)clickMs control:(NSInteger)target completion:(void (^)(BOOL))completion {
  if (_inPictureInPicture) return completion(YES);
  if (![_tab respondsToSelector:@selector(enterPictureInPictureForClickAt:completion:)]) return completion(NO);
  const NSTimeInterval clickAt = TakeControlPress(clickMs, target, self.window);
  [self traceManualPictureInPicture:[NSString stringWithFormat:@"%@ %@ (control %ld)", clickMs > 0 ? @"click" : @"key or accessibility press", clickAt > 0 ? @"verified" : @"not verified", (long)target]];
  if (clickAt <= 0) return completion(NO);
  [self thawHiddenPage];
  __weak SolaraCoreWebView *weakSelf = self;
  [_tab enterPictureInPictureForClickAt:clickAt
                             completion:^(NSString *route, BOOL opened) {
                               SolaraCoreWebView *view = weakSelf;
                               if (!view) return completion(NO);
                               [view traceManualPictureInPicture:[NSString stringWithFormat:@"route %@ opened=%d", route, opened]];
                               if (![route isEqualToString:@"session"]) return completion(opened || view->_inPictureInPicture);
                               [view awaitPictureInPicture:8 completion:completion];
                             }];
}

- (void)awaitPictureInPicture:(int)tries completion:(void (^)(BOOL))completion {
  if (_inPictureInPicture || tries <= 0) return completion(_inPictureInPicture);
  __weak SolaraCoreWebView *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (!view) return completion(NO);
    [view awaitPictureInPicture:tries - 1 completion:completion];
  });
}

- (void)updateAutoPictureInPicture {
  if (!_tab) return;
  NSDictionary *np = _nowPlaying[_nowPlayingFrame ?: @""];
  const BOOL playing = [np[@"playbackState"] isEqual:@"playing"] || _capturing;
  if (!_seenByUser && _autoPictureInPicture && playing) {
    [self traceAutoPictureInPicture:@"app: auto PiP left to Chrome"];
  } else if (_seenByUser && (_autoPictureInPictureActive || _inPictureInPicture)) {
    _autoPictureInPictureActive = NO;
    [self exitPictureInPicture];
  }
}

- (void)exitPictureInPicture {
  if ([_tab respondsToSelector:@selector(exitPictureInPicture)]) return [_tab exitPictureInPicture];
  [self executeJavaScript:@"document.pictureInPictureElement && document.exitPictureInPicture();"
                           "window.documentPictureInPicture && documentPictureInPicture.window && documentPictureInPicture.window.close()"];
}

- (void)securityInfo:(void (^)(NSDictionary<NSString *, id> *))completion {
  if (_tab.securityInfo) return completion(_tab.securityInfo);
  NSString *url = _tab.url ?: @"";
  NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
  NSString *level = [scheme isEqualToString:@"https"] ? @"secure" : [scheme isEqualToString:@"http"] ? @"insecure" : @"local";
  completion(@{@"level" : level, @"url" : url, @"origin" : NSNull.null});
}

- (void)pageCookies:(NSArray<NSString *> *)urls completion:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completion {
  if (!_tab || _tab.closed || !urls.count) return completion(nil);
  __block BOOL answered = NO;
  void (^answer)(NSArray *) = ^(NSArray *cookies) {
    if (answered) return;
    answered = YES;
    completion(cookies);
  };
  void (^done)(NSDictionary *, NSString *) = ^(NSDictionary *result, NSString *error) {
    NSArray *cookies = result[@"cookies"];
    answer([cookies isKindOfClass:NSArray.class] ? cookies : nil);
  };
  [_tab devToolsCall:@"Network.getCookies" params:@{@"urls" : urls} timeout:1.0 completion:done];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ answer(nil); });
}

- (void)openBlockedPopup:(NSString *)popupId always:(BOOL)always {
  [_tab openBlockedPopup:popupId always:always];
}

- (void)tab:(SolaraCoreTab *)tab didBlockRequests:(int)count lastURL:(NSString *)url {
  if (tab != _tab) return;
  _blockedCount += count;
  _lastBlocked = url;
  if (_blockedEmitQueued) return;
  _blockedEmitQueued = YES;
  __weak SolaraCoreWebView *weakSelf = self;
  const NSUInteger generation = _blockedGeneration;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    SolaraCoreWebView *view = weakSelf;
    if (!view || view->_blockedGeneration != generation || !view->_tab) return;
    view->_blockedEmitQueued = NO;
    [view emit:@"contentBlocked" payload:@{@"count" : @(view->_blockedCount), @"url" : view->_lastBlocked ?: @""}];
  });
}

- (void)tab:(SolaraCoreTab *)tab didBlockPopup:(NSDictionary<NSString *, NSString *> *)popup {
  [self emit:@"popupBlocked" payload:popup];
}

- (void)tab:(SolaraCoreTab *)tab preferredSizeDidChange:(NSSize)size {
  [self emit:@"preferredSize" payload:@{@"width" : @(size.width), @"height" : @(size.height)}];
}

- (void)clearSiteData:(void (^)(NSDictionary<NSString *, id> *))completion {
  NSString *origin = OriginOf(_tab.url);
  if (!origin) return completion(@{@"cookies" : @NO, @"storage" : @NO});
  [SolaraCoreServices clearSiteData:_profile origin:origin completion:completion];
}

- (void)resolvePasswordPrompt:(NSString *)action username:(NSString *)username password:(NSString *)password {
  [solaracore_host::PasswordPromptTab(self, _tab) resolvePasswordPrompt:action username:username password:password];
}

- (void)resolveAutofillPrompt:(NSInteger)promptId action:(NSString *)action {
  [_tab resolveAutofillPrompt:promptId action:action];
}

- (NSString *)executeExtensionAction:(NSString *)extensionId {
  return [_tab executeExtensionAction:extensionId];
}

- (void)resolveDisplayMedia:(NSString *)requestId sourceId:(NSString *)sourceId audio:(BOOL)shareAudio {
  NSDictionary *request = requestId ? _displayRequests[requestId] : nil;
  if (!request) return;
  [_displayRequests removeObjectForKey:requestId];
  NSString *audio = shareAudio && sourceId.length ? DisplayMediaAudioFor(Field<NSDictionary>(request, @"audio"), sourceId) : nil;
  if (sourceId.length && _tab && [SolaraCoreEngine respondsToSelector:@selector(allowDesktopCapture:tab:frame:origin:audio:)])
    [SolaraCoreEngine allowDesktopCapture:sourceId
                                  tab:_tab
                                frame:[request[@"frame"] length] ? request[@"frame"] : nil
                               origin:request[@"origin"]
                                audio:audio];
  [self callFrame:request[@"frame"] kind:@"displayMedia"
             json:JSONString(@{@"id" : request[@"id"], @"sourceId" : sourceId.length ? sourceId : NSNull.null, @"audio" : @(audio != nil)})];
}

- (NSString *)mediaCaptureSourceId {
  return _tab.mediaCaptureSourceId;
}

- (void)tab:(SolaraCoreTab *)tab navigationBecameDownload:(NSString *)url {
  solaracore_host::NoteNavigationDownload(url, _profile);
  if (_requestedURL && ![_requestedURL isEqualToString:url]) solaracore_host::NoteNavigationDownload(_requestedURL, _profile);
  _requestedURL = nil;
  [self emit:@"downloadNavigation" payload:@{@"url" : url ?: @"", @"committedUrl" : tab.url ?: @"", @"skipped" : @NO}];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)tab:(SolaraCoreTab *)tab
                           contextMenuItemsForSelection:(NSString *)text {
  return @[ @{
    @"id" : @"search",
    @"title" : [NSString stringWithFormat:@"Search %@ for “%@”", gSearchEngineName, SelectionLabel(text)],
    @"replaces" : @"search",
  } ];
}

- (void)tab:(SolaraCoreTab *)tab
    contextMenuCommand:(NSString *)itemId
                  text:(NSString *)selection
             modifiers:(NSDictionary<NSString *, NSNumber *> *)modifiers {
  if ([itemId isEqualToString:@"search"])
    [self emit:@"command" payload:@{@"command" : @"search", @"text" : selection ?: @"", @"modifiers" : modifiers ?: @{}}];
}

- (void)tab:(SolaraCoreTab *)tab didShowAutofillSuggestions:(NSArray<NSDictionary<NSString *, NSString *> *> *)items {
  NoteEvent(solaracore_host::BrowserId(tab), @"autofillSuggestions", @{@"items" : items ?: @[]});
}

- (void)tab:(SolaraCoreTab *)tab didShowContextMenu:(NSArray<NSDictionary *> *)items {
  [self tab:tab runContextMenu:@{@"items" : items ?: @[]}];
}

- (NSDictionary<NSString *, id> *)tab:(SolaraCoreTab *)tab runContextMenu:(NSDictionary<NSString *, id> *)menu {
  NSArray *items = Field<NSArray>(menu, @"items") ?: @[];
  NoteEvent(solaracore_host::BrowserId(tab), @"contextMenu", @{@"items" : items});
  static const char *log = getenv("SOLARA_CONTEXT_MENU_LOG");
  if (!log) {
    if (solaracore_host::Background()) {
      NSMutableArray<NSString *> *titles = [NSMutableArray array];
      for (NSDictionary *item in items)
        if (MenuItemType(item) != kMenuSeparator && Field<NSString>(item, @"label").length) [titles addObject:MenuTitle(item[@"label"])];
      solaracore_host::LogActivation([NSString stringWithFormat:@"context menu (not shown): %@", [titles componentsJoinedByString:@" | "]]);
    }
    return nil;
  }
  NSString *path = @(log), *pickPath = [path stringByAppendingString:@".pick"];
  NSDictionary *dump = @{
    @"url" : Field<NSString>(menu, @"url") ?: tab.url ?: @"",
    @"link" : Field<NSString>(menu, @"link") ?: @"",
    @"items" : DescribeMenu(items),
  };
  [JSONString(dump) writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  NSString *pick = [NSString stringWithContentsOfFile:pickPath encoding:NSUTF8StringEncoding error:nil];
  [NSFileManager.defaultManager removeItemAtPath:pickPath error:nil];
  pick = [pick stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSArray<NSString *> *parts = [pick componentsSeparatedByString:@"\t"];
  NSDictionary *found = pick.length ? FindMenuItem(items, parts[0]) : nil;
  if (!found) return nil;
  return @{@"command" : found[@"command"], @"path" : found[@"path"], @"flags" : @(parts.count > 1 ? parts[1].intValue : 0)};
}

- (void)tab:(SolaraCoreTab *)tab didChangePictureInPicture:(NSDictionary<NSString *, id> *)state {
  if (![state[@"kind"] isEqual:@"document"]) {
    const BOOL active = [state[@"active"] boolValue];
    if (!active && !_inPictureInPicture) return;
    _inPictureInPicture = active;
    [self emit:@"pictureInPicture" payload:@{@"kind" : @"video", @"active" : @(active)}];
    if (!active) return;
    solaracore_pip::WatchZoom();
    solaracore_pip::VideoEntered(self, [NSURL URLWithString:tab.url ?: @""].host ?: @"");
    return;
  }
  _inPictureInPicture = [state[@"active"] boolValue];
  [self emit:@"pictureInPicture" payload:@{@"kind" : @"document", @"active" : @([state[@"active"] boolValue])}];
}

- (void)tab:(SolaraCoreTab *)tab requestsActivation:(NSString *)reason {
  solaracore_pip::TabRequestedActivation(self);
  [self emit:@"activateRequest" payload:@{@"reason" : reason ?: @"page"}];
}

- (void)notificationAction:(NSString *)notificationId action:(NSString *)action {
  NSString *frame = notificationId ? _notificationFrames[notificationId] : nil;
  if (!frame) return;
  if (![action isEqualToString:@"click"]) [_notificationFrames removeObjectForKey:notificationId];
  [self callFrame:frame kind:@"notification" json:JSONString(@{@"id" : notificationId, @"action" : action ?: @""})];
}

- (void)resolveUnresponsive:(BOOL)terminate {
  [_tab resolveUnresponsive:terminate];
}

- (NSString *)discard:(BOOL)unload {
  if (unload) return @"unsupported";
  if (!_tab) return @"refused";
  if (_tab.discarded) return @"already";
  return [_tab discard] && _tab.discarded ? @"discarded" : @"refused";
}

- (BOOL)discarded {
  return _tab.discarded;
}

- (void)tabDidChangeDiscarded:(SolaraCoreTab *)tab {
  if (tab.discarded) [self emit:@"discarded" payload:@{@"url" : tab.url ?: @""}];
  else [self emit:@"ready" payload:@{@"browserId" : @(solaracore_host::BrowserId(tab)), @"tabId" : @(tab.tabId)}];
}

- (void)tabBecameUnresponsive:(SolaraCoreTab *)tab {
  [self emit:@"unresponsive" payload:@{}];
}

- (void)tabBecameResponsive:(SolaraCoreTab *)tab {
  [self emit:@"responsive" payload:@{}];
}

- (void)tab:(SolaraCoreTab *)tab didChangeMediaAccess:(NSDictionary<NSString *, NSNumber *> *)access {
  _capturing = [access[@"camera"] boolValue] || [access[@"microphone"] boolValue] || [access[@"screen"] boolValue];
  [self emit:@"mediaAccess" payload:access ?: @{}];
}

- (void)tab:(SolaraCoreTab *)tab externalAppRequest:(NSDictionary<NSString *, id> *)request {
  [self emit:@"externalApp" payload:request ?: @{}];
}

namespace {

constexpr NSTimeInterval kSwitchPrewarmGapSeconds = 0.1;

bool SwitchPrewarmOff() {
  const char *value = getenv("SOLARA_SWITCH_PREWARM");
  return value && (!strcmp(value, "off") || !strcmp(value, "0") || !strcmp(value, "false"));
}

}

- (BOOL)canWakeFrames {
  if (!_tab || !_visible || _frozen || _tab.closed || _tab.discarded || self.isHiddenOrHasHiddenAncestor) return NO;
  NSString *url = _tab.url;
  return [url hasPrefix:@"https:"] || [url hasPrefix:@"http:"] || [url hasPrefix:@"file:"];
}

+ (BOOL)prewarmForMouseEvent:(NSEvent *)event {
  static NSMapTable<id, NSNumber *> *lastByDisplay = [NSMapTable weakToStrongObjectsMapTable];
  NSWindow *window = event.window;
  if (!window) return NO;
  id display = window.screen ?: NSNull.null;
  if (event.timestamp - [lastByDisplay objectForKey:display].doubleValue < kSwitchPrewarmGapSeconds) return NO;
  const NSPoint point = event.locationInWindow;
  SolaraCoreWebView *target = nil;
  for (SolaraCoreWebView *view in LiveViews()) {
    if (view.window != window || view.isHiddenOrHasHiddenAncestor) continue;
    if (NSPointInRect(point, [view convertRect:view.bounds toView:nil])) return NO;
    if (!target && view.canWakeFrames) target = view;
  }
  if (target) {
    [target callFrame:@"" kind:@"wakeFrames" json:@"{}"];
    [lastByDisplay setObject:@(event.timestamp) forKey:display];
    return YES;
  }
  return NO;
}

+ (void)installSwitchPrewarm {
  static id monitor;
  if (monitor || SwitchPrewarmOff()) return;
  monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *event) {
    [SolaraCoreWebView prewarmForMouseEvent:event];
    return event;
  }];
}

@end

namespace {

NSMapTable<SolaraCoreTab *, SolaraCoreWebView *> *Views() {
  static NSMapTable *views = [NSMapTable weakToWeakObjectsMapTable];
  return views;
}

NSMutableDictionary<NSString *, SolaraCoreTab *> *Offered() {
  static NSMutableDictionary *offered = [NSMutableDictionary dictionary];
  return offered;
}

constexpr int64_t kOfferSeconds = 30;

}

@implementation SolaraCoreTabs

+ (void)setView:(SolaraCoreWebView *)view forTab:(SolaraCoreTab *)tab {
  if (view) [Views() setObject:view forKey:tab];
  else [Views() removeObjectForKey:tab];
}

+ (SolaraCoreWebView *)viewForTab:(SolaraCoreTab *)tab {
  return [Views() objectForKey:tab];
}

+ (NSString *)offerTab:(SolaraCoreTab *)tab {
  return [self offerTab:tab prefix:@"solaracore"];
}

+ (NSString *)offerTab:(SolaraCoreTab *)tab prefix:(NSString *)prefix {
  NSString *adoptId = [NSString stringWithFormat:@"%@:%d", prefix, solaracore_host::BrowserId(tab)];
  Offered()[adoptId] = tab;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kOfferSeconds * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (Offered()[adoptId] != tab) return;
    [Offered() removeObjectForKey:adoptId];
    if (![SolaraCoreTabs viewForTab:tab]) [tab close];
  });
  return adoptId;
}

+ (SolaraCoreTab *)offeredTab:(NSString *)adoptId {
  return adoptId.length ? Offered()[adoptId] : nil;
}

+ (SolaraCoreTab *)takeOffered:(NSString *)adoptId {
  SolaraCoreTab *tab = Offered()[adoptId];
  if (tab) [Offered() removeObjectForKey:adoptId];
  return tab;
}

+ (void)forget:(SolaraCoreTab *)tab {
  [Views() removeObjectForKey:tab];
  for (NSString *key in [Offered() allKeysForObject:tab]) [Offered() removeObjectForKey:key];
}

@end

namespace solaracore_host {

bool EngineHasTabModel() {
  static const bool has = [SolaraCoreWindow instancesRespondToSelector:@selector(adoptTab:)];
  return has;
}

namespace {
const void *kBrowserIdKey = &kBrowserIdKey;
NSMapTable<NSNumber *, SolaraCoreTab *> *TabsById() {
  static NSMapTable *tabs = [NSMapTable strongToWeakObjectsMapTable];
  return tabs;
}
}

int BrowserId(SolaraCoreTab *tab) {
  static int next = 0;
  NSNumber *id_ = objc_getAssociatedObject(tab, kBrowserIdKey);
  if (!id_) {
    id_ = @(++next);
    objc_setAssociatedObject(tab, kBrowserIdKey, id_, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [TabsById() setObject:tab forKey:id_];
  }
  return id_.intValue;
}

SolaraCoreTab *TabWithBrowserId(int browserId) {
  return [TabsById() objectForKey:@(browserId)];
}

}
