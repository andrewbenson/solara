#ifndef CHROME_BROWSER_SOLARA_AC_NOTIFICATIONS_H_
#define CHROME_BROWSER_SOLARA_AC_NOTIFICATIONS_H_

#include <memory>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "chrome/browser/notifications/notification_platform_bridge.h"
#include "chrome/browser/solara/public/ac_engine.h"

namespace solara {

enum class NotificationReleaseReason {
  kProfileUnload,
  kPrivateEnd,
  kSystemShutdown,
  kProfileDelete,
  kBrowserShutdown,
};

std::unique_ptr<NotificationPlatformBridge> CreateNotificationPlatformBridge();
bool NotificationBridgeConfigured();
void InitializeNotificationBridgeCoverage();
void NotificationHooksInstalled();
void DisplayNotificationWithPrivateProvenance(
    Profile* exact_private,
    NotificationHandler::Type type,
    const message_center::Notification& notification,
    std::unique_ptr<NotificationCommon::Metadata> metadata);
void RegisterNotificationProfile(Profile* profile);
void ReleaseNotificationProfile(Profile* profile,
                                NotificationReleaseReason reason);
void ReleaseNotificationProfilePath(
    const base::FilePath& profile_path,
    NotificationReleaseReason reason,
    base::OnceCallback<void(bool)> fenced);
void BeginNotificationDrain(base::OnceClosure continuation);
void RecordNotificationProviderAttempt(const char* kind);

}

#endif
