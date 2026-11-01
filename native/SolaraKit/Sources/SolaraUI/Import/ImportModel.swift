import Foundation
import Observation

public enum ImportStep: String, Sendable {
  case loading
  case choose
  case profiles
  case safari
  case access
  case unlock
  case dia
  case progress
  case done
}

public struct ImportExtensionsFound: Sendable, Equatable {
  public var profileId: String
  public var list: [ImportedExtension]
  public var opened: Bool

  public static let none = ImportExtensionsFound(profileId: "", list: [], opened: false)
}

@MainActor
@Observable
public final class ImportModel {
  public static let diaNotShared = "Custom tab names, colours, spaces and folders stay in Dia: its AppleScript doesn't share them."

  @ObservationIgnored public let services: ImportServices
  @ObservationIgnored public var doneDelay: Duration = .milliseconds(700)
  @ObservationIgnored public var diaPollInterval: Duration = .milliseconds(1500)
  @ObservationIgnored private var listeners: [Task<Void, Never>] = []
  public let appName: String

  public internal(set) var step: ImportStep = .loading
  public internal(set) var available = true
  public internal(set) var browsers: [ImportBrowser] = []
  public internal(set) var source: ImportBrowser?
  public var sourceProfiles: [String] = []
  public var spaces: [String] = []
  public var kinds: Set<ImportKind> = []
  public var target = ""
  public internal(set) var targets: [ImportTarget] = []
  public internal(set) var status: [ImportKind: ImportStatus] = [:]
  public internal(set) var failures: [ImportFailure] = []
  public internal(set) var counts = ImportCounts()
  public internal(set) var preparing = 1
  public internal(set) var error: String?
  public internal(set) var unlocking = false
  public internal(set) var fullDiskAccess = false
  public var safariCookies = true
  public internal(set) var notes: [String] = []
  public internal(set) var extensions = ImportExtensionsFound.none
  public internal(set) var arcHolders = 0
  public internal(set) var onboarding = false
  public internal(set) var diaStatus: DiaStatus = .checking
  public internal(set) var dia: [DiaProfileSummary]?
  public internal(set) var asking = false
  public internal(set) var runId: String?

  public init(services: ImportServices, appName: String) {
    self.services = services
    self.appName = appName
  }

  public func start() async {
    listen()
    let opening = await services.open()
    available = opening.available
    targets = opening.targets
    target = opening.defaultTarget
    guard opening.available else { return step = .choose }
    guard let list = await services.listBrowsers() else { return step = .choose }
    browsers = list
    let first = list.first { $0.id == opening.preferredSource }
      ?? list.first { !$0.needsFullDiskAccess && !$0.requiresExport && $0.family != .automation }
      ?? list.first
    if let first { choose(first) }
    step = .choose
  }

  func listen() {
    guard listeners.isEmpty else { return }
    let progress = services.progressUpdates()
    let targetList = services.targetUpdates()
    listeners = [
      Task { [weak self] in
        for await update in progress {
          guard let self else { return }
          self.take(update)
        }
      },
      Task { [weak self] in
        for await list in targetList {
          guard let self else { return }
          self.targets = list
        }
      },
    ]
  }

  public func dispose() {
    listeners.forEach { $0.cancel() }
    listeners = []
    runId = nil
    services.dispose()
  }

  func take(_ update: ImportProgressUpdate) {
    guard update.runId == runId, step == .progress else { return }
    preparing = update.preparing
    status = update.status
  }

  public func choose(_ browser: ImportBrowser) {
    source = browser
    let defaults = browser.profiles.filter(\.isDefault)
    sourceProfiles = (defaults.isEmpty ? Array(browser.profiles.prefix(1)) : defaults).map(\.id)
    let spaceProfiles = browser.sidebar == .arc || defaults.isEmpty ? browser.profiles : defaults
    spaces = spaceProfiles.flatMap(\.spaces).map(\.id)
    let offered: [ImportKind] = browser.requiresExport
      ? [.bookmarks, .history, .passwords]
      : browser.family == .automation ? [.tabs, .pinnedTabs] : browser.profiles.flatMap(\.available)
    kinds = Set(offered)
    if browser.family == .safari {
      let id = browser.id
      Task {
        let granted = await services.safariHasFullDiskAccess()
        if source?.id == id { fullDiskAccess = granted }
      }
    }
    dia = nil
    extensions = .none
    notes = []
    error = nil
  }

  public var allSpaces: [ImportSpace] { (source?.profiles ?? []).flatMap(\.spaces) }
  public var bySpaces: Bool { source?.sidebar != nil }
  public var spaceless: [ImportSourceProfile] { (source?.profiles ?? []).filter { $0.spaces.isEmpty } }
  public var isDiaTabs: Bool { source?.family == .automation }

