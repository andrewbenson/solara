// Copyright 2026 Solara. Apache-2.0.

#ifndef CHROME_BROWSER_SOLARA_AC_USER_HOOKS_H_
#define CHROME_BROWSER_SOLARA_AC_USER_HOOKS_H_

#include <cstdint>
#include <memory>
#include <optional>

#include "url/gurl.h"

namespace blink {
class URLLoaderThrottle;
}

namespace content {
class NavigationHandle;
class NavigationThrottleRegistry;
}

namespace solara {

void AddUserHooksThrottle(content::NavigationThrottleRegistry& registry);

std::unique_ptr<blink::URLLoaderThrottle> TakeUserHooksRewrite(
    std::optional<int64_t> navigation_id);

std::optional<GURL> PendingUserHooksRewrite(content::NavigationHandle& handle);

}

#endif
