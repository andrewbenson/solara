#include "solara/core/ac_device_chooser.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <map>
#include <string>
#include <memory>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/bluetooth/chrome_bluetooth_chooser_controller.h"
#include "components/permissions/bluetooth_chooser_controller.h"
#include "components/permissions/chooser_controller.h"
#include "content/public/browser/bluetooth_chooser.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "solara/core/ac_browser.h"
#include "solara/core/ac_external_apps.h"
#import "solara/core/solaracore_internal.h"

namespace solaracore {

namespace {

class DeviceChooser;

std::map<int, std::unique_ptr<DeviceChooser>>& Live() {
  static base::NoDestructor<std::map<int, std::unique_ptr<DeviceChooser>>> live;
  return *live;
}

class DeviceChooser : public permissions::ChooserController::View {
 public:
  DeviceChooser(std::unique_ptr<permissions::ChooserController> controller,
                content::RenderFrameHost* requester,
                SolaraCoreWindow* presenter,
                base::ScopedClosureRunner fullscreen_blocker)
      : controller_(std::move(controller)),
        contents_(content::WebContents::FromRenderFrameHost(requester)->GetWeakPtr()),
        requester_(requester->GetWeakDocumentPtr()),
        presenter_(presenter),
        fullscreen_blocker_(std::move(fullscreen_blocker)) {
    static int last_id = 0;
    id_ = ++last_id;
    ResetOptionIds();
    controller_->set_view(this);
  }
  ~DeviceChooser() override {
    if (controller_) {
      controller_->set_view(nullptr);
    }
  }

  int id() const { return id_; }
  content::WebContents* contents() const { return contents_.get(); }
  base::WeakPtr<DeviceChooser> GetWeakPtr() { return weak_factory_.GetWeakPtr(); }
  permissions::ChooserController* controller() const {
    return open_ ? controller_.get() : nullptr;
  }

  bool IsCurrent() const {
    auto* requester = requester_.AsRenderFrameHostIfValid();
    if (!contents_ || !requester || !requester->IsActive() ||
        !requester->IsRenderFrameLive() || !requester->GetPage().IsPrimary() ||
        content::WebContents::FromRenderFrameHost(requester) != contents_.get()) {
      return false;
    }
    auto* browser =
        GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents_.get());
    auto* host = browser ? WindowHost::ForBrowser(browser) : nullptr;
    return presenter_ && host && host->owner() == presenter_;
  }

  NSDictionary* State() const {
    NSMutableArray* options = [NSMutableArray array];
    NSMutableDictionary* state =
        [@{@"id" : @(id_), @"open" : @(open_), @"options" : options} mutableCopy];
    if (!open_ || !controller_) {
      return state;
    }
    permissions::ChooserController* c = controller_.get();
    state[@"title"] = base::SysUTF16ToNSString(c->GetTitle());
    state[@"okLabel"] = base::SysUTF16ToNSString(c->GetOkButtonLabel());
    state[@"cancelLabel"] = base::SysUTF16ToNSString(c->GetCancelButtonLabel());
    state[@"noOptionsText"] = base::SysUTF16ToNSString(c->GetNoOptionsText());
    state[@"scanningText"] =
        base::SysUTF16ToNSString(c->GetThrobberLabelAndTooltip().first);
    state[@"refreshing"] = @(refreshing_);
    state[@"canRefresh"] = @(c->ShouldShowReScanButton());
    state[@"adapterOff"] = @(c->ShouldShowAdapterOffView() && !adapter_on_);
    state[@"unauthorized"] =
        @(c->ShouldShowAdapterUnauthorizedView() && !authorized_);
    state[@"bothButtonsEnabled"] = @(c->BothButtonsAlwaysEnabled());
    state[@"showSignal"] = @(c->ShouldShowIconBeforeText());
    for (size_t i = 0; i < option_ids_.size(); ++i) {
      [options addObject:@{
        @"optionId" : @(option_ids_[i]),
        @"name" : base::SysUTF16ToNSString(c->GetOption(i)),
        @"connected" : @(c->IsConnected(i)),
        @"paired" : @(c->IsPaired(i)),
        @"signal" : @(c->ShouldShowIconBeforeText() ? c->GetSignalStrengthLevel(i) : -1),
      }];
    }
    return state;
  }

