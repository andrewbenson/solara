import AppKit
import AuthenticationServices
import CryptoKit
import WebKit

final class WebKitHub: NSObject, WKScriptMessageHandler {
  static let shared = WebKitHub()
  static let world = WKContentWorld.world(name: "solara")
  static let background = ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] == "1"
  static let silenced = background && ProcessInfo.processInfo.environment["SOLARA_ALLOW_AUDIO"] != "1"

  var events: ((String, [String: Any]) -> Void)?
  lazy var downloads = WebKitDownloads(hub: self)
  let contentBlocker = WebKitContentBlocker()
  private let externalApplication: (URL) -> URL?
  private let openExternal: ((URL) -> Void)?

  init(externalApplication: @escaping (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
       openExternal: ((URL) -> Void)? = nil) {
    self.externalApplication = externalApplication
    self.openExternal = openExternal
    super.init()
  }

  private final class WeakTab {
    weak var tab: WebKitTab?
    init(_ tab: WebKitTab) { self.tab = tab }
  }

  private struct PrivateSession {
    let store: WKWebsiteDataStore
    let token: String
  }

  private struct PendingPermission {
    let browserId: Int32
    let keys: [String]
    let store: WKWebsiteDataStore
    let decide: (Bool) -> Void
  }

  private struct PendingExternal {
    let url: URL
    let allowance: String?
    let grant: ExternalGrant?
  }

  private struct ExternalGrant {
    let origin: String
    let scheme: String
    let app: String
    let appPath: String
  }

  private var lastBrowserId: Int32 = -1000
  private var persistentStores: [Data: WKWebsiteDataStore] = [:]
  private var privateSessions: [Data: PrivateSession] = [:]
  private var owners: [ObjectIdentifier: WeakTab] = [:]
  private var liveByKey: [String: WeakTab] = [:]
  private let transferLock = NSLock()
  private var prepared = Set<String>()
  private var parked: [String: WKWebView] = [:]
  private var offered: [String: WKWebView] = [:]
  private var lastOffer = 0
  private var pendingPermissions: [String: PendingPermission] = [:]
  private var rememberedPermissions: [String: Bool] = [:]
  private var lastPermission = 0
  private var zoomByHost: [String: Double] = [:]
  private var pendingExternal = WebKitSessionResources<PendingExternal>()
  private var externalAllowances: [String: ExternalGrant] = [:]
  private var lastExternal = 0
  private var resumeHosts: [Data: WKWebView] = [:]
  private var deletedProfileStores: [Data: WKWebsiteDataStore] = [:]
  #if DEBUG
  private var storesHeldForTest: [Data: WKWebsiteDataStore] = [:]
  #endif

  func nextBrowserId() -> Int32 {
    lastBrowserId -= 1
    return lastBrowserId
  }

  static func isPrivate(_ profile: String) -> Bool { profile.hasPrefix("incognito:") }

  static func privateSession(_ profile: String) -> String {
    guard let at = profile.range(of: "@", options: .backwards) else { return "" }
    return String(profile[at.upperBound...])
  }

  static func regularProfile(_ profile: String) -> String { isPrivate(profile) ? privateSession(profile) : profile }

  private func session(_ name: String) -> PrivateSession {
    if let live = privateSessions[Data(name.utf8)] { return live }
    let made = PrivateSession(store: .nonPersistent(), token: UUID().uuidString)
    privateSessions[Data(name.utf8)] = made
    return made
  }

  func storeKey(_ profile: String) -> String {
    guard Self.isPrivate(profile) else { return profile }
    let name = Self.privateSession(profile)
    return "private@\(name)#\(session(name).token)"
  }

  static func storeIdentifier(_ profile: String) -> UUID {
    let scope = ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? ""
    var bytes = Array(SHA256.hash(data: Data("solara.webkit|\(scope)|\(profile)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
  }

  static func profileDirectories(_ profile: String) -> [URL] {
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    let webkit = library.appendingPathComponent("WebKit", isDirectory: true)
    let application = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    return [webkit, webkit.appendingPathComponent(application, isDirectory: true)].map {
      $0.appendingPathComponent("WebsiteDataStore", isDirectory: true).appendingPathComponent(storeIdentifier(profile).uuidString.lowercased(), isDirectory: true)
    }
  }

  static func establishedProfileDirectory(_ profile: String) -> Bool {
    do {
      guard try profileDirectories(profile).contains(where: { try ChromiumProfileData.directoryIdentity($0) != nil }) else {
        NSLog("[webkit] REFUSING profile data deletion: existing store has no established directory: %@", storeIdentifier(profile).uuidString)
        return false
      }
      return true
    } catch {
      NSLog("[webkit] REFUSING profile data deletion: directory resolution failed: %@", String(describing: error))
      return false
    }
  }

  static let profileDataRemovalDeadline: TimeInterval = 10

  func dataStore(for profile: String) -> WKWebsiteDataStore {
    if Self.isPrivate(profile) { return session(Self.privateSession(profile)).store }
    let key = Data(profile.utf8)
    if let store = persistentStores[key] ?? deletedProfileStores[key] { return store }
    let store = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(profile))
    persistentStores[key] = store
    return store
  }

  func liveDataStore(for profile: String, storeKey key: String) -> WKWebsiteDataStore? {
    guard Self.isPrivate(profile) else { return key.utf16.elementsEqual(profile.utf16) ? dataStore(for: profile) : nil }
    let name = Self.privateSession(profile)
    guard let live = privateSessions[Data(name.utf8)], key == "private@\(name)#\(live.token)" else { return nil }
    return live.store
  }

  func privateGeneration(profile: String, store: WKWebsiteDataStore?) -> WebKitResourceGeneration? {
    guard Self.isPrivate(profile) else { return nil }
    let name = Self.privateSession(profile)
    guard let live = privateSessions[Data(name.utf8)], store === live.store else { return nil }
    return WebKitResourceGeneration(session: name, token: live.token)
  }

  func endPrivateSession(_ name: String) {
    guard let ended = privateSessions.removeValue(forKey: Data(name.utf8)) else { return }
    let generation = WebKitResourceGeneration(session: name, token: ended.token)
    _ = pendingExternal.removePrivateSession(generation)
    downloads.endPrivateSession(generation)
    let prefix = "private@\(name)#\(ended.token)|"
    rememberedPermissions = rememberedPermissions.filter { !$0.key.hasPrefix(prefix) }
    zoomByHost = zoomByHost.filter { !$0.key.hasPrefix(prefix) }
    externalAllowances = externalAllowances.filter { !$0.key.hasPrefix(prefix) }
    closeViews(using: ended.store)
    ended.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
  }

  private func closeViews(using store: WKWebsiteDataStore) {
    let uses = { (view: WKWebView) in view.configuration.websiteDataStore === store }
    for tab in owners.values.compactMap(\.tab) where tab.webView.map(uses) == true { tab.close() }
    for (key, view) in parked where uses(view) {
      parked.removeValue(forKey: key)
      Self.close(view)
    }
    for (id, view) in offered where uses(view) {
      offered.removeValue(forKey: id)
      Self.close(view)
    }
    for (key, view) in resumeHosts where uses(view) {
      resumeHosts.removeValue(forKey: key)
      Self.close(view)
    }
    for (id, pending) in pendingPermissions where pending.store === store {
      pendingPermissions.removeValue(forKey: id)
      pending.decide(false)
      events?("onWebKitPermissionDismissed", ["id": id])
    }
  }

  static let safariVersion: String = {
    let paths = ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
    for path in paths {
      if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
        return version.split(separator: ".").prefix(2).joined(separator: ".")
      }
    }
    return "18.6"
  }()

  static let inspectable: Bool = {
    if !(ProcessInfo.processInfo.environment["SOLARA_DATA_DIR"] ?? "").isEmpty { return true }
    if Bundle.main.object(forInfoDictionaryKey: "ACDevBuild") as? String == "YES" { return true }
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code as! SecStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let info = info as? [String: Any]
    else { return true }
    return info[kSecCodeInfoTeamIdentifier as String] == nil
  }()

  static let passkeysEntitled: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
    return (value as? Bool) == true
  }()

  static let hidePasskeys = """
    (() => {
      try { delete window.PublicKeyCredential; } catch (e) {}
      const container = window.CredentialsContainer && CredentialsContainer.prototype;
      if (!container) return;
      for (const name of ["create", "get"]) {
        const original = container[name];
        if (typeof original !== "function") continue;
        Object.defineProperty(container, name, {
          configurable: true, writable: true,
          value: {
            [name](options) {
              if (options && typeof options === "object" && "publicKey" in options) {
                return Promise.reject(new DOMException("Passkeys aren't available in this browser.", "NotSupportedError"));
              }
              return original.apply(this, arguments);
            },
          }[name],
        });
      }
    })();
    """

  func makeUserContentController() -> WKUserContentController {
    let controller = WKUserContentController()
    controller.addUserScript(WKUserScript(source: WebKitPageScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world))
    controller.add(self, contentWorld: Self.world, name: "solara")
    controller.addUserScript(WKUserScript(source: WebKitPageScript.mediaBridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    if !Self.passkeysEntitled {
      controller.addUserScript(WKUserScript(source: Self.hidePasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }
    contentBlocker.register(controller)
    return controller
  }

  func configuration(profile: String) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = dataStore(for: profile)
    config.userContentController = makeUserContentController()
    config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
    config.mediaTypesRequiringUserActionForPlayback = []
    config.allowsAirPlayForMediaPlayback = true
    config.preferences.isElementFullscreenEnabled = !Self.background
    Self.allowPictureInPicture(config.preferences)
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    #if DEBUG
    if Self.background, ProcessInfo.processInfo.environment["SOLARA_TEST_SCRIPT_POPUPS"] == "1" {
      config.preferences.javaScriptCanOpenWindowsAutomatically = true
    }
    #endif
    config.preferences.isFraudulentWebsiteWarningEnabled = false
    config.defaultWebpagePreferences.preferredContentMode = .desktop
    return config
  }

  static func allowPictureInPicture(_ preferences: WKPreferences) {
    let selector = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
    guard let method = class_getInstanceMethod(WKPreferences.self, selector) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(method_getImplementation(method), to: Setter.self)(preferences, selector, true)
  }

  func register(_ webView: WKWebView, tab: WebKitTab) {
    contentBlocker.bind(webView)
    owners[ObjectIdentifier(webView)] = WeakTab(tab)
  }

  #if DEBUG
  func devReturnFromPictureInPicture(browserId: Int32) -> Bool {
    owners.values.compactMap(\.tab).first { $0.browserId == browserId }?.devReturnFromPictureInPicture() ?? false
  }
  #endif

  func unregister(_ webView: WKWebView) { owners.removeValue(forKey: ObjectIdentifier(webView)) }

  func owner(of webView: WKWebView) -> WebKitTab? { owners[ObjectIdentifier(webView)]?.tab }

  func noteLive(_ tab: WebKitTab, key: String) { liveByKey[key] = WeakTab(tab) }

  func forgetLive(_ tab: WebKitTab, key: String) {
    if liveByKey[key]?.tab === tab || liveByKey[key]?.tab == nil { liveByKey.removeValue(forKey: key) }
  }

  func liveTab(_ key: String) -> WebKitTab? { liveByKey[key]?.tab }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let webView = message.webView, let tab = owner(of: webView), let body = message.body as? [String: Any],
      let kind = body["kind"] as? String
    else { return }
    tab.pageMessage(kind, data: body["data"], frame: body["frame"] as? String ?? "", frameInfo: message.frameInfo)
  }

  func prepareTransfer(_ key: String) {
    transferLock.lock()
    prepared.insert(key)
    transferLock.unlock()
  }

  func releaseTransfer(_ key: String) {
    transferLock.lock()
    prepared.remove(key)
    transferLock.unlock()
    DispatchQueue.main.async {
      if let webView = self.parked.removeValue(forKey: key) { Self.close(webView) }
    }
  }

  func isPrepared(_ key: String) -> Bool {
    transferLock.lock()
    defer { transferLock.unlock() }
    return prepared.contains(key)
  }

  func park(_ webView: WKWebView, key: String) {
    if let old = parked[key], old !== webView { Self.close(old) }
    parked[key] = webView
  }

  func claimParked(_ key: String) -> WKWebView? {
    transferLock.lock()
    prepared.remove(key)
    transferLock.unlock()
    return parked.removeValue(forKey: key)
  }

  func offer(_ webView: WKWebView) -> String {
    lastOffer += 1
    let id = "webkit:\(lastOffer)"
    offered[id] = webView
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      if let left = self?.offered.removeValue(forKey: id) { Self.close(left) }
    }
    return id
  }

  func claimOffered(_ id: String) -> WKWebView? { offered.removeValue(forKey: id) }

  static func close(_ webView: WKWebView) {
    WebKitHub.shared.unregister(webView)
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.stopLoading()
    webView.pauseAllMediaPlayback(completionHandler: nil)
    webView.closeAllMediaPresentations(completionHandler: nil)
    webView.removeFromSuperview()
  }

  func resumeHost(for profile: String) -> WKWebView {
    let key = Data(storeKey(profile).utf8)
    if let host = resumeHosts[key] { return host }
    let host = WKWebView(frame: .zero, configuration: configuration(profile: profile))
    host.navigationDelegate = contentBlocker
    contentBlocker.bind(host)
    resumeHosts[key] = host
    return host
  }

  func zoom(profile: String, host: String) -> Double { zoomByHost[storeKey(profile) + "|" + host] ?? 1 }

  func setZoom(_ zoom: Double, profile: String, host: String) {
    let key = storeKey(profile) + "|" + host
    if zoom == 1 { zoomByHost.removeValue(forKey: key) } else { zoomByHost[key] = zoom }
  }

  static let permissionKinds = ["camera", "microphone"]

  private func permissionKey(_ profile: String, _ origin: String, _ kind: String) -> String { storeKey(profile) + "|" + origin + "|" + kind }

  func requestPermission(browserId: Int32, profile: String, origin: String, kinds: [String], decide: @escaping (Bool) -> Void) {
    let keys = kinds.map { permissionKey(profile, origin, $0) }
    let answers = keys.map { rememberedPermissions[$0] }
    if answers.contains(false) { return decide(false) }
    if answers.allSatisfy({ $0 == true }) { return decide(true) }
    lastPermission += 1
    let id = "wk-permission-\(lastPermission)"
    pendingPermissions[id] = PendingPermission(browserId: browserId, keys: keys, store: dataStore(for: profile), decide: decide)
    events?("onWebKitPermission", ["id": id, "browserId": Int(browserId), "origin": origin, "permissions": kinds])
  }

  func resolvePermission(_ id: String, result: String, remember: Bool) {
    guard let pending = pendingPermissions.removeValue(forKey: id) else { return }
    let allowed = result == "accept"
    if remember && result != "dismiss" { for key in pending.keys { rememberedPermissions[key] = allowed } }
    pending.decide(allowed)
  }

  func dropPermissions(browserId: Int32) {
    for (id, pending) in pendingPermissions where pending.browserId == browserId {
      pendingPermissions.removeValue(forKey: id)
      pending.decide(false)
      events?("onWebKitPermissionDismissed", ["id": id])
    }
  }

  func sitePermissions(profile: String, origin: String) -> [String: [String: Any]] {
    var settings: [String: [String: Any]] = [:]
    for kind in Self.permissionKinds {
      let answer = rememberedPermissions[permissionKey(profile, origin, kind)]
      settings[kind] = ["value": answer.map { $0 ? "allow" : "block" } ?? "ask", "isDefault": answer == nil]
    }
    return settings
  }

  func setSitePermission(profile: String, origin: String, kind: String, value: String) {
    guard Self.permissionKinds.contains(kind) else { return }
    let key = permissionKey(profile, origin, kind)
    switch value {
    case "allow": rememberedPermissions[key] = true
    case "block": rememberedPermissions[key] = false
    default: rememberedPermissions.removeValue(forKey: key)
    }
    guard value == "block" else { return }
    let store = dataStore(for: profile)
    let views = owners.values.compactMap(\.tab?.webView) + parked.values.compactMap { $0 as? SolaraWKWebView } + offered.values.compactMap { $0 as? SolaraWKWebView }
    for view in views where view.configuration.websiteDataStore === store && view.captureOrigins[kind]?.contains(origin) == true {
      view.stopCapture(kind)
    }
  }

  func reconcileCapture(_ view: SolaraWKWebView, profile: String) {
    for (kind, origins) in view.captureOrigins where origins.contains(where: { rememberedPermissions[permissionKey(profile, $0, kind)] == false }) {
      view.stopCapture(kind)
    }
  }

  static let blockedSchemes: Set<String> = [
    "afp", "cifs", "disk", "disks", "hcp", "ms-help", "nfs", "res", "shell", "smb", "vbscript", "view-source", "vnc",
    "x-man-page", "x-apple.systempreferences",
  ]

  func externalAppRequest(url: URL, origin: String?, profile: String, webView: WKWebView) -> [String: Any]? {
    let generation = privateGeneration(profile: profile, store: webView.configuration.websiteDataStore)
    guard !Self.isPrivate(profile) || generation != nil else { return nil }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme.isEmpty || Self.blockedSchemes.contains(scheme) {
      NSLog("[webkit] refused a link to the %@: scheme", scheme)
      return nil
    }
    let app = externalApplication(url)
    let name = app.map { (FileManager.default.displayName(atPath: $0.path) as NSString).deletingPathExtension }
    let trusted = origin.map(Self.isTrustworthy) ?? false
    let allowance = app != nil && trusted && !Self.isPrivate(profile) ? storeKey(profile) + "|" + origin! + "|" + scheme : nil
    let grant = allowance != nil ? ExternalGrant(origin: origin!, scheme: scheme, app: name!, appPath: app!.path) : nil
    if let allowance, externalAllowances[allowance] != nil {
      open(url)
      return nil
    }
    lastExternal += 1
    let id = "wk-external-\(lastExternal)"
    if app != nil {
      if pendingExternal.count >= 50 { pendingExternal.removeAll() }
      pendingExternal.insert(PendingExternal(url: url, allowance: allowance, grant: grant), id: id, generation: generation)
    }
    let title = name.map { "Open “\($0)”?" } ?? "No application is set to open this link"
    let message = app == nil
      ? "Your Mac doesn’t have an app for “\(scheme):” links."
      : origin.map { "\($0) wants to open this application." } ?? "This page wants to open this application."
    let remember = allowance != nil ? "Always allow \(origin!) to open links of this type in \(name!)" : nil
    return [
      "id": id, "url": url.absoluteString, "scheme": scheme, "origin": origin ?? NSNull(), "app": name ?? NSNull(),
      "appPath": app?.path ?? NSNull(), "icon": app.flatMap(Self.iconURI) ?? NSNull(), "title": title,
      "message": message, "remember": remember ?? NSNull(),
    ]
  }

  func resolveExternalApp(_ id: String, open: Bool, remember: Bool) {
    guard let pending = pendingExternal.removeValue(forKey: id), open else { return }
    if remember, let allowance = pending.allowance, let grant = pending.grant { externalAllowances[allowance] = grant }
    self.open(pending.url)
  }

  static func isTrustworthy(_ origin: String) -> Bool {
    guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
    if scheme == "https" { return true }
    let loopback = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    return scheme == "http" && loopback
  }

  func externalAppAllowances(profile: String) -> [[String: Any]] {
    let prefix = storeKey(profile) + "|"
    return externalAllowances.filter { $0.key.hasPrefix(prefix) }.values.map { grant in
      ["origin": grant.origin, "scheme": grant.scheme, "app": grant.app, "icon": Self.iconURI(URL(fileURLWithPath: grant.appPath)) ?? NSNull()]
    }
  }

  func removeExternalAppAllowance(profile: String, origin: String, scheme: String) {
    externalAllowances.removeValue(forKey: storeKey(profile) + "|" + origin + "|" + scheme)
  }

  private func open(_ url: URL) {
    if let openExternal { return openExternal(url) }
    if Self.background { return NSLog("[webkit] external URL (background mode, not opened): %@", url.absoluteString) }
    NSWorkspace.shared.open(url)
  }

  static func iconURI(_ app: URL) -> String? {
    let icon = NSWorkspace.shared.icon(forFile: app.path)
    let size = NSSize(width: 64, height: 64)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
  }

  static let siteDataTypes: Set<String> = WKWebsiteDataStore.allWebsiteDataTypes().subtracting([
    WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
  ])

  func clearBrowsingData(profile: String, types: [String], since: Double, completion: @escaping () -> Void) {
    var kinds = Set<String>()
    if types.contains("siteData") { kinds.formUnion(Self.siteDataTypes) }
    if types.contains("cache") { kinds.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]) }
    if types.contains("siteData") {
      let prefix = storeKey(profile) + "|"
      rememberedPermissions = rememberedPermissions.filter { !$0.key.hasPrefix(prefix) }
      externalAllowances = externalAllowances.filter { !$0.key.hasPrefix(prefix) }
    }
    guard !kinds.isEmpty else { return completion() }
    dataStore(for: profile).removeData(ofTypes: kinds, modifiedSince: Date(timeIntervalSince1970: since / 1000), completionHandler: completion)
  }

  static func covers(_ domain: String, host: String) -> Bool {
    let name = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    return !name.isEmpty && (host == name || host.hasSuffix("." + name))
  }

  func clearSiteData(profile: String, host rawHost: String, completion: @escaping ([String: Any]) -> Void) {
    let store = dataStore(for: profile)
    let host = rawHost.lowercased()
    store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
      let matching = records.filter { Self.covers($0.displayName, host: host) }
      store.httpCookieStore.getAllCookies { cookies in
        let count = cookies.filter { Self.covers($0.domain, host: host) }.count
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching) {
          completion(["cookies": count, "storage": true])
        }
      }
    }
  }

  func deleteProfileData(_ profile: String, deletionAllowed: @escaping () -> Bool = { true }, completion: @escaping (Bool) -> Void) {
    guard !SolaraCoreHost.safeMode else { return completion(false) }
    guard !Self.isPrivate(profile) else { return completion(true) }
    guard deletionAllowed() else { return completion(false) }
    let identifier = Self.storeIdentifier(profile)
    let key = Data(profile.utf8)
    deletedProfileStores[key] = .nonPersistent()
    downloads.cancelAll(profile: profile)
    if let host = resumeHosts.removeValue(forKey: key) { Self.close(host) }
    let prefix = profile + "|"
    rememberedPermissions = rememberedPermissions.filter { !$0.key.utf16.starts(with: prefix.utf16) }
    zoomByHost = zoomByHost.filter { !$0.key.utf16.starts(with: prefix.utf16) }
    externalAllowances = externalAllowances.filter { !$0.key.utf16.starts(with: prefix.utf16) }
    var answered = false
    let answer = { [weak self] (removed: Bool) in
      guard !answered else { return }
      answered = true
      if removed { self?.deletedProfileStores.removeValue(forKey: key) }
      completion(removed)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.profileDataRemovalDeadline) {
      guard !answered else { return }
      NSLog("[webkit] removing the data store %@ didn't finish in %.0f s", identifier.uuidString, Self.profileDataRemovalDeadline)
      answer(false)
    }
    WebKitStoreRemovals.exists(identifier) { exists in
      guard exists else { return answer(true) }
      guard Self.establishedProfileDirectory(profile), deletionAllowed() else { return answer(false) }
      let removeStore = {
        WebKitStoreRemovals.remove(identifier, tries: 12, deletionAllowed: deletionAllowed, done: answer)
      }
      guard let store = self.persistentStores.removeValue(forKey: key) else { return removeStore() }
      self.closeViews(using: store)
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { DispatchQueue.main.async(execute: removeStore) }
    }
  }

  #if DEBUG
  func storeExists(_ profile: String, done: @escaping (Bool) -> Void) {
    WebKitStoreRemovals.exists(Self.storeIdentifier(profile), done: done)
  }

  func holdStoreForTest(_ profile: String) { storesHeldForTest[Data(profile.utf8)] = dataStore(for: profile) }

  func touchStore(_ profile: String, done: @escaping (Bool) -> Void) {
    let cookies = dataStore(for: profile).httpCookieStore
    let cookie = HTTPCookie(properties: [.name: "solara-touch", .value: "1", .domain: "solara.test", .path: "/", .expires: Date().addingTimeInterval(86400)])
    cookies.getAllCookies { existing in
      let touched = existing.contains { $0.name == "solara-touch" && $0.domain.hasSuffix("solara.test") }
      guard let cookie else { return done(touched) }
      cookies.setCookie(cookie) { done(touched) }
    }
  }
  #endif
}

