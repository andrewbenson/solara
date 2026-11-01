#include "../ios/SolaraCoreFullScreenLights.h"

#include <cmath>
#include <cstdio>
#include <limits>

using namespace solaracore_full_screen_lights;

static int failures = 0;
#define CHECK(cond)                                                \
  do {                                                             \
    if (!(cond)) {                                                 \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
      failures++;                                                  \
    }                                                              \
  } while (0)

int main() {
  CHECK(RevealOffset(0, 24) == 0);
  CHECK(RevealOffset(1, 24) == 24);
  CHECK(RevealOffset(0.5, 37) == 18.5);
  CHECK(RevealOffset(1.5, 24) == 24);
  CHECK(RevealOffset(-0.2, 24) == 0);
  CHECK(RevealOffset(1, 0) == 0);
  CHECK(RevealOffset(1, -24) == 0);
  CHECK(RevealOffset(std::nan(""), 24) == 0);
  CHECK(RevealOffset(1, std::numeric_limits<double>::infinity()) == 0);
  CHECK(RevealOffset(0.25, 24) < RevealOffset(0.75, 24));
  if (failures) return 1;
  std::printf("full-screen-lights: ok\n");
  return 0;
}
