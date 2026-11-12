#import "solara/core/public/SolaraCore.h"

#include <cmath>
#include <map>
#include <sstream>
#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/task/thread_pool.h"
#include "content/public/browser/browser_thread.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/solara/ac_product.h"  // nogncheck
#include "chrome/browser/solara/ac_tab_restore.h"  // nogncheck
#include "chrome/browser/devtools/devtools_contents_resizing_strategy.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "base/metrics/user_metrics.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "chrome/browser/ui/tab_contents/core_tab_helper.h"
#include "chrome/common/content_restriction.h"
#include "chrome/common/pref_names.h"
#include "content/public/common/url_utils.h"
#include "components/policy/core/common/policy_pref_names.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "pdf/buildflags.h"
#include "printing/buildflags/buildflags.h"
#if BUILDFLAG(ENABLE_PDF)
#include "chrome/browser/pdf/pdf_extension_util.h"
#include "pdf/pdf_features.h"
#endif
#if BUILDFLAG(ENABLE_PRINTING)
#include "chrome/browser/printing/print_view_manager_common.h"
#endif
#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
#include "chrome/browser/printing/print_preview_dialog_controller.h"
#endif
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "components/keep_alive_registry/keep_alive_registry.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "content/public/browser/browsing_data_remover.h"
#include "components/prefs/pref_service.h"
#include "base/scoped_observation.h"
#include "base/supports_user_data.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/solara/ac_notifications.h"
#include "base/command_line.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_commands.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/media_session.h"
#include "components/version_info/version_info.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/reload_type.h"
#include "content/public/browser/render_frame_host.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "url/scheme_host_port.h"
#include "url/url_constants.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/browser/renderer_host/render_widget_host_impl.h"  // nogncheck
#include "content/browser/renderer_host/render_widget_host_view_mac.h"  // nogncheck
#include "content/public/browser/spare_render_process_host_manager.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension.h"
#include "solara/core/ac_extension_shortcuts.h"
#include "solara/core/ac_hooks.h"
#include "solara/core/ac_autofill_prompt.h"
#include "solara/core/ac_browser.h"
#include "solara/core/ac_content_hooks.h"
#include "solara/core/ac_contents_background.h"
#include "solara/core/ac_browser_window.h"
#include "solara/core/ac_extension_view.h"
#include "solara/core/ac_installed_bubble.h"
#include "solara/core/ac_lifetime.h"
#include "solara/core/ac_main_delegate.h"
#include "solara/core/ac_video_upscaling.h"
#include "solara/core/ac_navigation_hold.h"
#include "solara/core/ac_page_channel.h"
#include "solara/core/ac_password_prompt.h"
#include "solara/core/ac_tab_info.h"
#include "solara/core/ac_permissions.h"
#include "chrome/browser/ui/tab_sharing/tab_sharing_infobar_delegate.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/infobar.h"
#include "chrome/browser/ui/browser_window/public/desktop_browser_window_capabilities.h"
#include "base/pickle.h"
#include "chrome/browser/ui/browser_tabrestore.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "components/sessions/core/serialized_user_agent_override.h"
#include "solara/core/ac_device_chooser.h"
#include "solara/core/ac_cast_dialog.h"
#include "solara/core/ac_desktop_capture.h"
#include "solara/core/ac_devtools_call.h"
#include "solara/core/ac_host_visibility.h"
#include "solara/core/ac_picture_in_picture.h"
#include "solara/core/ac_autofill_trigger.h"
#include "base/trace_event/trace_config.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/picture_in_picture/auto_picture_in_picture_tab_helper.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/tracing_controller.h"
#include "content/public/browser/web_contents_media_capture_id.h"
#include "extensions/browser/install_prompt_data.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile_destroyer.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "chrome/browser/extensions/component_loader.h"
#include "extensions/common/manifest.h"
#include "extensions/common/mojom/manifest.mojom-shared.h"
#include "solara/core/ac_external_apps.h"
#include "base/base64.h"
#include "chrome/browser/extensions/api/side_panel/side_panel_service.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/resource_coordinator/lifecycle_unit_state.mojom.h"
#include "chrome/browser/resource_coordinator/tab_lifecycle_unit_external.h"
#include "base/json/values_util.h"
#include "chrome/browser/performance_manager/policies/cannot_discard_reason.h"
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
#include "chrome/browser/performance_manager/policies/page_discarding_helper.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "components/performance_manager/public/user_tuning/prefs.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "base/auto_reset.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "chrome/browser/apps/platform_apps/shortcut_manager.h"
#include "base/strings/string_number_conversions.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "components/blocked_content/popup_blocker_tab_helper.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/zoom/page_zoom.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/common/page_zoom.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "third_party/skia/include/core/SkColor.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColorSpace.h"
#include "third_party/skia/include/core/SkData.h"
#include "third_party/skia/include/encode/SkICC.h"
#include "third_party/skia/modules/skcms/skcms.h"
#include <algorithm>
#include <optional>
#import "solara/core/solaracore_internal.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/mac/coordinate_conversion.h"

extern "C" int ChromeMain(int argc, const char** argv);

@interface SolaraCoreProfile (Lifetime)
- (void)profileWillBeDestroyed;
@end

namespace {

id<SolaraCoreEngineDelegate> __strong g_delegate;
SolaraCoreEngine* __strong g_engine;

NSString* NS(const std::string& s) {
  return base::SysUTF8ToNSString(s);
}

CGImageRef CreatePicture(const SkBitmap& bitmap) {
  if (bitmap.drawsNothing() || bitmap.bytesPerPixel() != 4 ||
      (bitmap.colorType() != kBGRA_8888_SkColorType &&
       bitmap.colorType() != kRGBA_8888_SkColorType)) {
    return nullptr;
  }
  const bool opaque = bitmap.alphaType() == kOpaque_SkAlphaType;
  const CGBitmapInfo info =
      bitmap.colorType() == kBGRA_8888_SkColorType
          ? kCGBitmapByteOrder32Little |
                (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst)
          : kCGBitmapByteOrder32Big |
                (opaque ? kCGImageAlphaNoneSkipLast : kCGImageAlphaPremultipliedLast);
  CGColorSpaceRef space = nullptr;
  if (SkColorSpace* sk = bitmap.colorSpace()) {
    skcms_TransferFunction fn;
    skcms_Matrix3x3 toXYZD50;
    if (sk->isNumericalTransferFn(&fn) && sk->toXYZD50(&toXYZD50)) {
      if (sk_sp<SkData> icc = SkWriteICCProfile(fn, toXYZD50)) {
        CFDataRef data = CFDataCreate(nullptr, icc->bytes(), icc->size());
        space = CGColorSpaceCreateWithICCData(data);
        CFRelease(data);
      }
    }
  }
  if (!space) {
    space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  }
  CFDataRef pixels = CFDataCreate(nullptr, static_cast<const UInt8*>(bitmap.getPixels()),
                                  bitmap.computeByteSize());
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
  CGImageRef image = CGImageCreate(bitmap.width(), bitmap.height(), 8, 32, bitmap.rowBytes(),
                                   space, info, provider, nullptr, false,
                                   kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  CFRelease(pixels);
  CGColorSpaceRelease(space);
  return image;
}

NSString* NS(const std::u16string& s) {
  return base::SysUTF16ToNSString(s);
}

std::map<Profile*, SolaraCoreProfile*>& ProfileWrappers() {
  static base::NoDestructor<std::map<Profile*, SolaraCoreProfile*>> wrappers;
  return *wrappers;
}

class ProfileGoneObserver : public ProfileObserver {
 public:
  ProfileGoneObserver(Profile* profile, SolaraCoreProfile* wrapper)
      : wrapper_(wrapper) {
    observation_.Observe(profile);
  }
  void OnProfileWillBeDestroyed(Profile* profile) override {
    observation_.Reset();
    const solara::NotificationReleaseReason reason =
        solaracore::IsProfileDeleting(profile)
            ? solara::NotificationReleaseReason::kProfileDelete
            : profile->IsOffTheRecord()
                  ? solara::NotificationReleaseReason::kPrivateEnd
                  : solara::NotificationReleaseReason::kProfileUnload;
    solaracore::NoteProfileDying(profile);
    solara::ReleaseNotificationProfile(profile, reason);
    [wrapper_ profileWillBeDestroyed];
  }

 private:
  __weak SolaraCoreProfile* wrapper_;
  base::ScopedObservation<Profile, ProfileObserver> observation_{this};
};

id HexColor(SkColor color) {
  if (!SkColorGetA(color)) {
    return NSNull.null;
  }
  return [NSString stringWithFormat:@"#%02x%02x%02x", SkColorGetR(color),
                                    SkColorGetG(color), SkColorGetB(color)];
}

NSString* PngDataURL(const gfx::Image& image) {
  if (image.IsEmpty()) {
    return @"";
  }
  const gfx::ImageSkiaRep& rep = image.ToImageSkia()->GetRepresentation(2.0f);
  std::optional<std::vector<uint8_t>> png = gfx::PNGCodec::EncodeBGRASkBitmap(
      rep.GetBitmap(), false);
  if (!png) {
    return @"";
  }
  return NS("data:image/png;base64," + base::Base64Encode(*png));
}

bool g_auto_picture_in_picture = true;

void ApplyAutoPictureInPicture(Profile* profile) {
  g_solara_auto_picture_in_picture_off = !g_auto_picture_in_picture;
  HostContentSettingsMapFactory::GetForProfile(profile)->SetDefaultContentSetting(
      ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
      g_auto_picture_in_picture ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
}

void PrepareProfilePrefs(Profile* profile) {
  if (!profile) {
    return;
  }
  solara::RegisterNotificationProfile(profile);
  if (profile->IsOffTheRecord()) {
    return;
  }
  PrefService* prefs = profile->GetPrefs();
  if (prefs->FindPreference("session.restore_on_startup")) {
    prefs->SetInteger("session.restore_on_startup", 5);
  }
  if (prefs->FindPreference("download_bubble.partial_view_enabled")) {
    prefs->SetBoolean("download_bubble.partial_view_enabled", false);
  }
  ApplyAutoPictureInPicture(profile);
}

bool IsRegularLoadedProfile(Profile* profile) {
  return profile && !profile->IsOffTheRecord() && !profile->IsGuestSession() &&
         !profile->IsSystemProfile() && !solaracore::IsProfileDying(profile) &&
         !solaracore::IsProfileDeleting(profile) &&
         !IsProfileDirectoryMarkedForDeletion(profile->GetPath());
}

void NotifyProfileLoaded(const base::FilePath& path) {
  ProfileManager* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  Profile* profile = manager ? manager->GetProfileByPath(path) : nullptr;
  if (IsRegularLoadedProfile(profile) &&
      [g_delegate respondsToSelector:@selector(engine:didLoadProfile:)]) {
    [g_delegate engine:g_engine didLoadProfile:[SolaraCoreProfile wrapperFor:profile]];
  }
}

class ProfilePrefsApplier : public ProfileManagerObserver {
 public:
  explicit ProfilePrefsApplier(ProfileManager* manager) {
    observation_.Observe(manager);
  }
  void OnProfileAdded(Profile* profile) override {
    PrepareProfilePrefs(profile);
    if (!profile->IsOffTheRecord()) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&NotifyProfileLoaded, profile->GetPath()));
    }
  }
  void OnProfileManagerDestroying() override { observation_.Reset(); }

 private:
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> observation_{this};
};

void StartApplyingProfilePrefs() {
  ProfileManager* manager = g_browser_process->profile_manager();
  for (Profile* profile : manager->GetLoadedProfiles()) {
    PrepareProfilePrefs(profile);
  }
  static base::NoDestructor<ProfilePrefsApplier> applier(manager);
}

bool IsHostPreference(const std::string& name) {
  static const char* const kAllowed[] = {
      "credentials_enable_service", "autofill.profile_enabled",
      "autofill.credit_card_enabled", "download_bubble.partial_view_enabled"};
  for (const char* allowed : kAllowed) {
    if (name == allowed) {
      return true;
    }
  }
  return false;
}

class BrowsingDataDone : public content::BrowsingDataRemover::Observer {
 public:
  BrowsingDataDone(content::BrowsingDataRemover* remover, void (^completion)(void))
      : completion_(completion) {
    observation_.Observe(remover);
  }
  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    if (completion_) {
      completion_();
    }
    delete this;
  }

 private:
  void (^completion_)(void);
  base::ScopedObservation<content::BrowsingDataRemover,
                          content::BrowsingDataRemover::Observer>
      observation_{this};
};

}

namespace {

const char* BrowserTypeName(BrowserWindowInterface::Type type) {
  switch (type) {
    case BrowserWindowInterface::TYPE_NORMAL:
      return "normal";
    case BrowserWindowInterface::TYPE_POPUP:
      return "popup";
    case BrowserWindowInterface::TYPE_DEVTOOLS:
      return "devtools";
    case BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE:
      return "picture_in_picture";
    default:
      return "app";
  }
}

BrowserWindow* WindowForChromeBrowser(Browser* browser) {
  if (solaracore::ACBrowserWindow::IsOurs(browser) ||
      browser->GetType() == BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE ||
      ![g_delegate respondsToSelector:@selector
                   (engineWindowForNewBrowserOfProfile:type:)]) {
    return nullptr;
  }
  SolaraCoreWindow* window = [g_delegate
      engineWindowForNewBrowserOfProfile:[SolaraCoreProfile
                                             wrapperFor:browser->GetProfile()]
                                    type:@(BrowserTypeName(browser->GetType()))];
  solaracore::WindowHost* host = window.host;
  return host ? host->HostChromeBrowser(browser) : nullptr;
}

}

