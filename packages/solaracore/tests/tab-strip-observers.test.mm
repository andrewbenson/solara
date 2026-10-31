#include "../ios/SolaraCoreTabStripObservers.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace solaracore_tab_strip;

static int failures = 0;
#define CHECK(cond)                                                \
  do {                                                             \
    if (!(cond)) {                                                 \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
      failures++;                                                  \
    }                                                              \
  } while (0)

static NSDictionary *Tx(int rev) { return @{@"rev" : @(rev)}; }

int main() {
  @autoreleasepool {
    {
      Observers list;
      Observers *shared = &list;
      std::vector<std::string> heard;
      __block std::vector<std::string> *log = &heard;
      __block NSInteger second = 0;
      list.Add(^(NSDictionary *tx) {
        log->push_back("a" + std::to_string([tx[@"rev"] intValue]));
        shared->Remove(second);
      });
      second = list.Add(^(NSDictionary *tx) { log->push_back("b" + std::to_string([tx[@"rev"] intValue])); });
      list.Deliver(Tx(1));
      list.Deliver(Tx(2));
      CHECK((heard == std::vector<std::string>{"a1", "a2"}));
    }
    {
      Observers list;
      Observers *shared = &list;
      __block int calls = 0;
      __block NSInteger self_ = 0;
      self_ = list.Add(^(NSDictionary *) {
        calls++;
        shared->Remove(self_);
      });
      list.Deliver(Tx(1));
      list.Deliver(Tx(2));
      CHECK(calls == 1);
      CHECK(list.Empty());
    }
    {
      Observers list;
      Observers *shared = &list;
      std::vector<std::string> heard;
      __block std::vector<std::string> *log = &heard;
      __block bool added = false;
      list.Add(^(NSDictionary *tx) {
        log->push_back("a" + std::to_string([tx[@"rev"] intValue]));
        if (added) return;
        added = true;
        shared->Add(^(NSDictionary *later) { log->push_back("c" + std::to_string([later[@"rev"] intValue])); });
      });
      list.Deliver(Tx(1));
      list.Deliver(Tx(2));
      CHECK((heard == std::vector<std::string>{"a1", "a2", "c2"}));
    }
    {
      Observers list;
      Observers *shared = &list;
      std::vector<std::string> heard;
      __block std::vector<std::string> *log = &heard;
      list.Add(^(NSDictionary *tx) {
        const int rev = [tx[@"rev"] intValue];
        log->push_back("a" + std::to_string(rev));
        if (rev == 1) shared->Deliver(Tx(2));
      });
      list.Add(^(NSDictionary *tx) { log->push_back("b" + std::to_string([tx[@"rev"] intValue])); });
      list.Deliver(Tx(1));
      CHECK((heard == std::vector<std::string>{"a1", "b1", "a2", "b2"}));
    }
    {
      Observers list;
      __block int calls = 0;
      const NSInteger token = list.Add(^(NSDictionary *) { calls++; });
      list.Remove(token);
      list.Remove(token);
      list.Remove(token + 41);
      list.Deliver(Tx(1));
      CHECK(calls == 0);
      CHECK(list.Empty());
      CHECK(list.Add(^(NSDictionary *) {}) != token);
    }
    {
      Observers list;
      std::vector<std::string> heard;
      __block std::vector<std::string> *log = &heard;
      list.ClaimCommands();
      list.Add(^(NSDictionary *tx) { log->push_back("swift" + std::to_string([tx[@"rev"] intValue])); });
      list.SetHandler(^(NSDictionary *tx) { log->push_back("js" + std::to_string([tx[@"rev"] intValue])); });
      list.Deliver(Tx(1));
      list.SetHandler(^(NSDictionary *tx) { log->push_back("late" + std::to_string([tx[@"rev"] intValue])); });
      list.Deliver(Tx(2));
      list.SetHandler(nil);
      list.Deliver(Tx(3));
      CHECK((heard == std::vector<std::string>{"swift1", "js1", "swift2", "late2", "swift3"}));
      CHECK(list.CommandsClaimed());
    }
    {
      Observers list;
      Observers *shared = &list;
      std::vector<std::string> heard;
      __block std::vector<std::string> *log = &heard;
      list.SetHandler(^(NSDictionary *tx) {
        const int rev = [tx[@"rev"] intValue];
        log->push_back("old" + std::to_string(rev));
        shared->SetHandler(^(NSDictionary *later) { log->push_back("new" + std::to_string([later[@"rev"] intValue])); });
        if (rev == 1) shared->Deliver(Tx(2));
      });
      list.Add(^(NSDictionary *tx) { log->push_back("b" + std::to_string([tx[@"rev"] intValue])); });
      list.Deliver(Tx(1));
      list.Deliver(Tx(3));
      CHECK((heard == std::vector<std::string>{"old1", "b1", "b2", "new2", "b3", "new3"}));
    }
  }
  if (failures) return 1;
  std::printf("tab-strip-observers: ok\n");
  return 0;
}
