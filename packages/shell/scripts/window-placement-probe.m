#import <AppKit/AppKit.h>

static NSString *directory;
static BOOL busy;

static NSDictionary *Frame(NSRect frame) {
  return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height)};
}

static NSDictionary *State(NSWindow *window) {
  return @{@"frame": Frame(window.frame), @"fullscreen": @((window.styleMask & NSWindowStyleMaskFullScreen) != 0), @"zoomed": @(window.isZoomed), @"visible": @(window.isVisible), @"key": @(window.isKeyWindow)};
}

static NSArray *Screens(void) {
  NSMutableArray *screens = [NSMutableArray array];
  for (NSScreen *screen in NSScreen.screens) {
    [screens addObject:@{@"name": screen.localizedName, @"frame": Frame(screen.frame), @"visible": Frame(screen.visibleFrame), @"scale": @(screen.backingScaleFactor)}];
  }
  return screens;
}

static void Finish(NSMutableDictionary *result) {
  NSData *output = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
  [output writeToFile:[directory stringByAppendingPathComponent:@"result.json"] atomically:YES];
  busy = NO;
}

static NSEvent *MouseEvent(NSWindow *window, NSEventType type, NSPoint point) {
  NSEvent *event = [NSEvent mouseEventWithType:type location:[window convertPointFromScreen:point] modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
  CGEventRef cg = event.CGEvent;
  CGEventSetLocation(cg, CGPointMake(point.x, NSMaxY(NSScreen.screens.firstObject.frame) - point.y));
  return [NSEvent eventWithCGEvent:cg];
}

static void Process(NSDictionary *request) {
  NSMutableDictionary *result = [@{@"id": request[@"id"] ?: @"", @"request": request, @"screens": Screens(), @"os": NSProcessInfo.processInfo.operatingSystemVersionString, @"background": @(getenv("SOLARA_BACKGROUND") != NULL)} mutableCopy];
  @try {
    NSWindow *window = nil;
    for (NSWindow *candidate in NSApp.windows) {
      if (request[@"windowNumber"]) {
        if (candidate.windowNumber == [request[@"windowNumber"] integerValue]) { window = candidate; break; }
      } else if (candidate.isVisible && (candidate.styleMask & NSWindowStyleMaskResizable) && candidate.frame.size.width >= 600 && (!request[@"target"] || [candidate.className isEqual:request[@"target"]])) {
        window = candidate;
        break;
      }
    }
    if (!window) {
      result[@"error"] = @"no matching visible resizable window";
      Finish(result);
      return;
    }
    result[@"windowNumber"] = @(window.windowNumber);
    result[@"class"] = window.className;
    result[@"delegate"] = window.delegate ? NSStringFromClass([window.delegate class]) : @"nil";
    result[@"before"] = State(window);
    result[@"minSize"] = @{@"width": @(window.minSize.width), @"height": @(window.minSize.height)};
    NSString *action = request[@"action"];
    if ([action isEqual:@"frame"]) {
      NSArray *frame = request[@"frame"];
      if (frame.count != 4) [NSException raise:NSInvalidArgumentException format:@"frame requires four coordinates"];
      result[@"requested"] = Frame(NSMakeRect([frame[0] doubleValue], [frame[1] doubleValue], [frame[2] doubleValue], [frame[3] doubleValue]));
      [window setFrame:NSMakeRect([frame[0] doubleValue], [frame[1] doubleValue], [frame[2] doubleValue], [frame[3] doubleValue]) display:YES];
    } else if ([action isEqual:@"zoom"]) {
      [window performZoom:nil];
    } else if ([action isEqual:@"fullscreen"]) {
      [window toggleFullScreen:nil];
      result[@"realSpaceTransitionExercised"] = @NO;
      result[@"coverage"] = @"hidden instance fullscreen handling; real Space transition not exercised";
    } else if ([action isEqual:@"axZoom"]) {
      NSButton *button = [window standardWindowButton:NSWindowZoomButton];
      result[@"axButtonPresent"] = @(button != nil);
      result[@"axAccepted"] = @([button accessibilityPerformPress]);
      result[@"realSpaceTransitionExercised"] = @NO;
      result[@"coverage"] = @"public zoom-button accessibility press in hidden instance; real Space transition not exercised";
    } else if ([action isEqual:@"drag"]) {
      NSArray *from = request[@"from"], *to = request[@"to"];
      if (from.count != 2 || to.count != 2) [NSException raise:NSInvalidArgumentException format:@"drag requires two points"];
      NSPoint start = NSMakePoint([from[0] doubleValue], [from[1] doubleValue]);
      NSPoint end = NSMakePoint([to[0] doubleValue], [to[1] doubleValue]);
      result[@"requested"] = Frame(NSOffsetRect(window.frame, end.x - start.x, end.y - start.y));
      NSEvent *down = MouseEvent(window, NSEventTypeLeftMouseDown, start);
      [NSApp postEvent:MouseEvent(window, NSEventTypeLeftMouseDragged, end) atStart:NO];
      [NSApp postEvent:MouseEvent(window, NSEventTypeLeftMouseUp, end) atStart:NO];
      [window performWindowDragWithEvent:down];
    } else if (![action isEqual:@"read"]) {
      [NSException raise:NSInvalidArgumentException format:@"unknown action %@", action];
    }
    result[@"immediate"] = State(window);
    NSTimeInterval delay = [request[@"settleMs"] doubleValue] / 1000.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.1, MIN(delay, 2.0)) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      @try {
        result[@"settled"] = State(window);
        result[@"screen"] = window.screen.localizedName ?: @"nil";
        result[@"screenIndex"] = window.screen ? @([NSScreen.screens indexOfObjectIdenticalTo:window.screen]) : @(-1);
        if (window.screen) result[@"screenFrame"] = Frame(window.screen.frame);
        if ([action isEqual:@"fullscreen"] || [action isEqual:@"axZoom"]) {
          BOOL changed = ![result[@"before"] isEqual:result[@"settled"]];
          result[@"outcome"] = changed ? @"acted" : @"suppressed";
          result[@"outcomeEvidence"] = changed ? @"observable window state changed" : @"no observable window state change; acceptance recorded separately";
        }
      } @catch (NSException *exception) {
        result[@"exception"] = exception.description;
      }
      Finish(result);
    });
  } @catch (NSException *exception) {
    result[@"exception"] = exception.description;
    Finish(result);
  }
}

static void Start(void) {
  NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
    if (busy) return;
    NSString *command = [directory stringByAppendingPathComponent:@"command.json"];
    NSData *bytes = [NSData dataWithContentsOfFile:command];
    if (!bytes) return;
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:command error:NULL];
    if (![request isKindOfClass:NSDictionary.class]) return;
    busy = YES;
    Process(request);
  }];
  [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

__attribute__((constructor)) static void Install(void) {
  const char *path = getenv("SOLARA_FRAME_PROBE");
  if (!path || ![NSProcessInfo.processInfo.processName isEqual:@"Solara"]) return;
  directory = [NSString stringWithUTF8String:path];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Start(); });
}