namespace solaracore {

namespace {
std::vector<base::WeakPtr<Profile>>& DyingProfiles() {
  static base::NoDestructor<std::vector<base::WeakPtr<Profile>>> dying;
  return *dying;
}
}

void NoteProfileDying(Profile* profile) {
  if (profile && !IsProfileDying(profile)) {
    DyingProfiles().push_back(profile->GetWeakPtr());
  }
}

bool IsProfileDying(const Profile* profile) {
  std::erase_if(DyingProfiles(), [](const base::WeakPtr<Profile>& p) { return !p; });
  return profile && std::ranges::any_of(DyingProfiles(), [&](const base::WeakPtr<Profile>& p) {
           return p.get() == profile;
         });
}

namespace {
class GoneNotifier : public base::SupportsUserData::Data {
 public:
  static const void* Key() {
    static const int key = 0;
    return &key;
  }
  ~GoneNotifier() override {
    for (base::OnceClosure& waiter : waiters_) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, std::move(waiter));
    }
  }
  void Add(base::OnceClosure waiter) { waiters_.push_back(std::move(waiter)); }

 private:
  std::vector<base::OnceClosure> waiters_;
};

void WhenProfileGone(Profile* profile, base::OnceClosure done) {
  auto* notifier = static_cast<GoneNotifier*>(profile->GetUserData(GoneNotifier::Key()));
  if (!notifier) {
    auto owned = std::make_unique<GoneNotifier>();
    notifier = owned.get();
    profile->SetUserData(GoneNotifier::Key(), std::move(owned));
  }
  notifier->Add(std::move(done));
}
}

namespace {
std::vector<base::WeakPtr<Profile>>& DeletingProfiles() {
  static base::NoDestructor<std::vector<base::WeakPtr<Profile>>> deleting;
  return *deleting;
}
}

void NoteProfileDeleting(Profile* profile) {
  if (profile && !IsProfileDeleting(profile)) {
    DeletingProfiles().push_back(profile->GetWeakPtr());
  }
}

bool IsProfileDeleting(const Profile* profile) {
  std::erase_if(DeletingProfiles(), [](const base::WeakPtr<Profile>& p) { return !p; });
  return profile && std::ranges::any_of(DeletingProfiles(), [&](const base::WeakPtr<Profile>& p) {
           return p.get() == profile;
         });
}

void HostPermissionRequest(content::WebContents* contents, NSDictionary* request) {
  if ([g_delegate respondsToSelector:@selector(engine:permissionRequest:tab:)]) {
    [g_delegate engine:g_engine
        permissionRequest:request
                      tab:TabBridge::GetOrCreate(contents)->tab()];
  }
}

namespace {

std::string InstallPromptTypeName(extensions::InstallPromptData::PromptType type) {
  switch (type) {
    case extensions::InstallPromptData::INSTALL_PROMPT:
      return "install";
    case extensions::InstallPromptData::RE_ENABLE_PROMPT:
      return "re-enable";
    case extensions::InstallPromptData::PERMISSIONS_PROMPT:
      return "permissions";
    case extensions::InstallPromptData::EXTERNAL_INSTALL_PROMPT:
      return "external";
    case extensions::InstallPromptData::REMOTE_INSTALL_PROMPT:
      return "remote";
    case extensions::InstallPromptData::REPAIR_PROMPT:
      return "repair";
    default:
      return "other";
  }
}

using InstallDone = extensions::ExtensionInstallPromptClient::DoneCallback;

struct PendingInstall {
  InstallDone done;
  base::WeakPtr<Profile> profile;
};

std::map<std::string, PendingInstall>& InstallPrompts() {
  static base::NoDestructor<std::map<std::string, PendingInstall>> prompts;
  return *prompts;
}

}

bool HostExtensionInstallPrompt(Profile* profile,
                                content::WebContents* parent,
                                const extensions::InstallPromptData& prompt,
                                InstallDone* done_callback) {
  const extensions::Extension* extension = prompt.extension();
  if (!extension || !done_callback || done_callback->is_null() ||
      ![g_delegate respondsToSelector:@selector(engine:extensionInstallPrompt:tab:)]) {
    return false;
  }
  if (prompt.type() == extensions::InstallPromptData::EXTERNAL_INSTALL_PROMPT) {
    using Payload = extensions::ExtensionInstallPromptClient::DoneCallbackPayload;
    using Result = extensions::ExtensionInstallPromptClient::Result;
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE,
        base::BindOnce(std::move(*done_callback), Payload(Result::ABORTED)));
    return true;
  }
  static int last_id = 0;
  const std::string request_id = "install" + std::to_string(++last_id);
  NSMutableArray* permissions = [NSMutableArray array];
  for (size_t i = 0; i < prompt.GetPermissionCount(); ++i) {
    [permissions addObject:NS(prompt.GetPermission(i))];
  }
  NSString* icon = @"";
  if (!prompt.icon().IsEmpty()) {
    if (auto png = prompt.icon().As1xPNGBytes(); png && png->size()) {
      icon = NS("data:image/png;base64," +
                base::Base64Encode(base::span<const uint8_t>(*png)));
    }
  }
  NSDictionary* payload = @{
    @"requestId" : NS(request_id),
    @"profile" : NS(profile->GetOriginalProfile()->GetBaseName().value()),
    @"id" : NS(extension->id()),
    @"name" : NS(extension->name()),
    @"version" : NS(extension->VersionString()),
    @"type" : NS(InstallPromptTypeName(prompt.type())),
    @"icon" : icon,
    @"permissions" : permissions,
  };
  InstallPrompts()[request_id] = {std::move(*done_callback), profile->GetWeakPtr()};
  SolaraCoreTab* tab = parent ? TabBridge::GetOrCreate(parent)->tab() : nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    [g_delegate engine:g_engine extensionInstallPrompt:payload tab:tab];
  });
  return true;
}

void ResolveExtensionInstallPrompt(const std::string& request_id, bool accepted) {
  auto it = InstallPrompts().find(request_id);
  if (it == InstallPrompts().end()) {
    return;
  }
  PendingInstall pending = std::move(it->second);
  InstallPrompts().erase(it);
  if (!pending.profile) {
    return;
  }
  InstallDone done = std::move(pending.done);
  using Payload = extensions::ExtensionInstallPromptClient::DoneCallbackPayload;
  using Result = extensions::ExtensionInstallPromptClient::Result;
  std::move(done).Run(Payload(accepted ? Result::ACCEPTED : Result::USER_CANCELED));
}

void HostCastRoutes(Profile* profile, NSArray* routes) {
  if ([g_delegate respondsToSelector:@selector(engine:castRoutes:profile:)]) {
    [g_delegate engine:g_engine castRoutes:routes profile:[SolaraCoreProfile wrapperFor:profile]];
  }
}

bool HostWantsCastDialogs() {
  return [g_delegate respondsToSelector:@selector(engine:castDialog:tab:)];
}

void HostCastDialog(content::WebContents* contents, NSDictionary* state) {
  if (HostWantsCastDialogs()) {
    [g_delegate engine:g_engine castDialog:state tab:TabBridge::GetOrCreate(contents)->tab()];
  }
}

bool HostWantsDeviceChoosers() {
  return [g_delegate respondsToSelector:@selector(engine:deviceChooser:tab:)];
}

void HostDeviceChooser(content::WebContents* contents, NSDictionary* state) {
  if (HostWantsDeviceChoosers()) {
    [g_delegate engine:g_engine
         deviceChooser:state
                   tab:TabBridge::GetOrCreate(contents)->tab()];
  }
}

bool HostExtensionSidePanel(content::WebContents* contents,
                            const std::string& extension_id,
                            bool open) {
  if (![g_delegate respondsToSelector:@selector(engine:extensionSidePanel:tab:)]) {
    return false;
  }
  [g_delegate engine:g_engine
      extensionSidePanel:@{@"extensionId" : NS(extension_id), @"open" : @(open)}
                     tab:TabBridge::GetOrCreate(contents)->tab()];
  return true;
}

bool HostExtensionActionPopup(content::WebContents* contents,
                              const std::string& extension_id) {
  if (![g_delegate respondsToSelector:@selector(engine:extensionActionPopup:tab:)]) {
    return false;
  }
  return [g_delegate engine:g_engine
       extensionActionPopup:@{@"extensionId" : NS(extension_id)}
                        tab:TabBridge::GetOrCreate(contents)->tab()];
}

bool HostReservesKey(NSString* key, NSString* unshifted_key, unsigned long modifiers) {
  return [g_delegate respondsToSelector:@selector(engineIsReservedKey:unshiftedKey:modifiers:)] &&
         [g_delegate engineIsReservedKey:key unshiftedKey:unshifted_key modifiers:modifiers];
}

bool HostExtensionActionShortcut(content::WebContents* contents,
                                 const std::string& extension_id) {
  if (![g_delegate respondsToSelector:@selector(engine:extensionActionShortcut:tab:)]) {
    return false;
  }
  return [g_delegate engine:g_engine
      extensionActionShortcut:@{@"extensionId" : NS(extension_id)}
                          tab:TabBridge::GetOrCreate(contents)->tab()];
}

void HostPermissionRequestDismissed(NSString* request_id) {
  if ([g_delegate respondsToSelector:@selector(engine:permissionRequestDismissed:)]) {
    [g_delegate engine:g_engine permissionRequestDismissed:request_id];
  }
}

}

extern "C" __attribute__((visibility("default"))) int SolaraCoreMain(
    int argc,
    const char** argv) {
  return ChromeMain(argc, argv);
}

@implementation SolaraCoreEngine

+ (int)runWithArgc:(int)argc
              argv:(const char**)argv
          delegate:(id<SolaraCoreEngineDelegate>)delegate {
  bool is_browser = true;
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "--type=", 7) == 0) {
      is_browser = false;
    }
  }
  if (!is_browser) {
    return ChromeMain(argc, argv);
  }

  g_delegate = delegate;
  g_engine = [[SolaraCoreEngine alloc] init];
  g_solara_browser_window_factory = &WindowForChromeBrowser;
  solaracore::InstallRuleMatchedHook();
  solaracore::InstallExtensionInstalledHook();
  solaracore::InstallActionPopupHook();
  g_solara_reserved_accelerator = [](const ui::Accelerator& accelerator) {
    NSEvent* event = NSApp.currentEvent;
    return event.type == NSEventTypeKeyDown &&
           solaracore::ExtensionShortcuts::AcceleratorFor(event) == accelerator &&
           [g_delegate respondsToSelector:@selector(engineIsReservedKeyEvent:)] &&
           [g_delegate engineIsReservedKeyEvent:event];
  };
  g_solara_reserved_global_accelerator = &solaracore::IsReservedGlobalAccelerator;
  g_solara_global_shortcuts_resumed = &solaracore::GlobalShortcutsResumed;
  g_solara_history_eligible = [](content::WebContents* contents) {
    BrowserWindowInterface* browser =
        GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
    solaracore::WindowHost* host = browser ? solaracore::WindowHost::ForBrowser(browser) : nullptr;
    return !host || !host->internal();
  };
  AppShortcutManager::SuppressShortcutsForTesting();
  solaracore::SetLifetimeCallbacks({
      .quit_cancelled = base::BindRepeating([] {
        if ([g_delegate respondsToSelector:@selector(engineQuitCancelled)]) {
          [g_delegate engineQuitCancelled];
        }
      }),
  });
  solaracore::SetEngineCallbacks({
      .started = base::BindOnce([] {
        StartApplyingProfilePrefs();
        solara::StartTabHistoryCleaner();
        solaracore::InstallPermissionPrompts();
        solaracore::StartMediaCaptureObserver();
        solaracore::InstallExternalAppPrompts();
        solaracore::StartPictureInPictureObserver();
        solaracore::StartHostVisibility();
        solaracore::StartVideoUpscaling();
        [g_delegate engineDidStart];
      }),
      .shutting_down = base::BindOnce([] {
        solaracore::CloseAllExtensionViews();
        if ([g_delegate respondsToSelector:@selector(engineWillShutDown)]) {
          [g_delegate engineWillShutDown];
        }
      }),
  });

  std::vector<const char*> args(argv, argv + argc);
  static std::string features = "--enable-features=WebContentsDiscard";
  bool merged = false;
  for (const char*& arg : args) {
    if (strncmp(arg, "--enable-features=", 18) == 0 && !merged) {
      features = std::string(arg) + ",WebContentsDiscard";
      arg = features.c_str();
      merged = true;
    }
  }
  if (!merged) {
    args.push_back(features.c_str());
  }
  int rv = ChromeMain(static_cast<int>(args.size()), args.data());
  g_delegate = nil;
  return rv;
}

+ (SolaraCoreEngine*)sharedEngine {
  return g_engine;
}

- (SolaraCoreProfile*)defaultProfile {
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  return profile ? [SolaraCoreProfile wrapperFor:profile] : nil;
}

