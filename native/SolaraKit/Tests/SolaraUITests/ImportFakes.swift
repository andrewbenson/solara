import Foundation
@testable import SolaraUI

@MainActor
final class FakeImportServices: ImportServices {
  var opening = ImportOpening(
    available: true,
    preferredSource: nil,
    targets: [ImportTarget(id: "default", name: "Personal"), ImportTarget(id: "work", name: "Work")],
    defaultTarget: "default"
  )
  var browsers: [ImportBrowser]? = ImportFixtures.browsers
  var fullDiskAccess = false
  var unlocked: Set<String> = []
  var unlockSucceeds = true
  var outcome = ImportRunOutcome(
    status: [.bookmarks: .done, .history: .done],
    counts: ImportCounts(bookmarks: 12, history: 340)
  )
  var holdRun = false
  var diaStatuses: [DiaStatus] = [.granted]
  var diaRead: DiaRead = .read(profiles: ImportFixtures.diaProfiles, windowCount: 2)
  var diaOutcome = ImportRunOutcome(status: [.tabs: .done, .pinnedTabs: .done], counts: ImportCounts(tabs: 9))
  var fileOutcome: ImportFileOutcome = .imported(ImportCounts(bookmarks: 4), failed: [])
  var openDiaSucceeds = true
  var chosenFile: String? = "/Users/owner/Downloads/Safari Export.zip"
  var arcHolders = 0
  var onboarding = false
  var calls: [String] = []
  var requests: [ImportRunRequest] = []
  private var progress: AsyncStream<ImportProgressUpdate>.Continuation?
  private var targets: AsyncStream<[ImportTarget]>.Continuation?
  private var waiting: CheckedContinuation<ImportRunOutcome, Never>?

  func open() async -> ImportOpening { opening }
  func listBrowsers() async -> [ImportBrowser]? { browsers }

  func targetUpdates() -> AsyncStream<[ImportTarget]> {
    let (stream, continuation) = AsyncStream<[ImportTarget]>.makeStream()
    targets = continuation
    return stream
  }

  func progressUpdates() -> AsyncStream<ImportProgressUpdate> {
    let (stream, continuation) = AsyncStream<ImportProgressUpdate>.makeStream()
    progress = continuation
    return stream
  }

  func push(_ update: ImportProgressUpdate) { progress?.yield(update) }
  func push(targets list: [ImportTarget]) { targets?.yield(list) }

  func release(_ outcome: ImportRunOutcome) {
    waiting?.resume(returning: outcome)
    waiting = nil
  }

  func safariHasFullDiskAccess() async -> Bool { fullDiskAccess }
  func isBrowserUnlocked(_ browserId: String) async -> Bool { unlocked.contains(browserId) }

  func unlockBrowser(_ browserId: String) async -> Bool {
    calls.append("unlock \(browserId)")
    if unlockSucceeds { unlocked.insert(browserId) }
    return unlockSucceeds
  }

  func run(_ request: ImportRunRequest) async -> ImportRunOutcome {
    requests.append(request)
    calls.append("run \(request.browserId)")
    if holdRun { return await withCheckedContinuation { waiting = $0 } }
    return outcome
  }

  func cancel() { calls.append("cancel") }
  func dispose() { calls.append("dispose") }

  func diaAutomationStatus() async -> DiaStatus {
    calls.append("diaStatus")
    return diaStatuses.count > 1 ? diaStatuses.removeFirst() : diaStatuses[0]
  }

  func requestDiaAutomation() async -> DiaStatus {
    calls.append("requestDia")
    return .granted
  }

  func openDia() async -> Bool {
    calls.append("openDia")
    return openDiaSucceeds
  }

  func readDiaTabs() async -> DiaRead {
    calls.append("readDia")
    return diaRead
  }

  func runDia(profileIds: [String], target: String, pinned: Bool, open: Bool) async -> ImportRunOutcome {
    calls.append("runDia \(profileIds.joined(separator: ",")) \(target) pinned=\(pinned) open=\(open)")
    return diaOutcome
  }

  func importSafariExport(path: String, target: String) async -> ImportFileOutcome {
    calls.append("safariExport \(path) \(target)")
    return fileOutcome
  }

  func importSafariDirect(target: String, cookies: Bool) async -> ImportFileOutcome {
    calls.append("safariDirect \(target) cookies=\(cookies)")
    return fileOutcome
  }

