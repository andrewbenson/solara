#pragma once

namespace solaracore_windows {

inline bool ShouldRecoverCancelledClose(bool visible, bool closing, bool awaitingApp, bool appOwnsRoot) {
  return !visible && !closing && !awaitingApp && !appOwnsRoot;
}

}
