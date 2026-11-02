#pragma once

#import <AppKit/AppKit.h>

namespace solaracore_popup {

inline NSWindowCollectionBehavior CollectionBehavior(NSWindowCollectionBehavior behavior) {
  behavior &= ~NSWindowCollectionBehaviorPrimary;
  behavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
  behavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
  return behavior;
}

struct SpaceMove {
  NSWindowCollectionBehavior temporary;
  NSWindowCollectionBehavior restore;
};

inline SpaceMove MoveToActiveSpace(NSWindowCollectionBehavior behavior) {
  return {(behavior | NSWindowCollectionBehaviorMoveToActiveSpace) & ~NSWindowCollectionBehaviorCanJoinAllSpaces, behavior};
}

}
