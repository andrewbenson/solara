import AppKit
import ExpoModulesCore
import React
import WebKit

public class WebKitModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SolaraWebKit")
    Events("onWebKitDownload", "onWebKitPermission", "onWebKitPermissionDismissed")

    OnCreate {
      WebKitHub.shared.events = { [weak self] name, payload in self?.sendEvent(name, payload) }
    }

    Function("prepareTransfer") { (key: String) in WebKitHub.shared.prepareTransfer(key) }
    Function("releaseTransfer") { (key: String) in WebKitHub.shared.releaseTransfer(key) }
    AsyncFunction("resolvePermission") { (id: String, result: String, remember: Bool?) in
      WebKitHub.shared.resolvePermission(id, result: result, remember: remember ?? false)
    }.runOnQueue(.main)
    AsyncFunction("downloadCommand") { (action: String, id: String) in WebKitHub.shared.downloads.command(action, id: id) }.runOnQueue(.main)
    AsyncFunction("externalAppAllowances") { (profile: String) in WebKitHub.shared.externalAppAllowances(profile: profile) }
      .runOnQueue(.main)
    AsyncFunction("removeExternalAppAllowance") { (profile: String, origin: String, scheme: String) in
      WebKitHub.shared.removeExternalAppAllowance(profile: profile, origin: origin, scheme: scheme)
    }.runOnQueue(.main)
    AsyncFunction("removeDownloadStaging") { (path: String, uuid: String, folder: String) in
      WebKitDownloads.removeStaging(path, uuid: uuid, folder: folder)
    }
      .runOnQueue(.main)
    AsyncFunction("endPrivateSession") { (session: String) in WebKitHub.shared.endPrivateSession(session) }.runOnQueue(.main)
    AsyncFunction("sitePermissions") { (profile: String, origin: String) in
      WebKitHub.shared.sitePermissions(profile: profile, origin: origin)
    }.runOnQueue(.main)
    AsyncFunction("setSitePermission") { (profile: String, origin: String, kind: String, value: String) in
      WebKitHub.shared.setSitePermission(profile: profile, origin: origin, kind: kind, value: value)
    }.runOnQueue(.main)
    AsyncFunction("resolveExternalApp") { (id: String, open: Bool, remember: Bool?) in
      WebKitHub.shared.resolveExternalApp(id, open: open, remember: remember ?? false)
    }.runOnQueue(.main)
    AsyncFunction("clearBrowsingData") { (profile: String, types: [String], since: Double?, promise: Promise) in
      WebKitHub.shared.clearBrowsingData(profile: profile, types: types, since: since ?? 0) { promise.resolve(nil) }
    }.runOnQueue(.main)
    AsyncFunction("deleteProfileData") { (profile: String, promise: Promise) in
      WebKitHub.shared.deleteProfileData(profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("cookieStoreKey") { (profile: String) in WebKitHub.shared.storeKey(profile) }.runOnQueue(.main)
    AsyncFunction("importCookies") { (profile: String, storeKey: String, cookies: [[String: Any]], promise: Promise) in
      WebKitHub.shared.importCookies(cookies, profile: profile, storeKey: storeKey) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("info") { () -> [String: Any] in
      [
        "safariVersion": WebKitHub.safariVersion, "userAgentSuffix": "Version/\(WebKitHub.safariVersion) Safari/605.1.15",
        "passkeys": WebKitHub.passkeysEntitled,
      ]
    }.runOnQueue(.main)
    AsyncFunction("passkeyAccess") { () -> [String: Any] in WebKitPasskeys.access() }.runOnQueue(.main)
    AsyncFunction("requestPasskeyAccess") { (promise: Promise) in
      WebKitPasskeys.requestAccess { promise.resolve($0) }
    }.runOnQueue(.main)
    #if DEBUG
    AsyncFunction("devStoreExists") { (profile: String, promise: Promise) in
      WebKitHub.shared.storeExists(profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    AsyncFunction("devHoldStore") { (profile: String) in WebKitHub.shared.holdStoreForTest(profile) }.runOnQueue(.main)
    AsyncFunction("devTouchStore") { (profile: String, promise: Promise) in
      WebKitHub.shared.touchStore(profile) { promise.resolve($0) }
    }.runOnQueue(.main)
    #endif

    View(WebKitTabView.self) {
      Events(CefWebView.events)

      Prop("url") { (view: WebKitTabView, url: String?) in view.tab.initialURL = url }
      Prop("profile") { (view: WebKitTabView, profile: String?) in view.tab.profile = profile ?? "" }
      Prop("adoptId") { (view: WebKitTabView, id: String?) in view.tab.adoptId = id }
      Prop("transferKey") { (view: WebKitTabView, key: String?) in view.tab.transferKey = key }
      Prop("pageContext") { (view: WebKitTabView, context: [String: Any]?) in view.pageContext = context ?? [:] }
      Prop("visible") { (view: WebKitTabView, visible: Bool?) in view.tab.visible = visible ?? true }
      Prop("warm") { (view: WebKitTabView, warm: Bool?) in view.tab.warm = warm ?? false }
      Prop("pageBackgroundColor") { (view: WebKitTabView, color: NSColor?) in view.tab.pageBackgroundColor = color }

      AsyncFunction("loadUrl") { (view: WebKitTabView, url: String, userInitiated: Bool?, promise: Promise) in view.call("loadUrl", [url, userInitiated ?? false], promise) }.runOnQueue(.main)
      AsyncFunction("goBack") { (view: WebKitTabView, promise: Promise) in view.call("goBack", [], promise) }.runOnQueue(.main)
      AsyncFunction("goForward") { (view: WebKitTabView, promise: Promise) in view.call("goForward", [], promise) }.runOnQueue(.main)
      AsyncFunction("goToOffset") { (view: WebKitTabView, offset: Int, promise: Promise) in view.call("goToOffset", [offset], promise) }.runOnQueue(.main)
      AsyncFunction("reload") { (view: WebKitTabView, promise: Promise) in view.call("reload", [], promise) }.runOnQueue(.main)
      AsyncFunction("forceReload") { (view: WebKitTabView, promise: Promise) in view.call("forceReload", [], promise) }.runOnQueue(.main)
      AsyncFunction("stopLoading") { (view: WebKitTabView, promise: Promise) in view.call("stopLoading", [], promise) }.runOnQueue(.main)
      AsyncFunction("focus") { (view: WebKitTabView, promise: Promise) in view.call("focus", [], promise) }.runOnQueue(.main)
      AsyncFunction("setMuted") { (view: WebKitTabView, muted: Bool, promise: Promise) in view.call("setMuted", [muted], promise) }.runOnQueue(.main)
      AsyncFunction("zoomStep") { (view: WebKitTabView, direction: Int, promise: Promise) in view.call("zoomStep", [direction], promise) }.runOnQueue(.main)
      AsyncFunction("find") { (view: WebKitTabView, text: String, forward: Bool, findNext: Bool, promise: Promise) in view.call("find", [text, forward, findNext], promise) }.runOnQueue(.main)
      AsyncFunction("stopFinding") { (view: WebKitTabView, clear: Bool, promise: Promise) in view.call("stopFinding", [clear], promise) }.runOnQueue(.main)
      AsyncFunction("print") { (view: WebKitTabView, promise: Promise) in view.call("print", [], promise) }.runOnQueue(.main)
      AsyncFunction("runPageCommand") { (view: WebKitTabView, name: String, promise: Promise) in view.call("runPageCommand", [name], promise) }.runOnQueue(.main)
      AsyncFunction("showDevTools") { (view: WebKitTabView, panel: String?, promise: Promise) in view.call("showDevTools", [panel as Any? ?? NSNull()], promise) }.runOnQueue(.main)
      AsyncFunction("executeJavaScript") { (view: WebKitTabView, code: String, promise: Promise) in view.call("executeJavaScript", [code], promise) }.runOnQueue(.main)
      AsyncFunction("evaluate") { (view: WebKitTabView, code: String, promise: Promise) in view.call("evaluate", [code], promise) }.runOnQueue(.main)
      AsyncFunction("navigationEntries") { (view: WebKitTabView, promise: Promise) in view.call("navigationEntries", [], promise) }.runOnQueue(.main)
      AsyncFunction("capturePicture") { (view: WebKitTabView, scale: Double, promise: Promise) in view.call("capturePicture", [scale], promise) }.runOnQueue(.main)
      AsyncFunction("downloadFavicon") { (view: WebKitTabView, url: String, promise: Promise) in view.call("downloadFavicon", [url], promise) }.runOnQueue(.main)
      AsyncFunction("downloadImage") { (view: WebKitTabView, url: String, maxPixels: Int, promise: Promise) in view.call("downloadImage", [url, maxPixels], promise) }.runOnQueue(.main)
      AsyncFunction("mediaCommand") { (view: WebKitTabView, action: String, seconds: Double?, promise: Promise) in view.call("mediaCommand", [action, seconds ?? 0], promise) }.runOnQueue(.main)
      AsyncFunction("requestPictureInPicture") { (view: WebKitTabView, clickAt: Double?, control: Int?, promise: Promise) in view.call("requestPictureInPicture", [clickAt ?? 0, control ?? 0], promise) }.runOnQueue(.main)
      AsyncFunction("takeControlPress") { (view: WebKitTabView, clickAt: Double?, control: Int?, promise: Promise) in view.call("takeControlPress", [clickAt ?? 0, control ?? 0], promise) }.runOnQueue(.main)
      AsyncFunction("exitPictureInPicture") { (view: WebKitTabView, promise: Promise) in view.call("exitPictureInPicture", [], promise) }.runOnQueue(.main)
      AsyncFunction("getSecurityInfo") { (view: WebKitTabView, promise: Promise) in view.call("getSecurityInfo", [], promise) }.runOnQueue(.main)
      AsyncFunction("pageCookies") { (view: WebKitTabView, urls: [String], promise: Promise) in view.call("pageCookies", [urls], promise) }.runOnQueue(.main)
      AsyncFunction("openBlockedPopup") { (view: WebKitTabView, id: String, always: Bool?, promise: Promise) in view.call("openBlockedPopup", [id, always ?? false], promise) }.runOnQueue(.main)
      AsyncFunction("clearSiteData") { (view: WebKitTabView, promise: Promise) in view.call("clearSiteData", [], promise) }.runOnQueue(.main)
      AsyncFunction("resolvePasswordPrompt") { (view: WebKitTabView, action: String, username: String?, password: String?, promise: Promise) in view.call("resolvePasswordPrompt", [action, username as Any? ?? NSNull(), password as Any? ?? NSNull()], promise) }.runOnQueue(.main)
      AsyncFunction("resolveAutofillPrompt") { (view: WebKitTabView, promptId: Int, action: String, promise: Promise) in view.call("resolveAutofillPrompt", [promptId, action], promise) }.runOnQueue(.main)
      AsyncFunction("executeExtensionAction") { (view: WebKitTabView, extensionId: String, promise: Promise) in view.call("executeExtensionAction", [extensionId], promise) }.runOnQueue(.main)
      AsyncFunction("resolveDisplayMedia") { (view: WebKitTabView, id: String, sourceId: String?, audio: Bool, promise: Promise) in view.call("resolveDisplayMedia", [id, sourceId as Any? ?? NSNull(), audio], promise) }.runOnQueue(.main)
      AsyncFunction("mediaCaptureSourceId") { (view: WebKitTabView, promise: Promise) in view.call("mediaCaptureSourceId", [], promise) }.runOnQueue(.main)
      AsyncFunction("notificationAction") { (view: WebKitTabView, id: String, action: String, promise: Promise) in view.call("notificationAction", [id, action], promise) }.runOnQueue(.main)
      AsyncFunction("resolveUnresponsive") { (view: WebKitTabView, terminate: Bool, promise: Promise) in view.call("resolveUnresponsive", [terminate], promise) }.runOnQueue(.main)
      AsyncFunction("discard") { (view: WebKitTabView, unload: Bool?, promise: Promise) in view.call("discard", [unload ?? false], promise) }.runOnQueue(.main)
      AsyncFunction("setFrozen") { (view: WebKitTabView, frozen: Bool, promise: Promise) in view.call("setFrozen", [frozen], promise) }.runOnQueue(.main)

      OnViewDidUpdateProps { (view: WebKitTabView) in view.propsDidUpdate() }
    }
  }
}

final class WebKitTabView: ExpoView, WebKitTabDelegate, @preconcurrency RCTInvalidating {
  let tab = WebKitTab(frame: .zero)

  let onPageCreated = EventDispatcher()
  let onPageIssue = EventDispatcher()
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
  let onPageMessage = EventDispatcher()
  let onReady = EventDispatcher()
  let onDiscarded = EventDispatcher()
  let onPasswordPrompt = EventDispatcher()
  let onAutofillPrompt = EventDispatcher()
  let onTabStrip = EventDispatcher()
  let onExternalApp = EventDispatcher()
  let onPreferredSize = EventDispatcher()

  var pageContext: [String: Any] = [:]

  private var propsReady = false
  private var attachment: RNPageAttachment?
  private var invalidated = false
  private var mounted = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    tab.delegate = self
    wantsLayer = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    tab.frame = bounds
  }

  func propsDidUpdate() {
    propsReady = true
    syncAttachment()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard superview != nil else { return }
    if propsReady { syncAttachment() }
  }

  func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    RNPageEventTap.detach(attachment)
  }

  private func syncAttachment() {
    guard !invalidated, superview != nil else { return }
    attachment = RNPageEventTap.attach(owner: self, page: tab, tabId: tab.transferKey,
      engine: "webkit", profile: tab.profile, context: pageContext, previous: attachment) { [weak self] name, payload in
        self?.dispatchers[name]?(payload)
      }
    guard !mounted, attachment?.allowsStart != false else { return }
    RNPageEventTap.start(attachment: attachment) { [self] in
      mounted = true
      tab.frame = bounds
      addSubview(tab)
      tab.start()
    }
  }

  func call(_ method: String, _ args: [Any], _ promise: Promise) {
    RNPageEventTap.call(attachment: attachment, page: tab, transferKey: tab.transferKey, propsReady: propsReady, method: method, args: args,
      resolve: { @MainActor in promise.resolve($0) }, reject: { @MainActor in promise.reject($0, $1) })
  }

  deinit {
    let tab = self.tab
    if Thread.isMainThread { tab.close() } else { DispatchQueue.main.async { tab.close() } }
  }

  private lazy var dispatchers = PageEvents.dispatchers(of: self, as: EventDispatcher.self)

  func webKitTab(_ tab: WebKitTab, event name: String, payload: [String: Any]) {
    guard let prop = PageEvents.props[name] else { return }
    RNPageEventTap.forward(attachment: attachment, name: prop, payload: payload) { [weak self] body in
      self?.dispatchers[prop]?(body)
    }
  }
}
