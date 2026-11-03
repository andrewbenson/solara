#include "../ios/SolaraCoreKeyPrecedence.h"

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

static const NSTimeInterval kInterval = 0.5;

static bool Second(SharedShortcutPresses &presses, NSString *shortcut, NSInteger window, NSTimeInterval at) {
  return presses.TakeSecondPress(shortcut, window, at, false, kInterval).has_value();
}

int main() {
  @autoreleasepool {
    CHECK(KeyPrecedenceNamed(@"solara", KeyPrecedence::Website) == KeyPrecedence::Solara);
    CHECK(KeyPrecedenceNamed(@"website", KeyPrecedence::Solara) == KeyPrecedence::Website);
    CHECK(KeyPrecedenceNamed(@"both", KeyPrecedence::Website) == KeyPrecedence::Both);
    CHECK(KeyPrecedenceNamed(nil, KeyPrecedence::Solara) == KeyPrecedence::Solara);
    CHECK(KeyPrecedenceNamed(@"sometimes", KeyPrecedence::Website) == KeyPrecedence::Website);

    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"find", 1, 10.0));
      const auto first = presses.TakeSecondPress(@"find", 1, 10.3, false, kInterval);
      CHECK(first && first->at == 10.0);
      if (first) presses.NoteAnswered(*first, 10.3);
      CHECK(!Second(presses, @"find", 1, 10.4));
      CHECK(presses.WasAnsweredBySecondPress(@"find", 1, 10.0));
      CHECK(!presses.WasAnsweredBySecondPress(@"find", 1, 10.0));
    }
    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"find", 1, 10.0));
      CHECK(presses.TakeSecondPress(@"find", 1, 10.3, false, kInterval));
      CHECK(!presses.WasAnsweredBySecondPress(@"find", 1, 10.0));
    }
    {
      SharedShortcutPresses presses;
      int actions = 0;
      for (const NSTimeInterval at : {10.0, 10.1, 10.2, 10.3}) {
        if (const auto first = presses.TakeSecondPress(@"next", 1, at, false, kInterval)) {
          presses.NoteAnswered(*first, at);
          actions++;
        }
      }
      for (const NSTimeInterval at : {10.0, 10.2}) {
        if (!presses.WasAnsweredBySecondPress(@"next", 1, at)) actions++;
      }
      CHECK(actions == 2);
    }
    {
      SharedShortcutPresses presses;
      presses.NoteAnswered({@"sidebar", 1, 10.0}, 10.3);
      for (int i = 0; i < 64; i++) presses.NoteAnswered({@"find", 2, 11.0 + i * 0.5}, 11.3 + i * 0.5);
      CHECK(presses.WasAnsweredBySecondPress(@"sidebar", 1, 10.0));
      presses.NoteAnswered({@"next", 1, 50.0}, 50.3);
      presses.NoteAnswered({@"find", 2, 200.0}, 200.3);
      CHECK(!presses.WasAnsweredBySecondPress(@"next", 1, 50.0));
      CHECK(presses.WasAnsweredBySecondPress(@"find", 2, 200.0));
    }
    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"find", 1, 10.0));
      CHECK(!Second(presses, @"find", 1, 10.6));
      CHECK(Second(presses, @"find", 1, 10.9));
    }
    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"sidebar", 1, 10.0));
      CHECK(!Second(presses, @"find", 1, 10.1));
      CHECK(!Second(presses, @"sidebar", 1, 10.2));
      CHECK(Second(presses, @"sidebar", 1, 10.3));
    }
    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"find", 1, 10.0));
      CHECK(!Second(presses, @"find", 2, 10.1));
      CHECK(Second(presses, @"find", 2, 10.2));
    }
    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"find", 1, 10.0));
      CHECK(!presses.TakeSecondPress(@"find", 1, 10.1, true, kInterval));
      CHECK(Second(presses, @"find", 1, 10.2));
    }
    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"find", 1, 10.0));
      presses.ForgetFirstPress(@"find", 1, 10.0);
      CHECK(!Second(presses, @"find", 1, 10.2));
      presses.ForgetFirstPress(@"find", 1, 10.0);
      CHECK(Second(presses, @"find", 1, 10.3));
    }
    {
      SharedShortcutPresses presses;
      CHECK(!Second(presses, @"find", 1, 10.0));
      CHECK(!Second(presses, @"find", 1, 9.0));
    }
  }
  if (failures) return 1;
  std::printf("key-precedence: ok\n");
  return 0;
}
