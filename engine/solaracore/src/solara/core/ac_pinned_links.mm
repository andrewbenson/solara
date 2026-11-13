#include "solara/core/ac_pinned_links.h"

#import <Foundation/Foundation.h>

#include <map>
#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/callback_list.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/solara/ac_user_hooks.h"  // nogncheck
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "solara/core/ac_browser.h"
#include "solara/core/ac_content_hooks.h"
#include "solara/core/public/SolaraCore.h"
#include "third_party/blink/public/mojom/window_features/window_features.mojom.h"
#include "url/gurl.h"

namespace solaracore {
namespace {

void ReleasePending(content::WebContents* contents, bool discard);
void ReleasePendingSoon(base::WeakPtr<content::WebContents> contents,
                        bool discard);

struct ParkedNavigationObserver : content::WebContentsObserver {
  explicit ParkedNavigationObserver(content::WebContents* parked)
      : content::WebContentsObserver(parked) {}
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame() && !handle->IsSameDocument() &&
        !handle->HasCommitted()) {
      ReleasePendingSoon(web_contents()->GetWeakPtr(), false);
    }
  }
};

struct PendingLinkOpen : content::WebContentsObserver {
  explicit PendingLinkOpen(content::WebContents* source)
      : content::WebContentsObserver(source) {}
  ~PendingLinkOpen() override {
    parked_navigation.reset();
    source_detach = {};
    if (tab) {
      tab->DestroyTabFeatures();
    }
  }
  void WebContentsDestroyed() override {
    ReleasePending(contents, true);
  }

  std::unique_ptr<tabs::TabModel> tab;
  content::WebContents* contents = nullptr;
  base::WeakPtr<content::WebContents> source;
  GURL target;
  WindowOpenDisposition disposition;
  blink::mojom::WindowFeaturesPtr features;
  base::OneShotTimer deadline;
  base::CallbackListSubscription source_detach;
  std::unique_ptr<ParkedNavigationObserver> parked_navigation;
};

using PendingMap = std::map<content::WebContents*, std::unique_ptr<PendingLinkOpen>>;

PendingMap& PendingLinks() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

void ReleasePending(content::WebContents* contents, bool discard) {
  auto found = PendingLinks().find(contents);
  if (found == PendingLinks().end()) {
    return;
  }
  auto pending = std::move(found->second);
  PendingLinks().erase(found);
  if (discard || !pending->source || !pending->source->GetDelegate()) {
    return;
  }
  TabBridge::GetOrCreate(contents)->set_pinned_link_checked();
  pending->parked_navigation.reset();
  pending->source_detach = {};
  pending->tab->DestroyTabFeatures();
  bool blocked = false;
  pending->source->GetDelegate()->AddNewContents(
      pending->source.get(), tabs::TabModel::DestroyAndTakeWebContents(std::move(pending->tab)),
      pending->target,
      pending->disposition, *pending->features, true, &blocked);
}

void ReleasePendingSoon(base::WeakPtr<content::WebContents> contents,
                        bool discard) {
  if (!contents || !PendingLinks().contains(contents.get())) {
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
          [](base::WeakPtr<content::WebContents> alive, bool drop) {
            if (alive) {
              ReleasePending(alive.get(), drop);
            }
          }, std::move(contents), discard));
}

class PinnedLinkThrottle : public content::NavigationThrottle {
 public:
  explicit PinnedLinkThrottle(content::NavigationThrottleRegistry& registry)
      : content::NavigationThrottle(registry) {}

  ThrottleCheckResult WillStartRequest() override {
    auto* handle = navigation_handle();
    auto* contents = handle->GetWebContents();
    auto parked = PendingLinks().find(contents);
    new_window_ = parked != PendingLinks().end();
    content::WebContents* source =
        new_window_ ? parked->second->source.get() : contents;
    auto* bridge = TabBridge::FromWebContents(contents);
    const bool link = handle->WasInitiatedByLinkClick() ||
                      (new_window_ && bridge && bridge->created_from_link());
    if (!source || !handle->IsInPrimaryMainFrame() || handle->IsSameDocument() ||
        handle->IsFormSubmission() || handle->IsPost() ||
        handle->GetRequestMethod() != "GET" || !link ||
        (!new_window_ && !handle->HasUserGesture()) ||
        !handle->GetURL().SchemeIsHTTPOrHTTPS() ||
        !WantsPinnedLinkPolicy(source) ||
        (!new_window_ && !HasPlainPinnedLinkGesture(source))) {
      if (new_window_) {
        ReleasePendingSoon(contents->GetWeakPtr(), false);
      }
      return PROCEED;
    }
    source_url_ = source->GetLastCommittedURL();
    source_ = source->GetWeakPtr();
    source_document_ = source->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    candidate_ = true;
    std::optional<GURL> rewritten = solara::PendingUserHooksRewrite(*handle);
    asked_url_ = rewritten ? *rewritten : handle->GetURL();
    return Ask(asked_url_, false);
  }

