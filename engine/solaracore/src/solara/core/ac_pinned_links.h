#ifndef SOLARA_CORE_AC_PINNED_LINKS_H_
#define SOLARA_CORE_AC_PINNED_LINKS_H_

#include <memory>

#include "ui/base/window_open_disposition.h"

class GURL;
namespace blink::mojom {
class WindowFeatures;
}
namespace content {
class NavigationThrottleRegistry;
class WebContents;
}

namespace solaracore {

void InstallPinnedLinkHooks();
void AddPinnedLinkThrottle(content::NavigationThrottleRegistry& registry);
bool WantsPinnedLinkPolicy(content::WebContents* contents);
bool HasPlainPinnedLinkGesture(content::WebContents* contents);
content::WebContents* ParkPinnedLink(
    content::WebContents* source,
    std::unique_ptr<content::WebContents> contents,
    const GURL& target,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& features);

}

#endif
