#ifndef SOLARA_CORE_AC_DEVICE_CHOOSER_H_
#define SOLARA_CORE_AC_DEVICE_CHOOSER_H_

#import <Foundation/Foundation.h>

#include <memory>

#include "base/functional/callback.h"
#include "base/functional/callback_helpers.h"

namespace content {
class RenderFrameHost;
class WebContents;
}

namespace permissions {
class ChooserController;
}

namespace solaracore {

bool HandleDeviceChooser(content::RenderFrameHost* requester,
                         std::unique_ptr<permissions::ChooserController>* controller,
                         base::ScopedClosureRunner* fullscreen_blocker,
                         base::OnceClosure* close_closure);
void RetireStaleDeviceChoosers();
void RetireDeviceChoosersForTab(content::WebContents* contents);
void SelectDevice(int chooser_id, int option_id);
void CancelDeviceChooser(int chooser_id);
void RefreshDeviceChooser(int chooser_id);
void OpenDeviceChooserSettings(int chooser_id);
bool ShowTestBluetoothChooser(content::WebContents* contents, bool unauthorized);
NSArray<NSDictionary*>* TestChooserEvents();

bool HostWantsDeviceChoosers();
void HostDeviceChooser(content::WebContents* contents, NSDictionary* state);

}

#endif