  public var offeredKinds: [ImportKind] {
    guard let source else { return [] }
    if isDiaTabs { return ImportKind.allCases.filter { $0 == .tabs || $0 == .pinnedTabs } }
    return ImportKind.allCases.filter { kind in
      source.profiles.contains { $0.available.contains(kind) } && kind != .spaces && kind != .pinnedTabs
    }
  }

  public func label(_ kind: ImportKind) -> String {
    if kind == .tabs && bySpaces { return "Spaces and tabs" }
    if kind == .tabs && isDiaTabs { return "Open tabs" }
    if kind == .favorites && source?.sidebar == .zen { return "Essentials" }
    return kind.title
  }

  public func setKind(_ kind: ImportKind, _ on: Bool) {
    if on { kinds.insert(kind) } else { kinds.remove(kind) }
  }

  public var showsKinds: Bool {
    guard let source else { return false }
    return !source.requiresExport && !source.needsFullDiskAccess
  }

  public var canContinueChoose: Bool {
    guard let source else { return false }
    return source.requiresExport || source.needsFullDiskAccess || !kinds.isEmpty
  }

  public var canContinueProfiles: Bool {
    guard let source else { return false }
    if bySpaces {
      return !spaces.isEmpty || (source.sidebar == .zen && spaceless.contains { sourceProfiles.contains($0.id) })
    }
    return !sourceProfiles.isEmpty
  }

  public func toggleSpace(_ id: String, _ on: Bool) {
    if on { spaces.append(id) } else { spaces.removeAll { $0 == id } }
  }

  public func toggleSourceProfile(_ id: String, _ on: Bool) {
    if on { sourceProfiles.append(id) } else { sourceProfiles.removeAll { $0 == id } }
  }

  public static func detail(_ browser: ImportBrowser) -> String {
    let spaces = browser.profiles.reduce(0) { $0 + $1.spaces.count }
    if browser.needsFullDiskAccess { return "Needs Full Disk Access" }
    if browser.family == .automation { return "Asks Dia while it's open" }
    if browser.requiresExport { return "Direct or from an exported .zip" }
    if browser.sidebar != nil && spaces > 0 { return importPlural(spaces, "space") }
    if browser.profiles.count > 1 { return importPlural(browser.profiles.count, "profile") }
    return ""
  }

  public func goBack(to step: ImportStep) {
    self.step = step
  }

  public var unlockBackStep: ImportStep {
    (source?.profiles.count ?? 0) > 1 || bySpaces ? .profiles : .choose
  }

  public func next() async {
    guard let source else { return }
    error = nil
    if step == .choose && isDiaTabs {
      diaStatus = .checking
      step = .dia
      return await refreshDia()
    }
    if step == .profiles && isDiaTabs && dia != nil { return await runDia(sourceProfiles, kinds) }
    if step == .choose {
      if source.needsFullDiskAccess { return step = .access }
      if source.requiresExport { return step = .safari }
      if source.profiles.count > 1 || (bySpaces && allSpaces.count > 1) { return step = .profiles }
    }
    let encryptedTabs = kinds.contains(.tabs) && source.profiles.contains { sourceProfiles.contains($0.id) && $0.tabsNeedKey }
    if (step == .choose || step == .profiles) && (encryptedTabs || ImportKind.encrypted.contains { kinds.contains($0) }) && source.needsKeychain && available {
      if !(await services.isBrowserUnlocked(source.id)) { return step = .unlock }
    }
    await run(kinds)
  }

  public func unlock() async {
    guard available, let source else { return }
    unlocking = true
    let unlocked = await services.unlockBrowser(source.id)
    unlocking = false
    if unlocked {
      await run(kinds)
    } else {
      error = "macOS didn't allow access to \(source.name)'s keychain item. Try again, or skip the encrypted data."
    }
  }

  public func skipEncrypted() async {
    var without = kinds
    without.remove(.passwords)
    without.remove(.cookies)
    kinds = without
    await run(without, withoutKey: true)
  }

  func run(_ wanted: Set<ImportKind>, withoutKey: Bool = false) async {
    guard available, let source else { return }
    let id = UUID().uuidString
    runId = id
    status = [:]
    let selectedCount = source.profiles.filter { p in sourceProfiles.contains(p.id) || (bySpaces && p.spaces.contains { spaces.contains($0.id) }) }.count
    preparing = bySpaces ? max(1, spaces.count) : selectedCount
    step = .progress
    let request = ImportRunRequest(
      runId: id,
      browserId: source.id,
      profileIds: sourceProfiles,
      spaceIds: spaces,
      kinds: ImportKind.allCases.filter { wanted.contains($0) },
      target: target,
      withoutKey: withoutKey
    )
    let outcome = await services.run(request)
    guard runId == id, !outcome.cancelled else { return }
    extensions = ImportExtensionsFound(profileId: outcome.extensionsProfile, list: outcome.extensions, opened: false)
    notes = outcome.notes
    status = outcome.status
    failures = outcome.failures
    counts = outcome.counts
    await finish(id, delayed: true)
  }