- (NSArray<SolaraCoreProfile*>*)loadedProfiles {
  NSMutableArray<SolaraCoreProfile*>* profiles = [NSMutableArray array];
  ProfileManager* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  if (!manager) {
    return profiles;
  }
  for (Profile* profile : manager->GetLoadedProfiles()) {
    if (IsRegularLoadedProfile(profile)) {
      [profiles addObject:[SolaraCoreProfile wrapperFor:profile]];
    }
  }
  return profiles;
}

- (void)loadProfile:(NSString*)directoryName
         completion:(void (^)(SolaraCoreProfile*))completion {
  ProfileManager* manager = g_browser_process->profile_manager();
  base::FilePath path =
      manager->user_data_dir().Append(base::SysNSStringToUTF8(directoryName));
  Profile* loaded = manager->GetProfileByPath(path);
  if (IsProfileDirectoryMarkedForDeletion(path) ||
      (loaded && solaracore::IsProfileDeleting(loaded))) {
    completion(nil);
    return;
  }
  manager->CreateProfileAsync(
      path, base::BindOnce(
                [](void (^completion)(SolaraCoreProfile*), Profile* profile) {
                  completion(profile && !solaracore::IsProfileDeleting(profile)
                                 ? [SolaraCoreProfile wrapperFor:profile]
                                 : nil);
                },
                completion));
}

- (void)quit {
  solaracore::QuitEngine();
}

- (NSString*)pageScript {
  const std::string& script = solaracore::GetPageScript();
  return script.empty() ? nil : NS(script);
}

- (void)setPageScript:(NSString*)pageScript {
  solaracore::SetPageScript(pageScript ? base::SysNSStringToUTF8(pageScript)
                                   : std::string());
}

- (void)resolvePermission:(NSString*)requestId
                   result:(NSString*)result
                 remember:(BOOL)remember {
  solaracore::ResolvePermission(base::SysNSStringToUTF8(requestId),
                            base::SysNSStringToUTF8(result), remember);
}

static bool g_tracing = false;

namespace {

struct TracingStart {
  void (^completion)(BOOL);
  bool answered = false;
  int session = 0;
};

int g_tracing_session = 0;
std::weak_ptr<TracingStart>& PendingTracingStart() {
  static base::NoDestructor<std::weak_ptr<TracingStart>> pending;
  return *pending;
}

constexpr int kTracingStartChecks = 100;

bool IsCurrent(const TracingStart& start) {
  return start.session == g_tracing_session;
}

void AnswerTracingStart(const std::shared_ptr<TracingStart>& start, bool started) {
  if (start->answered) {
    return;
  }
  start->answered = true;
  if (!started && IsCurrent(*start)) {
    g_tracing = false;
  }
  start->completion(started);
}

void WatchTracingStart(std::shared_ptr<TracingStart> start, int checks_left) {
  if (start->answered) {
    return;
  }
  if (!IsCurrent(*start)) {
    AnswerTracingStart(start, false);
    return;
  }
  content::TracingController* tracing = content::TracingController::GetInstance();
  if (!tracing->IsTracing()) {
    AnswerTracingStart(start, false);
    return;
  }
  if (checks_left == 0) {
    AnswerTracingStart(start, false);
    tracing->StopTracing(nullptr);
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&WatchTracingStart, std::move(start), checks_left - 1),
      base::Milliseconds(100));
}

}

+ (void)beginTracing:(void (^)(BOOL started))completion {
  if (g_tracing) {
    completion(NO);
    return;
  }
  auto start = std::make_shared<TracingStart>();
  start->completion = completion;
  start->session = ++g_tracing_session;
  PendingTracingStart() = start;
  g_tracing = content::TracingController::GetInstance()->StartTracing(
      base::trace_event::TraceConfig(),
      base::BindOnce(
          [](std::shared_ptr<TracingStart> start) {
            if (start->answered) {
              if (IsCurrent(*start) && !g_tracing) {
                content::TracingController::GetInstance()->StopTracing(nullptr);
              }
              return;
            }
            AnswerTracingStart(start, true);
          },
          start));
  if (!g_tracing) {
    AnswerTracingStart(start, false);
    return;
  }
  WatchTracingStart(start, kTracingStartChecks);
}

+ (void)endTracing:(BOOL)keep completion:(void (^)(NSString* _Nullable path))completion {
  if (!g_tracing) {
    completion(nil);
    return;
  }
  g_tracing = false;
  ++g_tracing_session;
  if (std::shared_ptr<TracingStart> pending = PendingTracingStart().lock()) {
    AnswerTracingStart(pending, false);
  }
  NSDateFormatter* format = [[NSDateFormatter alloc] init];
  format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  format.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss.SSS";
  NSString* folder =
      keep ? [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory
                                                  inDomains:NSUserDomainMask]
                 .firstObject.path
           : NSTemporaryDirectory();
  [NSFileManager.defaultManager createDirectoryAtPath:folder
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString* path = [folder
      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ Trace %@.json",
                                                                base::SysUTF8ToNSString(solara::ProductName()),
                                                                [format stringFromDate:NSDate.date]]];
  const bool stopped = content::TracingController::GetInstance()->StopTracing(
      content::TracingController::CreateFileEndpoint(
          base::FilePath(base::SysNSStringToUTF8(path)),
          base::BindOnce(
              [](NSString* path, BOOL keep, void (^completion)(NSString*)) {
                if (keep) {
                  completion(path);
                } else {
                  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                  completion(nil);
                }
              },
              path, keep, completion)));
  if (!stopped) {
    completion(nil);
  }
}

+ (BOOL)isTracing {
  return g_tracing;
}

+ (void)startCasting:(int)dialogId sink:(NSString*)sinkId mode:(int)castMode {
  solaracore::StartCasting(dialogId, base::SysNSStringToUTF8(sinkId), castMode);
}

+ (void)stopCasting:(int)dialogId route:(NSString*)routeId {
  solaracore::StopCasting(dialogId, base::SysNSStringToUTF8(routeId));
}

+ (void)reservedShortcutsChanged {
  solaracore::ReservedShortcutsChanged();
}

+ (BOOL)isReservedGlobalShortcut:(NSString*)shortcut {
  return solaracore::IsReservedGlobalShortcut(shortcut);
}

+ (void)setVideoUpscaling:(BOOL)enabled {
  solaracore::SetVideoUpscalingEnabled(enabled);
}

+ (void)setVideoUpscalingTestConditions:(NSDictionary<NSString*, NSNumber*>*)conditions {
  NSNumber* low_power = conditions[@"lowPower"];
  NSNumber* thermal = conditions[@"thermalPressure"];
  solaracore::SetVideoUpscalingTestConditions(
      low_power ? std::optional<bool>(low_power.boolValue) : std::nullopt,
      thermal ? std::optional<bool>(thermal.boolValue) : std::nullopt);
}

+ (NSDictionary<NSString*, id>*)videoUpscalingState {
  return solaracore::VideoUpscalingState();
}

+ (void)setAutoPictureInPicture:(BOOL)enabled {
  g_auto_picture_in_picture = enabled;
  g_solara_auto_picture_in_picture_off = !enabled;
  for (Profile* profile : g_browser_process->profile_manager()->GetLoadedProfiles()) {
    if (!profile->IsOffTheRecord()) {
      ApplyAutoPictureInPicture(profile);
    }
  }
}

+ (void)terminateCastRoute:(NSString*)routeId {
  solaracore::TerminateCastRoute(base::SysNSStringToUTF8(routeId));
}

+ (void)closeCastDialog:(int)dialogId {
  solaracore::CloseCastDialog(dialogId);
}

+ (void)selectDevice:(int)chooserId index:(int)index {
  solaracore::SelectDevice(chooserId, index);
}

+ (void)cancelDeviceChooser:(int)chooserId {
  solaracore::CancelDeviceChooser(chooserId);
}

+ (void)refreshDeviceChooser:(int)chooserId {
  solaracore::RefreshDeviceChooser(chooserId);
}

+ (void)openDeviceChooserSettings:(int)chooserId {
  solaracore::OpenDeviceChooserSettings(chooserId);
}

+ (void)resolveExtensionInstallPrompt:(NSString*)requestId accepted:(BOOL)accepted {
  solaracore::ResolveExtensionInstallPrompt(base::SysNSStringToUTF8(requestId), accepted);
}

- (void)deleteProfile:(SolaraCoreProfile*)profile completion:(void (^)(BOOL admitted))completion {
  Profile* chrome_profile = profile.chromeProfile;
  ProfileManager* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  if (!manager || browser_shutdown::HasShutdownStarted() || !chrome_profile ||
      !chrome_profile->IsRegularProfile() || chrome_profile->ShutdownStarted() ||
      solaracore::IsProfileDying(chrome_profile) ||
      solaracore::IsProfileDeleting(chrome_profile) ||
      IsProfileDirectoryMarkedForDeletion(chrome_profile->GetPath()) ||
      chrome_profile->GetPath() ==
          manager->user_data_dir().Append(ProfileManager::GetInitialProfileDir())) {
    if (completion) completion(NO);
    return;
  }
  struct Deletion : public std::enable_shared_from_this<Deletion> {
    base::WeakPtr<Profile> profile;
    base::FilePath path;
    void (^completion)(BOOL) = nil;
    std::unique_ptr<ScopedKeepAlive> browser_keep_alive;
    std::unique_ptr<ScopedProfileKeepAlive> profile_keep_alive;
    int attempts = 0;
    bool finished = false;

    void Finish(bool admitted) {
      if (finished) return;
      finished = true;
      auto reply = completion;
      completion = nil;
      if (reply) reply(admitted);
      profile_keep_alive.reset();
      browser_keep_alive.reset();
    }
    void Commit() {
      if (finished) return;
      ProfileManager* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
      if (!profile || !manager || browser_shutdown::HasShutdownStarted() ||
          profile->ShutdownStarted() || manager->GetProfileByPath(path) != profile.get() ||
          IsProfileDirectoryMarkedForDeletion(path) ||
          solaracore::IsProfileDeleting(profile.get())) {
        Finish(false);
        return;
      }
      bool has_browsers = false;
      GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
        has_browsers |= browser->GetProfile()->GetOriginalProfile() == profile.get();
        return !has_browsers;
      });
      if (has_browsers) {
        if (++attempts == 100) {
          Finish(false);
          return;
        }
        content::GetUIThreadTaskRunner({})->PostDelayedTask(
            FROM_HERE,
            base::BindOnce([](std::shared_ptr<Deletion> request) { request->Commit(); },
                           shared_from_this()),
            base::Milliseconds(50));
        return;
      }
      solara::ReleaseNotificationProfilePath(
          path, solara::NotificationReleaseReason::kProfileDelete,
          base::BindOnce([](std::shared_ptr<Deletion> request, bool admitted) {
            if (!admitted) {
              request->Finish(false);
              return;
            }
            Profile* profile = request->profile.get();
            ProfileManager* manager = g_browser_process->profile_manager();
            solaracore::NoteProfileDeleting(profile);
            manager->GetDeleteProfileHelper().MaybeScheduleProfileForDeletion(
                request->path, base::DoNothing(), ProfileMetrics::DELETE_PROFILE_SETTINGS);
            manager->ClearFirstBrowserWindowKeepAlive(profile);
            for (const base::TimeDelta delay : {base::Seconds(2), base::Seconds(10)}) {
              content::GetUIThreadTaskRunner({})->PostDelayedTask(
                  FROM_HERE, base::BindOnce([](const base::FilePath& dir) {
                    if (!g_browser_process || !g_browser_process->profile_manager() ||
                        !IsProfileDirectoryMarkedForDeletion(dir) ||
                        g_browser_process->profile_manager()->GetProfileByPath(dir)) {
                      return;
                    }
                    base::ThreadPool::PostTask(
                        FROM_HERE,
                        {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
                         base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN},
                        base::BindOnce(base::IgnoreResult(&base::DeletePathRecursively), dir));
                  }, request->path), delay);
            }
            request->Finish(true);
          }, shared_from_this()));
    }
  };
  auto request = std::make_shared<Deletion>();
  request->profile = chrome_profile->GetWeakPtr();
  request->path = chrome_profile->GetPath();
  request->completion = completion;
  request->browser_keep_alive = std::make_unique<ScopedKeepAlive>(
      KeepAliveOrigin::PROFILE_MANAGER, KeepAliveRestartOption::DISABLED);
  request->profile_keep_alive = std::make_unique<ScopedProfileKeepAlive>(
      chrome_profile, ProfileKeepAliveOrigin::kProfileDeletionProcess);
  chrome::CloseAllBrowsersWithProfile(
      chrome_profile, false,
      base::BindRepeating([](std::shared_ptr<Deletion> request, const base::FilePath&) {
        request->Commit();
      }, request),
      base::BindRepeating([](std::shared_ptr<Deletion> request, const base::FilePath&) {
        request->Finish(false);
      }, request));
}

- (void)fenceNotificationsForProfileDeletionAtPath:(NSString*)path
                                      completion:(void (^)(BOOL))completion {
  const base::FilePath profile_path(base::SysNSStringToUTF8(path));
  if (profile_path.empty() || !profile_path.IsAbsolute()) {
    completion(NO);
    return;
  }
  solara::ReleaseNotificationProfilePath(
      profile_path,
      solara::NotificationReleaseReason::kProfileDelete,
      base::BindOnce([](void (^completion)(BOOL), bool admitted) {
        completion(admitted);
      }, completion));
}

