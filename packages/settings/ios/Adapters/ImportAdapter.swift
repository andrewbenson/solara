import AppKit
import Foundation
import SolaraCore
import SolaraEngine
import SolaraImportAdapter
import SolaraModel
import SolaraStore
import SolaraUI

@MainActor
final class ImportAdapter: ImportServices, ImportScriptPath {
  static let progressTopic = "import.progress"
  static let targetsTopic = "import.targets"
  private var session = 0
  private var swiftSession = 0
  private let direct = SettingsDirectWrites.store != nil
  private var service: ImportService? { direct ? ImportService.shared : nil }
  private var diaRoute: ImportRoute = .js
  private var diaLaunched = Date.distantPast

  func open() async -> ImportOpening {
    if direct { swiftSession = ImportRuns.shared.open() }
    let opened = await SettingsAdapters.js("import.open") as? [String: Any] ?? [:]
    session = opened.int("session") ?? 0
    if direct, let store = SettingsDirectWrites.store {
      let state = store.state
      return ImportOpening(
        available: (opened.bool("available") ?? false) && ImportRuns.shared.admitted(swiftSession),
        preferredSource: ImportPreferredSource.shared.take(),
        targets: ImportTargets.list(state).map { SolaraUI.ImportTarget(id: $0.id, name: $0.name) },
        defaultTarget: ImportTargets.defaultTarget(state)
      )
    }
    return ImportOpening(
      available: opened.bool("available") ?? false,
      preferredSource: opened.string("preferred"),
      targets: Self.targets(opened["targets"]),
      defaultTarget: opened.string("defaultTarget") ?? ""
    )
  }

  func listBrowsers() async -> [ImportBrowser]? {
    guard let service else {
      guard let list = await SettingsAdapters.js("import.listBrowsers") as? [[String: Any]] else { return nil }
      return list.compactMap(Self.browser)
    }
    guard let json = await service.browsersJSON() else { return nil }
    guard let list = await SettingsJS.shared.adoptBrowsers(json) else { return nil }
    let browsers = list.compactMap(Self.browser)
    ImportRuns.shared.browsers = browsers
    return browsers
  }

  func targetUpdates() -> AsyncStream<[ImportTarget]> {
    guard direct, let store = SettingsDirectWrites.store else { return SettingsJS.shared.stream(Self.targetsTopic) { Self.targets($0) } }
    return AsyncStream { continuation in
      let feed = ImportTargetsFeed(store.state)
      let listener = store.subscribe { commit in
        guard let list = feed.next(commit.state) else { return }
        continuation.yield(list.map { SolaraUI.ImportTarget(id: $0.id, name: $0.name) })
      }
      continuation.onTermination = { _ in store.unsubscribe(listener) }
    }
  }

  func progressUpdates() -> AsyncStream<ImportProgressUpdate> {
    SettingsJS.shared.stream(Self.progressTopic) { value in
      guard let dict = value as? [String: Any], let runId = dict.string("runId") else { return nil }
      return ImportProgressUpdate(runId: runId, preparing: dict.int("preparing") ?? 1, status: Self.statuses(dict["status"]))
    }
  }

  func safariHasFullDiskAccess() async -> Bool {
    guard let service else { return await SettingsAdapters.js("import.safariFullDiskAccess") as? Bool ?? false }
    return await service.safariHasFullDiskAccess()
  }

  func isBrowserUnlocked(_ browserId: String) async -> Bool {
    guard let service else { return await SettingsAdapters.js("import.isUnlocked", browserId) as? Bool ?? false }
    return service.isUnlocked(browserId)
  }

  func unlockBrowser(_ browserId: String) async -> Bool {
    guard let service else { return await SettingsAdapters.js("import.unlock", browserId) as? Bool ?? false }
    return await service.unlock(browserId)
  }

  func run(_ request: ImportRunRequest) async -> ImportRunOutcome {
    guard direct else { return await scriptRun(request, session: session) }
    return await ImportRuns.shared.run(request, session: swiftSession, engine: ImportRunEngine.shared, script: self, scriptSession: session)
  }

