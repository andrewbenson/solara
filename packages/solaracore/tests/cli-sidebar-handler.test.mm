#import "../ios/SolaraCoreEngineBridge.h"
#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"

#include <cassert>
#include <cstdlib>
#include <string>

static ac_cli_sidebar_handler_v1_t registered;

#ifndef SOLARA_TEST_NO_SIDEBAR_EXPORT
extern "C" AC_ENGINE_EXPORT void ac_cli_sidebar_register_v1(ac_cli_sidebar_handler_v1_t handler) {
  registered = handler;
}
#endif

int main() {
  @autoreleasepool {
#ifdef SOLARA_TEST_NO_SIDEBAR_EXPORT
    assert(![SolaraCoreCliSidebar setHandler:^NSString *(NSString *) { return @"{}"; }]);
    assert(!registered);
#else
    __block int edits = 0;
    assert([SolaraCoreCliSidebar setHandler:^NSString *(NSString *request) {
      if ([request isEqualToString:@"edit"]) ++edits;
      return @"{\"changes\":[\"renamed\"]}";
    }]);
    assert(registered);
    dispatch_semaphore_t offMain = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      assert(!NSThread.isMainThread);
      assert(!registered("edit"));
      assert(![SolaraCoreCliSidebar setHandler:nil]);
      dispatch_semaphore_signal(offMain);
    });
    assert(dispatch_semaphore_wait(offMain, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 5)) == 0);
    assert(registered && edits == 0);
    char *first = registered("edit");
    assert(first && std::string(first) == "{\"changes\":[\"renamed\"]}" && edits == 1);
    assert([SolaraCoreCliSidebar setHandler:^NSString *(NSString *) { return @"{\"changes\":[]}"; }]);
    char *second = registered("read");
    assert(second && std::string(second) == "{\"changes\":[]}");
    assert(std::string(first) == "{\"changes\":[\"renamed\"]}");
    free(first);
    free(second);
    assert([SolaraCoreCliSidebar setHandler:nil]);
    assert(!registered);
    assert(edits == 1);
#endif
  }
}