  func finish(_ id: String?, delayed: Bool) async {
    let started = ContinuousClock.now
    let count = await services.arcHolderCount()
    let onboardingNow = await services.isOnboarding()
    if delayed { try? await Task.sleep(until: started + doneDelay) }
    guard runId == id else { return }
    arcHolders = count
    onboarding = onboardingNow
    step = .done
  }

  public func refreshDia() async {
    guard available else { return }
    let next = await services.diaAutomationStatus()
    diaStatus = next
    if next == .granted { await readDia() }
  }

  public func allowDia() async {
    guard available else { return }
    asking = true
    let next = await services.requestDiaAutomation()
    asking = false
    diaStatus = next
    if next == .granted { await readDia() }
  }

  public func openDia() async {
    guard available else { return }
    if !(await services.openDia()) { error = "Couldn't open Dia. Open it yourself, then click Check Again." }
    await refreshDia()
  }

  public func readDia() async {
    guard available else { return }
    error = nil
    diaStatus = .reading
    switch await services.readDiaTabs() {
    case let .failed(code, message):
      diaStatus = code == "notRunning" ? .notRunning : code == "locked" ? .denied : .granted
      if code != "notRunning" && code != "locked" { error = "\(message). Try again." }
    case let .read(profiles, windowCount):
      diaStatus = .granted
      await takeDiaResult(profiles, windowCount: windowCount)
    }
  }

  func takeDiaResult(_ profiles: [DiaProfileSummary], windowCount: Int) async {
    dia = profiles
    guard let first = profiles.first else {
      error = windowCount > 0 ? "Dia has no open or pinned web pages to import." : "Dia has no open windows. Open one, then try again."
      return
    }
    source?.profiles = profiles.enumerated().map { index, p in
      ImportSourceProfile(id: p.id, name: p.name, isDefault: index == 0, available: [.tabs, .pinnedTabs])
    }
    sourceProfiles = [first.id]
    if profiles.count > 1 {
      step = .profiles
    } else {
      await runDia([first.id], kinds)
    }
  }

  public func diaSummary(_ profileId: String) -> String? {
    guard let p = dia?.first(where: { $0.id == profileId }) else { return nil }
    return "\(importPlural(p.pinnedCount, "pinned tab")) · \(importPlural(p.tabCount, "open tab"))"
  }

  func runDia(_ ids: [String], _ wanted: Set<ImportKind>) async {
    let order = ImportKind.allCases.filter { ($0 == .tabs || $0 == .pinnedTabs) && wanted.contains($0) }
    let id = UUID().uuidString
    runId = id
    status = Dictionary(uniqueKeysWithValues: order.map { ($0, ImportStatus.active) })
    preparing = (dia ?? []).filter { ids.contains($0.id) }.count
    step = .progress
    let outcome = await services.runDia(profileIds: ids, target: target, pinned: wanted.contains(.pinnedTabs), open: wanted.contains(.tabs))
    guard runId == id else { return }
    status = outcome.status
    failures = outcome.failures
    counts = outcome.counts
    notes = outcome.notes
    await finish(id, delayed: true)
  }

  public func importSafari(path: String) async {
    guard available else { return }
    error = nil
    let id = UUID().uuidString
    runId = id
    status = [.bookmarks: .active, .history: .active, .passwords: .active, .autofill: .active]
    preparing = 1
    step = .progress
    let outcome = await services.importSafariExport(path: path, target: target)
    guard runId == id else { return }
    switch outcome {
    case let .imported(imported, failed):
      status = [.bookmarks: .done, .history: .done, .passwords: .done, .autofill: failed.contains(.autofill) ? .failed : .done]
      counts = imported
      failures = failed.map { ImportFailure(kind: $0) }
      await finish(id, delayed: true)
    case .cancelled:
      return
    case let .failed(code):
      step = .safari
      error = code == "unsupported" ? "Please select a folder or zip file." : "The selected file is invalid. Please try again."
    }
  }

  public func importSafariDirect() async {
    guard available else { return }
    error = nil
    let cookies = safariCookies
    let id = UUID().uuidString
    runId = id
    status = [.bookmarks: .active, .history: .active, .tabs: .active]
    if cookies { status[.cookies] = .active }
    preparing = 1
    step = .progress
    let outcome = await services.importSafariDirect(target: target, cookies: cookies)
    guard runId == id else { return }
    switch outcome {
    case let .imported(imported, failed):
      status = [.bookmarks: .done, .history: .done, .tabs: .done]
      if cookies { status[.cookies] = failed.contains(.cookies) ? .failed : .done }
      counts = imported
      failures = failed.map { ImportFailure(kind: $0) }
      await finish(id, delayed: true)
    case .cancelled:
      return
    case let .failed(code):
      step = .safari
      error = code == "locked"
        ? "\(appName) still doesn't have Full Disk Access. Grant it above, or use the export file below."
        : "Couldn't read Safari's data. Try the export file below."
      fullDiskAccess = await services.safariHasFullDiskAccess()
    }
  }