  func scriptRun(_ request: ImportRunRequest, session: Int) async -> ImportRunOutcome {
    let arg: [String: Any] = [
      "runId": request.runId,
      "browserId": request.browserId,
      "profileIds": request.profileIds,
      "spaceIds": request.spaceIds,
      "kinds": request.kinds.map(\.rawValue),
      "target": request.target,
      "withoutKey": request.withoutKey,
    ]
    return Self.runOutcome(await SettingsAdapters.js("import.run", arg, session), kinds: request.kinds)
  }

  static func runOutcome(_ value: Any?, kinds: [SolaraUI.ImportKind]) -> ImportRunOutcome {
    guard let result = value as? [String: Any] else {
      return ImportRunOutcome(
        status: Dictionary(uniqueKeysWithValues: kinds.map { ($0, ImportStatus.failed) }),
        failures: kinds.map { ImportFailure(kind: $0) },
        notes: ["Import couldn't finish. Try again."]
      )
    }
    if result.bool("cancelled") == true { return .cancelledRun }
    let extensions = result.dict("extensions") ?? [:]
    return ImportRunOutcome(
      status: Self.statuses(result["status"]),
      failures: result.list("failures").compactMap { f in
        f.string("kind").flatMap(SolaraUI.ImportKind.init(rawValue:)).map { ImportFailure(kind: $0, profiles: f.strings("profiles")) }
      },
      counts: Self.counts(result.dict("counts")),
      notes: result.strings("notes"),
      extensionsProfile: extensions.string("profileId") ?? "",
      extensions: extensions.list("list").compactMap { e in
        guard let id = e.string("id") else { return nil }
        return SolaraUI.ImportedExtension(id: id, name: e.string("name") ?? id, webStoreUrl: e.string("webStoreUrl") ?? "")
      }
    )
  }

  func cancel() {
    guard direct else { return scriptCancel() }
    ImportRuns.shared.cancel(engine: ImportRunEngine.shared, script: self)
  }

  func dispose() {
    guard direct else { return scriptDispose() }
    ImportRuns.shared.dispose(engine: ImportRunEngine.shared, script: self)
  }

  func scriptCancel() { SettingsJS.shared.fire("import.cancel") }

  func scriptDispose() { SettingsJS.shared.fire("import.dispose") }

  #if DEBUG
  static var devVaultCount: Int { ImportService.shared.devVaultCount }
  #endif

  static func drainSwift() async {
    guard SettingsDirectWrites.store != nil else { return }
    await ImportRuns.shared.drain(engine: ImportRunEngine.shared)
  }

  func diaAutomationStatus() async -> DiaStatus {
    guard let service else { return Self.dia(await SettingsAdapters.js("import.diaStatus")) }
    return Self.dia(await service.diaStatus(ask: false))
  }

  func requestDiaAutomation() async -> DiaStatus {
    guard let service else { return Self.dia(await SettingsAdapters.js("import.requestDia")) }
    return Self.dia(await service.diaStatus(ask: ProcessInfo.processInfo.environment["SOLARA_BACKGROUND"] != "1"))
  }

  func openDia() async -> Bool {
    guard direct, ImportRuns.shared.diaRoute(engine: ImportRunEngine.shared) == .swift else { return await SettingsAdapters.js("import.openDia") as? Bool ?? false }
    diaLaunched = Date()
    return await ImportService.openDia()
  }

  func readDiaTabs() async -> DiaRead {
    diaRoute = direct ? ImportRuns.shared.diaRoute(engine: ImportRunEngine.shared) : .js
    guard diaRoute == .js else { return await readDiaTabsDirectly() }
    guard let result = await SettingsAdapters.js("import.readDia") as? [String: Any] else {
      return .failed(code: "unreadable", message: "Couldn't read Dia's tabs")
    }
    if let error = result.dict("error") {
      return .failed(code: error.string("code") ?? "unreadable", message: error.string("message") ?? "Couldn't read Dia's tabs")
    }
    let profiles = result.list("profiles").compactMap { p -> DiaProfileSummary? in
      guard let id = p.string("id") else { return nil }
      return DiaProfileSummary(id: id, name: p.string("name") ?? id, pinnedCount: p.int("pinned") ?? 0, tabCount: p.int("tabs") ?? 0)
    }
    return .read(profiles: profiles, windowCount: result.int("windowCount") ?? 0)
  }