- (void)fenceNotificationsForPrivateProfile:(SolaraCoreProfile*)profile {
  Profile* chrome_profile = profile.chromeProfile;
  if (chrome_profile && chrome_profile->IsOffTheRecord()) {
    solara::ReleaseNotificationProfile(
        chrome_profile, solara::NotificationReleaseReason::kPrivateEnd);
  }
}

- (void)releaseProfile:(SolaraCoreProfile*)profile {
  Profile* chrome_profile = profile.chromeProfile;
  if (!chrome_profile || !chrome_profile->IsOffTheRecord()) {
    return;
  }
  bool in_use = false;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
    in_use |= browser->GetProfile() == chrome_profile &&
              !browser->capabilities()->IsAttemptingToCloseBrowser();
    return !in_use;
  });
  if (!in_use) {
    base::WeakPtr<Profile> weak = chrome_profile->GetWeakPtr();
    solara::ReleaseNotificationProfile(
        chrome_profile, solara::NotificationReleaseReason::kPrivateEnd);
    if (weak && !solaracore::IsProfileDying(weak.get())) {
      ProfileDestroyer::DestroyOTRProfileWhenAppropriate(weak.get());
    }
  }
}

+ (void)allowDesktopCapture:(NSString*)sourceId
                        tab:(SolaraCoreTab*)tab
                      frame:(NSString*)frameId
                     origin:(NSString*)origin
                      audio:(NSString*)audio {
  solaracore::AllowDesktopCapture(tab.contents, base::SysNSStringToUTF8(sourceId ?: @""),
                              base::SysNSStringToUTF8(frameId ?: @""),
                              base::SysNSStringToUTF8(origin ?: @""),
                              base::SysNSStringToUTF8(audio ?: @""));
}

+ (NSDictionary<NSString*, NSNumber*>*)desktopCaptureAudio {
  return @{
    @"system" : @(solaracore::IsDesktopCaptureSystemAudioSupported()),
    @"application" : @(solaracore::IsDesktopCaptureApplicationAudioSupported()),
  };
}

+ (NSArray<NSDictionary*>*)testExternalLaunches {
  return solaracore::TestExternalLaunches();
}

+ (NSArray<NSDictionary*>*)testChooserEvents {
  return solaracore::TestChooserEvents();
}

+ (void)resolveExternalApp:(NSString*)requestId open:(BOOL)open remember:(BOOL)remember {
  solaracore::ResolveExternalApp(base::SysNSStringToUTF8(requestId), open, remember);
}

- (void)offTheRecordProfileFor:(SolaraCoreProfile*)profile
                    completion:(void (^)(SolaraCoreProfile*, NSString*))completion {
  Profile* original = profile.chromeProfile;
  if (!original || original->IsOffTheRecord()) {
    completion(nil, original ? @"not a regular profile" : @"the profile went");
    return;
  }
  Profile* current = original->GetPrimaryOTRProfile(false);
  if (current && solaracore::IsProfileDying(current)) {
    solaracore::WhenProfileGone(current, base::BindOnce(^{
                              [self offTheRecordProfileFor:profile completion:completion];
                            }));
    return;
  }
  SolaraCoreProfile* otr =
      [SolaraCoreProfile wrapperFor:original->GetPrimaryOTRProfile(true)];
  completion(otr, otr ? nil : @"Chrome is destroying it");
}

- (NSString*)keepAliveState {
  std::ostringstream out;
  out << *KeepAliveRegistry::GetInstance()
      << " trying_to_quit=" << browser_shutdown::IsTryingToQuit();
  return NS(out.str());
}

- (NSString*)chromiumVersion {
  return NS(std::string(version_info::GetVersionNumber()));
}

@end

@implementation SolaraCoreProfile {
  base::WeakPtr<Profile> _profile;
  std::unique_ptr<ProfileGoneObserver> _observer;
  NSString* __strong _name;
  NSString* __strong _path;
  BOOL _offTheRecord;
}

+ (SolaraCoreProfile*)wrapperFor:(Profile*)profile {
  if (!profile || solaracore::IsProfileDying(profile)) {
    return nil;
  }
  solara::RegisterNotificationProfile(profile);
  SolaraCoreProfile* __strong& wrapper = ProfileWrappers()[profile];
  if (!wrapper) {
    wrapper = [[SolaraCoreProfile alloc] init];
    wrapper->_profile = profile->GetWeakPtr();
    wrapper->_offTheRecord = profile->IsOffTheRecord();
    wrapper->_name = NS(profile->GetBaseName().value());
    wrapper->_path = NS(profile->GetPath().value());
    wrapper->_observer = std::make_unique<ProfileGoneObserver>(profile, wrapper);
  }
  return wrapper;
}

- (void)profileWillBeDestroyed {
  ProfileWrappers().erase(_profile.get());
  _profile.reset();
  _observer.reset();
}

- (Profile*)chromeProfile {
  return _profile.get();
}

- (BOOL)destroyed {
  return !_profile;
}

- (BOOL)offTheRecord {
  return _offTheRecord;
}

- (NSString*)name {
  return _name;
}

- (NSString*)path {
  return _path;
}

- (NSNumber*)boolPreference:(NSString*)name {
  const std::string key = base::SysNSStringToUTF8(name);
  if (!_profile || !IsHostPreference(key)) {
    return nil;
  }
  const PrefService::Preference* pref = _profile->GetPrefs()->FindPreference(key);
  return pref && pref->GetValue()->is_bool() ? @(pref->GetValue()->GetBool()) : nil;
}

- (void)setBoolPreference:(NSString*)name value:(BOOL)value {
  const std::string key = base::SysNSStringToUTF8(name);
  if (_profile && IsHostPreference(key) &&
      _profile->GetPrefs()->FindPreference(key)) {
    _profile->GetPrefs()->SetBoolean(key, value);
  }
}

- (NSArray<NSString*>*)sleepExceptions {
  NSMutableArray<NSString*>* patterns = [NSMutableArray array];
  if (!_profile) {
    return patterns;
  }
  for (const auto item : _profile->GetPrefs()->GetDict(
           performance_manager::user_tuning::prefs::kTabDiscardingExceptionsWithTime)) {
    [patterns addObject:NS(item.first)];
  }
  return patterns;
}

- (void)setSleepExceptions:(NSArray<NSString*>*)patterns {
  if (!_profile) {
    return;
  }
  PrefService* prefs = _profile->GetPrefs();
  const char* key =
      performance_manager::user_tuning::prefs::kTabDiscardingExceptionsWithTime;
  const base::DictValue& before = prefs->GetDict(key);
  base::DictValue after;
  for (NSString* pattern in patterns) {
    const std::string name = base::SysNSStringToUTF8(pattern);
    if (name.empty()) {
      continue;
    }
    const base::Value* added = before.Find(name);
    after.Set(name, added ? added->Clone() : base::TimeToValue(base::Time::Now()));
  }
  prefs->SetDict(key, std::move(after));
}

- (void)clearBrowsingData:(NSArray<NSString*>*)types
                    since:(NSDate*)since
               completion:(void (^)(void))completion {
  uint64_t mask = 0;
  for (NSString* type in types) {
    if ([type isEqualToString:@"history"]) {
      mask |= chrome_browsing_data_remover::DATA_TYPE_HISTORY;
    } else if ([type isEqualToString:@"siteData"]) {
      mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
    } else if ([type isEqualToString:@"cache"]) {
      mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
    } else if ([type isEqualToString:@"downloads"]) {
      mask |= content::BrowsingDataRemover::DATA_TYPE_DOWNLOADS;
    }
  }
  if (!_profile || !mask) {
    if (completion) {
      completion();
    }
    return;
  }
  content::BrowsingDataRemover* remover = _profile->GetBrowsingDataRemover();
  const base::Time begin =
      since ? base::Time::FromSecondsSinceUnixEpoch(since.timeIntervalSince1970)
            : base::Time();
  remover->RemoveAndReply(begin, base::Time::Max(), mask,
                          content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,
                          new BrowsingDataDone(remover, completion));
}

- (NSString*)loadComponentExtension:(NSString*)path {
  if (!_profile || !path.length) {
    return nil;
  }
  const base::FilePath root(base::SysNSStringToUTF8(path));
  for (const auto& extension :
       extensions::ExtensionRegistry::Get(_profile.get())->enabled_extensions()) {
    if (extension->location() == extensions::mojom::ManifestLocation::kComponent &&
        extension->path() == root) {
      return NS(extension->id());
    }
  }
  extensions::ComponentLoader* loader = extensions::ComponentLoader::Get(_profile.get());
  if (!loader) {
    return nil;
  }
  const std::string extension_id = loader->AddOrReplace(root);
  return extension_id.empty() ? nil : NS(extension_id);
}

- (void)warmSpareRenderer {
  if (_profile) {
    content::SpareRenderProcessHostManager::Get().WarmupSpare(_profile.get());
  }
}

- (void)unloadComponentExtension:(NSString*)extensionId {
  if (!_profile || !extensionId.length) {
    return;
  }
  if (extensions::ComponentLoader* loader = extensions::ComponentLoader::Get(_profile.get())) {
    loader->Remove(base::SysNSStringToUTF8(extensionId));
  }
}

- (void)holdNavigationsUntilRulesetsOf:(NSString*)extensionId {
  if (_profile) {
    solaracore::HoldNavigationsForRulesets(_profile.get(), base::SysNSStringToUTF8(extensionId));
  }
}

- (void)releaseNavigationHold:(NSString*)reason {
  if (_profile) {
    solaracore::ReleaseNavigationHold(_profile.get(), base::SysNSStringToUTF8(reason));
  }
}

- (void)releaseNavigationHoldReady {
  if (_profile) {
    solaracore::ReleaseNavigationHoldReady(_profile.get());
  }
}

- (void)watchCastRoutes {
  solaracore::WatchCastRoutes(_profile.get());
}

- (NSArray<NSDictionary<NSString*, id>*>*)extensions {
  NSMutableArray* list = [NSMutableArray array];
  if (!_profile) {
    return list;
  }
  auto* registry = extensions::ExtensionRegistry::Get(_profile.get());
  auto* actions = extensions::ExtensionActionManager::Get(_profile.get());
  for (const auto& extension : registry->enabled_extensions()) {
    if (extensions::Manifest::IsComponentLocation(extension->location())) {
      continue;
    }
    extensions::ExtensionAction* action =
        actions->GetExtensionAction(*extension);
    [list addObject:@{
      @"id" : NS(extension->id()),
      @"name" : NS(extension->name()),
      @"version" : NS(extension->VersionString()),
      @"enabled" : @YES,
      @"actionPopupURL" :
          action ? NS(action->GetPopupUrl(extensions::ExtensionAction::kDefaultTabId)
                          .spec())
                 : @"",
    }];
  }
  return list;
}

@end

@implementation SolaraCoreWindow {
  std::unique_ptr<solaracore::WindowHost> _host;
}

@synthesize delegate = _delegate;

- (instancetype)initWithContentRect:(NSRect)rect {
  if ((self = [super init])) {
    _host = std::make_unique<solaracore::WindowHost>(self,
                                                 gfx::ScreenRectFromNSRect(rect));
  }
  return self;
}

- (solaracore::WindowHost*)host {
  return _host.get();
}

- (NSWindow*)window {
  return _host->ns_window();
}

- (NSView*)hostView {
  return _host->host_view();
}

- (BOOL)closing {
  return _host && _host->closing();
}

- (SolaraCoreTab*)openTab:(NSString*)url
              profile:(SolaraCoreProfile*)profile
           foreground:(BOOL)foreground {
  Browser* browser = _host->BrowserFor(profile.chromeProfile);
  if (!browser) {
    return nil;
  }
  const bool ahead = !url.length;
  NavigateParams params(browser, GURL(ahead ? "about:blank" : base::SysNSStringToUTF8(url)),
                        ui::PAGE_TRANSITION_TYPED);
  params.disposition = foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                                  : WindowOpenDisposition::NEW_BACKGROUND_TAB;
  params.window_action = NavigateParams::WindowAction::kNoAction;
  base::AutoReset<solaracore::WindowHost::PendingOpen> pending(
      &_host->pending_open(), solaracore::WindowHost::PendingOpen{params.disposition, nullptr});
  Navigate(&params);
  content::WebContents* contents = params.navigated_or_inserted_contents;
  if (!contents) {
    return nil;
  }
  solaracore::TabBridge* bridge = solaracore::TabBridge::GetOrCreate(contents);
  if (ahead) {
    bridge->set_made_ahead();
    solaracore::MarkAheadBlank(contents);
  }
  return bridge->tab();
}

- (SolaraCoreTab*)openExtensionView:(NSString*)url
                        profile:(SolaraCoreProfile*)profile
                           kind:(NSString*)kind {
  content::WebContents* contents = solaracore::OpenExtensionView(
      _host->BrowserFor(profile.chromeProfile), GURL(base::SysNSStringToUTF8(url)),
      [kind isEqualToString:@"sidePanel"] ? solaracore::ExtensionViewKind::kSidePanel
                                          : solaracore::ExtensionViewKind::kPopup);
  return contents ? solaracore::TabBridge::GetOrCreate(contents)->tab() : nil;
}

