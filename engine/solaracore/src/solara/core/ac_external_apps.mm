#include "solara/core/ac_external_apps.h"

#import <AppKit/AppKit.h>

#include <map>
#include <utility>
#include <optional>
#include <string>

#include "base/base64.h"
#include "base/command_line.h"
#include "base/memory/weak_ptr.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/external_protocol/external_protocol_handler.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "solara/core/ac_hooks.h"
#include "solara/core/ac_browser.h"
#import "solara/core/solaracore_internal.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "services/network/public/cpp/is_potentially_trustworthy.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/page.h"

namespace solaracore {

namespace {

struct Pending {
  GURL url;
  base::WeakPtr<content::WebContents> contents;
  std::optional<url::Origin> origin;
  content::WeakDocumentPtr initiator;
  bool can_remember = false;
  bool can_open = false;
  __weak SolaraCoreWindow* presenter = nil;

  bool IsCurrent() const {
    content::WebContents* tab = contents.get();
    auto* frame = initiator.AsRenderFrameHostIfValid();
    if (!tab || !frame || !frame->IsActive() || !frame->IsRenderFrameLive() ||
        !frame->GetPage().IsPrimary() ||
        content::WebContents::FromRenderFrameHost(frame) != tab) {
      return false;
    }
    auto* browser = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(tab);
    auto* host = browser ? WindowHost::ForBrowser(browser) : nullptr;
    return presenter && host && host->owner() == presenter;
  }
};

std::map<std::string, Pending>& PendingRequests() {
  static base::NoDestructor<std::map<std::string, Pending>> pending;
  return *pending;
}

NSString* IconDataURI(NSURL* app, CGFloat size) {
  NSImage* icon = [NSWorkspace.sharedWorkspace iconForFile:app.path];
  if (!icon) {
    return nil;
  }
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:nullptr
                    pixelsWide:size * 2
                    pixelsHigh:size * 2
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace
                   bytesPerRow:0
                  bitsPerPixel:0];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext =
      [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [icon drawInRect:NSMakeRect(0, 0, size * 2, size * 2)];
  [NSGraphicsContext restoreGraphicsState];
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return png ? [@"data:image/png;base64," stringByAppendingString:
                   [png base64EncodedStringWithOptions:0]]
             : nil;
}

bool AskHost(const GURL& url,
             content::WebContents* contents,
             const std::optional<url::Origin>& initiating_origin,
             content::WeakDocumentPtr initiator_document,
             const std::u16string& program_name) {
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser || !WindowHost::ForBrowser(browser)) {
    return false;
  }
  SolaraCoreTab* tab = TabBridge::GetOrCreate(contents)->tab();
  id<SolaraCoreTabDelegate> delegate = tab.delegate;
  if (![delegate respondsToSelector:@selector(tab:externalAppRequest:)]) {
    return false;
  }
  NSURL* ns_url = [NSURL URLWithString:base::SysUTF8ToNSString(url.spec())];
  NSURL* app = ns_url ? [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:ns_url]
                      : nil;
  NSString* name =
      app ? [NSFileManager.defaultManager displayNameAtPath:app.path]
                .stringByDeletingPathExtension
          : nil;
  if (!name.length && !program_name.empty()) {
    name = base::SysUTF16ToNSString(program_name);
  }
  const bool has_origin = initiating_origin && !initiating_origin->opaque();
  NSString* origin =
      has_origin ? base::SysUTF8ToNSString(initiating_origin->Serialize()) : nil;
  NSString* scheme = base::SysUTF8ToNSString(std::string(url.scheme()));
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  const bool can_remember = app && has_origin && !profile->IsOffTheRecord() &&
                            network::IsOriginPotentiallyTrustworthy(*initiating_origin);

