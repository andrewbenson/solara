import Foundation
import SolaraEngine
import SolaraModel
import Testing
@testable import SolaraUI

@MainActor
final class FakeImportEngine: ImportEngine {
  var safeMode = false
  var unlocked: Set<String> = []
  var reads: [String: Result<ImportRead, ImportReadFailure>] = [:]
  var holdRead = false
  var cancelLeavesReadHeld = false
  private var heldRead: CheckedContinuation<Void, Never>?
  var readStarted: (() -> Void)?
  var profileList: [ImportTarget] = [ImportTarget(id: "default", name: "Personal"), ImportTarget(id: "work", name: "Work")]
  var askAnswer: Bool? = true
  var beforeAnswer: (() -> Void)?
  var onSave: ((Int) -> Void)?
  var nativeResult: ImportNativeWritten? = ImportNativeWritten(cookies: 5, addresses: 1, cards: 1, cookiesFailed: false, autofillFailed: false)
  var listed: [ImportedExtension] = [ImportedExtension(id: "ext", name: "Ext", webStoreUrl: "https://chromewebstore.google.com/detail/ext")]
  var calls: [String] = []
  var saved: [(String, String, String)] = []
  var discarded: [String] = []
  var written: [(String, String, [String])] = []
  var published: [ImportProgressUpdate] = []
  var logs: [String] = []
  var forgets = 0
  var created: [(String, String?)] = []
  var createFails = false
  var parents: ImportBookmarkParents? = ImportBookmarkParents(bar: "bar", other: "other", barEmpty: true, otherEmpty: false)
  var rootsAppearOnSubmit = false
  var bookmarkSubmits: [[BookmarkMutation]] = []
  var conditionFailures = 0
  var bookmarkFails = false
  var bookmarkReports = 0
  var onBookmarkSubmit: (() -> Void)?
  var workspaces: [(String, [JSONValue])] = []
  var workspaceResult: Int? = 2
  var steps: [String] = []
  var adoptHistoryAnswer: Int? = nil
  var adoptDeadlines: [TimeInterval] = []
  var adoptCutoffs: [Double] = []
  var onHistoryWrite: (() -> Void)?
  var adoptHistoryTimesOut = false
  var onAdoptHistory: (() -> Void)?
  var historyAdoptions: [(String, [ImportHistoryRow])] = []
  var historyWrites: [(String, [ImportHistoryRow])] = []
  var holdHistoryWrite = false
  var historyWriteSuspensions = 0
  var faviconAdoptionSuspensions = 0
  var faviconsAdopted = false
  var faviconsAdoptedAtBookmarks: [Bool] = []
  var historyWriteReleased = false
  var historyWritesAtAdoption: [Int] = []
  private var heldHistoryWrite: CheckedContinuation<Void, Never>?
  var faviconAdoptions: [(String, [ImportFaviconRow])] = []
  var faviconStores: [(String, [ImportFaviconRow])] = []
  var readCount = 0
  var onRead: ((Int) -> Void)?

  func transientImportRefused() { calls.append("refused") }
  func isUnlocked(_ browserId: String) -> Bool { unlocked.contains(browserId) }

  func unlock(_ browserId: String) async -> Bool {
    calls.append("unlock:\(browserId)")
    unlocked.insert(browserId)
    return true
  }

  func read(jobId: String, browserId: String, profileId: String, kinds: [ImportKind], progress: @escaping @MainActor (ImportKind, Bool) -> Void) async throws -> ImportRead {
    calls.append("read:\(profileId)")
    readCount += 1
    onRead?(readCount)
    readStarted?()
    if holdRead { await withCheckedContinuation { heldRead = $0 } }
    for kind in kinds {
      progress(kind, false)
      progress(kind, true)
    }
    switch reads[profileId] ?? .success(Self.read()) {
    case .success(let read): return read
    case .failure(let failure): throw failure
    }
  }

  func releaseRead() {
    heldRead?.resume()
    heldRead = nil
  }

  func cancelRead(jobId: String) {
    calls.append("cancelRead")
    guard heldRead != nil else { return }
    reads = reads.mapValues { _ in .failure(.cancelled) }
    reads["Default"] = .failure(.cancelled)
    reads["Profile 1"] = .failure(.cancelled)
    if !cancelLeavesReadHeld { releaseRead() }
  }

  func discard(token: String) { discarded.append(token) }

  func writeNative(token: String, engineProfile: String, kinds: [String]) async -> ImportNativeWritten? {
    steps.append("native")
    written.append((token, engineProfile, kinds))
    return nativeResult
  }

  func savePassword(engineProfile: String, origin: String, username: String, password: String) async -> Bool {
    steps.append("save")
    saved.append((engineProfile, origin, username))
    onSave?(saved.count)
    return true
  }

  func bookmarkParents(_ profile: String) -> ImportBookmarkParents? { parents }

  func submitBookmarks(profile: String, mutations: [BookmarkMutation]) async throws {
    steps.append("bookmarks")
    faviconsAdoptedAtBookmarks.append(faviconsAdopted)
    bookmarkSubmits.append(mutations)
    onBookmarkSubmit?()
    await Task.yield()
    if bookmarkFails { throw ImportBookmarkWriteFailure.failed }
    if conditionFailures > 0 {
      conditionFailures -= 1
      throw ImportBookmarkWriteFailure.conditionFailed
    }
    if rootsAppearOnSubmit, parents == nil { parents = ImportBookmarkParents(bar: "bar", other: "other", barEmpty: true, otherEmpty: true) }
  }

  func reportBookmarkFailure() { bookmarkReports += 1 }

  func importWorkspace(profile: String, windows: [JSONValue]) -> Int? {
    steps.append("workspace")
    workspaces.append((profile, windows))
    return workspaceResult
  }

  func adoptHistory(profile: String, rows: [ImportHistoryRow], oldestKept: Double, deadline: TimeInterval) async -> Int? {
    steps.append("adoptHistory")
    adoptDeadlines.append(deadline)
    adoptCutoffs.append(oldestKept)
    historyWritesAtAdoption.append(historyWrites.count)
    historyAdoptions.append((profile, rows))
    onAdoptHistory?()
    if adoptHistoryTimesOut { return nil }
    return adoptHistoryAnswer ?? rows.count
  }

  func importHistory(engineProfile: String, rows: [ImportHistoryRow]) async {
    onHistoryWrite?()
    for _ in 0..<historyWriteSuspensions { await Task.yield() }
    if holdHistoryWrite && !historyWriteReleased { await withCheckedContinuation { heldHistoryWrite = $0 } }
    historyWrites.append((engineProfile, rows))
  }