@MainActor
enum WebKitStoreRemovals {
  private static let webKitStarted: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

  static func exists(_ identifier: UUID, done: @escaping (Bool) -> Void) {
    webKitStarted
    WKWebsiteDataStore.fetchAllDataStoreIdentifiers { stores in
      DispatchQueue.main.async { done(stores.contains(identifier)) }
    }
  }

  static func remove(_ identifier: UUID, tries: Int, deletionAllowed: @escaping () -> Bool = { true }, done: @escaping (Bool) -> Void) {
    webKitStarted
    guard deletionAllowed() else { return done(false) }
    WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
      DispatchQueue.main.async {
        if error == nil { return done(true) }
        guard tries > 1 else {
          NSLog("[webkit] the data store %@ is still in use: %@", identifier.uuidString, error.map { "\($0)" } ?? "")
          return done(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { remove(identifier, tries: tries - 1, deletionAllowed: deletionAllowed, done: done) }
      }
    }
  }
}

@MainActor
enum WebKitPasskeys {
  static func access() -> [String: Any] {
    guard WebKitHub.passkeysEntitled else { return ["entitled": false, "status": "entitlementRequired"] }
    return ["entitled": true, "status": status(ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials)]
  }

  static func requestAccess(_ completion: @escaping ([String: Any]) -> Void) {
    guard WebKitHub.passkeysEntitled, deviceConfigured(), ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1" else {
      return completion(access())
    }
    nonisolated(unsafe) let reply = completion
    ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { state in
      DispatchQueue.main.async { reply(["entitled": true, "status": Self.status(state)]) }
    }
  }

