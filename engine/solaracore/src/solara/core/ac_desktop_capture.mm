// Copyright 2026 Solara. Apache-2.0.

#include "solara/core/ac_desktop_capture.h"

#include <map>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/task/bind_post_task.h"
#include "base/time/time.h"
#include "base/unguessable_token.h"
#include "base/values.h"
#include "chrome/browser/media/webrtc/desktop_media_picker_controller.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/desktop_media_id.h"
#include "content/public/browser/desktop_streams_registry.h"
#include "content/public/browser/media_stream_request.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "content/public/browser/weak_document_ptr.h"
#include "media/base/media_switches.h"
#include "solara/core/ac_browser.h"
#include "solara/core/ac_page_channel.h"
#include "third_party/blink/public/common/mediastream/media_stream_request.h"

namespace solaracore {

namespace {

constexpr base::TimeDelta kGrantLifetime = base::Seconds(15);
constexpr base::TimeDelta kOfferLifetime = base::Minutes(5);
constexpr size_t kMaxReceipts = 16;

using Control = content::SolaraCaptureControl;

struct CaptureReceipt {
  content::WeakDocumentPtr document;
  content::GlobalRenderFrameHostId frame_id;
  int page_request_id;
  bool audio;
  bool system_audio;
  std::string window_audio;
  base::TimeTicks expires;
  content::DesktopMediaID source;
  scoped_refptr<Control> control;

