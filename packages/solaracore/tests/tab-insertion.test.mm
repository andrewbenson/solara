#include "../ios/SolaraCoreTabInsertion.h"

#include <cstdio>

using namespace solaracore_tabs;

static int failures = 0;
#define CHECK(cond)                                                \
  do {                                                             \
    if (!(cond)) {                                                 \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
      failures++;                                                  \
    }                                                              \
  } while (0)

int main() {
  @autoreleasepool {
    CHECK(!ShouldAnnounceInsertedTab(true, @"popup"));
    CHECK(!ShouldAnnounceInsertedTab(false, @"popup"));
    CHECK(ShouldAnnounceInsertedTab(true, @"foreground_tab"));
    CHECK(ShouldAnnounceInsertedTab(true, @"background_tab"));
    CHECK(ShouldAnnounceInsertedTab(true, @"window"));
    CHECK(ShouldAnnounceInsertedTab(true, nil));
    CHECK(!ShouldAnnounceInsertedTab(false, @"foreground_tab"));
    CHECK(!ShouldAnnounceInsertedTab(false, nil));
  }
  if (failures) return 1;
  std::printf("tab-insertion: ok\n");
  return 0;
}
