#pragma once

#import <AppKit/AppKit.h>

namespace solaracore_keys {

inline bool IsPlainEscape(NSEvent *event) {
  const NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  return event.type == NSEventTypeKeyDown && event.keyCode == 53 &&
         !(mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl));
}

inline bool KeepsUnhandledEscapeFromWindow(NSEvent *event, bool windowFullScreen) {
  return windowFullScreen && IsPlainEscape(event);
}

}