  func releaseHistoryWrite() {
    historyWriteReleased = true
    heldHistoryWrite?.resume()
    heldHistoryWrite = nil
  }

  func adoptFavicons(profile: String, favicons: [ImportFaviconRow]) async {
    steps.append("adoptFavicons")
    faviconAdoptions.append((profile, favicons))
    for _ in 0..<faviconAdoptionSuspensions { await Task.yield() }
    faviconsAdopted = true
  }

  func storeFavicons(engineProfile: String, favicons: [ImportFaviconRow]) async {
    faviconStores.append((engineProfile, favicons))
  }

  func extensions(browserId: String, profileId: String) async -> [ImportedExtension] { listed }
  func forget() { forgets += 1 }
  func profiles() -> [ImportTarget] { profileList }
  func profileExists(_ id: String) -> Bool { profileList.contains { $0.id == id } || created.contains { "new-\($0.0)" == id } }
  func isPrivateProfile(_ id: String) -> Bool { id.hasPrefix("incognito:") }
  func engineProfile(_ id: String) -> String { "engine-\(id)" }

  func askImportAsNewProfile() async -> Bool? {
    calls.append("ask")
    beforeAnswer?()
    return askAnswer
  }

  func dismissImportAsNewProfile() { calls.append("dismiss") }

  func createProfile(name: String, color: String?) -> String? {
    created.append((name, color))
    return createFails ? nil : "new-\(name)"
  }

  func publish(_ progress: ImportProgressUpdate) { published.append(progress) }
  func log(_ line: String) { logs.append(line) }

  static func read(token: String? = "vault-1", name: String? = nil, failed: [ImportKind] = [], warnings: [ImportReadWarning] = [], credentials: [ImportCredential] = credentials(3),
                   bookmarks: ImportBookmarkNode? = nil, tabs: [ImportTabRow] = [], favorites: [ImportTabRow] = [], hasSpaces: Bool = false,
                   history: [ImportHistoryRow] = [], favicons: [ImportFaviconRow] = []) -> ImportRead {
    ImportRead(vaultToken: token, profileName: name, profileColor: nil, failed: failed, warnings: warnings, credentials: credentials,
               bookmarks: bookmarks, tabs: tabs, favorites: favorites, hasSpaces: hasSpaces, history: history, favicons: favicons)
  }

  static let recently = Date().timeIntervalSince1970 * 1000 - 3_600_000
  static let historyRows = [
    ImportHistoryRow(url: "https://h1.test/", title: "H1", visits: 3, lastVisit: recently - 10),
    ImportHistoryRow(url: "ftp://h2.test/", title: "H2", visits: 1, lastVisit: recently - 9),
    ImportHistoryRow(url: "HTTPS://h3.test/", title: "H3", visits: 0, lastVisit: recently - 8),
    ImportHistoryRow(url: "https://h1.test/", title: "H1 again", visits: 1, lastVisit: recently - 7),
    ImportHistoryRow(url: "file:///tmp/x.html", title: "X", visits: 1, lastVisit: recently - 6),
  ]

  static let icons = [
    ImportFaviconRow(page: "https://a.test/#top", icon: "https://a.test/favicon.ico", png: "AAA"),
    ImportFaviconRow(page: "https://t.test/", icon: "https://t.test/favicon.ico", png: "BBB"),
    ImportFaviconRow(page: "https://elsewhere.test/", icon: "https://elsewhere.test/favicon.ico", png: "CCC"),
    ImportFaviconRow(page: "https://a.test/", icon: "https://a.test/new.ico", png: "DDD"),
  ]

  static func link(_ title: String, _ url: String?, added: Double? = nil) -> ImportBookmarkNode {
    ImportBookmarkNode(isFolder: false, title: title, url: url, dateAdded: added, role: nil, pageTitle: nil, children: nil)
  }

  static func folder(_ title: String, _ children: [ImportBookmarkNode], role: String? = nil) -> ImportBookmarkNode {
    ImportBookmarkNode(isFolder: true, title: title, url: nil, dateAdded: nil, role: role, pageTitle: nil, children: children)
  }

  static let tree = folder("", [
    folder("Bookmarks Bar", [link("A", "https://a.test/"), folder("F", [link("B", "https://b.test/")])], role: "toolbar"),
    folder("Other Bookmarks", [link("", "https://c.test/", added: 5)], role: "other"),
    link("Loose", "https://d.test/"),
  ])

  static func credentials(_ n: Int) -> [ImportCredential] {
    (1...max(n, 1)).prefix(n).map { ImportCredential(url: "https://site\($0).test/login", username: "user\($0)", password: "secret\($0)", realm: nil) }
  }
}

@MainActor
final class FakeScriptPath: ImportScriptPath {
  var calls: [String] = []
  func scriptRun(_ request: ImportRunRequest, session: Int) async -> ImportRunOutcome {
    calls.append("run:\(request.runId):\(session)")
    return ImportRunOutcome(status: [.bookmarks: .done], counts: ImportCounts(bookmarks: 1))
  }
  func scriptCancel() { calls.append("cancel") }
  func scriptDispose() { calls.append("dispose") }
}

@MainActor
struct ImportRunTests {
  static let firefox = ImportBrowser(id: "firefox", name: "Firefox", family: .firefox, profiles: [ImportSourceProfile(id: "Default", name: "default-release", isDefault: true, available: [.bookmarks, .passwords])])
  static let zen = ImportBrowser(id: "zen", name: "Zen", family: .firefox, profiles: [ImportSourceProfile(id: "Default", name: "Default", isDefault: true, available: [.passwords])], sidebar: .zen)

