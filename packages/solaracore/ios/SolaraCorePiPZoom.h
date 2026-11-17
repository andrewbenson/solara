#pragma once

#include <algorithm>
#include <cmath>

namespace solaracore_pip_zoom {

struct Rect {
  double x, y, w, h;
  double maxX() const { return x + w; }
  double maxY() const { return y + h; }
};
struct Size {
  double w, h;
};
struct Point {
  double x, y;
};

enum class InputSource { Local, Global, View };

inline bool RoutesToPiP(InputSource source, bool enabled, bool eligible, bool eventWindow, bool pointerWindow) {
  return enabled && eligible && (source == InputSource::View ? eventWindow : pointerWindow);
}

enum class ScrollKind { Wheel, Begin, Change, End, Cancel, MomentumBegin, MomentumChange, MomentumEnd };

struct ScrollSession {
  bool active = false;
  bool momentum = false;
  double endedAt = -1;

  void Clear() { active = momentum = false; endedAt = -1; }

  bool Handle(ScrollKind kind, bool target, bool command, double now) {
    if (!target) { Clear(); return false; }
    switch (kind) {
      case ScrollKind::Wheel:
        Clear();
        return command;
      case ScrollKind::Begin:
        Clear();
        active = command;
        return active;
      case ScrollKind::Change:
        momentum = false;
        endedAt = -1;
        return active;
      case ScrollKind::End: {
        const bool handled = active;
        active = momentum = false;
        endedAt = handled ? now : -1;
        return handled;
      }
      case ScrollKind::Cancel: {
        const bool handled = active || momentum;
        Clear();
        return handled;
      }
      case ScrollKind::MomentumBegin:
        momentum = endedAt >= 0 && now >= endedAt && now - endedAt <= 0.25;
        active = false;
        endedAt = -1;
        return momentum;
      case ScrollKind::MomentumChange:
        return momentum;
      case ScrollKind::MomentumEnd: {
        const bool handled = momentum;
        Clear();
        return handled;
      }
    }
    return false;
  }
};

constexpr double kPerPoint = 0.004, kPerLine = 0.08;
constexpr double kDockSlop = 64;

inline double ScrollFactor(double deltaY, bool precise) {
  return std::exp((precise ? kPerPoint : kPerLine) * deltaY);
}

inline double MagnifyFactor(double magnification) {
  return std::max(0.05, 1 + magnification);
}

inline void WidthLimits(double aspect, Size minSize, Size maxSize, Rect visible, double *low, double *high) {
  *low = std::max({minSize.w, minSize.h * aspect, 1.0});
  *high = std::min({maxSize.w, maxSize.h * aspect, visible.w, visible.h * aspect});
  if (*low > *high) *low = *high;
}

inline double Anchor(double origin, double size, double next, double pointer, double low, double high) {
  double before = origin - low, after = high - (origin + size);
  if (std::min(before, after) <= kDockSlop) return before <= after ? origin : origin + size - next;
  double fraction = std::clamp((pointer - origin) / size, 0.0, 1.0);
  return pointer - fraction * next;
}

struct Result {
  Rect frame;
  double width;
};

inline Result Zoom(Rect frame, double width, double aspect, double factor, Point pointer, Rect visible, Size minSize,
                   Size maxSize) {
  double low, high;
  WidthLimits(aspect, minSize, maxSize, visible, &low, &high);
  double w = std::clamp(width * factor, low, high);
  double rw = std::clamp(std::round(w), std::ceil(low), std::max(std::ceil(low), std::floor(high)));
  double rh = std::round(rw / aspect);
  double x = Anchor(frame.x, frame.w, rw, pointer.x, visible.x, visible.maxX());
  double y = Anchor(frame.y, frame.h, rh, pointer.y, visible.y, visible.maxY());
  x = std::clamp(x, visible.x, visible.maxX() - rw);
  y = std::clamp(y, visible.y, visible.maxY() - rh);
  return {{std::round(x), std::round(y), rw, rh}, w};
}

}
