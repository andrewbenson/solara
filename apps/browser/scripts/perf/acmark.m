#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/signpost.h>

@interface CATransaction (ACMarkPrivate)
+ (void)addCommitHandler:(void (^)(void))block forPhase:(unsigned int)phase;
@end

static FILE *gOut;
static BOOL gLayoutTrace;
static os_log_t gLayoutLog;
static dispatch_queue_t gTraceWriter;

__attribute__((visibility("default"))) void SolaraLayoutTraceFlush(void) {
  if (gTraceWriter) dispatch_sync(gTraceWriter, ^{});
}

static double TraceNow(void) {
  return NSDate.date.timeIntervalSince1970 * 1000;
}

static void TraceRecord(NSString *name, os_signpost_id_t identifier, double at, NSInteger window) {
  NSString *line = [NSString stringWithFormat:@"{\"signpost\":\"%@\",\"at\":%.3f,\"window\":%ld,\"id\":\"%llu\"}\n", name, at, (long)window, (unsigned long long)identifier];
  dispatch_async(gTraceWriter, ^{
    fputs(line.UTF8String, gOut);
    fflush(gOut);
  });
}

static void TracePageRecord(NSString *name, os_signpost_id_t identifier, double at, NSView *view) {
  SEL selector = NSSelectorFromString(@"transferKey");
  id key = [view respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(view, selector) : nil;
  NSMutableArray *children = [NSMutableArray array];
  for (NSView *child in view.subviews) {
    [children addObject:@{@"class": NSStringFromClass(child.class), @"frame": @[@(child.frame.origin.x), @(child.frame.origin.y), @(child.frame.size.width), @(child.frame.size.height)],
      @"hidden": @(child.hidden), @"alpha": @(child.alphaValue)}];
  }
  NSDictionary *record = @{@"signpost": name, @"at": @(at), @"window": @(view.window.windowNumber),
    @"id": [NSString stringWithFormat:@"%llu", (unsigned long long)identifier], @"tabId": [key isKindOfClass:NSString.class] ? key : @"",
    @"frame": @[@(view.frame.origin.x), @(view.frame.origin.y), @(view.frame.size.width), @(view.frame.size.height)],
    @"parentSize": @[@(view.superview.bounds.size.width), @(view.superview.bounds.size.height)],
    @"hidden": @(view.hidden), @"hiddenAncestor": @(view.hiddenOrHasHiddenAncestor), @"alpha": @(view.alphaValue), @"children": children};
  dispatch_async(gTraceWriter, ^{
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!data) return;
    flockfile(gOut);
    fwrite(data.bytes, 1, data.length, gOut);
    fputc('\n', gOut);
    fflush(gOut);
    funlockfile(gOut);
  });
}

static BOOL HookPaintingTrace(void) {
  Class cls = NSClassFromString(@"SolaraCoreWebView");
  SEL paintingSelector = NSSelectorFromString(@"applyPainting");
  SEL visibleSelector = NSSelectorFromString(@"setVisible:");
  SEL drainSelector = NSSelectorFromString(@"drainPainting");
  Method painting = cls ? class_getInstanceMethod(cls, paintingSelector) : NULL;
  Method visible = cls ? class_getInstanceMethod(cls, visibleSelector) : NULL;
  Method drain = cls ? class_getClassMethod(cls, drainSelector) : NULL;
  if (!painting || !visible || !drain) return NO;
  SEL frameSelector = @selector(setFrameSize:);
  Method frameMethod = class_getInstanceMethod(cls, frameSelector);
  if (frameMethod) {
    IMP frameOriginal = method_getImplementation(frameMethod);
    method_setImplementation(frameMethod, imp_implementationWithBlock(^(NSView *view, NSSize size) {
      os_signpost_id_t identifier = os_signpost_id_generate(gLayoutLog);
      TracePageRecord(@"pageFrameBefore", identifier, TraceNow(), view);
      ((void (*)(id, SEL, NSSize))frameOriginal)(view, frameSelector, size);
      TracePageRecord(@"pageFrameAfter", identifier, TraceNow(), view);
    }));
  }
  IMP paintingOriginal = method_getImplementation(painting);
  method_setImplementation(painting, imp_implementationWithBlock(^(NSView *view) {
    os_signpost_id_t identifier = os_signpost_id_generate(gLayoutLog);
    os_signpost_interval_begin(gLayoutLog, identifier, "PagePainting");
    TracePageRecord(@"paintingBegin", identifier, TraceNow(), view);
    @try {
      ((void (*)(id, SEL))paintingOriginal)(view, paintingSelector);
    } @finally {
      TracePageRecord(@"paintingEnd", identifier, TraceNow(), view);
      os_signpost_interval_end(gLayoutLog, identifier, "PagePainting");
    }
  }));
  IMP visibleOriginal = method_getImplementation(visible);
  method_setImplementation(visible, imp_implementationWithBlock(^(NSView *view, BOOL on) {
    os_signpost_event_emit(gLayoutLog, OS_SIGNPOST_ID_EXCLUSIVE, "PageVisible", "%{public}s", on ? "on" : "off");
    TracePageRecord(on ? @"visibleOn" : @"visibleOff", OS_SIGNPOST_ID_EXCLUSIVE, TraceNow(), view);
    ((void (*)(id, SEL, BOOL))visibleOriginal)(view, visibleSelector, on);
  }));
  IMP drainOriginal = method_getImplementation(drain);
  method_setImplementation(drain, imp_implementationWithBlock(^(id owner) {
    os_signpost_id_t identifier = os_signpost_id_generate(gLayoutLog);
    os_signpost_interval_begin(gLayoutLog, identifier, "PaintingDrain");
    TraceRecord(@"paintingDrainBegin", identifier, TraceNow(), 0);
    @try {
      ((void (*)(id, SEL))drainOriginal)(owner, drainSelector);
    } @finally {
      TraceRecord(@"paintingDrainEnd", identifier, TraceNow(), 0);
      os_signpost_interval_end(gLayoutLog, identifier, "PaintingDrain");
    }
  }));
  return YES;
}