  func settled(_ runs: ImportRuns) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + .seconds(60)
    while runs.pendingWrites > 0 {
      if clock.now >= end { return false }
      await Task.yield()
    }
    return true
  }

  func setup(_ browsers: [ImportBrowser] = [ImportFixtures.chrome]) -> (ImportRuns, FakeImportEngine, FakeScriptPath, Int) {
    let runs = ImportRuns()
    runs.browsers = browsers
    runs.writeDeadline = .seconds(300)
    runs.drainDeadline = .seconds(300)
    let session = runs.open()
    return (runs, FakeImportEngine(), FakeScriptPath(), session)
  }

  func request(_ kinds: [ImportKind], browser: String = "chrome", profiles: [String] = ["Default"], target: String = "default", runId: String = "r1") -> ImportRunRequest {
    ImportRunRequest(runId: runId, browserId: browser, profileIds: profiles, spaceIds: [], kinds: kinds, target: target, withoutKey: false)
  }

  @Test func routeTakesOnlyCredentialKindsFromSidebarFreeChromiumOrFirefox() {
    #expect(ImportRoute.of(ImportFixtures.chrome, kinds: [.passwords, .cookies, .autofill]) == .swift)
    #expect(ImportRoute.of(Self.firefox, kinds: [.passwords]) == .swift)
    #expect(ImportRoute.of(Self.zen, kinds: [.passwords]) == .js)
    #expect(ImportRoute.of(ImportFixtures.arc, kinds: [.passwords]) == .js)
    #expect(ImportRoute.of(ImportFixtures.chrome, kinds: [.passwords, .bookmarks]) == .js)
    #expect(ImportRoute.of(ImportFixtures.chrome, kinds: []) == .js)
    #expect(ImportRoute.of(nil, kinds: [.passwords]) == .js)
  }

  @Test func originMatchesTheJSPatternOnUTF16() {
    #expect(ImportOrigin.of(url: "https://a.test/login?x", realm: nil) == "https://a.test")
    #expect(ImportOrigin.of(url: "https://a.test/x", realm: "https://realm.test/") == "https://realm.test")
    #expect(ImportOrigin.of(url: "https://a.test/x", realm: "ftp://realm.test/") == "https://a.test")
    #expect(ImportOrigin.of(url: "https://a.test/\u{301}x", realm: nil) == "https://a.test")
    #expect(ImportOrigin.of(url: "\u{212A}ttps://a.test", realm: nil) == nil)
    #expect(ImportOrigin.of(url: "h\u{17F}tps://a.test", realm: nil) == nil)
    #expect(ImportOrigin.of(url: "https://a.test", realm: "http\u{301}s://realm.test") == nil)
    #expect(ImportOrigin.of(url: "HTTPS://A.test\n/x", realm: nil) == "HTTPS://A.test\n")
    #expect(ImportOrigin.of(url: "android://hash@com.app/", realm: nil) == "android://hash@com.app")
    #expect(ImportOrigin.of(url: "not a url", realm: nil) == nil)
  }

  @Test func profileColorMatchesTheJSHueBuckets() {
    #expect(ImportProfileColor.of("#ff0000") == "red")
    #expect(ImportProfileColor.of("00ff00") == "green")
    #expect(ImportProfileColor.of("#4285F4") == "blue")
    #expect(ImportProfileColor.of("#808080") == "neutral")
    #expect(ImportProfileColor.of("#0000ffAA") == "purple")
    #expect(ImportProfileColor.of("#zzzzzz") == nil)
    #expect(ImportProfileColor.of(nil) == nil)
  }

  @Test func profileNamesCompareLikeJSTrimAndLowercase() {
    #expect(ImportProfileName.same(" Work\u{FEFF}", "work"))
    #expect(ImportProfileName.same("WORK\u{00A0}", "work"))
    #expect(!ImportProfileName.same("caf\u{E9}", "cafe\u{301}"))
  }

  @Test func chromiumRunWritesCredentialsInSwiftAndForgetsOnce() async {
    let (runs, engine, script, session) = setup()
    let outcome = await runs.run(request([.passwords, .cookies, .autofill]), session: session, engine: engine, script: script, scriptSession: 7)
    #expect(!outcome.cancelled)
    #expect(outcome.counts == ImportCounts(passwords: 3, cookies: 5, addresses: 1, cards: 1))
    #expect(outcome.status == [.passwords: .done, .cookies: .done, .autofill: .done])
    #expect(outcome.extensions.map(\.id) == ["ext"])
    #expect(outcome.extensionsProfile == "default")
    #expect(engine.written.map(\.0) == ["vault-1"])
    #expect(engine.written.first?.1 == "engine-default")
    #expect(engine.written.first?.2 == ["cookies", "autofill"])
    #expect(engine.saved.map(\.1) == ["https://site1.test", "https://site2.test", "https://site3.test"])
    #expect(engine.discarded.isEmpty)
    #expect(engine.forgets == 1)
    #expect(!engine.calls.contains { $0.hasPrefix("unlock") })
    #expect(script.calls.isEmpty)
    #expect(runs.route(of: "r1") == .swift)
    #expect(engine.logs == ["[import] run r1 route=swift family=chromium"])
  }

  @Test func progressPublishesPendingThenActiveThenDone() async {
    let (runs, engine, script, session) = setup()
    _ = await runs.run(request([.passwords]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.published.map { $0.status[.passwords] } == [.pending, .active, .done])
    #expect(engine.published.allSatisfy { $0.runId == "r1" && $0.preparing == 1 })
  }

  @Test func firefoxUnlocksBeforeReadingPasswords() async {
    let (runs, engine, script, session) = setup([Self.firefox])
    _ = await runs.run(request([.passwords], browser: "firefox"), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(Array(engine.calls.prefix(2)) == ["unlock:firefox", "read:Default"])
    #expect(engine.forgets == 1)
  }

  @Test func otherRunsGoToTheScriptPath() async {
    let (runs, engine, script, session) = setup([ImportFixtures.chrome, Self.zen])
    _ = await runs.run(request([.bookmarks, .passwords]), session: session, engine: engine, script: script, scriptSession: 4)
    _ = await runs.run(request([.passwords], browser: "zen", runId: "r2"), session: session, engine: engine, script: script, scriptSession: 4)
    #expect(script.calls == ["run:r1:4", "run:r2:4"])
    #expect(engine.calls.isEmpty)
    #expect(engine.logs == ["[import] run r1 route=js family=chromium", "[import] run r2 route=js family=firefox"])
  }

  @Test func aFailedReadMarksThatProfileAndTheNextGetsTheTarget() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Default"] = .failure(.failed)
    let outcome = await runs.run(request([.passwords], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.failures == [ImportFailure(kind: .passwords, profiles: ["Person 1"])])
    #expect(engine.saved.allSatisfy { $0.0 == "engine-default" })
    #expect(engine.created.isEmpty)
  }

  @Test func aCancelledReadReturnsCancelledAndWritesNothing() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Default"] = .failure(.cancelled)
    let outcome = await runs.run(request([.passwords, .cookies]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.cancelled)
    #expect(engine.written.isEmpty)
    #expect(engine.saved.isEmpty)
    #expect(engine.forgets == 1)
  }

  @Test func cancellingPartwayThroughPasswordsStopsTheCount() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Default"] = .success(FakeImportEngine.read(credentials: FakeImportEngine.credentials(5)))
    engine.onSave = { count in if count == 2 { runs.cancel(engine: engine, script: script) } }
    let outcome = await runs.run(request([.passwords, .cookies]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.saved.count == 2)
    #expect(outcome.counts.passwords == 2)
    #expect(outcome.counts.cookies == 5)
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    #expect(!outcome.cancelled)
    #expect(script.calls == ["cancel"])
    #expect(engine.forgets == 1)
  }

  @Test func cancellingDuringALaterReadKeepsWhatEarlierProfilesSaved() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Profile 1"] = .failure(.cancelled)
    engine.onRead = { count in if count == 2 { runs.cancel(engine: engine, script: script) } }
    let outcome = await runs.run(request([.passwords, .cookies], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(!outcome.cancelled)
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    #expect(outcome.counts.passwords == 3)
    #expect(outcome.counts.cookies == 5)
    #expect(engine.created.isEmpty)
    #expect(engine.forgets == 1)
  }

  @Test func cancellingAfterAFailedLaterReadStopsBeforeTheNextProfile() async {
    let three = ImportBrowser(id: "chrome", name: "Google Chrome", family: .chromium, needsKeychain: true, keychainService: "Chrome Safe Storage", profiles: ImportFixtures.chrome.profiles + [ImportSourceProfile(id: "Profile 2", name: "Side", isDefault: false, available: ImportFixtures.chromeKinds)])
    let (runs, engine, script, session) = setup([three])
    engine.reads["Profile 1"] = .failure(.failed)
    engine.onRead = { count in if count == 2 { runs.cancel(engine: engine, script: script) } }
    let outcome = await runs.run(request([.passwords], profiles: ["Default", "Profile 1", "Profile 2"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.readCount == 2)
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    #expect(outcome.counts.passwords == 3)
  }

  @Test func aClashWithNoWindowToAskInFailsThatProfileAndFinishes() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Profile 1"] = .success(FakeImportEngine.read(token: "vault-2", name: "Work"))
    engine.askAnswer = nil
    let outcome = await runs.run(request([.passwords, .cookies], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(!outcome.cancelled)
    #expect(outcome.counts.passwords == 3)
    #expect(outcome.failures.contains(ImportFailure(kind: .passwords, profiles: ["Work"])))
    #expect(outcome.status[.passwords] == .failed)
    #expect(outcome.notes == [ImportRunner.noDestinationNote("Work")])
    #expect(engine.discarded == ["vault-2"])
    #expect(engine.created.isEmpty)
  }

  @Test func aFailedNewProfileFailsThatProfileAndFinishes() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Profile 1"] = .success(FakeImportEngine.read(token: "vault-2", name: "Side"))
    engine.createFails = true
    let outcome = await runs.run(request([.passwords, .cookies], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(!outcome.cancelled)
    #expect(outcome.counts.passwords == 3)
    #expect(outcome.failures.contains(ImportFailure(kind: .cookies, profiles: ["Work"])))
    #expect(outcome.notes == [ImportRunner.noDestinationNote("Side")])
    #expect(engine.discarded == ["vault-2"])
    #expect(engine.saved.count == 3)
  }

  @Test func cancellingBeforeTheVaultTakeDiscardsAndWritesNothing() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Profile 1"] = .success(FakeImportEngine.read(token: "vault-2", name: "Work"))
    engine.beforeAnswer = { runs.cancel(engine: engine, script: script) }
    let outcome = await runs.run(request([.passwords, .cookies], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    #expect(engine.written.map(\.0) == ["vault-1"])
    #expect(engine.discarded == ["vault-2"])
    #expect(engine.saved.count == 3)
    #expect(engine.created.isEmpty)
  }

  @Test func aPrivateOrMissingTargetDiscardsTheVault() async {
    let (runs, engine, script, session) = setup()
    let outcome = await runs.run(request([.cookies], target: "incognito:w1@default"), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.written.isEmpty)
    #expect(engine.discarded == ["vault-1"])
    #expect(outcome.counts.cookies == 0)
    let (runs2, engine2, script2, session2) = setup()
    _ = await runs2.run(request([.cookies], target: "gone"), session: session2, engine: engine2, script: script2, scriptSession: 1)
    #expect(engine2.written.isEmpty)
    #expect(engine2.discarded == ["vault-1"])
  }

  @Test func aFailedNativeWriteMarksBothNativeKindsFailed() async {
    let (runs, engine, script, session) = setup()
    engine.nativeResult = nil
    let outcome = await runs.run(request([.cookies, .autofill]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.status[.cookies] == .failed)
    #expect(outcome.status[.autofill] == .failed)
  }

  @Test func aClashAsksAndEitherCreatesOrReplaces() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Profile 1"] = .success(FakeImportEngine.read(token: "vault-2", name: " work "))
    _ = await runs.run(request([.passwords], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.calls.filter { $0 == "ask" }.count == 1)
    #expect(engine.created.map(\.0) == [" work "])

    let (runs2, engine2, script2, session2) = setup()
    engine2.reads["Profile 1"] = .success(FakeImportEngine.read(token: "vault-2", name: "Work"))
    engine2.askAnswer = false
    _ = await runs2.run(request([.passwords], profiles: ["Default", "Profile 1"]), session: session2, engine: engine2, script: script2, scriptSession: 1)
    #expect(engine2.created.isEmpty)
    #expect(engine2.saved.suffix(3).allSatisfy { $0.0 == "engine-work" })
  }

  @Test func aNewProfileWithoutAClashTakesTheSourceColor() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Profile 1"] = .success(FakeImportEngine.read(token: "vault-2", name: "Side"))
    _ = await runs.run(request([.passwords], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.created.map(\.0) == ["Side"])
    #expect(engine.created.first?.1 == "green")
    #expect(!engine.calls.contains("ask"))
  }

  @Test func disposingDuringTheClashCancelsTheRunAndDiscards() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Profile 1"] = .success(FakeImportEngine.read(token: "vault-2", name: "Work"))
    engine.askAnswer = nil
    engine.beforeAnswer = { runs.dispose(engine: engine, script: script) }
    let outcome = await runs.run(request([.passwords, .cookies], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    #expect(engine.discarded == ["vault-2"])
    #expect(engine.created.isEmpty)
    #expect(engine.calls.contains("dismiss"))
    #expect(script.calls == ["dispose"])
  }

  @Test func warningsBecomeNotesUnlessTheKindFailed() async {
    let (runs, engine, script, session) = setup()
    engine.reads["Default"] = .success(FakeImportEngine.read(failed: [.cookies], warnings: [
      ImportReadWarning(kind: .passwords, code: "skipped", message: "2 passwords were skipped"),
      ImportReadWarning(kind: .cookies, code: "undecryptable", message: "3 cookies couldn't be read"),
      ImportReadWarning(kind: .passwords, code: "other", message: "ignored"),
    ]))
    let outcome = await runs.run(request([.passwords, .cookies]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.notes == ["2 passwords were skipped."])
    #expect(outcome.status[.cookies] == .failed)
  }

  @Test func safeModeRefusesSeveralProfiles() async {
    let (runs, engine, script, session) = setup()
    engine.safeMode = true
    let outcome = await runs.run(request([.passwords], profiles: ["Default", "Profile 1"]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.notes == ["Import one source profile into an existing profile in safe mode."])
    #expect(outcome.failures == [ImportFailure(kind: .passwords, profiles: ["Person 1", "Work"])])
    #expect(engine.calls == ["refused"])
  }

  @Test func aDrainWaitsForTheSwiftRunAndRevokesTheSession() async {
    let (runs, engine, script, session) = setup()
    engine.holdRead = true
    engine.cancelLeavesReadHeld = true
    var started = false
    engine.readStarted = { started = true }
    let running = Task { await runs.run(request([.passwords]), session: session, engine: engine, script: script, scriptSession: 1) }
    while !started { await Task.yield() }
    let draining = Task { await runs.drain(engine: engine) }
    for _ in 0..<20 { await Task.yield() }
    #expect(runs.drains == 1)
    #expect(!runs.admitted(session))
    engine.releaseRead()
    let outcome = await running.value
    await draining.value
    #expect(outcome.cancelled)
    #expect(runs.drains == 0)
    #expect(!runs.admitted(session))
    #expect(runs.admitted(runs.open()))
    #expect(engine.calls.contains("cancelRead"))
  }

  @Test func cancelReachesTheSwiftRunAndTheScriptRunStartedBackToBack() async {
    let (runs, engine, script, session) = setup()
    engine.holdRead = true
    var started = false
    engine.readStarted = { started = true }
    let swift = Task { await runs.run(request([.passwords], runId: "s"), session: session, engine: engine, script: script, scriptSession: 2) }
    while !started { await Task.yield() }
    runs.cancel(engine: engine, script: script)
    let swiftOutcome = await swift.value
    let jsOutcome = await runs.run(request([.bookmarks], runId: "j"), session: session, engine: engine, script: script, scriptSession: 2)
    runs.cancel(engine: engine, script: script)
    #expect(!swiftOutcome.cancelled)
    #expect(swiftOutcome.notes == [ImportRunner.stoppedNote])
    #expect(swiftOutcome.counts == ImportCounts())
    #expect(!jsOutcome.cancelled)
    #expect(engine.calls.contains("cancelRead"))
    #expect(script.calls == ["cancel", "run:j:2", "cancel"])
    #expect(runs.route(of: "s") == .swift)
    #expect(runs.route(of: "j") == .js)
  }

  @Test func bookmarkDraftsFollowTheJSShape() {
    #expect(ImportBookmarks.draft(FakeImportEngine.link("", "https://c.test/", added: 5)) == .object(["title": "https://c.test/", "url": "https://c.test/", "addedAt": .number(5)]))
    #expect(ImportBookmarks.draft(FakeImportEngine.link("", nil)) == .object(["title": "", "url": ""]))
    #expect(ImportBookmarks.draft(FakeImportEngine.folder("F", [])) == .object(["title": "F", "children": .array([])]))
    let (toolbar, other) = ImportBookmarks.split(FakeImportEngine.tree)
    #expect(toolbar.map(\.title) == ["A", "F"])
    #expect(other.map(\.title) == ["", "Loose"])
    #expect(ImportBookmarks.linkCount(toolbar + other) == 4)
  }

  @Test func anEmptyBarTakesTheLinksAndAFullOtherGetsTheImportedFolder() {
    let parents = ImportBookmarkParents(bar: "bar", other: "other", barEmpty: true, otherEmpty: false)
    let (toolbar, other) = ImportBookmarks.split(FakeImportEngine.tree)
    let edits = ImportBookmarks.edits(profile: "default", toolbar: toolbar, other: other, parents: parents, browserName: "Google Chrome")
    #expect(edits.map(\.method) == ["expectChildren", "addBookmarkTree", "addBookmarkTree"])
    #expect(edits[0].args == [.string("default"), .string("bar"), .array([])])
    #expect(edits[1].args[2] == .string("bar"))
    #expect(edits[2].args[2] == .string("other"))
    #expect(edits[2].args[1].array?.first?["title"]?.string == "Imported from Google Chrome")
  }

  @Test func stepsRunInTheJSOrder() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.reads["Default"] = .success(FakeImportEngine.read(bookmarks: FakeImportEngine.tree, tabs: [ImportTabRow(url: "https://t.test/", title: "T", pinned: false, customTitle: nil)],
                                                            favorites: [ImportTabRow(url: "https://f.test/", title: "F", pinned: false, customTitle: "Fav")]))
    let outcome = await runs.run(request([.bookmarks, .passwords, .cookies, .tabs, .favorites]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.steps == ["bookmarks", "native", "workspace", "save", "save", "save"])
    #expect(outcome.counts.bookmarks == 4)
    #expect(outcome.counts.tabs == 2)
    let windows = engine.workspaces.first?.1 ?? []
    #expect(windows.count == 2)
    #expect(windows.first?["group"]?.string == "Imported")
    #expect(windows.last?["pinnedAgainst"]?.string == "tiles")
    #expect(windows.last?["tabs"]?.array?.first?["pinned"] == .bool(true))
    #expect(windows.last?["tabs"]?.array?.first?["customTitle"]?.string == "Fav")
  }

  @Test func tabsFromASpacesSourceAreLeftOut() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.reads["Default"] = .success(FakeImportEngine.read(tabs: [ImportTabRow(url: "https://t.test/", title: "T", pinned: false, customTitle: nil)], hasSpaces: true))
    _ = await runs.run(request([.tabs]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.workspaces.isEmpty)
  }

  @Test func missingRootsAreCreatedBeforeBookmarksArePlaced() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.parents = nil
    engine.rootsAppearOnSubmit = true
    engine.reads["Default"] = .success(FakeImportEngine.read(bookmarks: FakeImportEngine.tree))
    let outcome = await runs.run(request([.bookmarks]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.bookmarkSubmits.first == [BookmarkMutation(method: "addBookmarkTree", args: [.string("default"), .array([])])])
    #expect(engine.bookmarkSubmits.count == 2)
    #expect(outcome.counts.bookmarks == 4)
  }

  @Test func aConditionFailureRetriesUpToThreeTimes() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.conditionFailures = 1
    engine.reads["Default"] = .success(FakeImportEngine.read(bookmarks: FakeImportEngine.tree))
    let once = await runs.run(request([.bookmarks]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.bookmarkSubmits.count == 2)
    #expect(once.counts.bookmarks == 4)

    let (runs2, engine2, script2, session2) = setup()
    runs2.darkRoute = true
    engine2.conditionFailures = 3
    engine2.reads["Default"] = .success(FakeImportEngine.read(bookmarks: FakeImportEngine.tree))
    let thrice = await runs2.run(request([.bookmarks, .passwords]), session: session2, engine: engine2, script: script2, scriptSession: 1)
    #expect(engine2.bookmarkSubmits.count == 3)
    #expect(thrice.counts.bookmarks == 0)
    #expect(thrice.status[.bookmarks] == .failed)
    #expect(engine2.bookmarkReports == 1)
    #expect(thrice.counts.passwords == 3)
  }

  @Test func cancellingAfterBookmarksSavesNothingMore() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.onBookmarkSubmit = { runs.cancel(engine: engine, script: script) }
    engine.reads["Default"] = .success(FakeImportEngine.read(bookmarks: FakeImportEngine.tree, tabs: [ImportTabRow(url: "https://t.test/", title: "T", pinned: false, customTitle: nil)]))
    let outcome = await runs.run(request([.bookmarks, .passwords, .cookies, .tabs]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.steps == ["bookmarks"])
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    #expect(outcome.counts.bookmarks == 4)
    #expect(engine.discarded == ["vault-1"])
  }

  @Test func aDrainAfterBookmarksEndsAsACancelledRun() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.onBookmarkSubmit = { Task { @MainActor in await runs.drain(engine: engine) } }
    engine.reads["Default"] = .success(FakeImportEngine.read(bookmarks: FakeImportEngine.tree))
    let outcome = await runs.run(request([.bookmarks, .passwords, .cookies]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.cancelled)
    #expect(engine.steps == ["bookmarks"])
    #expect(engine.discarded == ["vault-1"])
  }

  @Test func tabsTheWorkspaceRefusesAreFailed() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.workspaceResult = nil
    engine.reads["Default"] = .success(FakeImportEngine.read(tabs: [ImportTabRow(url: "https://t.test/", title: "T", pinned: false, customTitle: nil)]))
    let outcome = await runs.run(request([.tabs, .passwords]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(outcome.status[.tabs] == .failed)
    #expect(outcome.counts.tabs == 0)
    #expect(outcome.counts.passwords == 3)
  }

  @Test func theDarkRouteTakesBookmarksTabsAndFavoritesOnlyWhenSet() {
    #expect(ImportRoute.of(ImportFixtures.chrome, kinds: [.bookmarks, .passwords]) == .js)
    #expect(ImportRoute.of(ImportFixtures.chrome, kinds: [.bookmarks, .tabs, .favorites, .passwords], dark: true) == .swift)
    #expect(ImportRoute.of(ImportFixtures.chrome, kinds: [.bookmarks, .history], dark: true) == .swift)
    #expect(ImportRoute.of(ImportFixtures.chrome, kinds: [.bookmarks, .spaces], dark: true) == .js)
  }

  @Test func parentsNeedOnlyAViewNotSyncReadiness() {
    let document: JSONValue = ["nodes": ["bar@e": ["kind": "folder", "children": .array([])], "other@e": ["kind": "folder", "children": .array(["x"])]], "roots": [:]]
    let parents = ImportBookmarkWrites.parents(hasView: true, document: document, bar: "bar@e", other: "other@e")
    #expect(parents == ImportBookmarkParents(bar: "bar@e", other: "other@e", barEmpty: true, otherEmpty: false))
    #expect(ImportBookmarkWrites.parents(hasView: false, document: document, bar: "bar@e", other: "other@e") == nil)
    #expect(ImportBookmarkWrites.parents(hasView: true, document: ["nodes": [:]], bar: "bar@e", other: "other@e") == nil)
  }

  struct Stale: Error {}

  @Test func aStaleBindingIsWaitedOutWithTheSameBinding() async throws {
    var tries = 0
    var slept: [Duration] = []
    let held = try await ImportBookmarkWrites.whileEngineHolds(binding: { "engine-1/7" }, isStale: { $0 is Stale }, sleep: { slept.append($0) }) { binding in
      tries += 1
      #expect(binding == "engine-1/7")
      if tries <= 2 { throw Stale() }
    }
    #expect(held == "engine-1/7")
    #expect(tries == 3)
    #expect(slept == [.milliseconds(25), .milliseconds(50)])
  }

  @Test func aStaleBindingGivesUpWhenTheEngineChanges() async {
    var bindings = ["engine-1/7", "engine-2/8"]
    var tries = 0
    await #expect(throws: Stale.self) {
      _ = try await ImportBookmarkWrites.whileEngineHolds(binding: { bindings.removeFirst() }, isStale: { $0 is Stale }, sleep: { _ in }) { _ in
        tries += 1
        throw Stale()
      }
    }
    #expect(tries == 1)
  }

  @Test func aStaleBindingGivesUpAfterTheRetryWindow() async {
    var clock = ContinuousClock.now
    var tries = 0
    await #expect(throws: Stale.self) {
      _ = try await ImportBookmarkWrites.whileEngineHolds(binding: { "engine-1/7" }, isStale: { $0 is Stale }, sleep: { clock += $0 + .seconds(4) }, now: { clock }) { _ in
        tries += 1
        throw Stale()
      }
    }
    #expect(tries == 4)
  }

  @Test func aCancelledTaskStopsRetryingAStaleBinding() async {
    var tries = 0
    let task = Task { @MainActor in
      try await ImportBookmarkWrites.whileEngineHolds(binding: { "engine-1/7" }, isStale: { $0 is Stale }, sleep: { _ in }) { _ in
        tries += 1
        withUnsafeCurrentTask { $0?.cancel() }
        throw Stale()
      }
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(tries == 1)
  }

  @Test func otherErrorsAreNotRetried() async {
    var tries = 0
    await #expect(throws: ImportBookmarkWriteFailure.self) {
      _ = try await ImportBookmarkWrites.whileEngineHolds(binding: { "engine-1/7" }, isStale: { $0 is Stale }, sleep: { _ in }) { _ in
        tries += 1
        throw ImportBookmarkWriteFailure.conditionFailed
      }
    }
    #expect(tries == 1)
  }

  @Test func faviconPagesFollowTheJSPageKey() {
    #expect(ImportFavicons.page("https://a.test/#x") == "https://a.test/")
    #expect(ImportFavicons.page("https://a.test/a#b#c") == "https://a.test/a")
    #expect(ImportFavicons.page("a#b\nc") == "a#b\nc")
    #expect(ImportFavicons.page("x\n#y") == "x\n")
    #expect(ImportFavicons.page("https://a.test/") == "https://a.test/")
  }

  @Test func faviconsAreChosenForToolbarFavoritesAndTabsWithoutSpaces() {
    let tab = ImportTabRow(url: "https://t.test/", title: "T", pinned: false, customTitle: nil)
    let read = FakeImportEngine.read(tabs: [tab], favicons: FakeImportEngine.icons)
    #expect(ImportFavicons.chosen(read).map(\.png) == ["BBB"])
    #expect(ImportFavicons.chosen(FakeImportEngine.read(bookmarks: FakeImportEngine.tree, tabs: [tab], favicons: FakeImportEngine.icons)).map(\.png) == ["AAA", "BBB", "DDD"])
    let toolbar = FakeImportEngine.folder("", [FakeImportEngine.folder("Bar", [FakeImportEngine.link("A", "https://a.test/")], role: "toolbar")])
    let withToolbar = FakeImportEngine.read(bookmarks: toolbar, tabs: [tab], hasSpaces: true, favicons: FakeImportEngine.icons)
    #expect(ImportFavicons.chosen(withToolbar).map(\.png) == ["AAA", "DDD"])
    #expect(ImportFavicons.byPage(ImportFavicons.chosen(withToolbar)).map { $0.page + "=" + $0.favicon.png } == ["https://a.test/=DDD"])
  }

  @Test func historyKeepsHTTPAndFileRowsCaseSensitivelyAndCountsDistinctURLs() {
    let usable = ImportHistory.usable(FakeImportEngine.historyRows)
    #expect(usable.map(\.title) == ["H1", "H1 again", "X"])
    #expect(ImportHistory.distinctCount(usable) == 2)
  }

  @Test func historyOlderThanTheEngineKeepsIsLeftOutAndUntitledRowsStay() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = 86_400_000.0
    let at = now.timeIntervalSince1970 * 1000
    let rows = [
      ImportHistoryRow(url: "https://boundary.test/", title: "Boundary", visits: 1, lastVisit: at - 90 * day),
      ImportHistoryRow(url: "https://inside.test/", title: "Inside", visits: 1, lastVisit: at - 90 * day + 1),
      ImportHistoryRow(url: "https://recent.test/", title: "Recent", visits: 3, lastVisit: at - 89 * day),
      ImportHistoryRow(url: "https://expired.test/", title: "Expired", visits: 9, lastVisit: at - 91 * day),
      ImportHistoryRow(url: "https://untitled.test/", title: "", visits: 1, lastVisit: at - 3_600_000),
    ]
    #expect(ImportHistory.usable(rows, now: now).map(\.url) == ["https://inside.test/", "https://recent.test/", "https://untitled.test/"])
    #expect(ImportHistory.oldestKept(now) == at - 90 * day)
  }

  @Test func faviconsAndHistoryRunInTheJSOrder() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    runs.devTrace = []
    let toolbar = FakeImportEngine.folder("", [FakeImportEngine.folder("Bar", [FakeImportEngine.link("A", "https://a.test/")], role: "toolbar")])
    let tab = ImportTabRow(url: "https://t.test/", title: "T", pinned: false, customTitle: nil)
    engine.adoptHistoryAnswer = 1
    engine.reads["Default"] = .success(FakeImportEngine.read(bookmarks: toolbar, tabs: [tab], history: FakeImportEngine.historyRows, favicons: FakeImportEngine.icons))
    let outcome = await runs.run(request([.bookmarks, .history, .passwords, .cookies, .tabs]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(await settled(runs))
    #expect(runs.devTrace == ["favicons", "bookmarks", "history", "native", "workspace", "passwords"])
    #expect(engine.steps == ["adoptFavicons", "bookmarks", "adoptHistory", "native", "workspace", "save", "save", "save"])
    #expect(outcome.counts.history == 1)
    #expect(engine.historyAdoptions.first?.1.map(\.title) == ["H1", "H1 again", "X"])
    #expect(engine.historyWrites.first?.0 == "engine-default")
    #expect(engine.historyWrites.first?.1.count == 3)
    #expect(engine.faviconAdoptions.first?.1.map(\.png) == ["AAA", "BBB", "DDD"])
    #expect(engine.faviconStores.first?.0 == "engine-default")
  }

  @Test func aHistoryCountFallsBackToDistinctRowsAndLogsNoURL() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.adoptHistoryTimesOut = true
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    let outcome = await runs.run(request([.history]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(await settled(runs))
    #expect(outcome.counts.history == 2)
    #expect(engine.historyWrites.count == 1)
    #expect(engine.logs.contains("[import] history count fell back profile=default"))
    let many = (0..<6000).map { ImportHistoryRow(url: "https://m\($0).test/", title: "", visits: 1, lastVisit: FakeImportEngine.recently) }
    #expect(ImportHistory.fallbackCount(many) == ImportHistory.storeKeeps)
    #expect(!engine.logs.contains { $0.contains("h1.test") || $0.contains("tmp/x") })
  }

  @Test func theEngineGetsTheHistoryEvenWhenJSNeverAnswers() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.adoptHistoryTimesOut = true
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    _ = await runs.run(request([.history]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(await settled(runs))
    #expect(engine.historyAdoptions.count == 1)
    #expect(engine.historyWrites.map(\.0) == ["engine-default"])
    #expect(engine.historyWrites.first?.1 == ImportHistory.usable(FakeImportEngine.historyRows))
  }

  @Test func theEngineWriteEndsBeforeJSAdoptsTheHistoryEvenWhenTheProfileLoadsLate() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.historyWriteSuspensions = 8
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    _ = await runs.run(request([.history]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.historyWritesAtAdoption == [1])
  }

  @Test func aStuckEngineWriteHoldsTheRunOnlyUntilItsDeadline() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    runs.writeDeadline = .milliseconds(30)
    engine.holdHistoryWrite = true
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    let outcome = await runs.run(request([.history]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.historyAdoptions.count == 1)
    #expect(outcome.counts.history == 3)
    #expect(engine.logs.contains("[import] history write still running profile=default"))
    #expect(engine.historyWrites.isEmpty)
    engine.releaseHistoryWrite()
    #expect(await settled(runs))
    #expect(engine.historyWrites.count == 1)
  }

  @Test func cancellingDuringTheHistoryWaitEndsTheWaitAndSkipsTheAdopt() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    runs.writeDeadline = .seconds(300)
    engine.holdHistoryWrite = true
    engine.onHistoryWrite = { runs.cancel(engine: engine, script: script) }
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = await runs.run(request([.history, .cookies]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(clock.now - started < .seconds(150))
    #expect(engine.historyAdoptions.isEmpty)
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    engine.releaseHistoryWrite()
    #expect(await settled(runs))
  }

  @Test func theAdoptGetsTheRowsDeadlineAndTheCutoffItsRowsWereFilteredWith() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    let before = Date().timeIntervalSince1970 * 1000 - ImportHistory.engineKeepsMs
    _ = await runs.run(request([.history]), session: session, engine: engine, script: script, scriptSession: 1)
    let after = Date().timeIntervalSince1970 * 1000 - ImportHistory.engineKeepsMs
    #expect(engine.adoptDeadlines == [ImportHistory.adoptDeadline(rows: 3)])
    #expect(engine.adoptCutoffs.count == 1)
    #expect(engine.adoptCutoffs.allSatisfy { $0 >= before && $0 <= after })
  }

  @Test func faviconsAreAdoptedBeforeBookmarksArePlaced() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.faviconAdoptionSuspensions = 8
    let toolbar = FakeImportEngine.folder("", [FakeImportEngine.folder("Bar", [FakeImportEngine.link("A", "https://a.test/")], role: "toolbar")])
    engine.reads["Default"] = .success(FakeImportEngine.read(bookmarks: toolbar, favicons: FakeImportEngine.icons))
    _ = await runs.run(request([.bookmarks]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.faviconAdoptions.count == 1)
    #expect(engine.faviconsAdoptedAtBookmarks == [true])
  }

  @Test func aDrainGivesUpOnAStuckWriteAfterItsDeadlineAndSaysSo() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    runs.writeDeadline = .milliseconds(10)
    runs.drainDeadline = .milliseconds(50)
    engine.holdHistoryWrite = true
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    _ = await runs.run(request([.history]), session: session, engine: engine, script: script, scriptSession: 1)
    var drained = false
    let draining = Task { @MainActor in
      await runs.drain(engine: engine)
      drained = true
    }
    let clock = ContinuousClock()
    let bound = clock.now + .seconds(60)
    while !drained && clock.now < bound { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(drained)
    #expect(engine.logs.contains("[import] drain left 1 write running"))
    engine.releaseHistoryWrite()
    await draining.value
  }

  @Test func theAdoptDeadlineGrowsWithTheRowsAndStaysCapped() {
    #expect(ImportHistory.adoptDeadline(rows: 0) == 1.5)
    #expect(ImportHistory.adoptDeadline(rows: 50_000) > 1.5)
    #expect(ImportHistory.adoptDeadline(rows: 10_000_000) == ImportHistory.adoptDeadlineCap)
  }

  @Test func aPrivateDestinationTakesNoHistoryOrFavicons() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    let tab = ImportTabRow(url: "https://t.test/", title: "T", pinned: false, customTitle: nil)
    engine.reads["Default"] = .success(FakeImportEngine.read(tabs: [tab], history: FakeImportEngine.historyRows, favicons: FakeImportEngine.icons))
    let outcome = await runs.run(request([.history, .tabs], target: "incognito:default"), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(await settled(runs))
    #expect(engine.historyAdoptions.isEmpty)
    #expect(engine.historyWrites.isEmpty)
    #expect(engine.faviconAdoptions.isEmpty)
    #expect(engine.faviconStores.isEmpty)
    #expect(outcome.counts.history == 0)
  }

  @Test func cancellingDuringHistoryStopsBeforeTheNativeWrite() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    engine.onAdoptHistory = { runs.cancel(engine: engine, script: script) }
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    let outcome = await runs.run(request([.history, .passwords, .cookies]), session: session, engine: engine, script: script, scriptSession: 1)
    #expect(engine.steps == ["adoptHistory"])
    #expect(outcome.notes == [ImportRunner.stoppedNote])
    #expect(engine.discarded == ["vault-1"])
  }

  @Test func aDrainWaitsForPendingHistoryWrites() async {
    let (runs, engine, script, session) = setup()
    runs.darkRoute = true
    runs.writeDeadline = .milliseconds(10)
    engine.holdHistoryWrite = true
    engine.reads["Default"] = .success(FakeImportEngine.read(history: FakeImportEngine.historyRows))
    _ = await runs.run(request([.history]), session: session, engine: engine, script: script, scriptSession: 1)
    var drained = false
    let draining = Task { @MainActor in
      await runs.drain(engine: engine)
      drained = true
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(!drained)
    #expect(runs.pendingWrites == 1)
    engine.releaseHistoryWrite()
    await draining.value
    #expect(drained)
    #expect(engine.historyWrites.count == 1)
  }

  @Test func historyAndFaviconRowsNeverPrint() {
    let row = FakeImportEngine.historyRows[0]
    let icon = FakeImportEngine.icons[0]
    #expect(!"\(row) \(String(reflecting: row)) \(icon) \(String(reflecting: icon))".contains("test"))
  }

  @Test func credentialsNeverPrint() {
    let credential = ImportCredential(url: "https://a.test", username: "me", password: "hunter2", realm: nil)
    let read = FakeImportEngine.read(credentials: [credential])
    for text in [String(describing: credential), String(reflecting: credential), "\(credential)", String(describing: read), String(reflecting: read), "\(read)"] {
      #expect(!text.contains("hunter2"))
      #expect(!text.contains("me"))
    }
  }
}
