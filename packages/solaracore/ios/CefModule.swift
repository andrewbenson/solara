import ExpoModulesCore
import AppKit
import IOKit.ps

public enum SolaraCoreEventTaps {
  @MainActor public static var observers: [(String, [String: Any]) -> Void] = []

  static func send(_ name: String, _ payload: [String: Any]) {
    nonisolated(unsafe) let body = payload
    let deliver = { MainActor.assumeIsolated { for observer in observers { observer(name, body) } } }
    if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
  }
}

public class CefModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraCEF")
    Events("onDownload", "onPermission", "onPermissionDismissed", "onContentBlocker", "onSystemState", "onEngineEvent", "onTabStrip")

    OnCreate {
      SolaraCoreEngineBridge.setEventHandler { [weak self] topic, json in self?.sendEvent("onEngineEvent", ["topic": topic, "payload": json]) }
      SolaraCoreTabStrip.setHandler { [weak self] tx in
        self?.sendEvent("onTabStrip", tx)
        SolaraCoreEventTaps.send("tabStrip", tx)
      }
      SolaraCoreServices.downloadsHandler = { [weak self] download in self?.sendEvent("onDownload", download) }
      SolaraCoreHost.eventHandler = { [weak self] name, payload in
        SolaraCoreEventTaps.send(name, payload)
        switch name {
        case "permission": self?.sendEvent("onPermission", payload)
        case "permissionDismissed": self?.sendEvent("onPermissionDismissed", payload)
        case "download": self?.sendEvent("onDownload", payload)
        case "contentBlocker": self?.sendEvent("onContentBlocker", payload)
        default: break
        }
      }
      SystemState.shared.onChange = { [weak self] state in self?.sendEvent("onSystemState", state) }
      SystemState.shared.start()
    }

    AsyncFunction("engineInfo") { SolaraCoreHost.engineInfo }.runOnQueue(.main)
    AsyncFunction("forwardEngineTopics") { (topics: [String]) in SolaraCoreEngineBridge.forwardTopics(topics) }.runOnQueue(.main)
    AsyncFunction("chromeWindows") { SolaraCoreHost.chromeWindows }.runOnQueue(.main)
    AsyncFunction("devExternalLaunches") { SolaraCoreHost.testExternalLaunches() }.runOnQueue(.main)
    AsyncFunction("devEvents") { (browserId: Int) in SolaraCoreWebView.devEvents(browserId: Int32(browserId)) }.runOnQueue(.main)
    AsyncFunction("devWindowNumber") { (browserId: Int) in SolaraCoreWebView.devWindowNumber(browserId: Int32(browserId)) }.runOnQueue(.main)
    AsyncFunction("devLiveExtensionViews") { (host: String) in SolaraCoreWebView.devLiveExtensionViews(host) }.runOnQueue(.main)
    AsyncFunction("devPictureInPicture") { SolaraCoreWebView.devPictureInPicture() }.runOnQueue(.main)
    AsyncFunction("devPictureInPictureAction") { (action: String) in SolaraCoreWebView.devPictureInPictureAction(action) }.runOnQueue(.main)
    AsyncFunction("devKeepBrowsersOnClose") { (keep: [Int], failing: [Int]) in
      SolaraCoreWebView.devKeepBrowsersOnClose(keep.map { NSNumber(value: $0) }, failing: failing.map { NSNumber(value: $0) })
    }.runOnQueue(.main)
    AsyncFunction("devKeptOnClose") { (browserId: Int) in SolaraCoreWebView.devKeptOnClose(browserId: Int32(browserId)) }.runOnQueue(.main)
    AsyncFunction("devFailKeptMoves") { (count: Int) in SolaraCoreWebView.devFailKeptMoves(count) }.runOnQueue(.main)
    AsyncFunction("devKeepTabsOnClose") { (count: Int) in SolaraCoreWebView.devKeepTabsOnClose(count) }.runOnQueue(.main)
    AsyncFunction("devFocusPage") { (browserId: Int) in SolaraCoreWebView.devFocusPage(browserId: Int32(browserId)) }.runOnQueue(.main)
    AsyncFunction("devWindow") { (windowNumber: Int, action: String) -> String in
      guard let window = NSApp.window(withWindowNumber: windowNumber) else { return "" }
      return ACChromeWindowHost.devAction(action, window: window) ?? ""
    }.runOnQueue(.main)
    Function("prepareTransfer") { (key: String) in SolaraCoreWebView.prepareTransfer(key) }
    Function("releaseTransfer") { (key: String) in SolaraCoreWebView.releaseTransfer(key) }
    Function("claimLaunchTab") { (key: String, url: String, profile: String) in
      SolaraCoreWebView.claimLaunchTab(key, url: url, profile: profile)
    }
    Function("revealTab") { (key: String) in SolaraCoreWebView.revealTab(key) }
    Function("dropTabReveals") { (key: String) in SolaraCoreWebView.dropTabReveals(key) }
    Function("revealOffered") { (adoptId: String, key: String) in SolaraCoreWebView.revealOffered(adoptId, over: key) }
    AsyncFunction("routeLinkTabs") { (urls: [String]) -> [String: Any] in SolaraCoreWebView.routeLinkTabs(urls) }.runOnQueue(.main)
    AsyncFunction("tabStripCommand") { (id: Int, command: [String: Any]) in
      if SolaraCoreTabStrip.commandsClaimed { return NSLog("[tabs] a script sent a strip command after Swift took over the strip; dropped") }
      SolaraCoreTabStrip.command(id, command: command)
    }
      .runOnQueue(.main)
    AsyncFunction("tabStrips") { SolaraCoreTabStrip.allStrips }.runOnQueue(.main)
    AsyncFunction("components") { (promise: Promise) in SolaraCoreServices.components { promise.resolve($0) } }.runOnQueue(.main)

    AsyncFunction("beginTracing") { (promise: Promise) in SolaraCoreHost.beginTracing { promise.resolve($0) } }.runOnQueue(.main)
    AsyncFunction("endTracing") { (keep: Bool, promise: Promise) in SolaraCoreHost.endTracing(keep: keep) { promise.resolve($0) } }
      .runOnQueue(.main)
    AsyncFunction("isTracing") { SolaraCoreHost.isTracing }.runOnQueue(.main)
    AsyncFunction("setSearchEngineName") { (name: String) in SolaraCoreWebView.setSearchEngineName(name) }.runOnQueue(.main)
    AsyncFunction("setDisplayMediaPicker") { (enabled: Bool) in SolaraCoreWebView.setDisplayMediaPicker(enabled) }.runOnQueue(.main)
    AsyncFunction("setPeekModifier") { (modifier: String) in SolaraCoreWebView.setPeekModifier(modifier) }.runOnQueue(.main)
    AsyncFunction("setSplitLinkModifier") { (modifier: String) in SolaraCoreWebView.setSplitLinkModifier(modifier) }.runOnQueue(.main)
    AsyncFunction("setSelectionPopover") { (enabled: Bool) in SolaraCoreWebView.setSelectionPopoverEnabled(enabled) }.runOnQueue(.main)
    AsyncFunction("devPostPeekMouseUp") { (keys: String, tabId: String) in SolaraCoreWebView.devPostPeekMouseUp(keys, over: tabId) }.runOnQueue(.main)
    AsyncFunction("setAutoPictureInPicture") { (enabled: Bool) in SolaraCoreWebView.setAutoPictureInPictureEnabled(enabled) }.runOnQueue(.main)
    AsyncFunction("setVideoUpscaling") { (enabled: Bool) in SolaraCoreWebView.setVideoUpscalingEnabled(enabled) }.runOnQueue(.main)
    AsyncFunction("setVideoUpscalingTestConditions") { (conditions: [String: Bool]) in
      SolaraCoreWebView.setVideoUpscalingTestConditions(conditions.mapValues { NSNumber(value: $0) })
    }.runOnQueue(.main)
    AsyncFunction("videoUpscalingState") { SolaraCoreWebView.videoUpscalingState() }.runOnQueue(.main)
    AsyncFunction("displayMediaSources") { SolaraCoreHost.displayMediaSources }.runOnQueue(.main)
    AsyncFunction("listTasks") { (promise: Promise) in SolaraCoreServices.tasks { promise.resolve($0) } }.runOnQueue(.main)
    AsyncFunction("systemState") { SystemState.shared.snapshot }.runOnQueue(.main)
    Function("inputIdleSeconds") { () -> Double in
      guard NSRunningApplication.current.isActive else { return 3600 }
      return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }

    AsyncFunction("cancelDownload") { (id: String) in SolaraCoreServices.downloadCommand("cancel", id: id) }.runOnQueue(.main)
    AsyncFunction("pauseDownload") { (id: String) in SolaraCoreServices.downloadCommand("pause", id: id) }.runOnQueue(.main)
    AsyncFunction("resumeDownload") { (id: String) in SolaraCoreServices.downloadCommand("resume", id: id) }.runOnQueue(.main)
    AsyncFunction("keepDownload") { (id: String) in SolaraCoreServices.downloadCommand("keep", id: id) }.runOnQueue(.main)

    AsyncFunction("resolvePermission") { (id: String, result: String, remember: Bool?) in
      SolaraCoreHost.resolvePermission(id, result: result, remember: remember ?? false)
    }.runOnQueue(.main)
    AsyncFunction("resolveExternalApp") { (id: String, open: Bool, remember: Bool?) in
      SolaraCoreHost.resolveExternalApp(id, open: open, remember: remember ?? false)
    }.runOnQueue(.main)
    AsyncFunction("getExternalAppAllowances") { (profile: String, promise: Promise) in
      SolaraCoreServices.externalAppAllowances(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("removeExternalAppAllowance") { (profile: String, origin: String, scheme: String) in
      SolaraCoreServices.removeExternalAppAllowance(profile: profile, origin: origin, scheme: scheme)
    }.runOnQueue(.main)

    AsyncFunction("clearBrowsingData") { (profile: String, types: [String], since: Double?, promise: Promise) in
      SolaraCoreServices.clearBrowsingData(profile: profile, types: types, since: since ?? 0) { promise.resolve(nil) }
    }.runOnQueue(.main)
    AsyncFunction("releaseProfile") { (profile: String) in SolaraCoreHost.releaseProfile(profile) }.runOnQueue(.main)
    AsyncFunction("deleteProfileData") { (profile: String, promise: Promise) in
      if profile.isEmpty { return SolaraCoreProfileData.deleteDefault { promise.resolve(["remaining": $0]) } }
      SolaraCoreHost.deleteProfileData(profile) { promise.resolve(["remaining": $0]) }
    }.runOnQueue(.main)

    AsyncFunction("fetchFavicon") { (url: String, profile: String, promise: Promise) in
      SolaraCoreFavicons.fetch(url, profile: profile, name: nil) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("engineCall") { (name: String, profile: String, args: String?, promise: Promise) in
      if !CefModule.engineCalls.contains(name) { return promise.resolve(#"{"error":"not an engine call: \#(name)"}"#) }
      if profile.hasPrefix("incognito") { return promise.resolve(#"{"error":"no engine data for a private profile"}"#) }
      SolaraCoreEngineBridge.call(name, profile: profile, args: args) { promise.resolve($0) }
    }.runOnQueue(.main)

    AsyncFunction("getContentBlocker") { (promise: Promise) in
      SolaraCoreContentBlocker.state { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("setContentBlockerEnabled") { (enabled: Bool, promise: Promise) in
      SolaraCoreContentBlocker.setEnabled(enabled) { CefModule.settle(promise, $0) }
    }.runOnQueue(.main)
    AsyncFunction("setFilterListEnabled") { (id: String, enabled: Bool, promise: Promise) in
      SolaraCoreContentBlocker.setList(id, enabled: enabled) { CefModule.settle(promise, $0) }
    }.runOnQueue(.main)
    AsyncFunction("isContentBlockerAllowed") { (host: String, promise: Promise) in
      SolaraCoreContentBlocker.isAllowed(host: host) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("setContentBlockerAllowed") { (host: String, allowed: Bool, promise: Promise) in
      SolaraCoreContentBlocker.setAllowed(allowed, host: host) { CefModule.settle(promise, $0) }
    }.runOnQueue(.main)
    AsyncFunction("devContentBlockerFailNextMessage") { SolaraCoreContentBlocker.devFailNextMessage() }.runOnQueue(.main)
    AsyncFunction("devContentBlockerDelayNextLoad") { (ms: Double) in SolaraCoreContentBlocker.devDelayNextLoad(ms) }.runOnQueue(.main)

    AsyncFunction("setSiteSetting") { (profile: String, origin: String, type: String, value: String) in
      SolaraCoreServices.setSiteSetting(value, profile: profile, origin: origin, type: type)
    }.runOnQueue(.main)
    AsyncFunction("getSiteSettings") { (profile: String, origin: String, promise: Promise) in
      SolaraCoreServices.siteSettings(profile: profile, origin: origin) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("getSiteSettingsOrigins") { (profile: String, promise: Promise) in
      SolaraCoreServices.siteSettingsOrigins(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("resetSiteSettings") { (profile: String, origin: String) in
      SolaraCoreServices.resetSiteSettings(profile: profile, origin: origin)
    }.runOnQueue(.main)
    AsyncFunction("clearSiteData") { (profile: String, origin: String, promise: Promise) in
      SolaraCoreServices.clearSiteData(profile: profile, origin: origin) { promise.resolve($0) }
    }.runOnQueue(.main)

    AsyncFunction("setZoom") { (profile: String, host: String, zoom: Double) in
      SolaraCoreServices.setZoom(zoom, profile: profile, host: host)
    }.runOnQueue(.main)
    AsyncFunction("getZoomLevels") { (profile: String, promise: Promise) in
      SolaraCoreServices.zoomLevels(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)

    AsyncFunction("listPasswords") { (profile: String, promise: Promise) in
      SolaraCoreServices.listPasswords(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("unlockPasswords") { (profile: String, promise: Promise) in
      SolaraCoreServices.unlockPasswords(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("getPassword") { (profile: String, origin: String, username: String, promise: Promise) in
      SolaraCoreServices.password(profile: profile, origin: origin, username: username) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("savePassword") { (profile: String, origin: String, username: String, password: String, promise: Promise) in
      SolaraCoreServices.savePassword(profile: profile, origin: origin, username: username, password: password) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("updatePassword") {
      (profile: String, origin: String, username: String, newUsername: String?, newPassword: String?, promise: Promise) in
      SolaraCoreServices.updatePassword(profile: profile, origin: origin, username: username, newUsername: newUsername,
                                    newPassword: newPassword) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("deletePassword") { (profile: String, origin: String, username: String, promise: Promise) in
      SolaraCoreServices.deletePassword(profile: profile, origin: origin, username: username) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("getNeverSavePasswordOrigins") { (profile: String, promise: Promise) in
      SolaraCoreServices.neverSaveOrigins(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("allowSavingPasswords") { (profile: String, origin: String, promise: Promise) in
      SolaraCoreServices.allowSaving(profile: profile, origin: origin) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("exportPasswords") { (profile: String, promise: Promise) in
      SolaraCoreServices.exportPasswords(profile: profile, path: nil) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("getPasswordAutofill") { (profile: String) in
      SolaraCoreServices.boolPreference("credentials_enable_service", profile: profile)
    }.runOnQueue(.main)
    AsyncFunction("setPasswordAutofill") { (profile: String, enabled: Bool) in
      SolaraCoreServices.setBoolPreference("credentials_enable_service", value: enabled, profile: profile)
    }.runOnQueue(.main)

    AsyncFunction("getAutofillSettings") { (profile: String) in
      [
        "addresses": SolaraCoreServices.boolPreference("autofill.profile_enabled", profile: profile),
        "cards": SolaraCoreServices.boolPreference("autofill.credit_card_enabled", profile: profile),
      ]
    }.runOnQueue(.main)
    AsyncFunction("setAutofillSettings") { (profile: String, addresses: Bool?, cards: Bool?) in
      if let addresses { SolaraCoreServices.setBoolPreference("autofill.profile_enabled", value: addresses, profile: profile) }
      if let cards { SolaraCoreServices.setBoolPreference("autofill.credit_card_enabled", value: cards, profile: profile) }
    }.runOnQueue(.main)
    AsyncFunction("listAddresses") { (profile: String, promise: Promise) in
      SolaraCoreServices.addresses(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("saveAddress") { (profile: String, address: [String: Any], promise: Promise) in
      SolaraCoreServices.saveAddress(address, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("listCards") { (profile: String, promise: Promise) in
      SolaraCoreServices.cards(profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("saveCard") { (profile: String, card: [String: Any], number: String?, promise: Promise) in
      SolaraCoreServices.saveCard(card, number: number, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("deleteAutofillEntry") { (profile: String, id: String, promise: Promise) in
      SolaraCoreServices.deleteAutofillEntry(id, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("revealCardNumber") { (profile: String, id: String, promise: Promise) in
      SolaraCoreServices.revealCardNumber(id, profile: profile) { promise.resolve($0) }
    }.runOnQueue(.main)

    View(CefWebView.self) {
      Events(CefWebView.events)

      Prop("url") { (view: CefWebView, url: String?) in view.browser.initialURL = url }
      Prop("profile") { (view: CefWebView, profile: String?) in view.browser.profile = profile ?? "" }
      Prop("adoptId") { (view: CefWebView, id: String?) in view.browser.adoptId = id }
      Prop("transferKey") { (view: CefWebView, key: String?) in view.browser.transferKey = key }
      Prop("standalone") { (view: CefWebView, standalone: Bool?) in view.browser.standalone = standalone ?? false }
      Prop("temporary") { (view: CefWebView, temporary: Bool?) in view.browser.temporary = temporary ?? false }
      Prop("temporarySource") { (view: CefWebView, source: String?) in view.browser.temporarySource = source }
      Prop("extensionHost") { (view: CefWebView, kind: String?) in view.browser.extensionHost = kind }
      Prop("visible") { (view: CefWebView, visible: Bool?) in view.browser.visible = visible ?? true }
      Prop("warm") { (view: CefWebView, warm: Bool?) in view.browser.warm = warm ?? false }
      Prop("neighbour") { (view: CefWebView, neighbour: Bool?) in view.browser.neighbour = neighbour ?? false }
      Prop("pageBackgroundColor") { (view: CefWebView, color: NSColor?) in view.browser.pageBackgroundColor = color }
      Prop("pageColor") { (view: CefWebView, color: String?) in view.browser.pageColor = color }
      Prop("contentsBackgroundColor") { (view: CefWebView, color: NSColor?) in view.browser.contentsBackgroundColor = color }
      Prop("shownUrl") { (view: CefWebView, url: String?) in view.browser.shownURL = url }
      Prop("autoPictureInPicture") { (view: CefWebView, enabled: Bool?) in
        view.browser.autoPictureInPicture = enabled ?? false
      }

      AsyncFunction("loadUrl") { (view: CefWebView, url: String, userInitiated: Bool?) in
        view.browser.loadURL(url, userInitiated: userInitiated ?? false)
      }.runOnQueue(.main)
      AsyncFunction("goBack") { (view: CefWebView) in view.browser.goBack() }.runOnQueue(.main)
      AsyncFunction("goForward") { (view: CefWebView) in view.browser.goForward() }.runOnQueue(.main)
      AsyncFunction("goToOffset") { (view: CefWebView, offset: Int) in view.browser.go(toHistoryOffset: offset) }.runOnQueue(.main)
      AsyncFunction("reload") { (view: CefWebView) in view.browser.reload() }.runOnQueue(.main)
      AsyncFunction("forceReload") { (view: CefWebView) in view.browser.reloadIgnoringCache() }.runOnQueue(.main)
      AsyncFunction("stopLoading") { (view: CefWebView) in view.browser.stopLoading() }.runOnQueue(.main)
      AsyncFunction("focus") { (view: CefWebView) in view.browser.focusPage() }.runOnQueue(.main)
      AsyncFunction("setMuted") { (view: CefWebView, muted: Bool) in view.browser.setMuted(muted) }.runOnQueue(.main)
      AsyncFunction("zoomStep") { (view: CefWebView, direction: Int) in view.browser.zoomStep(direction) }.runOnQueue(.main)
      AsyncFunction("find") { (view: CefWebView, text: String, forward: Bool, findNext: Bool) in
        view.browser.find(text, forward: forward, findNext: findNext)
      }.runOnQueue(.main)
      AsyncFunction("stopFinding") { (view: CefWebView, clear: Bool) in view.browser.stopFinding(clear) }.runOnQueue(.main)
      AsyncFunction("print") { (view: CefWebView) in view.browser.print() }.runOnQueue(.main)
      AsyncFunction("runPageCommand") { (view: CefWebView, name: String) in view.browser.runPageCommand(name) }.runOnQueue(.main)
      AsyncFunction("showDevTools") { (view: CefWebView, panel: String?) in view.browser.showDevTools(panel: panel) }
        .runOnQueue(.main)
      AsyncFunction("executeJavaScript") { (view: CefWebView, code: String) in
        view.browser.executeJavaScript(code)
      }.runOnQueue(.main)
      AsyncFunction("evaluate") { (view: CefWebView, code: String, promise: Promise) in
        view.browser.evaluate(code) { json in promise.resolve(json) }
      }.runOnQueue(.main)
      AsyncFunction("navigationEntries") { (view: CefWebView, promise: Promise) in
        view.browser.navigationEntries { promise.resolve($0) }
      }.runOnQueue(.main)
      AsyncFunction("capturePicture") { (view: CefWebView, scale: Double, promise: Promise) in
        view.browser.capturePicture(scale) { promise.resolve($0) }
      }.runOnQueue(.main)
      AsyncFunction("downloadFavicon") { (view: CefWebView, url: String, promise: Promise) in
        view.browser.downloadFavicon(url, name: nil) { promise.resolve($0) }
      }.runOnQueue(.main)
      AsyncFunction("downloadImage") { (view: CefWebView, url: String, maxPixels: Int, promise: Promise) in
        view.browser.downloadImage(url, maxPixels: maxPixels) { promise.resolve($0) }
      }.runOnQueue(.main)

      AsyncFunction("mediaCommand") { (view: CefWebView, action: String, seconds: Double?) in
        view.browser.mediaCommand(action, seconds: seconds ?? 0)
      }.runOnQueue(.main)
      AsyncFunction("requestPictureInPicture") { (view: CefWebView, clickAt: Double?, control: Int?, promise: Promise) in
        view.browser.requestPictureInPicture(clickAt: clickAt ?? 0, control: control ?? 0) { promise.resolve($0) }
      }.runOnQueue(.main)
      AsyncFunction("takeControlPress") { (view: CefWebView, clickAt: Double?, control: Int?) -> Bool in
        view.browser.takeControlPress(clickAt: clickAt ?? 0, control: control ?? 0)
      }.runOnQueue(.main)
      AsyncFunction("exitPictureInPicture") { (view: CefWebView) in view.browser.exitPictureInPicture() }.runOnQueue(.main)

      AsyncFunction("getSecurityInfo") { (view: CefWebView, promise: Promise) in
        view.browser.securityInfo { promise.resolve($0) }
      }.runOnQueue(.main)
      AsyncFunction("pageCookies") { (view: CefWebView, urls: [String], promise: Promise) in
        view.browser.pageCookies(urls) { promise.resolve($0 ?? []) }
      }.runOnQueue(.main)
      AsyncFunction("openBlockedPopup") { (view: CefWebView, id: String, always: Bool?) in
        view.browser.openBlockedPopup(id, always: always ?? false)
      }.runOnQueue(.main)
      AsyncFunction("clearSiteData") { (view: CefWebView, promise: Promise) in
        view.browser.clearSiteData { promise.resolve($0) }
      }.runOnQueue(.main)

      AsyncFunction("resolvePasswordPrompt") { (view: CefWebView, action: String, username: String?, password: String?) in
        view.browser.resolvePasswordPrompt(action, username: username, password: password)
      }.runOnQueue(.main)
      AsyncFunction("resolveAutofillPrompt") { (view: CefWebView, promptId: Int, action: String) in
        view.browser.resolveAutofillPrompt(promptId, action: action)
      }.runOnQueue(.main)
      AsyncFunction("executeExtensionAction") { (view: CefWebView, extensionId: String) in
        view.browser.executeExtensionAction(extensionId)
      }.runOnQueue(.main)

      AsyncFunction("resolveDisplayMedia") { (view: CefWebView, id: String, sourceId: String?, audio: Bool) in
        view.browser.resolveDisplayMedia(id, sourceId: sourceId, audio: audio)
      }.runOnQueue(.main)
      AsyncFunction("mediaCaptureSourceId") { (view: CefWebView) in view.browser.mediaCaptureSourceId }.runOnQueue(.main)
      AsyncFunction("notificationAction") { (view: CefWebView, id: String, action: String) in
        view.browser.notificationAction(id, action: action)
      }.runOnQueue(.main)

      AsyncFunction("resolveUnresponsive") { (view: CefWebView, terminate: Bool) in
        view.browser.resolveUnresponsive(terminate: terminate)
      }.runOnQueue(.main)
      AsyncFunction("discard") { (view: CefWebView, unload: Bool?) in view.browser.discard(unload: unload ?? false) }
        .runOnQueue(.main)
      AsyncFunction("setFrozen") { (view: CefWebView, frozen: Bool) in view.browser.frozen = frozen }.runOnQueue(.main)

      OnViewDidUpdateProps { (view: CefWebView) in view.propsDidUpdate() }
    }
  }

  static func settle(_ promise: Promise, _ error: String?) {
    if let error { promise.reject("ERR_CONTENT_BLOCKER", error) } else { promise.resolve(nil) }
  }
}

final class CefWebView: ExpoView, SolaraCoreWebViewDelegate {
  static let events = PageEvents.names

  let browser = SolaraCoreWebView(frame: .zero)

  let onNavigationChange = EventDispatcher()
  let onProgress = EventDispatcher()
  let onFavicon = EventDispatcher()
  let onMedia = EventDispatcher()
  let onNowPlaying = EventDispatcher()
  let onMediaAccess = EventDispatcher()
  let onOpenWindow = EventDispatcher()
  let onPopupBlocked = EventDispatcher()
  let onFindResult = EventDispatcher()
  let onFullscreen = EventDispatcher()
  let onStatus = EventDispatcher()
  let onCrashed = EventDispatcher()
  let onUnresponsive = EventDispatcher()
  let onResponsive = EventDispatcher()
  let onLoadError = EventDispatcher()
  let onSecurity = EventDispatcher()
  let onZoom = EventDispatcher()
  let onContentBlocked = EventDispatcher()
  let onDownloadNavigation = EventDispatcher()
  let onNotification = EventDispatcher()
  let onNotificationClose = EventDispatcher()
  let onPictureInPicture = EventDispatcher()
  let onActivateRequest = EventDispatcher()
  let onDisplayMediaRequest = EventDispatcher()
  let onWindowClose = EventDispatcher()
  let onCommand = EventDispatcher()
  let onPageFocus = EventDispatcher()
  let onPagePress = EventDispatcher()
  let onPageMessage = EventDispatcher()
  let onReady = EventDispatcher()
  let onDiscarded = EventDispatcher()
  let onPasswordPrompt = EventDispatcher()
  let onAutofillPrompt = EventDispatcher()
  let onTabStrip = EventDispatcher()
  let onExternalApp = EventDispatcher()
  let onPreferredSize = EventDispatcher()

  private var propsReady = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    browser.delegate = self
    wantsLayer = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    browser.frame = bounds
  }

  func propsDidUpdate() {
    guard !propsReady else { return }
    propsReady = true
    browser.frame = bounds
    addSubview(browser)
  }

  deinit {
    browser.closeBrowser()
  }

  private lazy var dispatchers = PageEvents.dispatchers(of: self, as: EventDispatcher.self)

  func webView(_ view: SolaraCoreWebView, event name: String, payload: [String: Any]) {
    if let prop = PageEvents.props[name] { dispatchers[prop]?(payload) }
  }
}

final class SystemState {
  static let shared = SystemState()
  var onChange: (([String: Any]) -> Void)?
  private var memoryPressure = "normal"
  private var memorySource: DispatchSourceMemoryPressure?
  private var powerSource: CFRunLoopSource?
  private var lowPowerObserver: NSObjectProtocol?

  var snapshot: [String: Any] {
    let battery = SystemState.battery()
    return [
      "onBattery": battery.onBattery,
      "batteryLevel": battery.level as Any,
      "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "memoryPressure": memoryPressure,
      "physicalMemory": Double(ProcessInfo.processInfo.physicalMemory),
    ]
  }

  func start() {
    guard memorySource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self, weak source] in
      guard let self, let event = source?.data else { return }
      self.memoryPressure = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
      self.changed()
    }
    source.resume()
    memorySource = source

    let context = Unmanaged.passUnretained(self).toOpaque()
    if let loop = IOPSNotificationCreateRunLoopSource({ context in
      guard let context else { return }
      Unmanaged<SystemState>.fromOpaque(context).takeUnretainedValue().changed()
    }, context)?.takeRetainedValue() {
      CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
      powerSource = loop
    }
    lowPowerObserver = NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in self?.changed() }
  }

  private func changed() {
    let state = snapshot
    if Thread.isMainThread { onChange?(state) } else { DispatchQueue.main.async { self.onChange?(state) } }
  }

  private static func battery() -> (onBattery: Bool, level: Double?) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
    let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    var level: Double?
    let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = description[kIOPSCurrentCapacityKey] as? Double,
        let max = description[kIOPSMaxCapacityKey] as? Double, max > 0
      else { continue }
      level = current / max
    }
    return (providing == kIOPMBatteryPowerKey, level)
  }
}

#if SOLARA_PROBES
@MainActor
public enum SavedLoginRead {
  public static func exists(origin: String, username: String) async -> Bool {
    await withCheckedContinuation { continuation in
      SolaraCoreServices.listPasswords(profile: "") { result in
        let rows = result["passwords"] as? [[String: Any]] ?? []
        let exists = rows.contains { row in
          let savedOrigin = (row["origin"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          return savedOrigin == origin && row["username"] as? String == username
        }
        continuation.resume(returning: exists)
      }
    }
  }
}
#endif

#if SOLARA_PROBES
@MainActor
public enum WindowAccessibilityRead {
  public static func shortcutFields(windowNumber: Int) -> [[String: Any]] {
    guard let window = NSApp.window(withWindowNumber: windowNumber), let root = window.contentView else { return [] }
    var result: [[String: Any]] = []
    var visited = 0
    func walk(_ view: NSView, depth: Int) {
      guard depth <= 40, visited < 2048, result.count < 64 else { return }
      visited += 1
      guard !view.isHiddenOrHasHiddenAncestor, !NSStringFromClass(type(of: view)).contains("RenderWidgetHostView"), !(view is NSSecureTextField), !NSStringFromClass(type(of: view)).contains("Secure") else { return }
      if let role = view.accessibilityRole(), [NSAccessibility.Role.textField, .textArea].contains(role) {
        let label = String((view.accessibilityLabel() ?? "").prefix(512))
        let value = (view as? NSTextField)?.stringValue ?? view.accessibilityValue() as? String ?? ""
        result.append(["role": role.rawValue, "label": label, "value": String(value.prefix(512))])
      }
      for child in view.subviews { walk(child, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return result
  }

  public static func textFieldCount(windowNumber: Int) -> Int? {
    guard let window = NSApp.window(withWindowNumber: windowNumber),
      let listing = ACChromeWindowHost.devAction("ax", window: window) else { return nil }
    return listing.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("AXTextField") }.count
  }
}
#endif

#if SOLARA_PROBES
public enum VideoUpscalingRead {
  public static func snapshot() -> [String: Any] { SolaraCoreWebView.videoUpscalingState() as? [String: Any] ?? [:] }
}
#endif

#if SOLARA_PROBES
import ObjectiveC

@MainActor
private enum WindowDragCounter {
  static var installed = false
  static var count = 0

  static func snapshot() -> Int {
    if !installed {
      installed = true
      for name in ["performWindowDragWithEvent:", "performWindowDragWithEvent:completionHandler:"] {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { continue }
        let original = method_getImplementation(method)
        if name.hasSuffix("Handler:") {
          let block: @convention(block) (NSWindow, NSEvent, AnyObject?) -> Void = { window, event, completion in
            MainActor.assumeIsolated { count += 1 }
            typealias Call = @convention(c) (AnyObject, Selector, NSEvent, AnyObject?) -> Void
            unsafeBitCast(original, to: Call.self)(window, selector, event, completion)
          }
          method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
          let block: @convention(block) (NSWindow, NSEvent) -> Void = { window, event in
            MainActor.assumeIsolated { count += 1 }
            typealias Call = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            unsafeBitCast(original, to: Call.self)(window, selector, event)
          }
          method_setImplementation(method, imp_implementationWithBlock(block))
        }
      }
    }
    return count
  }
}

@MainActor
public enum WindowDragRead {
  public static var count: Int { WindowDragCounter.snapshot() }
}
#endif