static BOOL HookLayoutTrace(void) {
  Class cls = NSClassFromString(@"RCTUIManager");
  SEL layoutSelector = NSSelectorFromString(@"_layoutAndMount");
  SEL mountSelector = NSSelectorFromString(@"flushUIBlocksWithCompletion:");
  Method layout = cls ? class_getInstanceMethod(cls, layoutSelector) : NULL;
  Method mount = cls ? class_getInstanceMethod(cls, mountSelector) : NULL;
  if (!layout || !mount) return NO;
  IMP layoutOriginal = method_getImplementation(layout);
  method_setImplementation(layout, imp_implementationWithBlock(^(id manager) {
    os_signpost_id_t identifier = os_signpost_id_generate(gLayoutLog);
    os_signpost_interval_begin(gLayoutLog, identifier, "RNLayout");
    TraceRecord(@"rnLayoutBegin", identifier, TraceNow(), 0);
    @try {
      ((void (*)(id, SEL))layoutOriginal)(manager, layoutSelector);
    } @finally {
      TraceRecord(@"rnLayoutEnd", identifier, TraceNow(), 0);
      os_signpost_interval_end(gLayoutLog, identifier, "RNLayout");
    }
  }));
  IMP mountOriginal = method_getImplementation(mount);
  method_setImplementation(mount, imp_implementationWithBlock(^(id manager, id completion) {
    NSMutableArray *pending = [manager valueForKey:@"_pendingUIBlocks"];
    if ([pending isKindOfClass:NSMutableArray.class] && pending.count) {
      os_signpost_id_t identifier = os_signpost_id_generate(gLayoutLog);
      TraceRecord(@"rnMountQueued", identifier, TraceNow(), 0);
      [pending insertObject:[^(id owner, NSDictionary *registry) {
        os_signpost_interval_begin(gLayoutLog, identifier, "RNMount");
        TraceRecord(@"rnMountBegin", identifier, TraceNow(), 0);
      } copy] atIndex:0];
      [pending addObject:[^(id owner, NSDictionary *registry) {
        TraceRecord(@"rnMountEnd", identifier, TraceNow(), 0);
        os_signpost_interval_end(gLayoutLog, identifier, "RNMount");
      } copy]];
    }
    ((void (*)(id, SEL, id))mountOriginal)(manager, mountSelector, completion);
  }));
  return YES;
}

static void Mark(NSString *key, NSInteger window) {
  fprintf(gOut, "{\"%s\":%.1f,\"window\":%ld}\n", key.UTF8String, NSDate.date.timeIntervalSince1970 * 1000, (long)window);
  fflush(gOut);
}

static void Signpost(const char *name, long window, double at) {
  fprintf(gOut, "{\"signpost\":\"%s\",\"at\":%.1f,\"window\":%ld}\n", name, at, window);
  fflush(gOut);
}

