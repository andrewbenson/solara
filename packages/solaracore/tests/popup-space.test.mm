#include "../ios/SolaraCorePopupSpace.h"

#include <cstdio>

using namespace solaracore_popup;

static int failures = 0;
#define CHECK(cond)                                                \
  do {                                                             \
    if (!(cond)) {                                                 \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
      failures++;                                                  \
    }                                                              \
  } while (0)

int main() {
  const NSWindowCollectionBehavior primary = NSWindowCollectionBehaviorPrimary | NSWindowCollectionBehaviorFullScreenPrimary;
  const NSWindowCollectionBehavior preserved = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle;
  const NSWindowCollectionBehavior auxiliary = NSWindowCollectionBehaviorFullScreenAuxiliary;
  CHECK(CollectionBehavior(NSWindowCollectionBehaviorDefault) == auxiliary);
  CHECK(CollectionBehavior(primary) == auxiliary);
  CHECK(CollectionBehavior(primary | preserved) == (auxiliary | preserved));
  CHECK(CollectionBehavior(auxiliary | preserved) == (auxiliary | preserved));
  CHECK(CollectionBehavior(primary | NSWindowCollectionBehaviorCanJoinAllSpaces) ==
        (auxiliary | NSWindowCollectionBehaviorCanJoinAllSpaces));

  const SpaceMove move = MoveToActiveSpace(auxiliary | preserved | NSWindowCollectionBehaviorCanJoinAllSpaces);
  CHECK(move.temporary == (auxiliary | preserved | NSWindowCollectionBehaviorMoveToActiveSpace));
  CHECK(move.restore == (auxiliary | preserved | NSWindowCollectionBehaviorCanJoinAllSpaces));
  CHECK(!(move.temporary & NSWindowCollectionBehaviorCanJoinAllSpaces));
  CHECK(!(move.restore & NSWindowCollectionBehaviorMoveToActiveSpace));
  const SpaceMove alreadyMoving = MoveToActiveSpace(auxiliary | NSWindowCollectionBehaviorMoveToActiveSpace);
  CHECK(alreadyMoving.temporary == (auxiliary | NSWindowCollectionBehaviorMoveToActiveSpace));
  CHECK(alreadyMoving.restore == (auxiliary | NSWindowCollectionBehaviorMoveToActiveSpace));
  const SpaceMove empty = MoveToActiveSpace(NSWindowCollectionBehaviorDefault);
  CHECK(empty.temporary == NSWindowCollectionBehaviorMoveToActiveSpace);
  CHECK(empty.restore == NSWindowCollectionBehaviorDefault);

  if (failures) return 1;
  std::printf("popup-space: ok\n");
  return 0;
}
