// Copyright 2026 Solara. Apache-2.0.

#ifndef SOLARA_CORE_AC_DESKTOP_CAPTURE_H_
#define SOLARA_CORE_AC_DESKTOP_CAPTURE_H_

#include <string>

namespace content {
struct MediaStreamRequest;
class RenderFrameHost;
class WebContents;
}

namespace solaracore {

struct DesktopCaptureState {
  bool starting = false;
  bool active = false;
  bool ended = false;
  bool waiting_for_start_for_testing = false;
};

std::string OfferDesktopCapture(content::RenderFrameHost& frame,
                                int page_request_id,
                                bool audio,
                                bool system_audio,
                                const std::string& window_audio);
void AnswerDesktopCapture(content::WebContents* contents,
                          const std::string& receipt,
                          const std::string& source,
                          bool share_audio);
void ConfirmDesktopCapture(content::RenderFrameHost& frame,
                           const std::string& receipt);
bool CancelDesktopCaptures(content::WebContents* contents);
DesktopCaptureState GetDesktopCaptureState(content::WebContents* contents);

bool IsDesktopCaptureSystemAudioSupported();
bool IsDesktopCaptureApplicationAudioSupported();

void ApplyDesktopCaptureGrant(content::WebContents* contents,
                              content::MediaStreamRequest& request);

}

#endif