- (SolaraCoreProfile*)activeProfile {
  Profile* profile = _host->active_profile();
  return profile ? [SolaraCoreProfile wrapperFor:profile] : nil;
}

- (void)setActiveProfile:(SolaraCoreProfile*)profile {
  if (profile.chromeProfile) {
    _host->BrowserFor(profile.chromeProfile);
    _host->SetActiveProfile(profile.chromeProfile);
  }
}

- (void)activateTab:(SolaraCoreTab*)tab {
  if (solaracore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self activateTab:tab];
    });
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser) {
    return;
  }
  auto focusing = solaracore::TabBridge::GetOrCreate(contents)->HostFocuses();
  _host->NoteHostActivated(static_cast<Browser*>(browser));
  TabStripModel* model = browser->GetTabStripModel();
  int index = model->GetIndexOfWebContents(contents);
  if (index != TabStripModel::kNoTab && index != model->active_index()) {
    model->ActivateTabAt(index);
  }
}

- (NSArray<SolaraCoreTab*>*)tabsForProfile:(SolaraCoreProfile*)profile {
  NSMutableArray* tabs = [NSMutableArray array];
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  if (!browser) {
    return tabs;
  }
  TabStripModel* model = browser->GetTabStripModel();
  for (int i = 0; i < model->count(); ++i) {
    [tabs addObject:solaracore::TabBridge::GetOrCreate(model->GetWebContentsAt(i))
                        ->tab()];
  }
  return tabs;
}

- (int)chromeWindowIdForProfile:(SolaraCoreProfile*)profile {
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  return browser ? browser->GetSessionID().id() : -1;
}

- (BOOL)executeChromeCommand:(int)commandId profile:(SolaraCoreProfile*)profile {
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  return browser && !browser->IsDeleteScheduled() && chrome::ExecuteCommand(browser, commandId);
}

- (BOOL)internal {
  return _host->internal();
}

- (void)setInternal:(BOOL)internal {
  _host->set_internal(internal);
}

- (void)showInactive {
  _host->ShowInactive();
}

- (BOOL)actedFullScreen {
  return _host->acted_fullscreen();
}

- (void)setActedFullScreen:(BOOL)acted {
  _host->set_acted_fullscreen(acted);
}

- (void)adoptTab:(SolaraCoreTab*)tab {
  if (solaracore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self adoptTab:tab];
    });
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* from =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  Browser* to = _host->BrowserFor(
      Profile::FromBrowserContext(contents->GetBrowserContext()));
  if (!from || !to || from == to) {
    return;
  }
  TabStripModel* source = from->GetTabStripModel();
  const int index = source->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab) {
    return;
  }
  std::unique_ptr<tabs::TabModel> moved = source->DetachTabAtForInsertion(index);
  if (!moved) {
    return;
  }
  TabStripModel* target = to->GetTabStripModel();
  target->InsertDetachedTabAt(target->count(), std::move(moved),
                              AddTabTypes::ADD_NONE);
}

- (void)placeTab:(SolaraCoreTab*)tab index:(int)index pinned:(BOOL)pinned {
  if (solaracore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self placeTab:tab index:index pinned:pinned];
    });
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser || solaracore::WindowHost::ForBrowser(browser) != _host.get()) {
    return;
  }
  TabStripModel* model = browser->GetTabStripModel();
  int at = model->GetIndexOfWebContents(contents);
  if (at == TabStripModel::kNoTab) {
    return;
  }
  if (model->IsTabPinned(at) != static_cast<bool>(pinned)) {
    at = model->SetTabPinned(at, pinned);
  }
  const int pinned_count = model->IndexOfFirstNonPinnedTab();
  int to = std::clamp(index, 0, model->count() - 1);
  to = pinned ? std::min(to, pinned_count - 1) : std::max(to, pinned_count);
  if (to != at) {
    model->MoveWebContentsAt(at, to, false);
  }
}

- (SolaraCoreTab*)restoreTab:(NSString*)state
                 profile:(SolaraCoreProfile*)profile
              foreground:(BOOL)foreground {
  if (solaracore::IsNotifyingTabStrip()) {
    return nil;
  }
  std::optional<std::vector<uint8_t>> bytes =
      state ? base::Base64Decode(base::SysNSStringToUTF8(state)) : std::nullopt;
  Browser* browser = profile.chromeProfile ? _host->BrowserFor(profile.chromeProfile) : nullptr;
  if (!bytes || bytes->empty() || !browser) {
    return nil;
  }
  base::Pickle pickle = base::Pickle::WithUnownedBuffer(*bytes);
  base::PickleIterator it(pickle);
  int version = 0, selected = 0, count = 0;
  if (!it.ReadInt(&version) || version != 1 || !it.ReadInt(&selected) ||
      !it.ReadInt(&count) || count <= 0 || count > 1000) {
    return nil;
  }
  std::vector<sessions::SerializedNavigationEntry> navigations;
  for (int i = 0; i < count; ++i) {
    sessions::SerializedNavigationEntry entry;
    if (!entry.ReadFromPickle(&it)) {
      return nil;
    }
    navigations.push_back(std::move(entry));
  }
  selected = std::clamp(selected, 0, count - 1);
  base::AutoReset<solaracore::WindowHost::PendingOpen> pending(
      &_host->pending_open(),
      solaracore::WindowHost::PendingOpen{
          foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                     : WindowOpenDisposition::NEW_BACKGROUND_TAB,
          nullptr});
  content::WebContents* contents = chrome::AddRestoredTab(
      browser, navigations, browser->GetTabStripModel()->count(), selected,
      std::string(), std::nullopt, foreground,
      false, base::TimeTicks::Now(), base::Time::Now(),
      nullptr, sessions::SerializedUserAgentOverride(),
      {}, false,
      std::nullopt);
  return contents ? solaracore::TabBridge::GetOrCreate(contents)->tab() : nil;
}

- (SolaraCoreTab*)duplicateTab:(SolaraCoreTab*)source
                   profile:(SolaraCoreProfile*)profile
                foreground:(BOOL)foreground {
  if (solaracore::IsNotifyingTabStrip()) {
    return nil;
  }
  content::WebContents* contents = source.contents;
  Profile* chrome_profile = profile.chromeProfile;
  if (!contents || !chrome_profile ||
      Profile::FromBrowserContext(contents->GetBrowserContext()) != chrome_profile) {
    return nil;
  }
  Browser* browser = _host->BrowserFor(chrome_profile);
  if (!browser) {
    return nil;
  }
  std::unique_ptr<content::WebContents> copy = contents->Clone();
  content::WebContents* raw = copy.get();
  base::AutoReset<solaracore::WindowHost::PendingOpen> pending(
      &_host->pending_open(),
      solaracore::WindowHost::PendingOpen{
          foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                     : WindowOpenDisposition::NEW_BACKGROUND_TAB,
          contents->GetWeakPtr()});
  TabStripModel* model = browser->GetTabStripModel();
  model->InsertWebContentsAt(model->count(), std::move(copy),
                             foreground ? AddTabTypes::ADD_ACTIVE : AddTabTypes::ADD_NONE);
  return solaracore::TabBridge::GetOrCreate(raw)->tab();
}

- (NSInteger)keptOnCloseCountForProfile:(SolaraCoreProfile*)profile {
  return profile.chromeProfile ? _host->KeptOnCloseCount(profile.chromeProfile) : 0;
}

- (void)prepareProfile:(SolaraCoreProfile*)profile {
  if (profile.chromeProfile) {
    _host->BrowserFor(profile.chromeProfile);
  }
}

- (NSDictionary<NSString*, id>*)devCloseBrowserKeepingWindow:(SolaraCoreProfile*)profile {
  Profile* chrome_profile = profile.chromeProfile;
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("solara-test-browser-lifetime")) {
    return @{@"error" : @"needs --solara-test-browser-lifetime"};
  }
  Browser* closed = chrome_profile ? _host->ExistingBrowserFor(chrome_profile) : nullptr;
  if (!closed || closed->IsDeleteScheduled() || _host->closing()) {
    return @{@"error" : @"no live Browser for this profile in an open window"};
  }
  const int tabs = closed->GetTabStripModel()->count();
  closed->GetWindow()->Close();
  const bool scheduled = closed->IsDeleteScheduled();
  Browser* cached = _host->ExistingBrowserFor(chrome_profile);
  Browser* acquired = scheduled ? _host->BrowserFor(chrome_profile) : nullptr;
  return @{
    @"tabsBefore" : @(tabs),
    @"scheduled" : @(scheduled),
    @"cachedIsScheduled" : @(cached == closed),
    @"acquired" : @(acquired != nullptr),
    @"acquiredIsScheduled" : @(acquired && (acquired == closed || acquired->IsDeleteScheduled())),
    @"windowOpen" : @(!_host->closing()),
  };
}

- (void)close {
  _host->Close();
}

@end

namespace {

std::optional<bool> RunPageCommand(content::WebContents* contents, int command) {
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  PrefService* prefs = profile->GetPrefs();
  CoreTabHelper* core = CoreTabHelper::FromWebContents(contents);
  const int restrictions = core ? core->content_restrictions() : 0;
  switch (command) {
#if BUILDFLAG(ENABLE_PRINTING)
    case IDC_PRINT:
    case IDC_BASIC_PRINT: {
      auto* dialogs = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
      const bool can_print = prefs->GetBoolean(prefs::kPrintingEnabled) && !contents->IsCrashed() &&
                             !(dialogs && dialogs->IsDialogActive()) &&
                             !(restrictions & CONTENT_RESTRICTION_PRINT);
      bool preview = false;
#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
      auto* previews = printing::PrintPreviewDialogController::GetInstance();
      preview = previews && (previews->GetPrintPreviewForContents(contents) ||
                             previews->is_creating_print_preview_dialog());
#endif
      if (!can_print && !(command == IDC_BASIC_PRINT && preview &&
                          prefs->GetBoolean(prefs::kPrintingEnabled))) {
        return false;
      }
      if (command == IDC_PRINT) {
        printing::StartPrint(contents, prefs->GetBoolean(prefs::kPrintPreviewDisabled),
                             false);
      } else {
        printing::StartBasicPrint(contents);
      }
      return true;
    }
#endif
    case IDC_SAVE_PAGE: {
      PrefService* local_state = g_browser_process->local_state();
      content::NavigationEntry* entry = contents->GetController().GetLastCommittedEntry();
      if ((local_state && !local_state->GetBoolean(prefs::kAllowFileSelectionDialogs)) ||
          static_cast<policy::DownloadRestriction>(
              prefs->GetInteger(policy::policy_prefs::kDownloadRestrictions)) ==
              policy::DownloadRestriction::ALL_FILES ||
          (restrictions & CONTENT_RESTRICTION_SAVE) ||
          (entry && !content::IsSavableURL(entry->GetURL()))) {
        return false;
      }
      base::RecordAction(base::UserMetricsAction("SavePage"));
#if BUILDFLAG(ENABLE_PDF)
      if (contents->GetContentsMimeType() == "application/pdf" &&
          chrome_pdf::features::IsOopifPdfEnabled() &&
          pdf_extension_util::MaybeDispatchSaveEvent(contents->GetPrimaryMainFrame())) {
        return true;
      }
#endif
      contents->OnSavePage();
      return true;
    }
    case IDC_DEV_TOOLS_CONSOLE:
    case IDC_DEV_TOOLS_INSPECT:
      DevToolsWindow::OpenDevToolsWindow(
          contents,
          command == IDC_DEV_TOOLS_CONSOLE ? DevToolsToggleAction::ShowConsolePanel()
                                           : DevToolsToggleAction::Inspect(),
          DevToolsOpenedByAction::kMainMenuOrMainShortcut);
      return true;
    case IDC_DEV_TOOLS_TOGGLE: {
      DevToolsWindow* tools = DevToolsWindow::GetInstanceForInspectedWebContents(contents);
      if (tools && tools->IsDocked()) {
        if (content::WebContents* docked = DevToolsWindow::GetInTabWebContents(contents, nullptr)) {
          docked->DispatchBeforeUnload(false);
        }
      } else {
        DevToolsWindow::OpenDevToolsWindow(contents, DevToolsToggleAction::Show(),
                                           DevToolsOpenedByAction::kMainMenuOrMainShortcut);
      }
      return true;
    }
    default:
      return std::nullopt;
  }
}

}

@interface SolaraCoreInputSuppression : NSObject
- (instancetype)initWithContents:(content::WebContents*)contents;
@end

@implementation SolaraCoreInputSuppression {
  std::optional<content::WebContents::ScopedIgnoreInputEvents> _ignoring;
}

- (instancetype)initWithContents:(content::WebContents*)contents {
  if ((self = [super init])) {
    _ignoring.emplace(contents->IgnoreInputEvents(std::nullopt));
  }
  return self;
}

- (void)dealloc {
  _ignoring.reset();
}

@end