static BOOL HookSignposts(void) {
  void (*set)(void (*)(const char *, long, double)) = dlsym(RTLD_DEFAULT, "SolaraSignpostsSetObserver");
  if (!set) return NO;
  set(Signpost);
  return YES;
}

__attribute__((constructor)) static void Start(void) {
  const char *dir = getenv("SOLARA_DATA_DIR");
  if (!dir) return;
  if (![NSBundle.mainBundle.bundlePath hasSuffix:@".app"] || [NSBundle.mainBundle.bundlePath containsString:@"Helper"]) return;
  gOut = fopen([NSString stringWithFormat:@"%s/bench-marks.jsonl", dir].UTF8String, "a");
  if (!gOut) return;
  const char *trace = getenv("SOLARA_LAYOUT_TRACE");
  gLayoutTrace = trace && strcmp(trace, "1") == 0;
  if (gLayoutTrace) {
    gLayoutLog = os_log_create("network.benson.solara", "RNLayoutStages");
    gTraceWriter = dispatch_queue_create("solara.bench.layout-trace", DISPATCH_QUEUE_SERIAL);
    if (!HookPaintingTrace()) {
      __block int tries = 0;
      CFRunLoopTimerRef retry = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, ^(CFRunLoopTimerRef timer) {
        if (HookPaintingTrace() || ++tries >= 20) CFRunLoopTimerInvalidate(timer);
      });
      CFRunLoopAddTimer(CFRunLoopGetMain(), retry, kCFRunLoopCommonModes);
      CFRelease(retry);
    }
    if (!HookLayoutTrace()) {
      __block int tries = 0;
      CFRunLoopTimerRef retry = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, ^(CFRunLoopTimerRef timer) {
        if (HookLayoutTrace() || ++tries >= 20) CFRunLoopTimerInvalidate(timer);
      });
      CFRunLoopAddTimer(CFRunLoopGetMain(), retry, kCFRunLoopCommonModes);
      CFRelease(retry);
    }
  }
  BOOL keylog = getenv("AC_BENCH_KEYLOG") != NULL;
  if (keylog || gLayoutTrace) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
      double now = NSDate.date.timeIntervalSince1970 * 1000;
      if (gLayoutTrace) {
        os_signpost_event_emit(gLayoutLog, OS_SIGNPOST_ID_EXCLUSIVE, "KeyDown");
        TraceRecord(@"keyDown", OS_SIGNPOST_ID_EXCLUSIVE, now, event.windowNumber);
      }
      if (keylog) {
        fprintf(gOut, "{\"keydown\":%.1f,\"made\":%.1f,\"window\":%ld,\"char\":%d}\n", now,
                now - (NSProcessInfo.processInfo.systemUptime - event.timestamp) * 1000, (long)event.windowNumber, event.characters.length ? (int)[event.characters characterAtIndex:0] : 0);
        fflush(gOut);
      }
      return event;
    }];
  }
  if (!HookSignposts()) {
    __block int tries = 0;
    CFRunLoopTimerRef retry = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.5, 0.5, 0, 0, ^(CFRunLoopTimerRef t) {
      if (HookSignposts() || ++tries >= 20) CFRunLoopTimerInvalidate(t);
    });
    CFRunLoopAddTimer(CFRunLoopGetMain(), retry, kCFRunLoopCommonModes);
  }
  [NSNotificationCenter.defaultCenter addObserverForName:@"RCTContentDidAppearNotification" object:nil queue:nil
                                              usingBlock:^(NSNotification *note) {
    if ([note.object isKindOfClass:NSView.class] && [NSStringFromClass([((NSView *)note.object).superview class]) hasSuffix:@"ShellView"]) return;
    NSInteger window = [note.object isKindOfClass:NSView.class] ? ((NSView *)note.object).window.windowNumber : 0;
    Mark(@"content", window);
    if (gLayoutTrace) {
      os_signpost_id_t identifier = os_signpost_id_generate(gLayoutLog);
      os_signpost_interval_begin(gLayoutLog, identifier, "RNContentCommit");
      TraceRecord(@"rnContentBegin", identifier, TraceNow(), window);
      [CATransaction addCommitHandler:^{
        TraceRecord(@"rnContentEnd", identifier, TraceNow(), window);
        os_signpost_interval_end(gLayoutLog, identifier, "RNContentCommit");
      } forPhase:2];
    }
    [CATransaction addCommitHandler:^{ Mark(@"committed", window); } forPhase:2];
  }];
}
