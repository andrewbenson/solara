import AppKit
import Foundation
import SolaraUI

@MainActor
final class ImportAdapter: ImportServices {
  static let progressTopic = "import.progress"
  static let targetsTopic = "import.targets"
  private var session = 0

  func open() async -> ImportOpening {
    let opened = await SettingsAdapters.js("import.open") as? [String: Any] ?? [:]
    session = opened.int("session") ?? 0
    return ImportOpening(
      available: opened.bool("available") ?? false,
      preferredSource: opened.string("preferred"),
      targets: Self.targets(opened["targets"]),
      defaultTarget: opened.string("defaultTarget") ?? ""
    )
  }

  func listBrowsers() async -> [ImportBrowser]? {
    guard let list = await SettingsAdapters.js("import.listBrowsers") as? [[String: Any]] else { return nil }
    return list.compactMap(Self.browser)
  }

  func targetUpdates() -> AsyncStream<[ImportTarget]> {
    SettingsJS.shared.stream(Self.targetsTopic) { Self.targets($0) }
  }

  func progressUpdates() -> AsyncStream<ImportProgressUpdate> {
    SettingsJS.shared.stream(Self.progressTopic) { value in
      guard let dict = value as? [String: Any], let runId = dict.string("runId") else { return nil }
      return ImportProgressUpdate(runId: runId, preparing: dict.int("preparing") ?? 1, status: Self.statuses(dict["status"]))
    }
  }

  func safariHasFullDiskAccess() async -> Bool { await SettingsAdapters.js("import.safariFullDiskAccess") as? Bool ?? false }

  func isBrowserUnlocked(_ browserId: String) async -> Bool { await SettingsAdapters.js("import.isUnlocked", browserId) as? Bool ?? false }

  func unlockBrowser(_ browserId: String) async -> Bool { await SettingsAdapters.js("import.unlock", browserId) as? Bool ?? false }

  func run(_ request: ImportRunRequest) async -> ImportRunOutcome {
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

  static func runOutcome(_ value: Any?, kinds: [ImportKind]) -> ImportRunOutcome {
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
        f.string("kind").flatMap(ImportKind.init(rawValue:)).map { ImportFailure(kind: $0, profiles: f.strings("profiles")) }
      },
      counts: Self.counts(result.dict("counts")),
      notes: result.strings("notes"),
      extensionsProfile: extensions.string("profileId") ?? "",
      extensions: extensions.list("list").compactMap { e in
        guard let id = e.string("id") else { return nil }
        return ImportedExtension(id: id, name: e.string("name") ?? id, webStoreUrl: e.string("webStoreUrl") ?? "")
      }
    )
  }

  func cancel() { SettingsJS.shared.fire("import.cancel") }

  func dispose() { SettingsJS.shared.fire("import.dispose") }

  func diaAutomationStatus() async -> DiaStatus { Self.dia(await SettingsAdapters.js("import.diaStatus")) }

  func requestDiaAutomation() async -> DiaStatus { Self.dia(await SettingsAdapters.js("import.requestDia")) }

  func openDia() async -> Bool { await SettingsAdapters.js("import.openDia") as? Bool ?? false }

  func readDiaTabs() async -> DiaRead {
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

  func runDia(profileIds: [String], target: String, pinned: Bool, open: Bool) async -> ImportRunOutcome {
    let kinds: [ImportKind] = (open ? [.tabs] : []) + (pinned ? [.pinnedTabs] : [])
    return Self.runOutcome(await SettingsAdapters.js("import.runDia", ["profileIds": profileIds, "target": target, "pinned": pinned, "open": open], session), kinds: kinds)
  }

  func importSafariExport(path: String, target: String) async -> ImportFileOutcome {
    Self.fileOutcome(await SettingsAdapters.js("import.safariExport", path, target, session))
  }

  func importSafariDirect(target: String, cookies: Bool) async -> ImportFileOutcome {
    Self.fileOutcome(await SettingsAdapters.js("import.safariDirect", target, cookies, session))
  }

  func importBookmarksHTML(target: String) async -> ImportFileOutcome {
    Self.fileOutcome(await SettingsAdapters.js("import.bookmarksHtml", target, session))
  }

  func chooseImportFile(_ kind: ImportFileKind) async -> String? {
    await SettingsAdapters.js("import.chooseFile", kind.rawValue) as? String
  }

  func openFullDiskAccessSettings() { SettingsJS.shared.fire("import.openFullDiskAccessSettings") }

  func openAutomationSettings() { SettingsJS.shared.fire("import.openAutomationSettings") }

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

  static func statuses(_ value: Any?) -> [ImportKind: ImportStatus] {
    var out: [ImportKind: ImportStatus] = [:]
    for (key, raw) in value as? [String: Any] ?? [:] {
      if let kind = ImportKind(rawValue: key), let status = (raw as? String).flatMap(ImportStatus.init(rawValue:)) { out[kind] = status }
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
    let failed = dict.strings("failed").compactMap(ImportKind.init(rawValue:))
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
      available: p.strings("available").compactMap(ImportKind.init(rawValue:)),
      spaces: p.list("spaces").compactMap { s in
        guard let id = s.string("id") else { return nil }
        return ImportSpace(id: id, name: s.string("name") ?? "", color: s.string("color"), emoji: s.string("emoji"), pinnedCount: s.int("pinnedCount") ?? 0, tabCount: s.int("tabCount") ?? 0)
      },
      tabsNeedKey: p.bool("tabsNeedKey") ?? false
    )
  }
}
