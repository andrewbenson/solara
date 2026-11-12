#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdlib.h>

static void Print(NSDictionary *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

static id Attribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = NULL;
  if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
  return CFBridgingRelease(value);
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 3) {
      Print(@{@"error": @"usage: pip-ax-probe <hidden-pid> <PiP-window-number>"});
      return 2;
    }
    char *pidEnd = NULL, *windowEnd = NULL;
    long pid = strtol(argv[1], &pidEnd, 10);
    unsigned long number = strtoul(argv[2], &windowEnd, 10);
    if (pid <= 0 || pid > INT_MAX || !pidEnd || *pidEnd || !number || number > UINT_MAX || !windowEnd || *windowEnd) {
      Print(@{@"error": @"invalid PID or window number"});
      return 2;
    }
    if (!AXIsProcessTrusted()) {
      Print(@{@"trusted": @NO, @"skipped": @"the probe has no Accessibility trust; no permission prompt was requested"});
      return 0;
    }
    typedef AXError (*WindowNumberFunction)(AXUIElementRef, CGWindowID *);
    WindowNumberFunction windowNumber = (WindowNumberFunction)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    if (!windowNumber) {
      Print(@{@"trusted": @YES, @"skipped": @"the AX window-number lookup is unavailable"});
      return 0;
    }
    AXUIElementRef application = AXUIElementCreateApplication((pid_t)pid);
    AXUIElementSetMessagingTimeout(application, 2);
    NSArray *windows = Attribute(application, kAXWindowsAttribute);
    AXUIElementRef target = NULL;
    for (id candidate in windows) {
      AXUIElementRef element = (__bridge AXUIElementRef)candidate;
      CGWindowID candidateNumber = 0;
      pid_t candidatePid = 0;
      if (AXUIElementGetPid(element, &candidatePid) == kAXErrorSuccess && candidatePid == pid &&
          windowNumber(element, &candidateNumber) == kAXErrorSuccess && candidateNumber == number) {
        target = (AXUIElementRef)CFRetain(element);
        break;
      }
    }
    CFRelease(application);
    if (!target) {
      NSRunningApplication *running = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
      NSArray *cgWindows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)number));
      NSDictionary *matched = nil;
      for (NSDictionary *candidate in cgWindows) {
        if ([candidate[(__bridge NSString *)kCGWindowNumber] unsignedLongValue] == number &&
            [candidate[(__bridge NSString *)kCGWindowOwnerPID] longValue] == pid) {
          matched = candidate;
          break;
        }
      }
      NSNumber *layer = matched[(__bridge NSString *)kCGWindowLayer];
      BOOL hidden = matched && layer && layer.integerValue < 0;
      NSMutableDictionary *result = [@{
        @"trusted": @YES, @"pid": @(pid), @"window": @(number),
        @"axWindowCount": @(windows.count),
        @"activationPolicy": running ? @(running.activationPolicy) : NSNull.null,
        @"cgWindowMatched": @(matched != nil), @"cgWindowLayer": layer ?: NSNull.null,
      } mutableCopy];
      result[hidden ? @"skipped" : @"error"] = hidden
          ? @"hidden PiP not published in AXWindows; external AX routing requires owner check"
          : @"the exact PiP window was absent from AXWindows and a negative-layer owned CG window could not be confirmed";
      Print(result);
      return hidden ? 0 : 1;
    }
    AXUIElementSetMessagingTimeout(target, 2);
    id position = Attribute(target, kAXPositionAttribute);
    id size = Attribute(target, kAXSizeAttribute);
    CGPoint point;
    CGSize dimensions;
    if (!position || !size || CFGetTypeID((__bridge CFTypeRef)position) != AXValueGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)size) != AXValueGetTypeID() ||
        !AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &point) ||
        !AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &dimensions)) {
      CFRelease(target);
      Print(@{@"trusted": @YES, @"error": @"the PiP AX geometry was unavailable"});
      return 1;
    }
    Boolean positionWritable = false, sizeWritable = false;
    AXError positionQuery = AXUIElementIsAttributeSettable(target, kAXPositionAttribute, &positionWritable);
    AXError sizeQuery = AXUIElementIsAttributeSettable(target, kAXSizeAttribute, &sizeWritable);
    CGPoint originalPoint = point;
    CGSize originalDimensions = dimensions;
    point.x += 100;
    dimensions.width += 100;
    AXValueRef moved = AXValueCreate(kAXValueCGPointType, &point);
    AXValueRef resized = AXValueCreate(kAXValueCGSizeType, &dimensions);
    AXError positionWrite = AXUIElementSetAttributeValue(target, kAXPositionAttribute, moved);
    AXError sizeWrite = AXUIElementSetAttributeValue(target, kAXSizeAttribute, resized);
    id afterPosition = Attribute(target, kAXPositionAttribute);
    id afterSize = Attribute(target, kAXSizeAttribute);
    CGPoint afterPoint = originalPoint;
    CGSize afterDimensions = originalDimensions;
    BOOL geometryRead = afterPosition && afterSize &&
        CFGetTypeID((__bridge CFTypeRef)afterPosition) == AXValueGetTypeID() &&
        CFGetTypeID((__bridge CFTypeRef)afterSize) == AXValueGetTypeID() &&
        AXValueGetValue((__bridge AXValueRef)afterPosition, kAXValueCGPointType, &afterPoint) &&
        AXValueGetValue((__bridge AXValueRef)afterSize, kAXValueCGSizeType, &afterDimensions);
    BOOL positionChanged = !CGPointEqualToPoint(originalPoint, afterPoint);
    BOOL sizeChanged = !CGSizeEqualToSize(originalDimensions, afterDimensions);
    AXError sizeRestore = AXUIElementSetAttributeValue(target, kAXSizeAttribute, (__bridge CFTypeRef)size);
    AXError positionRestore = AXUIElementSetAttributeValue(target, kAXPositionAttribute, (__bridge CFTypeRef)position);
    id restoredPosition = Attribute(target, kAXPositionAttribute);
    id restoredSize = Attribute(target, kAXSizeAttribute);
    CGPoint restoredPoint = afterPoint;
    CGSize restoredDimensions = afterDimensions;
    BOOL restoredRead = restoredPosition && restoredSize &&
        CFGetTypeID((__bridge CFTypeRef)restoredPosition) == AXValueGetTypeID() &&
        CFGetTypeID((__bridge CFTypeRef)restoredSize) == AXValueGetTypeID() &&
        AXValueGetValue((__bridge AXValueRef)restoredPosition, kAXValueCGPointType, &restoredPoint) &&
        AXValueGetValue((__bridge AXValueRef)restoredSize, kAXValueCGSizeType, &restoredDimensions);
    BOOL geometryRestored = restoredRead && CGPointEqualToPoint(originalPoint, restoredPoint) &&
        CGSizeEqualToSize(originalDimensions, restoredDimensions);
    Print(@{
      @"trusted": @YES, @"pid": @(pid), @"window": @(number),
      @"role": Attribute(target, kAXRoleAttribute) ?: @"",
      @"subrole": Attribute(target, kAXSubroleAttribute) ?: @"",
      @"positionWritable": @(positionWritable), @"sizeWritable": @(sizeWritable),
      @"positionQueryStatus": @(positionQuery), @"sizeQueryStatus": @(sizeQuery),
      @"positionWriteStatus": @(positionWrite), @"sizeWriteStatus": @(sizeWrite),
      @"geometryRead": @(geometryRead), @"geometryChanged": @(positionChanged || sizeChanged),
      @"positionChanged": @(positionChanged), @"sizeChanged": @(sizeChanged),
      @"originalPosition": @[@(originalPoint.x), @(originalPoint.y)],
      @"originalSize": @[@(originalDimensions.width), @(originalDimensions.height)],
      @"requestedPosition": @[@(point.x), @(point.y)],
      @"requestedSize": @[@(dimensions.width), @(dimensions.height)],
      @"observedPosition": @[@(afterPoint.x), @(afterPoint.y)],
      @"observedSize": @[@(afterDimensions.width), @(afterDimensions.height)],
      @"positionRestoreStatus": @(positionRestore), @"sizeRestoreStatus": @(sizeRestore),
      @"geometryRestored": @(geometryRestored),
    });
    CFRelease(moved);
    CFRelease(resized);
    CFRelease(target);
    return 0;
  }
}
