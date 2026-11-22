import Foundation
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
    written.append((token, engineProfile, kinds))
    return nativeResult
  }

  func savePassword(engineProfile: String, origin: String, username: String, password: String) async -> Bool {
    saved.append((engineProfile, origin, username))
    onSave?(saved.count)
    return true
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

  static func read(token: String? = "vault-1", name: String? = nil, failed: [ImportKind] = [], warnings: [ImportReadWarning] = [], credentials: [ImportCredential] = credentials(3)) -> ImportRead {
    ImportRead(vaultToken: token, profileName: name, profileColor: nil, failed: failed, warnings: warnings, credentials: credentials)
  }

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

  func setup(_ browsers: [ImportBrowser] = [ImportFixtures.chrome]) -> (ImportRuns, FakeImportEngine, FakeScriptPath, Int) {
    let runs = ImportRuns()
    runs.browsers = browsers
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

  @Test func credentialsNeverPrint() {
    let credential = ImportCredential(url: "https://a.test", username: "me", password: "hunter2", realm: nil)
    let read = FakeImportEngine.read(credentials: [credential])
    for text in [String(describing: credential), String(reflecting: credential), "\(credential)", String(describing: read), String(reflecting: read), "\(read)"] {
      #expect(!text.contains("hunter2"))
      #expect(!text.contains("me"))
    }
  }
}