  private func readDiaTabsDirectly() async -> DiaRead {
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
    if diaRoute == .swift {
      return await ImportRuns.shared.importDia(profileIds: profileIds, target: target, pinned: pinned, open: open, session: swiftSession, engine: ImportRunEngine.shared)
    }
    let kinds: [SolaraUI.ImportKind] = (open ? [.tabs] : []) + (pinned ? [.pinnedTabs] : [])
    return Self.runOutcome(await SettingsAdapters.js("import.runDia", ["profileIds": profileIds, "target": target, "pinned": pinned, "open": open], session), kinds: kinds)
  }

  func importSafariExport(path: String, target: String) async -> ImportFileOutcome {
    guard direct else { return await scriptSafari(.export(path: path), target: target, cookies: false, session: session) }
    return await ImportRuns.shared.importSafari(.export(path: path), target: target, cookies: false, session: swiftSession, engine: ImportRunEngine.shared, script: self, scriptSession: session)
  }

  func importSafariDirect(target: String, cookies: Bool) async -> ImportFileOutcome {
    guard direct else { return await scriptSafari(.direct, target: target, cookies: cookies, session: session) }
    return await ImportRuns.shared.importSafari(.direct, target: target, cookies: cookies, session: swiftSession, engine: ImportRunEngine.shared, script: self, scriptSession: session)
  }

  func scriptSafari(_ source: ImportSafariSource, target: String, cookies: Bool, session: Int) async -> ImportFileOutcome {
    switch source {
    case .export(let path): Self.fileOutcome(await SettingsAdapters.js("import.safariExport", path, target, session))
    case .direct: Self.fileOutcome(await SettingsAdapters.js("import.safariDirect", target, cookies, session))
    }
  }

  func importBookmarksHTML(target: String) async -> ImportFileOutcome {
    guard direct else { return await scriptBookmarksHTML(target: target, session: session) }
    return await ImportRuns.shared.importBookmarksFile(target: target, session: swiftSession, engine: ImportRunEngine.shared, script: self, scriptSession: session)
  }

  func scriptBookmarksHTML(target: String, session: Int) async -> ImportFileOutcome {
    Self.fileOutcome(await SettingsAdapters.js("import.bookmarksHtml", target, session))
  }

  func chooseImportFile(_ kind: ImportFileKind) async -> String? {
    guard direct else { return await SettingsAdapters.js("import.chooseFile", kind.rawValue) as? String }
    return await ImportService.chooseFile(kind.rawValue)
  }

  func openFullDiskAccessSettings() {
    guard direct else { return SettingsJS.shared.fire("import.openFullDiskAccessSettings") }
    ImportService.openPrivacySettings("Privacy_AllFiles")
  }

  func openAutomationSettings() {
    guard direct else { return SettingsJS.shared.fire("import.openAutomationSettings") }
    ImportService.openPrivacySettings("Privacy_Automation")
  }

  func openInWebStore(profileId: String, urls: [String]) { SettingsJS.shared.fire("import.openInWebStore", profileId, urls, session) }

  func arcHolderCount() async -> Int { await SettingsAdapters.js("import.arcHolders") as? Int ?? 0 }

  func restoreArcFolders() async -> Int { await SettingsAdapters.js("import.restoreArcFolders", session) as? Int ?? 0 }

  func isOnboarding() async -> Bool { await SettingsAdapters.js("import.onboarding") as? Bool ?? false }

  func close() { SettingsJS.shared.fire("import.close") }