  content::RenderFrameHost* LiveFrame() const {
    auto* frame = document.AsRenderFrameHostIfValid();
    return frame && frame->IsActive() && frame->IsRenderFrameLive() &&
                   frame->GetPage().IsPrimary()
               ? frame
               : nullptr;
  }
};

void ShareAudio(CaptureReceipt& receipt) {
  if (!receipt.audio) {
    return;
  }
  auto& source = receipt.source;
  switch (source.type) {
    case content::DesktopMediaID::TYPE_WEB_CONTENTS:
      source.audio_share = true;
      break;
    case content::DesktopMediaID::TYPE_SCREEN:
      source.audio_share =
          receipt.system_audio && IsDesktopCaptureSystemAudioSupported();
      break;
    case content::DesktopMediaID::TYPE_WINDOW:
      if (receipt.window_audio == "window" &&
          IsDesktopCaptureApplicationAudioSupported()) {
        source.window_audio_type = content::DesktopMediaID::AudioType::kApplication;
      } else if ((receipt.window_audio == "window" ||
                  receipt.window_audio == "system") &&
                 IsDesktopCaptureSystemAudioSupported()) {
        source.window_audio_type = content::DesktopMediaID::AudioType::kSystem;
      }
      source.audio_share =
          source.window_audio_type != content::DesktopMediaID::AudioType::kNone;
      break;
    case content::DesktopMediaID::TYPE_NONE:
      break;
  }
}

class CaptureReceipts : public content::WebContentsObserver,
                        public content::WebContentsUserData<CaptureReceipts> {
 public:
  ~CaptureReceipts() override = default;

  std::string Offer(content::RenderFrameHost& frame,
                    int page_request_id,
                    bool audio,
                    bool system_audio,
                    const std::string& window_audio) {
    Prune();
    if (requests_.size() >= kMaxReceipts || !frame.IsActive() ||
        !frame.GetPage().IsPrimary() ||
        frame.GetLastCommittedOrigin().opaque()) {
      return {};
    }
    std::string token = std::string(content::kSolaraCaptureReceiptPrefix) +
                        base::UnguessableToken::Create().ToString();
    requests_.emplace(token, CaptureReceipt{
        frame.GetWeakDocumentPtr(), frame.GetGlobalId(), page_request_id,
        audio, system_audio, window_audio, base::TimeTicks::Now() + kOfferLifetime,
        {}, nullptr});
    SchedulePrune(kOfferLifetime);
    return token;
  }

  void Answer(const std::string& token, const std::string& source,
              bool share_audio) {
    Prune();
    auto it = requests_.find(token);
    if (it == requests_.end() || !it->second.source.is_null()) {
      return;
    }
    auto& receipt = it->second;
    receipt.source = content::DesktopMediaID::Parse(source);
    if (receipt.source.is_null()) {
      Reply(receipt, {});
      requests_.erase(it);
      return;
    }
    receipt.source.audio_share = false;
    receipt.source.window_audio_type = content::DesktopMediaID::AudioType::kNone;
    if (share_audio) {
      ShareAudio(receipt);
    }
    receipt.expires = base::TimeTicks::Now() + kGrantLifetime;
    ever_approved_ = true;
    SchedulePrune(kGrantLifetime);
    if (!base::CommandLine::ForCurrentProcess()->HasSwitch(
            "solara-test-hold-capture-reply")) {
      Reply(receipt, token);
    }
  }

  void Apply(content::MediaStreamRequest& request) {
    Prune();
    auto it = requests_.find(request.requested_video_device_ids.front());
    if (it == requests_.end() || !request.solara_capture_control) {
      return;
    }
    auto& receipt = it->second;
    auto* frame = receipt.LiveFrame();
    if (!frame || receipt.source.is_null() || receipt.control ||
        frame != content::RenderFrameHost::FromID(
                     request.render_process_id, request.render_frame_id) ||
        frame->GetLastCommittedOrigin() != request.url_origin) {
      return;
    }
    auto* main = GetWebContents().GetPrimaryMainFrame();
    request.requested_video_device_ids = {
        content::DesktopStreamsRegistry::GetInstance()->RegisterStream(
            main->GetProcess()->GetDeprecatedID(), main->GetRoutingID(),
            request.url_origin, receipt.source,
            content::kRegistryStreamTypeDesktop)};
    receipt.control = request.solara_capture_control;
    receipt.control->SetChangeCallback(base::BindPostTask(
        content::GetUIThreadTaskRunner({}),
        base::BindRepeating(&CaptureReceipts::ControlChanged,
                            weak_factory_.GetWeakPtr())));
  }

  void Confirm(content::RenderFrameHost& frame, const std::string& token) {
    auto it = requests_.find(token);
    const bool allowed =
        it != requests_.end() && it->second.LiveFrame() == &frame &&
        it->second.control &&
        it->second.control->state() == Control::State::kActive;
    DeliverConfirmation(frame, token, allowed);
  }

  bool CancelAll(bool reply) {
    if (requests_.empty()) {
      return false;
    }
    auto requests = std::move(requests_);
    requests_.clear();
    ever_approved_ = true;
    for (const auto& [token, receipt] : requests) {
      if (receipt.control) {
        receipt.control->Cancel();
      }
      if (reply) {
        Reply(receipt, {});
        if (auto* frame = receipt.LiveFrame()) {
          DeliverConfirmation(*frame, token, false);
        }
      }
    }
    return true;
  }

  DesktopCaptureState State() const {
    DesktopCaptureState result;
    for (const auto& [token, receipt] : requests_) {
      if (receipt.source.is_null()) {
        continue;
      }
      if (!receipt.control) {
        result.starting |= receipt.expires > base::TimeTicks::Now();
        continue;
      }
      auto state = receipt.control->state();
      result.starting |= state == Control::State::kStarting;
      result.active |= state == Control::State::kActive;
      result.waiting_for_start_for_testing |=
          receipt.control->IsWaitingForStartForTesting();
    }
    result.ended = ever_approved_ && !result.active && !result.starting;
    return result;
  }

 private:
  friend class content::WebContentsUserData<CaptureReceipts>;
  explicit CaptureReceipts(content::WebContents* contents)
      : content::WebContentsObserver(contents),
        content::WebContentsUserData<CaptureReceipts>(*contents) {}

  void ReadyToCommitNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsSameDocument()) {
      return;
    }
    if (navigation->IsInPrimaryMainFrame()) {
      CancelAll(false);
      return;
    }
    for (auto it = requests_.begin(); it != requests_.end();) {
      auto* frame = it->second.LiveFrame();
      if (frame && frame->GetFrameTreeNodeId() == navigation->GetFrameTreeNodeId()) {
        if (it->second.control) {
          it->second.control->Cancel();
        }
        it = requests_.erase(it);
      } else {
        ++it;
      }
    }
  }

  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    for (auto it = requests_.begin(); it != requests_.end();) {
      if (it->second.frame_id == frame->GetGlobalId()) {
        if (it->second.control) {
          it->second.control->Cancel();
        }
        it = requests_.erase(it);
      } else {
        ++it;
      }
    }
  }

  void PrimaryPageChanged(content::Page&) override {
    Prune();
  }

  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    CancelAll(false);
  }

  void WebContentsDestroyed() override {
    CancelAll(false);
  }

  void SchedulePrune(base::TimeDelta delay) {
    content::GetUIThreadTaskRunner({})->PostDelayedTask(
        FROM_HERE, base::BindOnce(&CaptureReceipts::Prune, weak_factory_.GetWeakPtr()),
        delay);
  }

  void Prune() {
    const auto now = base::TimeTicks::Now();
    for (auto it = requests_.begin(); it != requests_.end();) {
      const auto& receipt = it->second;
      if (!receipt.LiveFrame()) {
        if (receipt.control) {
          receipt.control->Cancel();
        }
      } else if (!receipt.control && receipt.expires <= now) {
        Reply(receipt, {});
      } else if (!receipt.control ||
                 receipt.control->state() != Control::State::kEnded) {
        ++it;
        continue;
      }
      it = requests_.erase(it);
    }
  }

  void ControlChanged() {
    Prune();
    auto* contents = web_contents();
    auto* bridge = contents ? TabBridge::FromWebContents(contents) : nullptr;
    if (bridge) {
      bridge->MediaAccessChanged();
    }
  }

  void DeliverConfirmation(content::RenderFrameHost& frame,
                           const std::string& token, bool allowed) {
    base::DictValue response;
    response.Set("receipt", token);
    response.Set("allowed", allowed);
    std::string json;
    if (base::JSONWriter::Write(response, &json)) {
      PageChannel::GetOrCreate(&GetWebContents())->CallFrame(
          PageChannel::FrameId(&frame), "displayMediaReady", json);
    }
  }

  void Reply(const CaptureReceipt& receipt, const std::string& token) {
    if (auto* frame = receipt.LiveFrame()) {
      base::DictValue response;
      response.Set("id", receipt.page_request_id);
      response.Set("receipt", token);
      response.Set("audio", receipt.source.audio_share);
      std::string json;
      if (base::JSONWriter::Write(response, &json)) {
        PageChannel::GetOrCreate(&GetWebContents())->CallFrame(
            PageChannel::FrameId(frame), "displayMedia", json);
      }
    }
  }

  bool ever_approved_ = false;
  std::map<std::string, CaptureReceipt> requests_;
  base::WeakPtrFactory<CaptureReceipts> weak_factory_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(CaptureReceipts);

}

