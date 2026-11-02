#include "../ios/SolaraCoreEscapeKey.h"

#include <cstdio>

using namespace solaracore_keys;

static int failures = 0;
#define CHECK(cond)                                                \
  do {                                                             \
    if (!(cond)) {                                                 \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
      failures++;                                                  \
    }                                                              \
  } while (0)

static NSEvent *Key(NSEventType type, unsigned short code, NSEventModifierFlags mods) {
  NSString *chars = code == 53 ? @"\x1b" : @"a";
  return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:mods timestamp:0 windowNumber:0 context:nil characters:chars
       charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}

int main() {
  @autoreleasepool {
    NSEvent *escape = Key(NSEventTypeKeyDown, 53, 0);
    CHECK(KeepsUnhandledEscapeFromWindow(escape, true));
    CHECK(KeepsUnhandledEscapeFromWindow(Key(NSEventTypeKeyDown, 53, NSEventModifierFlagShift), true));
    CHECK(KeepsUnhandledEscapeFromWindow(Key(NSEventTypeKeyDown, 53, NSEventModifierFlagFunction), true));
    CHECK(!KeepsUnhandledEscapeFromWindow(escape, false));
    CHECK(!KeepsUnhandledEscapeFromWindow(Key(NSEventTypeKeyUp, 53, 0), true));
    CHECK(!KeepsUnhandledEscapeFromWindow(Key(NSEventTypeKeyDown, 53, NSEventModifierFlagCommand), true));
    CHECK(!KeepsUnhandledEscapeFromWindow(Key(NSEventTypeKeyDown, 53, NSEventModifierFlagOption), true));
    CHECK(!KeepsUnhandledEscapeFromWindow(Key(NSEventTypeKeyDown, 53, NSEventModifierFlagControl), true));
    CHECK(!KeepsUnhandledEscapeFromWindow(Key(NSEventTypeKeyDown, 0, 0), true));
    CHECK(IsPlainEscape(escape));
    CHECK(!IsPlainEscape(Key(NSEventTypeKeyDown, 53, NSEventModifierFlagCommand | NSEventModifierFlagControl)));
  }
  if (failures) return 1;
  std::printf("escape-key: ok\n");
  return 0;
}