namespace {

using performance_manager::policies::CannotDiscardReason;

NSString* SleepBlockerName(CannotDiscardReason reason) {
  switch (reason) {
    case CannotDiscardReason::kNotATab:
      return @"notATab";
    case CannotDiscardReason::kAlreadyDiscarded:
      return @"alreadyAsleep";
    case CannotDiscardReason::kDiscardAttempted:
      return @"attemptedBefore";
    case CannotDiscardReason::kNoMainFrame:
      return @"noMainFrame";
    case CannotDiscardReason::kVisible:
      return @"visible";
    case CannotDiscardReason::kAudible:
      return @"audible";
    case CannotDiscardReason::kRecentlyAudible:
      return @"recentlyAudible";
    case CannotDiscardReason::kRecentlyVisible:
      return @"recentlyVisible";
    case CannotDiscardReason::kPictureInPicture:
      return @"pictureInPicture";
    case CannotDiscardReason::kPdf:
      return @"pdf";
    case CannotDiscardReason::kNotWebOrInternal:
      return @"notWeb";
    case CannotDiscardReason::kInvalidURL:
      return @"invalidURL";
    case CannotDiscardReason::kOptedOut:
      return @"siteException";
    case CannotDiscardReason::kNotificationsEnabled:
      return @"notifications";
    case CannotDiscardReason::kExtensionProtected:
      return @"extension";
    case CannotDiscardReason::kCapturingVideo:
      return @"capturingVideo";
    case CannotDiscardReason::kCapturingAudio:
      return @"capturingAudio";
    case CannotDiscardReason::kBeingMirrored:
      return @"mirrored";
    case CannotDiscardReason::kCapturingWindow:
      return @"capturingWindow";
    case CannotDiscardReason::kCapturingDisplay:
      return @"capturingDisplay";
    case CannotDiscardReason::kConnectedToBluetooth:
      return @"bluetooth";
    case CannotDiscardReason::kConnectedToUSB:
      return @"usb";
    case CannotDiscardReason::kActiveTab:
      return @"activeTab";
    case CannotDiscardReason::kPinnedTab:
      return @"pinnedTab";
    case CannotDiscardReason::kDevToolsOpen:
      return @"devTools";
    case CannotDiscardReason::kBackgroundActivity:
      return @"backgroundActivity";
    case CannotDiscardReason::kFormInteractions:
      return @"formInteraction";
    case CannotDiscardReason::kUserEdits:
      return @"userEdits";
    case CannotDiscardReason::kGlicShared:
      return @"shared";
    case CannotDiscardReason::kWebApp:
      return @"webApp";
  }
  return @"unknown";
}

const performance_manager::PageNode* PageNodeOf(content::WebContents* contents) {
  if (!contents || !performance_manager::PerformanceManager::IsAvailable()) {
    return nullptr;
  }
  return performance_manager::PerformanceManager::GetPrimaryPageNodeForWebContents(contents)
      .get();
}

}

@implementation SolaraCoreTab {
  raw_ptr<content::WebContents> _contents;
  int _browserId;
  NSColor* __strong _pageBackgroundColor;
}

@synthesize delegate = _delegate;

- (instancetype)initWithContents:(content::WebContents*)contents {
  if ((self = [super init])) {
    static int lastBrowserId = 0;
    _contents = contents;
    _browserId = ++lastBrowserId;
  }
  return self;
}

- (int)browserId {
  return _browserId;
}

- (BOOL)initialDocumentAccessed {
  return _contents && content::SolaraHasAccessedInitialMainDocument(_contents);
}

- (BOOL)committedInitial {
  if (!_contents) {
    return NO;
  }
  content::NavigationEntry* entry = _contents->GetController().GetLastCommittedEntry();
  return !entry || entry->IsInitialEntry();
}

+ (NSString*)originForURL:(NSString*)url {
  GURL gurl(base::SysNSStringToUTF8(url ?: @""));
  if (!gurl.is_valid()) {
    return nil;
  }
  const url::Origin origin = url::Origin::Create(gurl);
  const url::SchemeHostPort& tuple = origin.GetTupleOrPrecursorTupleIfOpaque();
  return tuple.IsValid() ? base::SysUTF8ToNSString(tuple.Serialize()) : @"";
}

- (NSString*)committedOrigin {
  if (!_contents) {
    return nil;
  }
  content::NavigationEntry* entry = _contents->GetController().GetLastCommittedEntry();
  if (!entry || entry->IsInitialEntry()) {
    return nil;
  }
  const url::SchemeHostPort& tuple =
      _contents->GetPrimaryMainFrame()->GetLastCommittedOrigin().GetTupleOrPrecursorTupleIfOpaque();
  return tuple.IsValid() ? base::SysUTF8ToNSString(tuple.Serialize()) : @"";
}

- (id)suppressInput {
  return _contents ? [[SolaraCoreInputSuppression alloc] initWithContents:_contents] : nil;
}

- (NSDictionary*)appBadge {
  return _contents ? solaracore::TabBridge::GetOrCreate(_contents)->app_badge() : nil;
}

- (NSString*)faviconURL {
  if (!_contents) {
    return nil;
  }
  const GURL& url = solaracore::TabBridge::GetOrCreate(_contents)->favicon_url();
  return url.is_valid() ? NS(url.spec()) : nil;
}

- (NSString*)themeColor {
  std::optional<SkColor> color = _contents ? _contents->GetThemeColor() : std::nullopt;
  if (!color) {
    return nil;
  }
  return [NSString stringWithFormat:@"#%02x%02x%02x", SkColorGetR(*color),
                                    SkColorGetG(*color), SkColorGetB(*color)];
}

- (BOOL)audible {
  return _contents && _contents->IsCurrentlyAudible();
}

- (BOOL)muted {
  return _contents && _contents->IsAudioMuted();
}

- (void)setMuted:(BOOL)muted {
  if (_contents) {
    _contents->SetAudioMuted(muted);
  }
}

- (void)loadURL:(NSString*)url userInitiated:(BOOL)userInitiated {
  if (!_contents) {
    return;
  }
  content::NavigationController::LoadURLParams params(
      GURL(base::SysNSStringToUTF8(url)));
  if (params.url.SchemeIs(url::kJavaScriptScheme)) {
    solaracore::EndAheadBlank(_contents);
  }
  params.transition_type = userInitiated
                               ? ui::PageTransitionFromInt(
                                     ui::PAGE_TRANSITION_TYPED |
                                     ui::PAGE_TRANSITION_FROM_ADDRESS_BAR)
                               : ui::PAGE_TRANSITION_AUTO_TOPLEVEL;
  params.has_user_gesture = userInitiated;
  if (solaracore::OnlyShowedBlank(_contents)) {
    params.should_replace_current_entry = true;
  }
  _contents->GetController().LoadURLWithParams(params);
}

- (void)goToOffset:(int)offset {
  if (_contents && _contents->GetController().CanGoToOffset(offset)) {
    _contents->GetController().GoToOffset(offset);
  }
}

- (void)reloadIgnoringCache {
  if (_contents) {
    _contents->GetController().Reload(content::ReloadType::BYPASSING_CACHE, true);
  }
}

- (NSArray<NSDictionary<NSString*, id>*>*)navigationEntries {
  NSMutableArray* entries = [NSMutableArray array];
  if (!_contents) {
    return entries;
  }
  content::NavigationController& controller = _contents->GetController();
  const int current = controller.GetCurrentEntryIndex();
  for (int i = 0; i < controller.GetEntryCount(); ++i) {
    content::NavigationEntry* entry = controller.GetEntryAtIndex(i);
    [entries addObject:@{
      @"url" : NS(entry->GetURL().spec()),
      @"title" : NS(entry->GetTitle()),
      @"current" : @(i == current),
    }];
  }
  return entries;
}

- (void)executeJavaScript:(NSString*)code {
  if (_contents) {
    solaracore::EndAheadBlank(_contents);
    solaracore::PageChannel::GetOrCreate(_contents)->Execute(
        base::SysNSStringToUTF8(code));
  }
}

- (NSDictionary*)securityInfo {
  return solaracore::SecurityInfoFor(_contents);
}

- (double)zoomFactor {
  return _contents ? blink::ZoomLevelToZoomFactor(
                         zoom::ZoomController::GetZoomLevelForWebContents(_contents))
                   : 1;
}

- (void)setZoomFactor:(double)zoomFactor {
  if (!_contents || zoomFactor <= 0) {
    return;
  }
  if (auto* zoom = zoom::ZoomController::FromWebContents(_contents)) {
    zoom->SetZoomLevel(blink::ZoomFactorToZoomLevel(zoomFactor));
  }
}

- (void)zoomStep:(int)direction {
  if (_contents) {
    zoom::PageZoom::Zoom(_contents, direction > 0   ? content::PAGE_ZOOM_IN
                                    : direction < 0 ? content::PAGE_ZOOM_OUT
                                                    : content::PAGE_ZOOM_RESET);
  }
}

- (double)pinchScale {
  return _contents ? solaracore::TabBridge::GetOrCreate(_contents)->pinch_scale() : 1;
}

- (BOOL)discard {
  if (!_contents) {
    return NO;
  }
  auto* unit =
      resource_coordinator::TabLifecycleUnitExternal::FromWebContents(_contents);
  return unit && unit->DiscardTab(
                     ::mojom::LifecycleUnitDiscardReason::EXTERNAL);
}

- (BOOL)discarded {
  return _contents && _contents->WasDiscarded();
}

- (NSArray<NSString*>*)reasonsNotToSleep {
  const performance_manager::PageNode* node = PageNodeOf(_contents);
  if (!node) {
    return @[ @"noPage" ];
  }
  auto* policy = performance_manager::policies::DiscardEligibilityPolicy::GetFromGraph(
      performance_manager::PerformanceManager::GetGraph());
  if (!policy) {
    return @[ @"noPage" ];
  }
  std::vector<CannotDiscardReason> reasons;
  const performance_manager::policies::CanDiscardResult result = policy->CanDiscard(
      node, ::mojom::LifecycleUnitDiscardReason::PROACTIVE, true, &reasons);
  NSMutableArray<NSString*>* names = [NSMutableArray array];
  for (CannotDiscardReason reason : reasons) {
    [names addObject:SleepBlockerName(reason)];
  }
  if (result != performance_manager::policies::CanDiscardResult::kEligible &&
      names.count == 0) {
    [names addObject:@"protected"];
  }
  return names;
}

- (BOOL)sleepIfEligible {
  const performance_manager::PageNode* node = PageNodeOf(_contents);
  if (!node) {
    return NO;
  }
  auto* helper = performance_manager::policies::PageDiscardingHelper::GetFromGraph(
      performance_manager::PerformanceManager::GetGraph());
  return helper &&
         helper->ImmediatelyDiscardMultiplePages(
             {node}, ::mojom::LifecycleUnitDiscardReason::PROACTIVE, true) &&
         _contents && _contents->WasDiscarded();
}

- (BOOL)sleepIfEligibleWaivingPinned {
  const performance_manager::PageNode* node = PageNodeOf(_contents);
  if (!node) {
    return NO;
  }
  auto* policy = performance_manager::policies::DiscardEligibilityPolicy::GetFromGraph(
      performance_manager::PerformanceManager::GetGraph());
  if (!policy) {
    return NO;
  }
  std::vector<CannotDiscardReason> reasons;
  const performance_manager::policies::CanDiscardResult result = policy->CanDiscard(
      node, ::mojom::LifecycleUnitDiscardReason::PROACTIVE, true, &reasons);
  if (result == performance_manager::policies::CanDiscardResult::kEligible) {
    return [self sleepIfEligible];
  }
  if (reasons.empty()) {
    return NO;
  }
  for (CannotDiscardReason reason : reasons) {
    if (reason != CannotDiscardReason::kPinnedTab) {
      return NO;
    }
  }
  return [self discard] && _contents && _contents->WasDiscarded();
}

- (BOOL)frozen {
  return _contents && solaracore::TabBridge::GetOrCreate(_contents)->frozen();
}

- (void)setFrozen:(BOOL)frozen {
  if (frozen && _contents &&
      _contents->GetVisibility() == content::Visibility::VISIBLE) {
    return;
  }
  if (_contents) {
    solaracore::TabBridge::GetOrCreate(_contents)->set_frozen(frozen);
    _contents->SetPageFrozen(frozen);
  }
}

- (void)resolveUnresponsive:(BOOL)terminate {
  if (_contents) {
    solaracore::TabBridge::GetOrCreate(_contents)->ResolveUnresponsive(terminate);
  }
}

- (NSColor*)pageBackgroundColor {
  return _pageBackgroundColor;
}

- (NSString*)pageColor {
  if (!_contents) {
    return nil;
  }
  auto* channel = solaracore::PageChannel::FromWebContents(_contents);
  return channel && !channel->page_color().empty()
             ? base::SysUTF8ToNSString(channel->page_color())
             : nil;
}

- (void)setPageColor:(NSString*)color {
  if (_contents) {
    solaracore::PageChannel::GetOrCreate(_contents)->SetPageColor(
        color ? base::SysNSStringToUTF8(color) : std::string());
  }
}

- (void)setPageBackgroundColor:(NSColor*)color {
  _pageBackgroundColor = color;
  if (!_contents) {
    return;
  }
  if (!color) {
    solaracore::SetHostPageBaseBackgroundColor(_contents, std::nullopt);
    return;
  }
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  solaracore::SetHostPageBaseBackgroundColor(
      _contents, SkColorSetARGB(rgb.alphaComponent * 255, rgb.redComponent * 255,
                                rgb.greenComponent * 255, rgb.blueComponent * 255));
}