  void Select(int option_id) {
    if (!CanAct()) {
      return;
    }
    std::vector<size_t> indices;
    const auto option = std::ranges::find(option_ids_, option_id);
    if (option != option_ids_.end() &&
        option_ids_.size() == controller_->NumOptions()) {
      indices.push_back(static_cast<size_t>(option - option_ids_.begin()));
    } else if (option_id != -1 || !controller_->BothButtonsAlwaysEnabled()) {
      return;
    }
    std::unique_ptr<permissions::ChooserController> controller = Finish();
    controller->Select(indices);
    Release(std::move(controller));
  }

  void Cancel() {
    if (!CanAct()) {
      return;
    }
    std::unique_ptr<permissions::ChooserController> controller = Finish();
    controller->Cancel();
    Release(std::move(controller));
  }

  void Refresh() {
    if (CanAct()) {
      InvalidateOptionIds();
      controller_->RefreshOptions();
      Changed();
    }
  }

  void OpenSettings() {
    if (!CanAct() || !controller_->ShouldShowAdapterUnauthorizedView()) {
      return;
    }
    if (TestNoLaunch()) {
      RecordTestLaunch(@{
        @"url" : @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"
                 @"Privacy_Bluetooth",
        @"settings" : @"bluetooth",
      });
      return;
    }
    controller_->OpenPermissionPreferences();
  }

  void CloseFromChrome() {
    if (open_) {
      Release(Finish());
    }
  }

  void Announce() {
    announced_ = true;
    Changed();
  }

  void OnOptionsInitialized() override {
    ResetOptionIds();
    Changed();
  }
  void OnOptionAdded(size_t index) override {
    if (index <= option_ids_.size() &&
        controller_->NumOptions() == option_ids_.size() + 1) {
      option_ids_.insert(option_ids_.begin() + index, ++last_option_id_);
    } else {
      ResetOptionIds();
    }
    Changed();
  }
  void OnOptionRemoved(size_t index) override {
    if (index < option_ids_.size() &&
        controller_->NumOptions() + 1 == option_ids_.size()) {
      option_ids_.erase(option_ids_.begin() + index);
    } else {
      ResetOptionIds();
    }
    Changed();
  }
  void OnOptionUpdated(size_t) override { Changed(); }
  void OnAdapterEnabledChanged(bool enabled) override {
    adapter_on_ = enabled;
    ResetOptionIds();
    Changed();
  }
  void OnAdapterAuthorizationChanged(bool authorized) override {
    authorized_ = authorized;
    ResetOptionIds();
    Changed();
  }
  void OnRefreshStateChanged(bool refreshing) override {
    refreshing_ = refreshing;
    Changed();
  }

 private:
  void InvalidateOptionIds() { option_ids_.clear(); }

  void ResetOptionIds() {
    InvalidateOptionIds();
    for (size_t i = 0; i < controller_->NumOptions(); ++i) {
      option_ids_.push_back(++last_option_id_);
    }
  }

  bool CanAct() {
    if (!open_) {
      return false;
    }
    if (!IsCurrent()) {
      CloseFromChrome();
      return false;
    }
    return true;
  }

  void Changed() {
    if (!announced_ || !contents_) {
      return;
    }
    if (open_ && !IsCurrent()) {
      CloseFromChrome();
      return;
    }
    if (open_ && option_ids_.size() != controller_->NumOptions()) {
      ResetOptionIds();
    }
    HostDeviceChooser(contents_.get(), State());
  }