  public func chooseSafariExport() async {
    guard available, let path = await services.chooseImportFile(.safariExport) else { return }
    await importSafari(path: path)
  }

  public func importHTML() async {
    guard available else { return }
    switch await services.importBookmarksHTML(target: target) {
    case let .imported(imported, _):
      counts = ImportCounts(bookmarks: imported.bookmarks)
      failures = []
      status = [.bookmarks: .done]
      source = nil
      runId = nil
      await finish(nil, delayed: false)
    case .cancelled:
      return
    case .failed:
      error = "The selected file is invalid. Please try again."
    }
  }

  public func recheckAccess() async {
    guard available else { return }
    if step == .safari { return fullDiskAccess = await services.safariHasFullDiskAccess() }
    guard let list = await services.listBrowsers() else { return }
    browsers = list
    if let updated = list.first(where: { $0.id == source?.id }), !updated.needsFullDiskAccess {
      choose(updated)
      step = .choose
    }
  }

  public func appBecameActive() async {
    if (step == .safari && !fullDiskAccess) || step == .access { await recheckAccess() }
    if step == .dia && (diaStatus == .denied || diaStatus == .notRunning) { await refreshDia() }
  }

  public var pollsDia: Bool { step == .dia && diaStatus == .notRunning }

  public func pollDia() async {
    while pollsDia {
      try? await Task.sleep(for: diaPollInterval)
      guard !Task.isCancelled, pollsDia else { return }
      await Task { await self.refreshDia() }.value
    }
  }

  public func openInWebStore() {
    services.openInWebStore(profileId: extensions.profileId.isEmpty ? target : extensions.profileId, urls: extensions.list.map(\.webStoreUrl))
    extensions.opened = true
  }

  public func restoreArcFolders() async {
    arcHolders = await services.restoreArcFolders()
  }

  public func close() {
    services.close()
  }

  public func cancelProgress() {
    services.cancel()
    close()
  }

  public func tryAgain() {
    step = .choose
  }

  public var progressTitle: String {
    "Importing from \(isDiaTabs ? "Dia" : (source?.name ?? "file"))"
  }

  public var progressSubtitle: String {
    preparing > 1 ? "Preparing \(preparing) profiles" : "Preparing your profile"
  }

  public var progressRows: [(kind: ImportKind, status: ImportStatus)] {
    ImportKind.allCases.compactMap { kind in status[kind].map { (kind, $0) } }
  }

  public var summary: [String] {
    var parts: [String] = []
    if counts.bookmarks > 0 { parts.append(importPlural(counts.bookmarks, "bookmark")) }
    if counts.history > 0 { parts.append(importPlural(counts.history, "history item")) }
    if counts.passwords > 0 { parts.append(importPlural(counts.passwords, "password")) }
    if counts.cookies > 0 { parts.append(importPlural(counts.cookies, "cookie")) }
    if counts.addresses > 0 { parts.append("\(counts.addresses) \(counts.addresses == 1 ? "address" : "addresses")") }
    if counts.cards > 0 { parts.append(importPlural(counts.cards, "card")) }
    if counts.tabs > 0 { parts.append(importPlural(counts.tabs, "tab")) }
    return parts
  }

  public var importedLine: String? {
    summary.isEmpty ? nil : "Imported \(summary.joined(separator: ", "))."
  }

  public static func failureLine(_ failure: ImportFailure) -> String {
    failure.profiles.isEmpty
      ? "\(failure.kind.title) import failed"
      : "\(failure.kind.title) import failed for profiles \(failure.profiles.joined(separator: ", "))"
  }

  public var extensionsIntro: String {
    "\(source?.name ?? "Your browser") has \(importPlural(extensions.list.count, "extension")) from the Chrome Web Store. Add the ones you want there:"
  }

  public var extensionsOpenedLine: String {
    "\(extensions.list.count == 1 ? "Its page is" : "Their pages are") open in your sidebar\(onboarding ? ", ready when you finish setting up" : ""). Click Add to \(appName) on each one you want."
  }

  public var openExtensionsTitle: String {
    extensions.list.count == 1 ? "Open in Chrome Web Store" : "Open \(extensions.list.count) in Chrome Web Store"
  }

  public var keychainItem: String {
    guard let source else { return "" }
    return source.keychainService ?? "\(source.name) Safe Storage"
  }
}
