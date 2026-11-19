#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <signal.h>
#import <unistd.h>

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 4 && argc != 5) return 64;
    char *holdEnd = NULL;
    long holdMs = argc == 5 ? strtol(argv[4], &holdEnd, 10) : 0;
    if (holdMs < 0 || holdMs > 2000 || (argc == 5 && (!argv[4][0] || !holdEnd || *holdEnd))) return 64;
    pid_t pid = (pid_t)atoi(argv[1]);
    CGWindowID window = (CGWindowID)strtoul(argv[2], NULL, 10);
    NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[3]]];
    NSArray *steps = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (pid <= 1 || !window || ![steps isKindOfClass:NSArray.class] || steps.count > 512) return 64;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window));
    NSDictionary *info = windows.firstObject;
    if ([info[(id)kCGWindowOwnerPID] intValue] != pid) return 65;
    NSData *windowData = [NSJSONSerialization dataWithJSONObject:@{@"type": @"window", @"postEventAccess": @(CGPreflightPostEventAccess()), @"info": info} options:0 error:nil];
    puts([[NSString alloc] initWithData:windowData encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
    CGRect bounds;
    if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds)) return 65;
    typedef void (*SetWindowLocation)(CGEventRef, CGPoint);
    SetWindowLocation setWindowLocation = (SetWindowLocation)dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation");
    if (!setWindowLocation) return 69;
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CFTimeInterval start = CACurrentMediaTime();
    double previous = -1;
    for (NSDictionary *step in steps) {
      double at = [step[@"at"] doubleValue];
      if (at < previous || at < 0 || at > 15000) return 64;
      previous = at;
      while ((CACurrentMediaTime() - start) * 1000 < at) {
        if (kill(pid, 0) != 0) return 70;
        usleep(1000);
      }
      NSString *kind = step[@"type"];
      CGEventFlags flags = [step[@"flags"] unsignedLongLongValue];
      CGEventRef event = NULL;
      if ([kind isEqualToString:@"keyDown"] || [kind isEqualToString:@"keyUp"]) {
        event = CGEventCreateKeyboardEvent(source, [step[@"code"] unsignedShortValue], [kind isEqualToString:@"keyDown"]);
      } else if ([kind isEqualToString:@"scroll"]) {
        double dx = [step[@"dx"] doubleValue];
        event = CGEventCreateScrollWheelEvent(source, kCGScrollEventUnitPixel, 2, 0, (int32_t)lround(dx));
        CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, dx);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, (int64_t)lround(dx));
        CGEventSetIntegerValueField(event, kCGScrollWheelEventScrollPhase, [step[@"phase"] longLongValue]);
        CGPoint local = CGPointMake([step[@"x"] doubleValue], [step[@"y"] doubleValue]);
        CGEventSetLocation(event, CGPointMake(bounds.origin.x + local.x, bounds.origin.y + local.y));
        setWindowLocation(event, local);
      } else {
        NSDictionary *types = @{@"down": @(kCGEventLeftMouseDown), @"dragged": @(kCGEventLeftMouseDragged), @"moved": @(kCGEventMouseMoved), @"up": @(kCGEventLeftMouseUp)};
        NSNumber *type = types[kind];
        if (!type) return 64;
        CGPoint local = CGPointMake([step[@"x"] doubleValue], [step[@"y"] doubleValue]);
        event = CGEventCreateMouseEvent(source, [type unsignedIntValue], CGPointMake(bounds.origin.x + local.x, bounds.origin.y + local.y), kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
        setWindowLocation(event, local);
      }
      if (!event) return 71;
      CGEventSetFlags(event, flags);
      CGEventSetIntegerValueField(event, (CGEventField)51, window);
      CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer, window);
      CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, window);
      double postedUptime = NSProcessInfo.processInfo.systemUptime;
      double postedWallTime = NSDate.date.timeIntervalSince1970 * 1000;
      CGEventPostToPid(pid, event);
      CFRelease(event);
      NSMutableDictionary *record = [step mutableCopy];
      record[@"postedAt"] = @((CACurrentMediaTime() - start) * 1000);
      record[@"postedUptime"] = @(postedUptime);
      record[@"postedWallTime"] = @(postedWallTime);
      NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
      puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
      fflush(stdout);
    }
    if (holdMs > 0 && [steps.lastObject[@"type"] isEqualToString:@"up"]) {
      CFTimeInterval holdStart = CACurrentMediaTime();
      while ((CACurrentMediaTime() - holdStart) * 1000 < holdMs) {
        if (kill(pid, 0) != 0) {
          CFRelease(source);
          return 70;
        }
        usleep(1000);
      }
      NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"type": @"hold-complete", @"requestedMs": @(holdMs), @"heldMs": @((CACurrentMediaTime() - holdStart) * 1000), @"completedUptime": @(NSProcessInfo.processInfo.systemUptime)} options:0 error:nil];
      puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
      fflush(stdout);
    }
    CFRelease(source);
    return 0;
  }
}
