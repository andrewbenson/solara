#pragma once

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cstddef>
#include <optional>
#include <vector>

namespace solaracore_keys {

enum class KeyPrecedence { Solara, Website, Both };

inline KeyPrecedence KeyPrecedenceNamed(NSString *name, KeyPrecedence fallback) {
  if ([name isEqualToString:@"solara"]) return KeyPrecedence::Solara;
  if ([name isEqualToString:@"website"]) return KeyPrecedence::Website;
  if ([name isEqualToString:@"both"]) return KeyPrecedence::Both;
  return fallback;
}

struct ShortcutPress {
  NSString *shortcut = nil;
  NSInteger window = 0;
  NSTimeInterval at = 0;

  bool Is(NSString *otherShortcut, NSInteger otherWindow) const {
    return shortcut && [shortcut isEqualToString:otherShortcut] && window == otherWindow;
  }

  bool Is(NSString *otherShortcut, NSInteger otherWindow, NSTimeInterval otherAt) const {
    return Is(otherShortcut, otherWindow) && at == otherAt;
  }
};

class SharedShortcutPresses {
 public:
  static constexpr NSTimeInterval kAnsweredLifetime = 120;
  static constexpr size_t kAnsweredLimit = 1024;

  std::optional<ShortcutPress> TakeSecondPress(NSString *shortcut, NSInteger window, NSTimeInterval at, bool repeat, NSTimeInterval interval) {
    if (repeat) return std::nullopt;
    if (first_.Is(shortcut, window) && at >= first_.at && at - first_.at <= interval) {
      const ShortcutPress first = first_;
      first_ = {};
      return first;
    }
    first_ = {shortcut, window, at};
    return std::nullopt;
  }

  void NoteAnswered(const ShortcutPress &first, NSTimeInterval now) {
    std::erase_if(answered_, [&](const ShortcutPress &press) { return now - press.at > kAnsweredLifetime; });
    answered_.push_back(first);
    if (answered_.size() > kAnsweredLimit) answered_.erase(answered_.begin());
  }

  bool WasAnsweredBySecondPress(NSString *shortcut, NSInteger window, NSTimeInterval at) {
    const auto found = std::find_if(answered_.begin(), answered_.end(), [&](const ShortcutPress &press) { return press.Is(shortcut, window, at); });
    if (found == answered_.end()) return false;
    answered_.erase(found);
    return true;
  }

  void ForgetFirstPress(NSString *shortcut, NSInteger window, NSTimeInterval at) {
    if (first_.Is(shortcut, window, at)) first_ = {};
  }

 private:
  ShortcutPress first_;
  std::vector<ShortcutPress> answered_;
};

}
