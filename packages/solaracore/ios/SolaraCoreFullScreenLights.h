#pragma once

#include <algorithm>
#include <cmath>

namespace solaracore_full_screen_lights {

inline double RevealOffset(double revealAmount, double menuBarHeight) {
  if (!std::isfinite(revealAmount) || !std::isfinite(menuBarHeight) || revealAmount <= 0 || menuBarHeight <= 0) return 0;
  return std::min(revealAmount, 1.0) * menuBarHeight;
}

}