bool IsDesktopCaptureSystemAudioSupported() {
  return DesktopMediaPickerController::IsSystemAudioCaptureSupported(
      DesktopMediaPicker::Params::RequestSource::kExtension);
}

bool IsDesktopCaptureApplicationAudioSupported() {
  return media::IsApplicationLoopbackCaptureSupported();
}

std::string OfferDesktopCapture(content::RenderFrameHost& frame,
                                int page_request_id,
                                bool audio,
                                bool system_audio,
                                const std::string& window_audio) {
  auto* contents = content::WebContents::FromRenderFrameHost(&frame);
  if (!contents) {
    return {};
  }
  CaptureReceipts::CreateForWebContents(contents);
  return CaptureReceipts::FromWebContents(contents)->Offer(
      frame, page_request_id, audio, system_audio, window_audio);
}

void AnswerDesktopCapture(content::WebContents* contents,
                          const std::string& receipt,
                          const std::string& source,
                          bool share_audio) {
  if (auto* requests = contents ? CaptureReceipts::FromWebContents(contents) : nullptr) {
    requests->Answer(receipt, source, share_audio);
  }
}

void ConfirmDesktopCapture(content::RenderFrameHost& frame,
                           const std::string& receipt) {
  auto* contents = content::WebContents::FromRenderFrameHost(&frame);
  auto* requests = contents ? CaptureReceipts::FromWebContents(contents) : nullptr;
  if (requests && frame.IsActive() && frame.GetPage().IsPrimary()) {
    requests->Confirm(frame, receipt);
  }
}

bool CancelDesktopCaptures(content::WebContents* contents) {
  auto* requests = contents ? CaptureReceipts::FromWebContents(contents) : nullptr;
  return requests && requests->CancelAll(true);
}

DesktopCaptureState GetDesktopCaptureState(content::WebContents* contents) {
  auto* requests = contents ? CaptureReceipts::FromWebContents(contents) : nullptr;
  return requests ? requests->State() : DesktopCaptureState{};
}

void ApplyDesktopCaptureGrant(content::WebContents* contents,
                              content::MediaStreamRequest& request) {
  if (request.video_type != blink::mojom::MediaStreamType::GUM_DESKTOP_VIDEO_CAPTURE ||
      request.request_type != blink::MEDIA_GENERATE_STREAM ||
      request.requested_video_device_ids.empty()) {
    return;
  }
  if (auto* requests = CaptureReceipts::FromWebContents(contents)) {
    requests->Apply(request);
  }
}

}