  ThrottleCheckResult WillRedirectRequest() override {
    if (!candidate_ || !SourceValid() ||
        navigation_handle()->GetURL() == asked_url_) {
      return PROCEED;
    }
    asked_url_ = navigation_handle()->GetURL();
    return Ask(asked_url_, true);
  }

  ThrottleCheckResult WillFailRequest() override {
    ReleasePendingSoon(navigation_handle()->GetWebContents()->GetWeakPtr(), false);
    return PROCEED;
  }

  ThrottleCheckResult WillProcessResponse() override {
    ReleasePendingSoon(navigation_handle()->GetWebContents()->GetWeakPtr(), false);
    return PROCEED;
  }

  const char* GetNameForLogging() override { return "ACPinnedLinkThrottle"; }

 private:
  ThrottleCheckResult Ask(const GURL& url, bool redirect) {
    if (!url.SchemeIsHTTPOrHTTPS()) {
      return PROCEED;
    }
    request_ = @{
      @"requestId": NSUUID.UUID.UUIDString,
      @"url": base::SysUTF8ToNSString(url.spec()),
      @"sourceURL": base::SysUTF8ToNSString(source_url_.spec()),
      @"newWindow": @(new_window_),
      @"redirect": @(redirect),
    };
    asking_ = true;
    weak_factory_.InvalidateWeakPtrs();
    auto alive = weak_factory_.GetWeakPtr();
    deadline_.Start(FROM_HERE, base::Seconds(2),
                    base::BindOnce(&PinnedLinkThrottle::Decide, alive, false));
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
            [](base::WeakPtr<PinnedLinkThrottle> throttle) {
              if (!throttle) {
                return;
              }
              if (!throttle->SourceValid()) {
                throttle->Decide(false);
                return;
              }
              SolaraCoreTab* tab = TabBridge::GetOrCreate(throttle->source_.get())->tab();
              id<SolaraCoreTabDelegate> delegate = tab.delegate;
              if (![delegate respondsToSelector:@selector(tab:decidePinnedLink:completion:)] ||
                  ![delegate respondsToSelector:@selector(tab:shouldInterceptPinnedLink:)]) {
                throttle->Decide(false);
                return;
              }
              auto weak = throttle;
              scoped_refptr<base::SequencedTaskRunner> ui =
                  content::GetUIThreadTaskRunner({});
              [delegate tab:tab decidePinnedLink:throttle->request_
                  completion:^(BOOL intercept) {
                    ui->PostTask(
                        FROM_HERE, base::BindOnce(
                            [](base::WeakPtr<PinnedLinkThrottle> target, bool route) {
                              if (target) {
                                target->Decide(route);
                              }
                            }, weak, static_cast<bool>(intercept)));
                  }];
            }, alive));
    return DEFER;
  }

  bool SourceValid() {
    return (!new_window_ || PendingLinks().contains(
                               navigation_handle()->GetWebContents())) &&
           source_ && source_document_.AsRenderFrameHostIfValid() &&
           source_->GetLastCommittedURL() == source_url_ &&
           WantsPinnedLinkPolicy(source_.get());
  }

  void Decide(bool intercept) {
    if (!asking_) {
      return;
    }
    asking_ = false;
    deadline_.Stop();
    auto contents = navigation_handle()->GetWebContents()->GetWeakPtr();
    if (!intercept || !SourceValid()) {
      Resume();
      return;
    }
    SolaraCoreTab* tab = TabBridge::GetOrCreate(source_.get())->tab();
    id<SolaraCoreTabDelegate> delegate = tab.delegate;
    auto alive = weak_factory_.GetWeakPtr();
    const BOOL taken = [delegate tab:tab shouldInterceptPinnedLink:request_];
    if (!alive) {
      ReleasePendingSoon(contents, true);
      return;
    }
    if (!taken) {
      Resume();
      return;
    }
    std::unique_ptr<PendingLinkOpen> discarded;
    auto parked = PendingLinks().find(navigation_handle()->GetWebContents());
    if (parked != PendingLinks().end()) {
      discarded = std::move(parked->second);
      PendingLinks().erase(parked);
      discarded->deadline.Stop();
      discarded->parked_navigation.reset();
      discarded->source_detach = {};
    }
    CancelDeferredNavigation(CANCEL_AND_IGNORE);
    if (discarded) {
      discarded->tab->DestroyTabFeatures();
      base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(
          FROM_HERE, std::move(discarded));
    }
  }

  bool candidate_ = false;
  bool new_window_ = false;
  GURL asked_url_;
  bool asking_ = false;
  GURL source_url_;
  base::WeakPtr<content::WebContents> source_;
  content::WeakDocumentPtr source_document_;
  NSDictionary* __strong request_ = nil;
  base::OneShotTimer deadline_;
  base::WeakPtrFactory<PinnedLinkThrottle> weak_factory_{this};
};

}