  func importBookmarksHTML(target: String) async -> ImportFileOutcome {
    calls.append("bookmarksHTML \(target)")
    return fileOutcome
  }

  func chooseImportFile(_ kind: ImportFileKind) async -> String? {
    calls.append("choose \(kind.rawValue)")
    return chosenFile
  }

  func openFullDiskAccessSettings() { calls.append("openFullDiskAccessSettings") }
  func openAutomationSettings() { calls.append("openAutomationSettings") }
  func openInWebStore(profileId: String, urls: [String]) { calls.append("openInWebStore \(profileId) \(urls.count)") }
  func arcHolderCount() async -> Int { arcHolders }

  func restoreArcFolders() async -> Int {
    calls.append("restoreArcFolders")
    arcHolders = 0
    return 0
  }

  func isOnboarding() async -> Bool { onboarding }
  func close() { calls.append("close") }
}

enum ImportFixtures {
  static let chromeKinds: [ImportKind] = [.bookmarks, .history, .passwords, .cookies, .autofill, .tabs]

  static let chrome = ImportBrowser(
    id: "chrome",
    name: "Google Chrome",
    family: .chromium,
    needsKeychain: true,
    keychainService: "Chrome Safe Storage",
    profiles: [
      ImportSourceProfile(id: "Default", name: "Person 1", email: "owner@example.com", color: "#4285F4", isDefault: true, available: chromeKinds, tabsNeedKey: true),
      ImportSourceProfile(id: "Profile 1", name: "Work", color: "#34A853", isDefault: false, available: chromeKinds),
    ]
  )

  static let brave = ImportBrowser(
    id: "brave",
    name: "Brave",
    family: .chromium,
    needsKeychain: true,
    profiles: [ImportSourceProfile(id: "Default", name: "Default", isDefault: true, available: [.bookmarks, .history, .passwords])]
  )

  static let arc = ImportBrowser(
    id: "arc",
    name: "Arc",
    family: .arc,
    needsKeychain: true,
    profiles: [
      ImportSourceProfile(
        id: "Default",
        name: "Default",
        isDefault: true,
        available: [.bookmarks, .history, .passwords, .cookies, .tabs, .spaces, .pinnedTabs, .favorites],
        spaces: [
          ImportSpace(id: "s1", name: "Personal", color: "#FF6B6B", emoji: "🏠", pinnedCount: 8, tabCount: 14),
          ImportSpace(id: "s2", name: "Work", color: "#5B8DEF", pinnedCount: 21, tabCount: 3),
          ImportSpace(id: "s3", name: "", color: nil, pinnedCount: 1, tabCount: 1),
        ]
      ),
    ],
    sidebar: .arc
  )

  static let zen = ImportBrowser(
    id: "zen",
    name: "Zen",
    family: .firefox,
    profiles: [
      ImportSourceProfile(id: "a", name: "Default", isDefault: true, available: [.bookmarks, .history, .tabs, .favorites], spaces: [ImportSpace(id: "z1", name: "Home", pinnedCount: 2, tabCount: 5)]),
      ImportSourceProfile(id: "b", name: "Spare", isDefault: false, available: [.bookmarks, .history]),
    ],
    sidebar: .zen
  )

  static let safari = ImportBrowser(
    id: "safari",
    name: "Safari",
    family: .safari,
    requiresExport: true,
    profiles: [ImportSourceProfile(id: "Default", name: "Default", isDefault: true, available: [.bookmarks, .history, .tabs])]
  )

  static let firefox = ImportBrowser(
    id: "firefox",
    name: "Firefox",
    family: .firefox,
    needsFullDiskAccess: true,
    profiles: [ImportSourceProfile(id: "default-release", name: "default-release", isDefault: true, available: [.bookmarks, .history, .passwords])]
  )

  static let dia = ImportBrowser(id: "dia-tabs", name: "Dia", family: .automation, profiles: [])

  static let browsers: [ImportBrowser] = [chrome, arc, brave, safari, firefox, dia]

  static let diaProfiles = [
    DiaProfileSummary(id: "p1", name: "Personal", pinnedCount: 4, tabCount: 11),
    DiaProfileSummary(id: "p2", name: "Work", pinnedCount: 1, tabCount: 1),
  ]
}
