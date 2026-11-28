import AppKit
import Foundation
import SolaraCore
import SolaraEngine
import SolaraImportAdapter
import SolaraModel
import SolaraStore
import SolaraShell
import SolaraSyncAdapter
import SolaraUI

@MainActor
final class ImportAdapter: ImportServices {
  var swiftSession = 0
  private var service: ImportService { ImportService.shared }
  private var diaLaunched = Date.distantPast

  func open() async -> ImportOpening {
    swiftSession = ImportRuns.shared.open()
    guard let store = ImportRunEngine.store else {
      return ImportOpening(available: false, preferredSource: ImportPreferredSource.shared.take(), targets: [], defaultTarget: "")
    }
    return ImportOpening(available: ImportRuns.shared.admitted(swiftSession), preferredSource: ImportPreferredSource.shared.take(),
      targets: ImportTargets.list(store.state).map { SolaraUI.ImportTarget(id: $0.id, name: $0.name) }, defaultTarget: ImportTargets.defaultTarget(store.state))
  }

  func listBrowsers() async -> [ImportBrowser]? {
    guard let json = await service.browsersJSON(),
      let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return nil }
    let browsers = list.compactMap(Self.browser)
    ImportRuns.shared.browsers = browsers
    return browsers
  }

  func targetUpdates() -> AsyncStream<[ImportTarget]> {
    guard let store = ImportRunEngine.store else { return AsyncStream { $0.finish() } }
    return AsyncStream { continuation in
      let feed = ImportTargetsFeed(store.state)
      let listener = store.subscribe { commit in
        guard let list = feed.next(commit.state) else { return }
        continuation.yield(list.map { SolaraUI.ImportTarget(id: $0.id, name: $0.name) })
      }
      continuation.onTermination = { _ in store.unsubscribe(listener) }
    }
  }

  func progressUpdates() -> AsyncStream<ImportProgressUpdate> { ImportProgressFeed.shared.stream() }

  func safariHasFullDiskAccess() async -> Bool {
    return await service.safariHasFullDiskAccess()
  }

  func isBrowserUnlocked(_ browserId: String) async -> Bool {
    return service.isUnlocked(browserId)
  }

  func unlockBrowser(_ browserId: String) async -> Bool {
    return await service.unlock(browserId)
  }

  func cancel() { ImportRuns.shared.cancel(engine: ImportRunEngine.shared) }

  func dispose() {
    swiftSession = 0
    ImportRuns.shared.dispose(engine: ImportRunEngine.shared)
  }

  #if DEBUG
  static var devVaultCount: Int { ImportService.shared.devVaultCount }
  #endif

  static func drainSwift() async {
    await ImportRuns.shared.drain(engine: ImportRunEngine.shared)
  }

  func diaAutomationStatus() async -> DiaStatus {
    return Self.dia(await service.diaStatus(ask: false))
  }

  func requestDiaAutomation() async -> DiaStatus {
    return Self.dia(await service.diaStatus(ask: ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1"))
  }

  func openDia() async -> Bool {
    diaLaunched = Date()
    return await ImportService.openDia()
  }

  func readDiaTabs() async -> DiaRead {
    do {
      var result = try await ImportService.shared.readDiaTabs()
      var tries = 0
      while result.windowCount == 0, Date().timeIntervalSince(diaLaunched) < 15, tries < 8 {
        try await Task.sleep(for: .milliseconds(1500))
        result = try await ImportService.shared.readDiaTabs()
        tries += 1
      }
      let read = Self.diaRead(result)
      ImportRuns.shared.dia = read
      return .read(profiles: read.profiles.map { DiaProfileSummary(id: $0.id, name: $0.name, pinnedCount: $0.pinned.count, tabCount: $0.tabs.count) }, windowCount: read.windowCount)
    } catch let error as SolaraImportAdapter.ImportError {
      return .failed(code: error.code, message: error.description)
    } catch {
      return .failed(code: "unreadable", message: error.localizedDescription)
    }
  }

  nonisolated static func diaRead(_ result: SolaraImportAdapter.DiaTabsResult) -> ImportDiaRead {
    ImportDiaRead(
      profiles: result.profiles.map { ImportDiaProfile(id: $0.id, name: $0.name, pinned: $0.pinned.map(ImportRunEngine.tab), tabs: $0.tabs.map(ImportRunEngine.tab)) },
      windowCount: result.windowCount,
      favicons: result.favicons.map { ImportFaviconRow(page: $0.page, icon: $0.icon, png: $0.png) }
    )
  }

  func runDia(profileIds: [String], target: String, pinned: Bool, open: Bool) async -> ImportRunOutcome {
    await ImportRuns.shared.importDia(profileIds: profileIds, target: target, pinned: pinned, open: open, session: swiftSession, engine: ImportRunEngine.shared)
  }

  func importSafariExport(path: String, target: String) async -> ImportFileOutcome {
    await ImportRuns.shared.importSafari(.export(path: path), target: target, cookies: false, session: swiftSession, engine: ImportRunEngine.shared)
  }

  func importSafariDirect(target: String, cookies: Bool) async -> ImportFileOutcome {
    await ImportRuns.shared.importSafari(.direct, target: target, cookies: cookies, session: swiftSession, engine: ImportRunEngine.shared)
  }

  func importBookmarksHTML(target: String) async -> ImportFileOutcome {
    await ImportRuns.shared.importBookmarksFile(target: target, session: swiftSession, engine: ImportRunEngine.shared)
  }

  func chooseImportFile(_ kind: ImportFileKind) async -> String? {
    return await ImportService.chooseFile(kind.rawValue)
  }

  func openFullDiskAccessSettings() {
    ImportService.openPrivacySettings("Privacy_AllFiles")
  }

  func openAutomationSettings() {
    ImportService.openPrivacySettings("Privacy_Automation")
  }

  func openInWebStore(profileId: String, urls: [String]) {
    guard !urls.isEmpty, let store = SettingsDirectWrites.store, store.state.profiles[profileId] != nil, !Ids.isIncognitoProfile(profileId) else { return }
    let state = store.state
    let regular = { (id: String) in state.windows[id].map { !$0.incognito } ?? false }
    let window = state.ui.focusOrder.first(where: regular) ?? state.windowOrder.first(where: regular)
      ?? SettingsDirectWrites.write(store, Command("createWindow", [["profileId": .string(profileId)]]))?.result?.string
    guard let window else { return }
    for (index, url) in urls.enumerated() {
      SettingsDirectWrites.write(store, Command("newTab", [.string(window), ["url": .string(url), "profileId": .string(profileId), "background": .bool(index > 0)]]))
    }
  }

  func arcHolderCount() async -> Int { NativeBookmarkHolderRestoration.count() }

  func restoreArcFolders() async -> Int {
    guard ImportRuns.shared.admitted(swiftSession) else { return await arcHolderCount() }
    return await NativeBookmarkHolderRestoration.restoreAll()
  }

  func isOnboarding() async -> Bool { NativeOnboarding.isActive }

  func close() { WindowHost.closeBrowserWindow("import") }

  static func dia(_ value: Any?) -> DiaStatus {
    (value as? String).flatMap(DiaStatus.init(rawValue:)) ?? .denied
  }

  static func browser(_ b: [String: Any]) -> ImportBrowser? {
    guard let id = b.string("id") else { return nil }
    return ImportBrowser(
      id: id,
      name: b.string("name") ?? id,
      family: b.string("family").flatMap(ImportBrowserFamily.init(rawValue:)) ?? .chromium,
      iconPath: b.string("iconPath"),
      requiresExport: b.bool("requiresExport") ?? false,
      needsKeychain: b.bool("needsKeychain") ?? false,
      needsFullDiskAccess: b.bool("needsFullDiskAccess") ?? false,
      keychainService: b.string("keychainService"),
      profiles: b.list("profiles").compactMap(profile),
      sidebar: b.string("sidebar").flatMap(ImportSidebar.init(rawValue:))
    )
  }

  static func profile(_ p: [String: Any]) -> ImportSourceProfile? {
    guard let id = p.string("id") else { return nil }
    return ImportSourceProfile(
      id: id,
      name: p.string("name") ?? id,
      email: p.string("email"),
      avatarPath: p.string("avatarPath"),
      color: p.string("color"),
      isDefault: p.bool("isDefault") ?? false,
      available: p.strings("available").compactMap(SolaraUI.ImportKind.init(rawValue:)),
      spaces: p.list("spaces").compactMap { s in
        guard let id = s.string("id") else { return nil }
        return ImportSpace(id: id, name: s.string("name") ?? "", color: s.string("color"), emoji: s.string("emoji"), pinnedCount: s.int("pinnedCount") ?? 0, tabCount: s.int("tabCount") ?? 0)
      },
      tabsNeedKey: p.bool("tabsNeedKey") ?? false
    )
  }
}

@MainActor
final class ImportRunEngine: ImportEngine {
  static let shared = ImportRunEngine()
  private var openAlert: (alert: NSAlert, window: NSWindow)?

  static var store: Store? {
    guard !NativeStoreHandle.frozen, NativeStoreHandle.ownsWorkspace else { return nil }
    return NativeStoreHandle.store
  }

  var safeMode: Bool { SolaraCoreHost.safeMode || Self.store == nil || Self.store?.config.safeMode == true }

  func transientImportRefused() {
    guard let window = Self.importWindow() else { return }
    let alert = NSAlert()
    alert.messageText = "Safe Mode"
    alert.informativeText = "Imported tabs, spaces, pinned tabs and new profiles cannot be saved in safe mode. Open Solara normally to import them."
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window)
  }

  func isUnlocked(_ browserId: String) -> Bool { ImportService.shared.isUnlocked(browserId) }

  func unlock(_ browserId: String) async -> Bool { await ImportService.shared.unlock(browserId) }

  func readSafari(jobId: String, from source: ImportSafariSource) async throws -> ImportRead {
    let exportPath: String? = if case .export(let path) = source { path } else { nil }
    do {
      return Self.imported(try await ImportService.shared.readSafari(jobId: jobId, exportPath: exportPath))
    } catch let error as SolaraImportAdapter.ImportError {
      throw error == .cancelled ? ImportSafariReadFailure.cancelled : ImportSafariReadFailure.failed(error.code)
    } catch {
      throw ImportSafariReadFailure.failed("unreadable")
    }
  }

  func bookmarkParents(_ profile: String) -> ImportBookmarkParents? {
    guard let owner = NativeBookmarkOwner.current, let snapshot = try? owner.snapshot(profile: profile) else { return nil }
    let document = snapshot.document
    let roots = BookmarkFlat.roots(snapshot.binding.engine)
    return ImportBookmarkWrites.parents(hasView: snapshot.hasView, document: document, bar: roots.bar, other: roots.other)
  }

  func submitBookmarks(profile: String, mutations: [BookmarkMutation]) async throws {
    guard let owner = NativeBookmarkOwner.writableCurrent else { throw ImportBookmarkWriteFailure.failed }
    let requestID = BookmarkString.encode("import-bookmarks-\(UUID().uuidString)")
    do {
      let binding = try await ImportBookmarkWrites.whileEngineHolds(binding: { try owner.binding(profile: profile) }, isStale: { ($0 as? BookmarkWriterError) == .staleBinding }) { binding in
        _ = try await owner.submitAsync(profile: profile, mutations: mutations, binding: binding, requestID: requestID)
      }
      _ = try? owner.acknowledgeReceipt(profile: profile, requestID: requestID, binding: binding)
    } catch BookmarkWriterError.conditionFailed {
      throw ImportBookmarkWriteFailure.conditionFailed
    } catch {
      throw ImportBookmarkWriteFailure.failed
    }
  }

  static func adoptTimeout(_ deadline: TimeInterval) -> TimeInterval {
    #if DEBUG
    let env = ProcessInfo.processInfo.environment
    if !(env["SOLARA_DATA_DIR"] ?? "").isEmpty, let ms = env["SOLARA_IMPORT_TEST_ADOPT_TIMEOUT_MS"].flatMap(Double.init) { return ms / 1000 }
    #endif
    return deadline
  }

  nonisolated static func historyPayload(_ rows: [ImportHistoryRow]) -> [[String: Any]] {
    rows.map { ["url": $0.url, "title": $0.title, "visits": $0.visits, "lastVisit": $0.lastVisit] }
  }

  func adoptHistory(profile: String, rows: [ImportHistoryRow], deadline: TimeInterval) async -> Int? {
    guard let reply = try? await SettingsJS.shared.invoke("replica.adoptHistory", [profile, Self.historyPayload(rows)], timeout: Self.adoptTimeout(deadline)) else { return nil }
    return (reply as? NSNumber)?.intValue
  }

  func importHistory(engineProfile: String, rows: [ImportHistoryRow]) async {
    do {
      _ = try await NativeHistoryCatalog.command(kind: "importHistory", engineProfile: engineProfile, payload: ["rows": Self.historyPayload(rows)])
    } catch {
      NSLog("[history] the import's history was not saved")
    }
  }

  func adoptFavicons(profile: String, favicons: [ImportFaviconRow]) async {
    guard !safeMode, profileExists(profile), !isPrivateProfile(profile),
      let library = NativeHistoryCatalog.catalog.favicons else { return }
    let engine = engineProfile(profile)
    for row in favicons {
      guard let data = Data(base64Encoded: row.png) else { continue }
      library.adopt(page: row.page, source: row.icon, data: data, engineProfile: engine)
    }
    NotificationCenter.default.post(name: FaviconLibrary.didInvalidate, object: nil)
    #if DEBUG
    await SettingsJS.shared.devHoldImportAdoption()
    #endif
  }

  func storeFavicons(profile: String, engineProfile: String, favicons: [ImportFaviconRow]) async {
    await ImportFaviconWrites.persist(profile: profile, engineProfile: engineProfile, favicons: favicons, binding: {
      guard !self.safeMode, self.profileExists(profile), !self.isPrivateProfile(profile) else { return nil }
      return self.engineProfile(profile)
    }, load: { engineProfile in
      await withCheckedContinuation { continuation in
        SolaraCoreHost.ensureProfile(engineProfile) { continuation.resume(returning: $0) }
      }
    }, store: { engineProfile, page, favicon in
      _ = try? await NativeHistoryCatalog.command(kind: "storeFavicon", engineProfile: engineProfile, payload: ["page": page, "icon": favicon.icon, "png": favicon.png])
    })
  }

  func reportBookmarkFailure() {
    NSLog("[bookmarks] the import's bookmarks were not saved")
  }

  func chooseImportFile(_ kind: SolaraUI.ImportFileKind) async -> String? { await ImportService.chooseFile(kind.rawValue) }

  func readBookmarksFile(path: String) async -> ImportBookmarkNode? {
    await Task.detached { (try? NetscapeBookmarks.load(ImportModule.fileURL(path))).map(Self.bookmark) }.value
  }

  func importWorkspace(profile: String, windows: [JSONValue]) -> Int? {
    placeWorkspace(profile: profile, windows: windows, theme: nil)?.tabs
  }

  func placeWorkspace(profile: String, windows: [JSONValue], theme: JSONValue?) -> ImportWorkspaceWritten? {
    guard let store = SettingsDirectWrites.store, !safeMode, profileExists(profile), !isPrivateProfile(profile) else { return nil }
    var payload: JSONObject = ["profileId": .string(profile), "windows": .array(windows)]
    if let theme { payload["theme"] = theme }
    guard let result = SettingsDirectWrites.write(store, Command("importWorkspace", [.object(payload)]))?.result,
      let tabs = result["tabs"]?.number, let skipped = result["skipped"]?.number else { return nil }
    return ImportWorkspaceWritten(tabs: Int(tabs), skipped: Int(skipped))
  }

  func adoptProfileTheme(profile: String) async throws -> Bool {
    guard !safeMode, profileExists(profile), !isPrivateProfile(profile) else { return false }
    return try await SettingsJS.shared.invoke("import.adoptProfileTheme", [profile], timeout: nil) as? Bool == true
  }

  func importPullRequestsFolder(profile: String, source: String) async {
    guard !safeMode, profileExists(profile), !isPrivateProfile(profile),
      let payload = try? JSONSerialization.data(withJSONObject: ["profileId": profile, "kind": "pullRequests", "source": source]) else { return }
    _ = try? await NativeLiveEngine.shared.command(name: "importFolder", payloadJSON: String(decoding: payload, as: UTF8.self))
  }

  func cancelRead(jobId: String) { ImportService.shared.cancelRead(jobId: jobId) }

  func discard(token: String) { ImportService.shared.discard(token) }

  func writeNative(token: String, engineProfile: String, kinds: [String]) async -> ImportNativeWritten? {
    guard let written = await ImportService.shared.write(token: token, engineProfile: engineProfile, kinds: kinds) else { return nil }
    return ImportNativeWritten(cookies: written.cookies, addresses: written.addresses, cards: written.cards,
                               cookiesFailed: written.cookiesFailed, autofillFailed: written.autofillFailed)
  }

  func savePassword(engineProfile: String, origin: String, username: String, password: String) async -> Bool {
    await EngineCalls.result({ done in
      SolaraCoreServices.savePassword(profile: engineProfile, origin: origin, username: username, password: password) { done($0) }
    }) { $0["error"] == nil }
  }

  func extensions(browserId: String, profileId: String) async -> [SolaraUI.ImportedExtension] {
    await ImportService.shared.extensions(browserId: browserId, profileId: profileId).map {
      SolaraUI.ImportedExtension(id: $0.id, name: $0.name, webStoreUrl: $0.webStoreUrl)
    }
  }

  func forget() { ImportService.shared.forget() }

  func profiles() -> [SolaraUI.ImportTarget] {
    guard let store = Self.store else { return [] }
    return ImportTargets.list(store.state).map { SolaraUI.ImportTarget(id: $0.id, name: $0.name) }
  }

  func profileExists(_ id: String) -> Bool { Self.store?.state.profiles[id] != nil }

  func isPrivateProfile(_ id: String) -> Bool { Ids.isIncognitoProfile(id) }

  func engineProfile(_ id: String) -> String { Self.store?.state.engineProfile(id) ?? id }

  func askImportAsNewProfile() async -> Bool? {
    #if DEBUG
    let environment = ProcessInfo.processInfo.environment
    if !(environment["SOLARA_DATA_DIR"] ?? "").isEmpty, environment["SOLARA_IMPORT_TEST_PROMPT"] == "abort" { return nil }
    #endif
    guard let window = Self.importWindow() else { return nil }
    let alert = NSAlert()
    alert.messageText = "Import as new profile?"
    alert.informativeText = "Import this data as a new profile to avoid data loss. If you replace a profile, your passwords, cookies, and payment info will be replaced, while your bookmarks and history will be combined."
    alert.addButton(withTitle: "Import as new profile")
    alert.addButton(withTitle: "Replace this profile")
    openAlert = (alert, window)
    let response = await alert.beginSheetModal(for: window)
    if openAlert?.alert === alert { openAlert = nil }
    switch response {
    case .alertFirstButtonReturn: return true
    case .alertSecondButtonReturn: return false
    default: return nil
    }
  }

  func dismissImportAsNewProfile() {
    guard let open = openAlert else { return }
    openAlert = nil
    open.window.endSheet(open.alert.window, returnCode: .abort)
  }

  func createProfile(name: String, color: String?, icon: String?, shareWith: String?) -> String? {
    guard let store = SettingsDirectWrites.store else { return nil }
    let args = Self.profilePayload(name: name, color: color, icon: icon, shareWith: shareWith)
    return SettingsDirectWrites.write(store, Command("createProfile", [args]))?.result?.string
  }

  func publish(_ progress: ImportProgressUpdate) {
    ImportProgressFeed.shared.publish(progress)
  }

  func log(_ line: String) { NSLog("%@", line) }

  static func importWindow() -> NSWindow? {
    NativeImportWindow.hosting?.viewIfLoaded?.window ?? NSApp.windows.first { $0.contentViewController is ImportHostingController }
  }
}

@MainActor
private final class ImportProgressFeed {
  static let shared = ImportProgressFeed()
  private var listeners: [UUID: AsyncStream<ImportProgressUpdate>.Continuation] = [:]

  func stream() -> AsyncStream<ImportProgressUpdate> {
    AsyncStream { continuation in
      let id = UUID()
      listeners[id] = continuation
      continuation.onTermination = { _ in Task { @MainActor in self.listeners[id] = nil } }
    }
  }

  func publish(_ progress: ImportProgressUpdate) {
    for continuation in listeners.values { continuation.yield(progress) }
  }
}