  private static func deviceConfigured() -> Bool {
    if #available(macOS 26.2, *) { return ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys }
    return true
  }

  private static func status(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> String {
    guard deviceConfigured() else { return "deviceNotConfigured" }
    switch state {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
  }
}

@MainActor
protocol WebKitDownloadSource: AnyObject {
  var originalRequest: URLRequest? { get }
  var progress: Progress { get }
  var delegate: (any WKDownloadDelegate)? { get set }
  func cancel(_ completionHandler: (@MainActor (Data?) -> Void)?)
}

extension WKDownload: WebKitDownloadSource {}

final class WebKitDownloads: NSObject, WKDownloadDelegate {
  private enum Phase { case running, pausing, paused, resuming, done }

  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
  }

  private final class Item: WebKitDownloadPayload {
    let uuid = UUID().uuidString
    var id: String { "wk-download-" + uuid }
    var download: (any WebKitDownloadSource)?
    weak var webView: WKWebView?
    var panel: NSSavePanel?
    var phase = Phase.running
    var replaces: FileIdentity?
    var staging: URL?
    var state = "downloading"
    var received: Int64 = 0
    var total: Int64 = 0
    var speed: Double = 0
    var progress: NSKeyValueObservation?
    var sampledAt = Date()
    var sampledBytes: Int64 = 0
    var reportedAt = Date.distantPast

    var stagingFile: URL? { staging.map { $0.appendingPathComponent(filename.isEmpty ? "download" : filename) } }
  }

  private unowned let hub: WebKitHub
  var destinationSettings: ((String, @escaping (URL, Bool) -> Void) -> Void)?
  var restartDownload: ((WKWebView?, String, Data?, URLRequest?, @escaping (any WebKitDownloadSource) -> Void) -> Void)?
  var retainedDownloadCount: Int { items.count }

  init(hub: WebKitHub) {
    self.hub = hub
    super.init()
  }

  private var items = WebKitSessionResources<Item>()
  private var byDownload: [ObjectIdentifier: String] = [:]
  private let fallbackFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

  private func resolveDestination(for profile: String, completion: @escaping (URL, Bool) -> Void) {
    if let destinationSettings { return destinationSettings(profile, completion) }
    guard SolaraCoreEngineBridge.exports("ac_downloads_settings") else { return completion(fallbackFolder, true) }
    SolaraCoreEngineBridge.call("ac_downloads_settings", profile: WebKitHub.regularProfile(profile), args: nil) { [weak self] json in
      let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
      let folder = (parsed?["folder"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
      let ask = parsed?["askWhereToSave"] as? Bool ?? (folder == nil)
      DispatchQueue.main.async {
        guard let self else { return }
        completion(folder ?? self.fallbackFolder, ask)
      }
    }
  }

  @discardableResult
  func adopt(_ download: any WebKitDownloadSource, profile: String, webView: WKWebView?) -> String? {
    let generation = hub.privateGeneration(profile: profile, store: webView?.configuration.websiteDataStore)
    guard !WebKitHub.isPrivate(profile) || generation != nil else {
      download.cancel(nil)
      return nil
    }
    let item = Item(url: download.originalRequest?.url?.absoluteString ?? "", profile: profile)
    item.webView = webView
    item.request = download.originalRequest
    attach(download, to: item)
    items.insert(item, id: item.id, generation: generation)
    return item.id
  }

  private func attach(_ download: any WebKitDownloadSource, to item: Item) {
    item.download = download
    byDownload[ObjectIdentifier(download)] = item.id
    download.delegate = self
    let id = item.id
    item.progress = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
      DispatchQueue.main.async {
        guard let self, let item = self.items[id], item.phase == .running else { return }
        item.received = progress.completedUnitCount
        item.total = max(0, progress.totalUnitCount)
        let now = Date()
        let elapsed = now.timeIntervalSince(item.sampledAt)
        if elapsed >= 0.5 {
          item.speed = Double(item.received - item.sampledBytes) / elapsed
          item.sampledAt = now
          item.sampledBytes = item.received
        }
        if now.timeIntervalSince(item.reportedAt) >= 0.25 {
          item.reportedAt = now
          self.report(item)
        }
      }
    }
  }

  private func detach(_ item: Item) {
    if let download = item.download { byDownload.removeValue(forKey: ObjectIdentifier(download)) }
    item.progress = nil
    item.download = nil
  }

  private func item(for download: any WebKitDownloadSource) -> Item? { byDownload[ObjectIdentifier(download)].flatMap { items[$0] } }

  private func report(_ item: Item) {
    guard items[item.id] === item else { return }
    let payload: [String: Any] = [
      "id": item.id, "url": item.url, "filename": item.filename, "path": item.path, "state": item.state,
      "paused": item.phase == .pausing || item.phase == .paused || item.phase == .resuming,
      "received": Double(item.received), "total": Double(item.total), "speed": item.speed, "mimeType": item.mimeType,
      "profile": item.profile, "offTheRecord": false, "staging": item.staging?.path ?? NSNull(),
      "destination": item.final?.path ?? NSNull(),
    ]
    hub.events?("onWebKitDownload", payload)
  }

  static let stagingPrefix = ".solara-download-"

  static func makeStaging(in folder: URL, uuid: String) -> URL? {
    let staging = folder.appendingPathComponent(stagingPrefix + uuid, isDirectory: true)
    return mkdir(staging.path, 0o700) == 0 ? staging : nil
  }

  static func plainAbsolute(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count > 1 && parts[0].isEmpty && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  static func removeStaging(_ path: String, uuid: String, folder: String) -> Bool {
    guard !SolaraCoreHost.safeMode else { return false }
    guard UUID(uuidString: uuid) != nil, plainAbsolute(path), plainAbsolute(folder),
      (path as NSString).deletingLastPathComponent == folder, (path as NSString).lastPathComponent == stagingPrefix + uuid
    else { return false }
    var info = stat()
    guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
    guard lstat(path, &info) == 0 else { return errno == ENOENT }
    guard info.st_mode & S_IFMT == S_IFDIR else { return false }
    return (try? FileManager.default.removeItem(atPath: path)) != nil
  }

  private static func identity(_ path: String) -> FileIdentity? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return FileIdentity(device: info.st_dev, inode: info.st_ino)
  }

  private static func dropStaging(_ item: Item) {
    guard let staging = item.staging else { return }
    item.staging = nil
    try? FileManager.default.removeItem(at: staging)
  }

  private static func place(_ file: URL, at final: URL, replacing: FileIdentity?) -> URL? {
    if let replacing, identity(final.path) == replacing, rename(file.path, final.path) == 0 { return final }
    let base = final.deletingPathExtension().lastPathComponent
    let ext = final.pathExtension
    for n in 0...9999 {
      let name = n == 0 ? final.lastPathComponent : ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
      let candidate = final.deletingLastPathComponent().appendingPathComponent(name)
      if renamex_np(file.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
      if errno != EEXIST { return nil }
    }
    return nil
  }

  func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
    decideDestination(download, response: response, suggestedFilename: suggestedFilename, completionHandler: completionHandler)
  }

  func decideDestination(_ download: any WebKitDownloadSource, response: URLResponse, suggestedFilename: String,
                         completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
    guard let item = item(for: download) else { return completionHandler(nil) }
    if let file = item.stagingFile {
      try? FileManager.default.removeItem(at: file)
      item.path = file.path
      report(item)
      return completionHandler(file)
    }
    let name = Self.safeName(suggestedFilename.isEmpty ? (response.suggestedFilename ?? "download") : suggestedFilename)
    item.mimeType = response.mimeType ?? ""
    item.total = max(0, response.expectedContentLength)
    item.destination = completionHandler
    let accept = { [weak self, weak item] (target: URL?, replacing: Bool) in
      guard let self, let item, self.items[item.id] === item, let completion = item.destination else { return }
      item.destination = nil
      item.panel = nil
      guard item.phase != .done else { return completion(nil) }
      guard let target, let staging = Self.makeStaging(in: target.deletingLastPathComponent(), uuid: item.uuid) else {
        item.phase = .done
        item.state = target == nil ? "cancelled" : "failed"
        self.report(item)
        completion(nil)
        return
      }
      item.final = target
      item.replaces = replacing ? Self.identity(target.path) : nil
      item.staging = staging
      item.filename = target.lastPathComponent
      let file = staging.appendingPathComponent(item.filename)
      item.path = file.path
      self.report(item)
      completion(file)
    }
    resolveDestination(for: item.profile) { [weak self, weak item] folder, ask in
      guard let self, let item, self.items[item.id] === item, item.destination != nil, item.phase != .done else { return }
      guard ask, !WebKitHub.background else { return accept(folder.appendingPathComponent(name), false) }
      let panel = NSSavePanel()
      item.panel = panel
      panel.directoryURL = folder
      panel.nameFieldStringValue = name
      panel.begin { [weak panel] response in accept(response == .OK ? panel?.url : nil, true) }
    }
  }

  func downloadDidFinish(_ download: WKDownload) { finish(download) }

  func finish(_ download: any WebKitDownloadSource) {
    guard let item = item(for: download) else { return }
    item.phase = .done
    detach(item)
    if let file = item.stagingFile, let final = item.final, let placed = Self.place(file, at: final, replacing: item.replaces) {
      item.path = placed.path
      item.filename = placed.lastPathComponent
      item.state = "finished"
      let size = ((try? FileManager.default.attributesOfItem(atPath: placed.path))?[.size] as? NSNumber)?.int64Value
      if let size {
        item.received = size
        item.total = size
      }
    } else {
      item.state = "failed"
    }
    Self.dropStaging(item)
    report(item)
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    fail(download, error: error, resumeData: resumeData)
  }

  func fail(_ download: any WebKitDownloadSource, error: Error, resumeData: Data?) {
    guard let item = item(for: download) else { return }
    detach(item)
    switch item.phase {
    case .pausing, .paused:
      if let resumeData { item.resumeData = resumeData }
      item.phase = .paused
    case .done:
      break
    case .running, .resuming:
      item.phase = .done
      item.state = (error as NSError).code == NSURLErrorCancelled ? "cancelled" : "failed"
      Self.dropStaging(item)
    }
    report(item)
  }

  func endPrivateSession(_ generation: WebKitResourceGeneration) {
    for item in items.removePrivateSession(generation) {
      let download = item.download
      item.phase = .done
      item.panel?.cancel(nil)
      item.panel = nil
      detach(item)
      Self.dropStaging(item)
      item.webView = nil
      item.replaces = nil
      item.retire()
      download?.cancel(nil)
    }
  }

  func handles(_ id: String) -> Bool { id.hasPrefix("wk-download-") }

  func cancelAll(profile: String) {
    for item in items.values where item.profile.utf16.elementsEqual(profile.utf16) && item.phase != .done { command("cancel", id: item.id) }
  }

  func command(_ action: String, id: String) {
    guard let item = items[id] else { return }
    switch action {
    case "cancel":
      guard item.phase != .done else { return }
      let download = item.download
      item.phase = .done
      item.state = "cancelled"
      item.resumeData = nil
      let destination = item.destination
      item.destination = nil
      item.panel?.cancel(nil)
      item.panel = nil
      detach(item)
      report(item)
      destination?(nil)
      if let download {
        download.cancel { [weak self, weak item] _ in
          DispatchQueue.main.async {
            guard let self, let item, self.items[item.id] === item else { return }
            Self.dropStaging(item)
          }
        }
      } else {
        Self.dropStaging(item)
      }
    case "pause":
      guard item.phase == .running, let download = item.download else { return }
      item.phase = .pausing
      report(item)
      let downloadIdentity = ObjectIdentifier(download)
      download.cancel { [weak self, weak item] data in
        DispatchQueue.main.async {
          guard let self, let item, self.items[item.id] === item, item.phase == .pausing || item.phase == .paused else { return }
          if let data { item.resumeData = data }
          if item.download.map(ObjectIdentifier.init) == downloadIdentity { self.detach(item) }
          if item.phase == .pausing { item.phase = .paused }
        }
      }
    case "resume":
      guard item.phase == .paused else { return }
      let data = item.resumeData
      let saved = item.request ?? URL(string: item.url).map { URLRequest(url: $0) }
      let request = saved.flatMap { ["GET", "HEAD"].contains(($0.httpMethod ?? "GET").uppercased()) ? $0 : nil }
      guard data != nil || request != nil else {
        item.phase = .done
        item.state = "failed"
        Self.dropStaging(item)
        return report(item)
      }
      item.phase = .resuming
      item.resumeData = nil
      let restarts = data == nil
      let resumed: (any WebKitDownloadSource) -> Void = { [weak self, weak item] download in
        DispatchQueue.main.async {
          guard let self, let item, self.items[item.id] === item, item.phase == .resuming else { return download.cancel(nil) }
          item.phase = .running
          if restarts { item.received = 0 }
          item.sampledAt = Date()
          item.sampledBytes = item.received
          self.attach(download, to: item)
          self.report(item)
        }
      }
      if let restartDownload { return restartDownload(item.webView, item.profile, data, request, resumed) }
      let host = item.webView ?? hub.resumeHost(for: item.profile)
      hub.contentBlocker.prepare(host.configuration.userContentController) { [weak self, weak item, weak host] error in
        guard let self, let item, let host, self.items[item.id] === item, item.phase == .resuming else { return }
        if let error {
          item.phase = .paused
          item.resumeData = data
          NSLog("[webkit-blocker] download restart blocked: %@", error.localizedDescription)
          self.report(item)
          return
        }
        if let data { host.resumeDownload(fromResumeData: data) { resumed($0) } }
        else if let request { host.startDownload(using: request) { resumed($0) } }
      }
    default: break
    }
  }

  static func safeName(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
    return trimmed.isEmpty ? "download" : trimmed
  }
}
