#include "solara/core/ac_seams.h"

#include <memory>

#include "base/check.h"
#include "base/functional/callback.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/solara/ac_notifications.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "components/permissions/chooser_controller.h"
#include "components/sessions/core/live_tab.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_install_prompt_client.h"
#include "extensions/common/extension_id.h"
#include "solara/core/ac_hooks.h"
#include "solara/core/ac_browser.h"
#include "solara/core/ac_cast_dialog.h"
#include "solara/core/ac_browser_window.h"
#include "solara/core/ac_device_chooser.h"

namespace solaracore {

namespace {

bool HandlePasswordBubble(content::WebContents* web_contents) {
  WindowHost* host = WindowHost::ForBrowser(
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(web_contents));
  return host && host->OfferPasswordSave(web_contents);
}

bool HandleExtensionSidePanel(BrowserWindowInterface* browser_window,
                              content::WebContents* web_contents,
                              const extensions::ExtensionId& extension_id,
                              bool open) {
  content::WebContents* contents = web_contents;
  if (!contents && browser_window && browser_window->GetActiveTabInterface()) {
    contents = browser_window->GetActiveTabInterface()->GetContents();
  }
  BrowserWindowInterface* browser =
      contents ? GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents)
               : browser_window;
  if (!contents || !WindowHost::ForBrowser(browser)) {
    return false;
  }
  return HostExtensionSidePanel(contents, extension_id, open);
}

bool LiveTabSkipsRestore(sessions::LiveTab* live_tab, SessionID* source) {
  int32_t source_id = 0;
  if (!live_tab || !IsTemporaryTabId(live_tab->GetSessionID().id(), &source_id)) {
    return false;
  }
  if (source && source_id > 0) {
    *source = SessionID::FromSerializedValue(source_id);
  }
  return true;
}

bool OmitsFromSessionService(const BrowserWindowInterface* browser) {
  return ACBrowserWindow::IsOurs(browser);
}

bool IsHiddenFromExtensions(const BrowserWindowInterface* browser) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return host && host->internal();
}

bool KeepsWindowWithoutTabs(const BrowserWindowInterface* browser) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return host && !host->closing() && !browser_shutdown::IsTryingToQuit();
}

void BrowserCloseStarting(BrowserWindowInterface* browser) {
  if (WindowHost* host = WindowHost::ForBrowser(browser)) {
    host->BrowserCloseStarting(browser);
  }
}

bool KeepsTabOnClose(const BrowserWindowInterface* browser,
                     content::WebContents* contents) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return host && host->KeepsTabOnClose(browser, contents);
}

bool BrowserWillCloseTabs(BrowserWindowInterface* browser) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return !host || host->BrowserWillCloseTabs(browser);
}

void BrowserCloseCancelled(BrowserWindowInterface* browser) {
  if (WindowHost* host = WindowHost::ForBrowser(browser)) {
    host->BrowserCloseCancelled(browser);
  }
}

std::unique_ptr<BrowserWebContentsDelegate> CreateWebContentsDelegate(
    BrowserWindowInterface* browser,
    ExclusiveAccessManager& exclusive_access_manager,
    chrome::BrowserCommandController& command_controller,
    UnloadController& unload_controller,
    web_app::AppBrowserController* app_browser_controller,
    BrowserWindow& window,
    DesktopBrowserWindowCapabilities& capabilities,
    BrowserUiController& browser_ui_controller) {
  ACBrowserWindow* ours = ACBrowserWindow::FromWindow(&window);
  if (!ours) {
    return nullptr;
  }
  ours->Register(browser);
  return std::make_unique<ACWebContentsDelegate>(
      browser, exclusive_access_manager, command_controller, unload_controller,
      app_browser_controller, window, capabilities, browser_ui_controller,
      ours->host_weak());
}

void DevToolsDockChanged(BrowserWindowInterface* browser,
                         content::WebContents* inspected,
                         content::WebContents* devtools) {
  if (WindowHost* host = WindowHost::ForBrowser(browser)) {
    host->DevToolsDockChanged(inspected, devtools);
  }
}

}

void InstallChromeHooks() {
  CHECK(solara::NotificationBridgeConfigured());
  CHECK(!g_solara_notification_bridge_factory);
  g_solara_notification_bridge_factory = &solara::CreateNotificationPlatformBridge;
  g_solara_notification_provider_attempt = &solara::RecordNotificationProviderAttempt;
  g_solara_password_bubble = &HandlePasswordBubble;
  g_solara_extension_install_prompt = &HostExtensionInstallPrompt;
  g_solara_device_chooser = &HandleDeviceChooser;
  g_solara_wants_cast_dialog = &WantsCastDialog;
  g_solara_cast_dialog = &HandleCastDialog;
  g_solara_extension_side_panel = &HandleExtensionSidePanel;
  g_solara_hidden_from_extensions = &IsHiddenFromExtensions;
  g_solara_keeps_window_without_tabs = &KeepsWindowWithoutTabs;
  g_solara_browser_close_starting = &BrowserCloseStarting;
  g_solara_keeps_tab_on_close = &KeepsTabOnClose;
  g_solara_browser_will_close_tabs = &BrowserWillCloseTabs;
  g_solara_browser_close_cancelled = &BrowserCloseCancelled;
  g_solara_devtools_dock_changed = &DevToolsDockChanged;
  g_solara_create_web_contents_delegate = &CreateWebContentsDelegate;
  g_solara_initial_main_document_accessed = &InitialMainDocumentAccessed;
  g_solara_live_tab_skips_restore = &LiveTabSkipsRestore;
  g_solara_omits_from_session_service = &OmitsFromSessionService;
  g_solara_viewless_browsers = true;
  solara::NotificationHooksInstalled();
}

}