- (NSColor*)contentsBackgroundColor {
  std::optional<SkColor> color =
      _contents ? solaracore::ContentsBackgroundColor(_contents) : std::nullopt;
  return color ? [NSColor colorWithSRGBRed:SkColorGetR(*color) / 255.0
                                     green:SkColorGetG(*color) / 255.0
                                      blue:SkColorGetB(*color) / 255.0
                                     alpha:1]
               : nil;
}

- (void)setContentsBackgroundColor:(NSColor*)color {
  if (!_contents) {
    return;
  }
  NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  solaracore::SetContentsBackgroundColor(
      _contents, rgb ? std::optional<SkColor>(SkColorSetRGB(std::lround(rgb.redComponent * 255),
                                                            std::lround(rgb.greenComponent * 255),
                                                            std::lround(rgb.blueComponent * 255)))
                     : std::nullopt);
}

- (NSString*)executeExtensionAction:(NSString*)extensionId {
  if (!_contents) {
    return @"none";
  }
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(_contents->GetBrowserContext())
          ->enabled_extensions()
          .GetByID(base::SysNSStringToUTF8(extensionId));
  auto* runner = extensions::ExtensionActionRunner::GetForWebContents(_contents);
  if (!extension || !runner) {
    return @"none";
  }
  switch (runner->RunAction(extension, true)) {
    case extensions::ExtensionAction::ShowAction::kShowPopup:
      return @"popup";
    case extensions::ExtensionAction::ShowAction::kToggleSidePanel:
      return @"sidePanel";
    case extensions::ExtensionAction::ShowAction::kNone:
      return @"none";
  }
  return @"none";
}

- (NSDictionary<NSString*, NSDictionary*>*)actionStatesForExtensions:
    (NSArray<NSString*>*)extensionIds {
  NSMutableDictionary* states = [NSMutableDictionary dictionary];
  if (!_contents) {
    return states;
  }
  content::BrowserContext* context = _contents->GetBrowserContext();
  const int tab_id = self.tabId;
  for (NSString* extensionId in extensionIds) {
    const extensions::Extension* extension =
        extensions::ExtensionRegistry::Get(context)->enabled_extensions().GetByID(
            base::SysNSStringToUTF8(extensionId));
    extensions::ExtensionAction* action =
        extension ? extensions::ExtensionActionManager::Get(context)
                        ->GetExtensionAction(*extension)
                  : nullptr;
    if (!action) {
      continue;
    }
    gfx::Image icon = action->GetExplicitlySetIcon(tab_id);
    if (icon.IsEmpty()) {
      icon = action->GetDeclarativeIcon(tab_id);
    }
    NSString* badge = NS(action->GetDisplayBadgeText(tab_id));
    states[extensionId] = @{
      @"title" : NS(action->GetTitle(tab_id)),
      @"badgeText" : [badge hasPrefix:@"<<"] ? @"" : badge,
      @"badgeColor" : HexColor(action->GetBadgeBackgroundColor(tab_id)),
      @"badgeTextColor" : HexColor(action->GetBadgeTextColor(tab_id)),
      @"popup" : NS(action->GetPopupUrl(tab_id).spec()),
      @"enabled" : @(action->GetIsVisible(tab_id)),
      @"icon" : PngDataURL(icon),
    };
  }
  return states;
}

- (NSString*)sidePanelURLForExtension:(NSString*)extensionId {
  if (!_contents) {
    return nil;
  }
  content::BrowserContext* context = _contents->GetBrowserContext();
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(context)->enabled_extensions().GetByID(
          base::SysNSStringToUTF8(extensionId));
  auto* service = extension ? extensions::SidePanelService::Get(context) : nullptr;
  if (!service) {
    return nil;
  }
  auto options = service->GetOptions(*extension, self.tabId);
  if (!options.path || !options.enabled.value_or(false)) {
    return nil;
  }
  return NS(extension->GetResourceURL(*options.path).spec());
}

- (void)openBlockedPopup:(NSString*)popupId always:(BOOL)always {
  if (solaracore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self openBlockedPopup:popupId always:always];
    });
    return;
  }
  if (!_contents) {
    return;
  }
  auto* popups = blocked_content::PopupBlockerTabHelper::FromWebContents(_contents);
  int id_number = 0;
  if (!popups || !base::StringToInt(base::SysNSStringToUTF8(popupId), &id_number) ||
      !popups->GetBlockedPopupRequests().contains(id_number)) {
    return;
  }
  if (always) {
    HostContentSettingsMapFactory::GetForProfile(_contents->GetBrowserContext())
        ->SetContentSettingDefaultScope(_contents->GetLastCommittedURL(), GURL(),
                                        ContentSettingsType::POPUPS,
                                        CONTENT_SETTING_ALLOW);
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(_contents);
  solaracore::WindowHost* host = solaracore::WindowHost::ForBrowser(browser);
  std::optional<base::AutoReset<solaracore::WindowHost::PendingOpen>> pending;
  if (host) {
    pending.emplace(&host->pending_open(),
                    solaracore::WindowHost::PendingOpen{
                        WindowOpenDisposition::NEW_FOREGROUND_TAB,
                        _contents->GetWeakPtr()});
  }
  popups->ShowBlockedPopup(id_number, WindowOpenDisposition::NEW_FOREGROUND_TAB);
}

- (BOOL)executeChromeCommand:(int)command {
  if (solaracore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self executeChromeCommand:command];
    });
    return YES;
  }
  if (!_contents) {
    return NO;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(_contents);
  if (!browser) {
    return NO;
  }
  TabStripModel* model = browser->GetTabStripModel();
  const int index = model->GetIndexOfWebContents(_contents);
  const int active = model->active_index();
  if (index == TabStripModel::kNoTab) {
    return NO;
  }
  if (index == active) {
    return chrome::ExecuteCommand(browser, command);
  }
  if (std::optional<bool> ran = RunPageCommand(_contents, command)) {
    return *ran;
  }
  if (command == IDC_CARET_BROWSING_TOGGLE) {
    return chrome::ExecuteCommand(browser, command);
  }
  return NO;
}

- (void)devToolsCall:(NSString*)method
              params:(NSDictionary*)params
          completion:(void (^)(NSDictionary* result, NSString* error))completion {
  [self devToolsCall:method params:params timeout:0 completion:completion];
}

- (void)devToolsCall:(NSString*)method
              params:(NSDictionary*)params
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(NSDictionary* result, NSString* error))completion {
  base::DictValue dict;
  if (params.count) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:params options:0 error:nil];
    std::optional<base::DictValue> parsed =
        data ? base::JSONReader::ReadDict(
                   std::string_view(static_cast<const char*>(data.bytes), data.length),
                   base::JSON_PARSE_RFC)
             : std::nullopt;
    if (!parsed) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, @"params aren't JSON");
      });
      return;
    }
    dict = std::move(*parsed);
  }
  solaracore::CallDevTools(
      _contents, base::SysNSStringToUTF8(method), std::move(dict),
      timeout > 0 ? std::optional<base::TimeDelta>(base::Seconds(timeout)) : std::nullopt,
      base::BindOnce(
          [](void (^completion)(NSDictionary*, NSString*),
             std::optional<base::DictValue> result, std::optional<std::string> error) {
            if (!result) {
              completion(nil, base::SysUTF8ToNSString(error.value_or("error")));
              return;
            }
            std::optional<std::string> json = base::WriteJson(*result);
            NSData* data = json ? [NSData dataWithBytes:json->data() length:json->size()] : nil;
            id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
                             : nil;
            if (![object isKindOfClass:NSDictionary.class]) {
              completion(nil, @"the reply isn't JSON");
              return;
            }
            completion(object, nil);
          },
          completion));
}

- (NSString*)mediaCaptureSourceId {
  content::RenderFrameHost* frame =
      _contents ? _contents->GetPrimaryMainFrame() : nullptr;
  if (!frame || !frame->IsRenderFrameLive()) {
    return nil;
  }
  return NS(content::WebContentsMediaCaptureId(frame->GetProcess()->GetDeprecatedID(),
                                               frame->GetRoutingID())
                .ToString());
}

- (void)copyPicture:(NSTimeInterval)timeout completion:(void (^)(CGImageRef))completion {
  content::RenderWidgetHostView* view =
      _contents ? _contents->GetRenderWidgetHostView() : nullptr;
  if (!view || !view->IsSurfaceAvailableForCopy()) {
    completion(nullptr);
    return;
  }
  void (^done)(CGImageRef) = [completion copy];
  view->CopyFromSurface(
      gfx::Rect(), gfx::Size(), base::Seconds(timeout),
      base::BindOnce(^(const content::CopyFromSurfaceResult& result) {
        CGImageRef image = result.has_value() ? CreatePicture(result->bitmap) : nullptr;
        content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(^{
                                                       done(image);
                                                       if (image) {
                                                         CGImageRelease(image);
                                                       }
                                                     }));
      }));
}

- (BOOL)stopCapture {
  if (!_contents) {
    return NO;
  }
  scoped_refptr<MediaStreamCaptureIndicator> indicator =
      MediaCaptureDevicesDispatcher::GetInstance()->GetMediaStreamCaptureIndicator();
  const bool capturing = indicator->IsCapturingTab(_contents) ||
                         indicator->IsCapturingWindow(_contents) ||
                         indicator->IsCapturingDisplay(_contents);
  indicator->StopMediaCapturing(_contents,
                                MediaStreamCaptureIndicator::MediaType::kDisplayMedia);
  return capturing;
}

- (void)noteShownByHost:(BOOL)shown {
  if (_contents) {
    solaracore::NoteTabShownByHost(_contents, shown);
  }
}

- (void)refreshAncestorGeometry {
  if (!_contents) return;
  content::WebContents* contents[] = {
    _contents, DevToolsWindow::GetInTabWebContents(_contents, nullptr)
  };
  for (content::WebContents* page : contents) {
    content::RenderWidgetHostView* view =
        page && !page->GetOuterWebContents() ? page->GetRenderWidgetHostView() : nullptr;
    NSView* native = view ? view->GetNativeView().GetNativeNSView() : nil;
    if (!native.window || native.isHiddenOrHasHiddenAncestor) continue;
    [native setFrameOrigin:native.frame.origin];
    NSRect rect = [native convertRect:native.bounds toView:nil];
    gfx::Rect bounds(rect);
    bounds.set_y(NSHeight(native.window.frame) - NSMaxY(rect));
    static_cast<content::RenderWidgetHostViewMac*>(view)->OnBoundsInWindowChanged(bounds, true);
    content::RenderWidgetHostImpl::From(view->GetRenderWidgetHost())->SendScreenRects();
  }
}

- (void)exitFullscreen {
  if (_contents && _contents->IsFullscreen()) {
    _contents->ExitFullscreen(true);
  }
}