  std::unique_ptr<permissions::ChooserController> Finish() {
    open_ = false;
    if (announced_ && contents_ && !contents_->IsBeingDestroyed()) {
      auto contents = contents_;
      NSDictionary* closed = State();
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(
              [](base::WeakPtr<content::WebContents> contents, NSDictionary* closed) {
                if (contents && !contents->IsBeingDestroyed()) {
                  HostDeviceChooser(contents.get(), closed);
                }
              },
              contents, closed));
    }
    controller_->set_view(nullptr);
    std::unique_ptr<permissions::ChooserController> controller = std::move(controller_);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce([](int id) { Live().erase(id); }, id_));
    return controller;
  }

  static void Release(std::unique_ptr<permissions::ChooserController> controller) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce([](std::unique_ptr<permissions::ChooserController>) {},
                       std::move(controller)));
  }

  std::unique_ptr<permissions::ChooserController> controller_;
  base::WeakPtr<content::WebContents> contents_;
  content::WeakDocumentPtr requester_;
  __weak SolaraCoreWindow* presenter_;
  std::vector<int> option_ids_;
  int last_option_id_ = 0;
  base::ScopedClosureRunner fullscreen_blocker_;
  int id_;
  bool open_ = true;
  bool announced_ = false;
  bool refreshing_ = false;
  bool adapter_on_ = true;
  bool authorized_ = true;
  base::WeakPtrFactory<DeviceChooser> weak_factory_{this};
};

DeviceChooser* Find(int id) {
  auto it = Live().find(id);
  return it == Live().end() ? nullptr : it->second.get();
}

DeviceChooser* Adopt(std::unique_ptr<permissions::ChooserController> controller,
                     content::RenderFrameHost* requester,
                     SolaraCoreWindow* presenter,
                     base::ScopedClosureRunner fullscreen_blocker = {}) {
  auto* contents = content::WebContents::FromRenderFrameHost(requester);
  RetireDeviceChoosersForTab(contents);
  auto chooser = std::make_unique<DeviceChooser>(
      std::move(controller), requester, presenter, std::move(fullscreen_blocker));
  DeviceChooser* raw = chooser.get();
  Live()[raw->id()] = std::move(chooser);
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<DeviceChooser> chooser) {
                       if (chooser) {
                         chooser->Announce();
                       }
                     },
                     raw->GetWeakPtr()));
  return raw;
}

constexpr char kTestBluetoothChooserSwitch[] = "solara-test-bluetooth-chooser";

NSMutableArray<NSDictionary*>* TestEvents() {
  static NSMutableArray<NSDictionary*>* events = [NSMutableArray array];
  return events;
}

NSString* EventName(content::BluetoothChooserEvent event) {
  switch (event) {
    case content::BluetoothChooserEvent::DENIED_PERMISSION:
      return @"denied";
    case content::BluetoothChooserEvent::CANCELLED:
      return @"cancelled";
    case content::BluetoothChooserEvent::SELECTED:
      return @"selected";
    case content::BluetoothChooserEvent::RESCAN:
      return @"rescan";
    case content::BluetoothChooserEvent::SHOW_OVERVIEW_HELP:
      return @"overviewHelp";
    case content::BluetoothChooserEvent::SHOW_ADAPTER_OFF_HELP:
      return @"adapterOffHelp";
    case content::BluetoothChooserEvent::SHOW_NEED_LOCATION_HELP:
      return @"needLocationHelp";
  }
  return @"unknown";
}

void DriveTestBluetoothChooser(int chooser_id, bool unauthorized) {
  DeviceChooser* chooser = Find(chooser_id);
  auto* controller = chooser ? static_cast<permissions::BluetoothChooserController*>(
                                   chooser->controller())
                             : nullptr;
  if (!controller) {
    return;
  }
  using content::BluetoothChooser;
  if (unauthorized) {
    controller->OnAdapterPresenceChanged(BluetoothChooser::AdapterPresence::UNAUTHORIZED);
    return;
  }
  controller->OnAdapterPresenceChanged(BluetoothChooser::AdapterPresence::POWERED_ON);
  controller->AddOrUpdateDevice("ac-test-device", false,
                                u"Solara Test Device", false,
                                false, 3);
  controller->OnDiscoveryStateChanged(BluetoothChooser::DiscoveryState::IDLE);
}

}