  static func targets(_ value: Any?) -> [ImportTarget] {
    (value as? [[String: Any]] ?? []).compactMap { t in
      guard let id = t.string("id") else { return nil }
      return ImportTarget(id: id, name: t.string("name") ?? id)
    }
  }

  static func statuses(_ value: Any?) -> [SolaraUI.ImportKind: ImportStatus] {
    var out: [SolaraUI.ImportKind: ImportStatus] = [:]
    for (key, raw) in value as? [String: Any] ?? [:] {
      if let kind = SolaraUI.ImportKind(rawValue: key), let status = (raw as? String).flatMap(ImportStatus.init(rawValue:)) { out[kind] = status }
    }
    return out
  }

  static func counts(_ dict: [String: Any]?) -> ImportCounts {
    guard let dict else { return ImportCounts() }
    return ImportCounts(
      bookmarks: dict.int("bookmarks") ?? 0,
      history: dict.int("history") ?? 0,
      tabs: dict.int("tabs") ?? 0,
      passwords: dict.int("passwords") ?? 0,
      cookies: dict.int("cookies") ?? 0,
      addresses: dict.int("addresses") ?? 0,
      cards: dict.int("cards") ?? 0
    )
  }

  static func fileOutcome(_ value: Any?) -> ImportFileOutcome {
    guard let dict = value as? [String: Any] else { return .failed(code: "unreadable") }
    if dict.bool("cancelled") == true { return .cancelled }
    if let code = dict.string("error") { return .failed(code: code) }
    let failed = dict.strings("failed").compactMap(SolaraUI.ImportKind.init(rawValue:))
    return .imported(counts(dict.dict("counts")), failed: failed)
  }

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

  var safeMode: Bool { SolaraCoreHost.safeMode || SettingsDirectWrites.store == nil }

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
    if env["SOLARA_DATA_DIR"] != nil, let ms = env["SOLARA_IMPORT_TEST_ADOPT_TIMEOUT_MS"].flatMap(Double.init) { return ms / 1000 }
    #endif
    return deadline
  }

  nonisolated static func historyPayload(_ rows: [ImportHistoryRow]) -> [[String: Any]] {
    rows.map { ["url": $0.url, "title": $0.title, "visits": $0.visits, "lastVisit": $0.lastVisit] }
  }

  func adoptHistory(profile: String, rows: [ImportHistoryRow], deadline: TimeInterval) async -> Int? {
    guard let reply = try? await SettingsJS.shared.invoke("import.adoptHistory", [profile, Self.historyPayload(rows)], timeout: Self.adoptTimeout(deadline)) else { return nil }
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
    let payload: [[String: Any]] = favicons.map { ["page": $0.page, "icon": $0.icon, "png": $0.png] }
    _ = try? await SettingsJS.shared.invoke("import.adoptFavicons", [profile, payload], timeout: 10)
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
    guard let store = SettingsDirectWrites.store else { return [] }
    return ImportTargets.list(store.state).map { SolaraUI.ImportTarget(id: $0.id, name: $0.name) }
  }

  func profileExists(_ id: String) -> Bool { SettingsDirectWrites.store?.state.profiles[id] != nil }

  func isPrivateProfile(_ id: String) -> Bool { Ids.isIncognitoProfile(id) }

  func engineProfile(_ id: String) -> String { SettingsDirectWrites.store?.state.engineProfile(id) ?? id }

  func askImportAsNewProfile() async -> Bool? {
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
    let body: [String: Any] = [
      "runId": progress.runId,
      "preparing": progress.preparing,
      "status": Dictionary(uniqueKeysWithValues: progress.status.map { ($0.key.rawValue, $0.value.rawValue) }),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    SettingsJS.shared.publish(ImportAdapter.progressTopic, json: String(decoding: data, as: UTF8.self))
  }

  func log(_ line: String) { NSLog("%@", line) }

  static func importWindow() -> NSWindow? {
    NativeImportWindow.hosting?.viewIfLoaded?.window ?? NSApp.windows.first { $0.contentViewController is ImportHostingController }
  }
}