- (void)exitExclusiveAccess {
  if (!_contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(_contents);
  ExclusiveAccessManager* manager =
      browser ? ExclusiveAccessManager::From(browser) : nullptr;
  if (manager) {
    manager->OnTabDeactivated(_contents);
  }
}

- (void)tracePictureInPicture:(NSString*)line withInputs:(BOOL)withInputs {
  if (!solaracore::PictureInPictureTracing()) {
    return;
  }
  if (withInputs && _contents) {
    solaracore::TraceAutoPictureInPictureInputs(_contents, line.UTF8String);
  } else {
    solaracore::TracePictureInPicture(base::SysNSStringToUTF8(line));
  }
}

- (BOOL)autoPictureInPictureIsChromes {
  if (!_contents) {
    return NO;
  }
  auto* helper = AutoPictureInPictureTabHelper::FromWebContents(_contents);
  if (!helper) {
    return NO;
  }
  if (helper->IsInAutoPictureInPicture() || helper->AreAutoPictureInPicturePreconditionsMet()) {
    return YES;
  }
  const GURL& url = _contents->GetLastCommittedURL();
  Profile* profile = Profile::FromBrowserContext(_contents->GetBrowserContext());
  return !g_solara_auto_picture_in_picture_off &&
         helper->HasAutoPictureInPictureBeenRegistered() &&
         (url.SchemeIs(url::kHttpsScheme) || url.SchemeIsFile()) &&
         MediaCaptureDevicesDispatcher::GetInstance()
             ->GetMediaStreamCaptureIndicator()
             ->IsCapturingUserMedia(_contents) &&
         HostContentSettingsMapFactory::GetForProfile(profile)->GetContentSetting(
             url, url, ContentSettingsType::AUTO_PICTURE_IN_PICTURE) == CONTENT_SETTING_ALLOW;
}

- (BOOL)showCastDialog {
  return solaracore::ShowCastDialog(_contents);
}

- (BOOL)devShowBluetoothChooser:(BOOL)unauthorized {
  return solaracore::ShowTestBluetoothChooser(_contents, unauthorized);
}

- (NSSize)preferredSize {
  const gfx::Size size =
      _contents ? solaracore::ExtensionPopupPreferredSize(_contents) : gfx::Size();
  return NSMakeSize(size.width(), size.height());
}

- (NSDictionary<NSString*, NSNumber*>*)popupFeatures {
  solaracore::TabBridge* bridge =
      _contents ? solaracore::TabBridge::FromWebContents(_contents) : nullptr;
  return bridge ? bridge->popup_features() : nil;
}

namespace {
TabSharingInfoBarDelegate* TabSharingDelegateFor(content::WebContents* contents,
                                                 content::WebContents* capturer) {
  auto* manager =
      contents ? infobars::ContentInfoBarManager::FromWebContents(contents) : nullptr;
  if (!manager || !capturer) {
    return nullptr;
  }
  TabSharingInfoBarDelegate* found = nullptr;
  for (infobars::InfoBar* infobar : manager->infobars()) {
    if (infobar->delegate()->GetIdentifier() !=
        infobars::InfoBarDelegate::TAB_SHARING_INFOBAR_DELEGATE) {
      continue;
    }
    auto* sharing = static_cast<TabSharingInfoBarDelegate*>(infobar->delegate());
    content::RenderFrameHost* frame =
        content::RenderFrameHost::FromID(sharing->capturer_id());
    if (frame && content::WebContents::FromRenderFrameHost(frame) == capturer) {
      if (found) {
        return nullptr;
      }
      found = sharing;
    }
  }
  return found;
}
}

- (BOOL)canShareThisTabInsteadFor:(SolaraCoreTab*)capturer {
  TabSharingInfoBarDelegate* sharing =
      TabSharingDelegateFor(_contents, capturer.contents);
  return sharing &&
         (sharing->GetButtons() & TabSharingInfoBarDelegate::kShareThisTabInstead) &&
         sharing->IsButtonEnabled(TabSharingInfoBarDelegate::kShareThisTabInstead);
}

- (BOOL)shareThisTabInsteadFor:(SolaraCoreTab*)capturer {
  if (![self canShareThisTabInsteadFor:capturer]) {
    return NO;
  }
  TabSharingDelegateFor(_contents, capturer.contents)->ShareThisTabInstead();
  return YES;
}

- (BOOL)showAutofillSuggestions:(BOOL)passwords {
  return solaracore::ShowAutofillSuggestions(_contents, passwords);
}

- (void)executeJavaScript:(NSString*)code frame:(NSString*)frameId {
  if (_contents) {
    solaracore::EndAheadBlank(_contents);
    solaracore::PageChannel::GetOrCreate(_contents)->ExecuteInFrame(
        base::SysNSStringToUTF8(frameId), base::SysNSStringToUTF8(code));
  }
}

- (void)evaluate:(NSString*)code completion:(void (^)(NSString*))completion {
  if (!_contents) {
    completion(nil);
    return;
  }
  solaracore::EndAheadBlank(_contents);
  solaracore::PageChannel::GetOrCreate(_contents)->Evaluate(
      base::SysNSStringToUTF8(code),
      base::BindOnce(
          [](void (^completion)(NSString*), const std::optional<std::string>& json) {
            completion(json ? NS(*json) : nil);
          },
          completion));
}

- (void)enterPictureInPictureForClickAt:(NSTimeInterval)clickTime
                             completion:(void (^)(NSString* route, BOOL opened))completion {
  if (!_contents) {
    completion(@"none", NO);
    return;
  }
  const solaracore::PictureInPictureRoute route =
      solaracore::PageChannel::GetOrCreate(_contents)->EnterPictureInPictureForClick(
          clickTime > 0 ? std::optional<base::TimeTicks>(base::TimeTicks() +
                                                         base::Seconds(clickTime))
                        : std::nullopt,
          base::BindOnce(
              [](void (^completion)(NSString*, BOOL), bool opened) {
                completion(@"element", opened);
              },
              completion));
  if (route == solaracore::PictureInPictureRoute::kMediaSession) {
    completion(@"session", NO);
  } else if (route == solaracore::PictureInPictureRoute::kNone) {
    completion(@"none", NO);
  }
}

- (void)exitPictureInPicture {
  if (!_contents) {
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<content::WebContents> contents) {
                       PictureInPictureWindowManager* manager =
                           PictureInPictureWindowManager::GetInstance();
                       if (contents && manager->GetWebContents() == contents.get()) {
                         manager->ExitPictureInPicture();
                       }
                     },
                     _contents->GetWeakPtr()));
}

- (BOOL)hasLiveFrame:(NSString*)frameId {
  return _contents && (!frameId.length ||
                       solaracore::PageChannel::GetOrCreate(_contents)->HasFrame(
                           base::SysNSStringToUTF8(frameId)));
}

- (void)callPage:(NSString*)kind json:(NSString*)json {
  if (_contents) {
    solaracore::EndAheadBlank(_contents);
    solaracore::PageChannel::GetOrCreate(_contents)->CallPage(
        base::SysNSStringToUTF8(kind), base::SysNSStringToUTF8(json));
  }
}

- (void)callFrame:(NSString*)frameId kind:(NSString*)kind json:(NSString*)json {
  if (_contents) {
    solaracore::EndAheadBlank(_contents);
    solaracore::PageChannel::GetOrCreate(_contents)->CallFrame(
        base::SysNSStringToUTF8(frameId), base::SysNSStringToUTF8(kind),
        base::SysNSStringToUTF8(json));
  }
}

- (content::WebContents*)contents {
  return _contents;
}

- (void)contentsDestroyed {
  _contents = nullptr;
}

- (void)notify:(SEL)selector {
  id<SolaraCoreTabDelegate> delegate = _delegate;
  if ([delegate respondsToSelector:selector]) {
    [delegate performSelector:selector withObject:self];
  }
}

- (BOOL)closed {
  if (!_contents) {
    return YES;
  }
  solaracore::TabBridge* bridge = solaracore::TabBridge::FromWebContents(_contents);
  return bridge && bridge->closing_after_unload();
}

- (BOOL)closingWithWindow {
  solaracore::TabBridge* bridge =
      _contents ? solaracore::TabBridge::FromWebContents(_contents) : nullptr;
  return bridge && bridge->closing_with_window();
}

- (NSView*)view {
  return _contents ? _contents->GetNativeView().GetNativeNSView() : nil;
}

- (SolaraCoreProfile*)profile {
  return _contents ? [SolaraCoreProfile
                         wrapperFor:Profile::FromBrowserContext(
                                        _contents->GetBrowserContext())]
                   : nil;
}

- (int)tabId {
  return _contents ? sessions::SessionTabHelper::IdForTab(_contents).id() : -1;
}

- (NSString*)url {
  return _contents ? NS(_contents->GetVisibleURL().spec()) : @"";
}

- (NSString*)title {
  return _contents ? NS(_contents->GetTitle()) : @"";
}

- (BOOL)loading {
  return _contents && _contents->IsLoading();
}

- (double)progress {
  return _contents ? _contents->GetLoadProgress() : 0;
}

- (NSImage*)favicon {
  if (!_contents) {
    return nil;
  }
  auto* driver = favicon::ContentFaviconDriver::FromWebContents(_contents);
  if (!driver || !driver->FaviconIsValid()) {
    return nil;
  }
  gfx::Image image = driver->GetFavicon();
  return image.IsEmpty() ? nil : image.ToNSImage();
}

- (BOOL)canGoBack {
  return _contents && _contents->GetController().CanGoBack();
}

- (BOOL)canGoForward {
  return _contents && _contents->GetController().CanGoForward();
}

- (void)loadURL:(NSString*)url {
  if (_contents) {
    GURL target(base::SysNSStringToUTF8(url));
    if (target.SchemeIs(url::kJavaScriptScheme)) {
      solaracore::EndAheadBlank(_contents);
    }
    _contents->GetController().LoadURL(target,
                                       content::Referrer(),
                                       ui::PAGE_TRANSITION_TYPED, std::string());
  }
}

- (void)focus {
  if (_contents) {
    auto focusing = solaracore::TabBridge::GetOrCreate(_contents)->HostFocuses();
    _contents->Focus();
  }
}

- (void)find:(NSString*)text forward:(BOOL)forward {
  if (!_contents) {
    return;
  }
  solaracore::TabBridge::GetOrCreate(_contents)->EnsureFindObserved();
  if (auto* helper = find_in_page::FindTabHelper::FromWebContents(_contents)) {
    helper->StartFinding(base::SysNSStringToUTF16(text), forward,
                         false, true);
  }
}

- (void)stopFinding {
  if (!_contents) {
    return;
  }
  if (auto* helper = find_in_page::FindTabHelper::FromWebContents(_contents)) {
    helper->StopFinding(find_in_page::SelectionAction::kKeep);
  }
}

- (void)goBack {
  if (self.canGoBack) {
    _contents->GetController().GoBack();
  }
}

- (void)goForward {
  if (self.canGoForward) {
    _contents->GetController().GoForward();
  }
}

- (void)reload {
  if (_contents) {
    _contents->GetController().Reload(content::ReloadType::NORMAL, true);
  }
}

- (void)loadIfNeeded {
  if (_contents && _contents->GetController().NeedsReload()) {
    _contents->GetController().LoadIfNecessary();
  }
}

- (void)stop {
  if (_contents) {
    _contents->Stop();
  }
}

- (BOOL)temporary {
  return _contents && solaracore::TabBridge::GetOrCreate(_contents)->temporary();
}

- (void)setTemporary:(BOOL)temporary {
  if (_contents) {
    solaracore::TabBridge::GetOrCreate(_contents)->SetTemporary(temporary);
  }
}

- (void)deliverHeldPageMessages {
  if (_contents) {
    solaracore::PageChannel::GetOrCreate(_contents)->DeliverHeld();
  }
}

- (void)setTemporarySource:(SolaraCoreTab*)source {
  if (_contents) {
    solaracore::TabBridge::GetOrCreate(_contents)->SetTemporarySource(
        source && source->_contents
            ? sessions::SessionTabHelper::IdForTab(source->_contents).id()
            : 0);
  }
}

- (void)closeNow {
  if (solaracore::IsNotifyingTabStrip() || solaracore::IsNotifyingNavigation()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self closeNow];
    });
    return;
  }
  if (!_contents || solaracore::CloseExtensionView(_contents)) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(_contents);
  if (!browser) {
    return;
  }
  solaracore::TabBridge* bridge = solaracore::TabBridge::GetOrCreate(_contents);
  if (bridge->closing_after_unload() ||
      browser->GetTabStripModel()->GetIndexOfWebContents(_contents) ==
          TabStripModel::kNoTab) {
    return;
  }
  bridge->set_closed_by_host();
  if (!browser_shutdown::HasShutdownStarted() &&
      _contents->NeedToFireBeforeUnloadOrUnloadEvents()) {
    bridge->CloseAfterUnloadHandlers(
        browser_shutdown::IsTryingToQuit() ||
        UnloadController::From(browser)->is_attempting_to_close_browser());
    return;
  }
  solaracore::DeleteTabClosedByHost(_contents);
}

- (void)close {
  if (solaracore::IsNotifyingTabStrip() || solaracore::IsNotifyingNavigation()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self close];
    });
    return;
  }
  if (!_contents || solaracore::CloseExtensionView(_contents)) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(_contents);
  if (!browser) {
    return;
  }
  solaracore::TabBridge::GetOrCreate(_contents)->set_closed_by_host();
  TabStripModel* model = browser->GetTabStripModel();
  int index = model->GetIndexOfWebContents(_contents);
  if (index != TabStripModel::kNoTab) {
    uint32_t close_types = TabCloseTypes::CLOSE_USER_GESTURE;
    if (!solaracore::OnlyShowedBlank(_contents)) {
      close_types |= TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB;
    }
    model->CloseWebContentsAt(index, close_types);
  }
}

- (void)showDevTools {
  if (_contents) {
    DevToolsWindow::OpenDevToolsWindow(_contents, DevToolsToggleAction::Show(),
                                       DevToolsOpenedByAction::kUnknown);
  }
}

- (void)closeDevTools {
  if (!_contents) {
    return;
  }
  if (content::WebContents* devtools =
          DevToolsWindow::GetInTabWebContents(_contents, nullptr)) {
    devtools->ClosePage();
  }
}

- (NSView*)devToolsView {
  if (!_contents) {
    return nil;
  }
  content::WebContents* devtools =
      DevToolsWindow::GetInTabWebContents(_contents, nullptr);
  return devtools ? devtools->GetNativeView().GetNativeNSView() : nil;
}

- (void)devToolsLayoutForSize:(NSSize)size
                     devTools:(NSRect*)devToolsFrame
                         page:(NSRect*)pageFrame {
  DevToolsContentsResizingStrategy strategy;
  gfx::Rect devtools_bounds, page_bounds;
  gfx::Rect container(0, 0, size.width, size.height);
  if (_contents && DevToolsWindow::GetInTabWebContents(_contents, &strategy)) {
    ApplyDevToolsContentsResizingStrategy(strategy, container, &devtools_bounds,
                                          &page_bounds);
  } else {
    page_bounds = container;
  }
  if (devToolsFrame) {
    *devToolsFrame = devtools_bounds.ToCGRect();
  }
  if (pageFrame) {
    *pageFrame = page_bounds.ToCGRect();
  }
}

- (NSDictionary<NSString*, id>*)passwordPrompt {
  return solaracore::PasswordPrompt(_contents);
}

- (void)resolvePasswordPrompt:(NSString*)action
                     username:(NSString*)username
                     password:(NSString*)password {
  solaracore::ResolvePasswordPrompt(_contents, action, username, password);
}

- (NSDictionary<NSString*, id>*)autofillPrompt {
  return solaracore::AutofillPrompt(_contents);
}

- (void)resolveAutofillPrompt:(NSInteger)promptId action:(NSString*)action {
  solaracore::ResolveAutofillPrompt(_contents, promptId, action);
}

@end
