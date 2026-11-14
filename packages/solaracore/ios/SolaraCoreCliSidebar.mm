#import "SolaraCoreEngineBridge.h"

#import <dlfcn.h>
#include <string.h>
#include "../../../engine/chromium/src/chrome/browser/solara/public/ac_engine.h"

namespace {
NSString * (^gSidebarHandler)(NSString *);

char *SidebarRequest(const char *json) {
  if (!NSThread.isMainThread || !gSidebarHandler) return nullptr;
  NSString *request = json ? [NSString stringWithUTF8String:json] : nil;
  if (!request) return nullptr;
  NSString *response = gSidebarHandler(request);
  return response ? strdup(response.UTF8String) : nullptr;
}
}

@implementation SolaraCoreCliSidebar

+ (BOOL)setHandler:(NSString * (^)(NSString *))handler {
  if (!NSThread.isMainThread) return NO;
  auto registration = (ac_cli_sidebar_register_v1_t)dlsym(RTLD_DEFAULT, "ac_cli_sidebar_register_v1");
  if (!registration) return NO;
  gSidebarHandler = [handler copy];
  registration(handler ? SidebarRequest : nullptr);
  return YES;
}

@end