  static int last_id = 0;
  const std::string request_id = "x" + std::to_string(++last_id);
  Pending pending{url, contents->GetWeakPtr(), initiating_origin, initiator_document,
                  can_remember, app != nil, WindowHost::ForBrowser(browser)->owner()};
  if (!pending.IsCurrent()) {
    return true;
  }
  RetireStaleExternalApps(contents);
  PendingRequests().emplace(request_id, std::move(pending));
  NSString* title = app ? [NSString stringWithFormat:@"Open “%@”?", name]
                        : @"No application is set to open this link";
  NSString* message =
      app ? (origin ? [NSString stringWithFormat:@"%@ wants to open this application.",
                                                 origin]
                    : @"This page wants to open this application.")
          : [NSString stringWithFormat:@"Your Mac doesn’t have an app for “%@:” links.",
                                       scheme];
  NSString* remember =
      can_remember
          ? [NSString stringWithFormat:@"Always allow %@ to open links of this type in %@",
                                       origin, name]
          : nil;
  NSDictionary* request = @{
        @"id" : base::SysUTF8ToNSString(request_id),
        @"url" : base::SysUTF8ToNSString(url.spec()),
        @"scheme" : scheme,
        @"origin" : origin ?: NSNull.null,
        @"app" : app ? name : NSNull.null,
        @"appPath" : app.path ?: NSNull.null,
        @"icon" : (app ? IconDataURI(app, 64) : nil) ?: NSNull.null,
        @"title" : title,
        @"message" : message ?: NSNull.null,
        @"remember" : remember ?: NSNull.null,
  };
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](const std::string& request_id, NSDictionary* request) {
                       auto it = PendingRequests().find(request_id);
                       if (it == PendingRequests().end()) {
                         return;
                       }
                       if (!it->second.IsCurrent()) {
                         PendingRequests().erase(it);
                         return;
                       }
                       SolaraCoreTab* tab =
                           TabBridge::GetOrCreate(it->second.contents.get())->tab();
                       id<SolaraCoreTabDelegate> delegate = tab.delegate;
                       if ([delegate respondsToSelector:@selector(tab:externalAppRequest:)]) {
                         [delegate tab:tab externalAppRequest:request];
                       }
                     },
                     request_id, request));
  return true;
}

}

namespace {

constexpr char kTestNoLaunchSwitch[] = "solara-test-external-protocol-no-launch";

NSMutableArray<NSDictionary*>* TestLaunches() {
  static NSMutableArray<NSDictionary*>* launches = [NSMutableArray array];
  return launches;
}

}

void InstallExternalAppPrompts() {
  g_solara_external_protocol_dialog = &AskHost;
}

void RetireStaleExternalApps(content::WebContents* superseded) {
  for (auto it = PendingRequests().begin(); it != PendingRequests().end();) {
    if ((!superseded || it->second.contents.get() != superseded) &&
        it->second.IsCurrent()) {
      ++it;
      continue;
    }
    NSString* request_id = base::SysUTF8ToNSString(it->first);
    auto contents = it->second.contents;
    it = PendingRequests().erase(it);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
            [](base::WeakPtr<content::WebContents> contents, NSString* request_id) {
              auto* bridge = contents ? TabBridge::FromWebContents(contents.get()) : nullptr;
              SolaraCoreTab* tab = bridge ? bridge->tab() : nil;
              id<SolaraCoreTabDelegate> delegate = tab.delegate;
              if ([delegate respondsToSelector:@selector(tab:externalAppRequest:)]) {
                [delegate tab:tab externalAppRequest:@{@"id" : request_id, @"closed" : @YES}];
              }
            },
            contents, request_id));
  }
}

void ResolveExternalApp(const std::string& request_id, bool open, bool remember) {
  auto it = PendingRequests().find(request_id);
  if (it == PendingRequests().end()) {
    return;
  }
  Pending pending = std::move(it->second);
  PendingRequests().erase(it);
  content::WebContents* contents = pending.contents.get();
  if (!open || !pending.can_open || !pending.IsCurrent()) {
    return;
  }
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  const std::string scheme(pending.url.scheme());
  if (remember && pending.can_remember && pending.origin) {
    ExternalProtocolHandler::SetBlockState(scheme, *pending.origin,
                                           ExternalProtocolHandler::DONT_BLOCK, profile);
  }
  if (base::CommandLine::ForCurrentProcess()->HasSwitch(kTestNoLaunchSwitch)) {
    const base::DictValue* allowed =
        pending.origin ? profile->GetPrefs()
                             ->GetDict(prefs::kProtocolHandlerPerOriginAllowedProtocols)
                             .FindDict(pending.origin->Serialize())
                       : nullptr;
    const bool remembered = allowed && allowed->FindBool(scheme).value_or(false);
    [TestLaunches() addObject:@{
      @"url" : base::SysUTF8ToNSString(pending.url.spec()),
      @"remembered" : @(remembered),
    }];
    return;
  }
  ExternalProtocolHandler::LaunchUrlWithoutSecurityCheck(pending.url, contents,
                                                         pending.initiator);
}

NSArray<NSDictionary*>* TestExternalLaunches() {
  return [TestLaunches() copy];
}

bool TestNoLaunch() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(kTestNoLaunchSwitch);
}

void RecordTestLaunch(NSDictionary* launch) {
  [TestLaunches() addObject:launch];
}

}
