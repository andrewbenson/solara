#pragma once

#import <Foundation/Foundation.h>

namespace solaracore_tabs {

inline bool ShouldAnnounceInsertedTab(bool awaitingApp, NSString *disposition) {
  return awaitingApp && ![disposition isEqualToString:@"popup"];
}

}