bool WantsPinnedLinkPolicy(content::WebContents* contents) {
  auto* source_tab = contents ? tabs::TabInterface::MaybeGetFromContents(contents) : nullptr;
  if (!source_tab || !source_tab->GetBrowserWindowInterface()) {
    return false;
  }
  TabBridge* bridge = TabBridge::FromWebContents(contents);
  SolaraCoreTab* tab = bridge ? bridge->tab() : nil;
  id<SolaraCoreTabDelegate> delegate = tab.delegate;
  return [delegate respondsToSelector:@selector(tabWantsPinnedLinkPolicy:)] &&
         [delegate tabWantsPinnedLinkPolicy:tab];
}

bool HasPlainPinnedLinkGesture(content::WebContents* contents) {
  TabBridge* bridge = contents ? TabBridge::FromWebContents(contents) : nullptr;
  SolaraCoreTab* tab = bridge ? bridge->tab() : nil;
  id<SolaraCoreTabDelegate> delegate = tab.delegate;
  return [delegate respondsToSelector:@selector(tabHasPlainLinkGesture:)] &&
         [delegate tabHasPlainLinkGesture:tab];
}

void InstallPinnedLinkHooks() {
  g_solara_created_window_link = [](content::WebContents* contents, bool link) {
    if (link) {
      TabBridge::GetOrCreate(contents)->set_created_from_link(true);
    }
  };
}

void AddPinnedLinkThrottle(content::NavigationThrottleRegistry& registry) {
  registry.AddThrottle(std::make_unique<PinnedLinkThrottle>(registry));
}

content::WebContents* ParkPinnedLink(
    content::WebContents* source,
    std::unique_ptr<content::WebContents> contents,
    const GURL& target,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& features) {
  content::WebContents* raw = contents.get();
  TabBridge::GetOrCreate(raw)->set_open(disposition, source);
  auto pending = std::make_unique<PendingLinkOpen>(source);
  pending->contents = raw;
  auto* source_tab = tabs::TabInterface::MaybeGetFromContents(source);
  pending->tab = std::make_unique<tabs::TabModel>(
      std::move(contents),
      source_tab->GetBrowserWindowInterface()->GetTabStripModel());
  pending->source = source->GetWeakPtr();
  pending->target = target;
  pending->disposition = disposition;
  pending->features = features.Clone();
  pending->deadline.Start(FROM_HERE, base::Seconds(10),
                          base::BindOnce(&ReleasePending, raw, false));
  pending->source_detach = source_tab->RegisterWillDetach(base::BindRepeating(
      [](content::WebContents* parked, tabs::TabInterface*,
         tabs::TabInterface::DetachReason) { ReleasePending(parked, true); },
      raw));
  pending->parked_navigation = std::make_unique<ParkedNavigationObserver>(raw);
  PendingLinks().emplace(raw, std::move(pending));
  return raw;
}

}