bool HandleDeviceChooser(content::RenderFrameHost* requester,
                         std::unique_ptr<permissions::ChooserController>* controller,
                         base::ScopedClosureRunner* fullscreen_blocker,
                         base::OnceClosure* close_closure) {
  content::WebContents* contents = content::WebContents::FromRenderFrameHost(requester);
  BrowserWindowInterface* browser =
      contents ? GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents)
               : nullptr;
  auto* host = browser ? WindowHost::ForBrowser(browser) : nullptr;
  if (!host || !controller || !*controller ||
      !fullscreen_blocker || !close_closure || !HostWantsDeviceChoosers()) {
    return false;
  }
  DeviceChooser* raw =
      Adopt(std::move(*controller), requester, host->owner(), std::move(*fullscreen_blocker));
  *close_closure = base::BindOnce(
      [](base::WeakPtr<DeviceChooser> chooser) {
        if (chooser) {
          chooser->CloseFromChrome();
        }
      },
      raw->GetWeakPtr());
  return true;
}

bool ShowTestBluetoothChooser(content::WebContents* contents, bool unauthorized) {
  if (!contents || !contents->GetPrimaryMainFrame() ||
      !base::CommandLine::ForCurrentProcess()->HasSwitch(kTestBluetoothChooserSwitch) ||
      !HostWantsDeviceChoosers()) {
    return false;
  }
  auto* browser = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  auto* host = browser ? WindowHost::ForBrowser(browser) : nullptr;
  if (!host) {
    return false;
  }
  auto chooser_id = std::make_shared<int>(0);
  auto handler = base::BindRepeating(
      [](std::shared_ptr<int> chooser_id, content::BluetoothChooserEvent event,
         const std::string& device) {
        [TestEvents() addObject:@{
          @"event" : EventName(event),
          @"device" : base::SysUTF8ToNSString(device),
        }];
        if (event == content::BluetoothChooserEvent::RESCAN) {
          base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
              FROM_HERE, base::BindOnce(&DriveTestBluetoothChooser, *chooser_id, false));
        }
      },
      chooser_id);
  DeviceChooser* chooser = Adopt(std::make_unique<ChromeBluetoothChooserController>(
                                     contents->GetPrimaryMainFrame(), handler),
                                 contents->GetPrimaryMainFrame(), host->owner());
  *chooser_id = chooser->id();
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&DriveTestBluetoothChooser, chooser->id(), unauthorized));
  return true;
}

NSArray<NSDictionary*>* TestChooserEvents() {
  return [TestEvents() copy];
}

void RetireStaleDeviceChoosers() {
  for (const auto& entry : Live()) {
    if (!entry.second->IsCurrent()) {
      entry.second->CloseFromChrome();
    }
  }
}

void RetireDeviceChoosersForTab(content::WebContents* contents) {
  for (const auto& entry : Live()) {
    if (entry.second->contents() == contents) {
      entry.second->CloseFromChrome();
    }
  }
}

void SelectDevice(int chooser_id, int option_id) {
  if (DeviceChooser* chooser = Find(chooser_id)) {
    chooser->Select(option_id);
  }
}

void CancelDeviceChooser(int chooser_id) {
  if (DeviceChooser* chooser = Find(chooser_id)) {
    chooser->Cancel();
  }
}

void RefreshDeviceChooser(int chooser_id) {
  if (DeviceChooser* chooser = Find(chooser_id)) {
    chooser->Refresh();
  }
}

void OpenDeviceChooserSettings(int chooser_id) {
  if (DeviceChooser* chooser = Find(chooser_id)) {
    chooser->OpenSettings();
  }
}

}
